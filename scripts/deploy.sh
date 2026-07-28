#!/usr/bin/env bash
# ============================================================================
# deploy.sh -- 一键部署 S3 网关:准备证书/虚拟凭证 -> 构建 Go 组件 -> 拉起 compose。
# 前置: 已把 .env.example 复制为 .env 并填好;真实 S3 凭证由 creds 边车按 S3_CREDS_SOURCE 自动获取。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .env ]] || { echo "缺少 .env,请先: cp .env.example .env 并填写"; exit 1; }

# 网关证书
if [[ ! -f nginx/certs/server.crt ]]; then
  echo "[deploy] 生成自签证书..."
  ./scripts/gen_cert.sh
fi

# 虚拟 AK/SK 库(客户端接入凭证,通过只读目录 bind mount 挂入 authd)
if [[ ! -s auth/keys.json ]] || [[ "$(cat auth/keys.json)" == "{}" ]]; then
  echo "[deploy] 生成首个客户端虚拟 AK/SK..."
  ./scripts/gen_keys.sh
fi
# keys.json 通过只读目录 bind mount 挂入 authd。authd 以非 root(65534)运行，
# 宿主文件需让该 UID 可读，否则 keys=0、全拒。
chown 65534:65534 auth/keys.json 2>/dev/null || true
chmod 600 auth/keys.json

# 真实 S3 凭证由 creds 边车按 S3_CREDS_SOURCE 在【运行态】自动获取并续期,
# 通用 S3 场景使用 S3_ACCESS_KEY/S3_SECRET_KEY。
set -a; . ./.env; set +a
export S3_REGION="${S3_REGION:-}"
export S3_ENDPOINT_HOST="${S3_ENDPOINT_HOST:-}"
export S3_BUCKET_HOST="${S3_BUCKET_HOST:-}"
export S3_ACCESS_KEY="${S3_ACCESS_KEY:-}"
export S3_SECRET_KEY="${S3_SECRET_KEY:-}"
export S3_SESSION_TOKEN="${S3_SESSION_TOKEN:-}"
export S3_CREDS_SOURCE="${S3_CREDS_SOURCE:-static}"
for required in S3_REGION S3_BUCKET_HOST; do
  if [[ -z "${!required:-}" ]]; then
    echo "[deploy] $required 不能为空，请检查 .env。"
    exit 1
  fi
done
SRC="$S3_CREDS_SOURCE"
case "$SRC" in
  static)
    if [[ -z "${S3_ACCESS_KEY:-}" || -z "${S3_SECRET_KEY:-}" ]]; then
      echo "[deploy] S3_CREDS_SOURCE=static 需在 .env 填写 S3_ACCESS_KEY / S3_SECRET_KEY。"; exit 1
    fi
    echo "[deploy] 凭证源=static:使用 .env 中的静态 S3 AK/SK。" ;;
  imds)
    echo "[deploy] 凭证源=imds:由实例 IAM 角色经元数据服务取临时凭证(当前实现为 Volcengine IMDS 兼容)。" ;;
  sts)
    if [[ -z "${VOLC_ACCESS_KEY:-}" || -z "${VOLC_SECRET_KEY:-}" || -z "${VOLC_ROLE_TRN:-}" ]]; then
      echo "[deploy] S3_CREDS_SOURCE=sts 需在 .env 填写 VOLC_ACCESS_KEY / VOLC_SECRET_KEY / VOLC_ROLE_TRN。"; exit 1
    fi
    echo "[deploy] 凭证源=sts:用长期 AK/SK 换 STS 临时凭证并自动续期(当前实现为 Volcengine STS 兼容)。" ;;
  *)
    echo "[deploy] 凭证源=auto:运行态按 imds->sts->static 顺序自动取凭证。"
    echo "         (通用 S3 兼容对象存储建议 S3_CREDS_SOURCE=static，以跳过云厂商专属 IMDS/STS 探测)" ;;
esac

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  DC=(docker-compose)
else
  echo "[deploy] 未找到 docker compose 插件或 docker-compose 命令"; exit 1
fi

if [[ ! -x auth/authd-linux-amd64 || ! -x creds/creds-linux-amd64 ]]; then
  if command -v go >/dev/null 2>&1; then
    echo "[deploy] 未发现预编译运行时二进制,本机使用 go 构建 linux/amd64 二进制..."
    (cd auth && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -buildvcs=false -trimpath -ldflags="-s -w" -o authd-linux-amd64 .)
    (cd creds && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -buildvcs=false -trimpath -ldflags="-s -w" -o creds-linux-amd64 .)
  else
    echo "[deploy] 缺少 auth/authd-linux-amd64 或 creds/creds-linux-amd64,且本机未安装 go。请使用 scripts/package.sh 生成的交付包。"
    exit 1
  fi
fi

if [[ ! -f creds/ca-certificates.crt ]]; then
  for p in /etc/ssl/cert.pem /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
    if [[ -r "$p" ]]; then cp "$p" creds/ca-certificates.crt; break; fi
  done
fi
[[ -f creds/ca-certificates.crt ]] || { echo "[deploy] 缺少 creds/ca-certificates.crt"; exit 1; }

SIGV4_PROXY_ARCHIVE="images/s3gw-sigv4-proxy-s3-compat-v2-linux-amd64.tar.gz"
if [[ -f "$SIGV4_PROXY_ARCHIVE" ]]; then
  echo "[deploy] 加载 S3 兼容修复版 sigv4-proxy 镜像..."
  gzip -dc "$SIGV4_PROXY_ARCHIVE" | docker load >/dev/null
fi
if ! docker image inspect s3gw-sigv4-proxy:s3-compat-v2 >/dev/null 2>&1; then
  echo "[deploy] 缺少 s3gw-sigv4-proxy:s3-compat-v2 镜像及其归档: $SIGV4_PROXY_ARCHIVE"
  exit 1
fi

echo "[deploy] 构建 authd/creds(Go 静态二进制 -> scratch 镜像)..."
"${DC[@]}" build authd creds

# nginx 改用 nginx-unprivileged(UID 101 非 root)。命名卷 nginx-logs 首次挂载时
# Docker 会用镜像里的目录内容(root:root)填充【空】卷,把预先 chown 冲掉,导致非 root
# nginx 无法写 s3audit.log 首启即 crash。对策:先把卷【播种】成非空且属主 101——
# 卷非空时 Docker 不再从镜像拷贝,101 属主得以保留。
COMPOSE_PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}"
NGINX_LOG_VOL="${COMPOSE_PROJECT}_nginx-logs"
docker volume create \
  --label "com.docker.compose.project=$COMPOSE_PROJECT" \
  --label "com.docker.compose.volume=nginx-logs" \
  "$NGINX_LOG_VOL" >/dev/null 2>&1 || true
docker run --rm -u 0 -v "$NGINX_LOG_VOL":/var/log/nginx alpine:3.20 \
  sh -c 'touch /var/log/nginx/s3audit.log && chown -R 101:101 /var/log/nginx' >/dev/null 2>&1 || \
  echo "[deploy] 警告: 无法初始化 nginx-logs 卷属主为 101:101,nginx(非root)可能无法写审计日志。"

echo "[deploy] 拉起服务(缺失的外部镜像会自动拉取)..."
# authd/creds may receive new container IPs when their images are rebuilt.
# Nginx resolves Compose service names at startup, so keeping an old Nginx
# container can leave it pointing at stale backend IPs after a repeat deploy.
"${DC[@]}" up -d --force-recreate

echo "[deploy] 当前状态:"
"${DC[@]}" ps
echo "[deploy] 完成。健康检查: curl -k https://127.0.0.1:${GW_LISTEN_PORT:-8443}/healthz"

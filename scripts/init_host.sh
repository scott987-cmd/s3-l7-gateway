#!/usr/bin/env bash
# ============================================================================
# init_host.sh -- 远端初始化:在 CentOS/RHEL(el9) 上安装 Docker Engine +
# compose 插件并启用。幂等,可重复执行。需 root。
# 官方源不可达时自动回退国内镜像(火山/阿里/清华)。
# 用法(远端): bash init_host.sh
# ============================================================================
set -euo pipefail
log(){ echo "[init] $*"; }

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  log "docker + compose 已就绪:$(docker --version)"
  systemctl enable --now docker >/dev/null 2>&1 || true
  if ! command -v aws >/dev/null 2>&1; then
    log "安装 aws-cli(用于一键验收/压测) ..."
    if ! dnf -y install awscli; then
      log "dnf 安装 awscli 失败,尝试官方 zip 安装器 ..."
      tmpdir="$(mktemp -d)"
      trap 'rm -rf "$tmpdir"' EXIT
      dnf -y install unzip >/dev/null || true
      curl -fsSL -o "$tmpdir/awscliv2.zip" "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
      unzip -q "$tmpdir/awscliv2.zip" -d "$tmpdir"
      "$tmpdir/aws/install" --update
    fi
  fi
  aws --version || true
  exit 0
fi

log "安装基础依赖 dnf-plugins-core / jq / openssl / curl ..."
dnf -y install dnf-plugins-core jq openssl curl tar gzip >/dev/null

REPO_DST="/etc/yum.repos.d/docker-ce.repo"
# 候选仓库(优先火山内网镜像,再阿里,再清华,最后官方)
REPOS=(
  "https://mirrors.ivolces.com/docker/linux/centos/docker-ce.repo"
  "https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo"
  "https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/centos/docker-ce.repo"
  "https://download.docker.com/linux/centos/docker-ce.repo"
)

install_ok=0
for url in "${REPOS[@]}"; do
  log "尝试仓库: $url"
  if ! curl -fsSL -m 20 -o "$REPO_DST" "$url"; then
    log "  下载仓库文件失败,换下一个镜像"; continue
  fi
  # 把官方 download.docker.com 的 baseurl 替换为当前镜像域(仅当来源为镜像时)
  case "$url" in
    *mirrors.ivolces.com*) sed -i 's#https://download.docker.com/#https://mirrors.ivolces.com/docker/#g' "$REPO_DST" || true ;;
    *mirrors.aliyun.com*)  sed -i 's#https://download.docker.com/#https://mirrors.aliyun.com/docker-ce/#g' "$REPO_DST" || true ;;
    *tuna*)                sed -i 's#https://download.docker.com/#https://mirrors.tuna.tsinghua.edu.cn/docker-ce/#g' "$REPO_DST" || true ;;
  esac
  dnf clean all >/dev/null 2>&1 || true
  log "  安装 docker-ce / cli / containerd / compose 插件 / buildx ..."
  if dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
    install_ok=1; break
  fi
  log "  该镜像安装失败,换下一个"
done

if [[ "$install_ok" != "1" ]]; then
  log "所有镜像均安装失败,请检查网络/DNS。"; exit 1
fi

log "启用并启动 docker ..."
systemctl enable --now docker

if ! command -v aws >/dev/null 2>&1; then
  log "安装 aws-cli(用于一键验收/压测) ..."
  if ! dnf -y install awscli; then
    log "dnf 安装 awscli 失败,尝试官方 zip 安装器 ..."
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT
    dnf -y install unzip >/dev/null || true
    curl -fsSL -o "$tmpdir/awscliv2.zip" "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
    unzip -q "$tmpdir/awscliv2.zip" -d "$tmpdir"
    "$tmpdir/aws/install" --update
  fi
fi

# 配置国内 registry 镜像加速(拉取 nginx/sigv4-proxy 基础镜像用)
REG_DST="/etc/docker/daemon.json"
mkdir -p "$(dirname "$REG_DST")"
if [[ ! -f "$REG_DST" ]]; then
  cat > "$REG_DST" <<'JSON'
{
  "registry-mirrors": ["https://docker.mirrors.ustc.edu.cn", "https://docker.m.daocloud.io", "https://mirror.ccs.tencentyun.com"]
}
JSON
  systemctl restart docker || true
fi

log "校验:"
docker --version
docker compose version
aws --version || true
log "完成。"

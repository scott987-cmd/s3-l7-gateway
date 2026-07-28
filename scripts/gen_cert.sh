#!/usr/bin/env bash
# ============================================================================
# gen_cert.sh —— 为网关生成自签 TLS 证书(内部域名/IP)。
# 生产环境请替换为内部 CA 签发的证书。
# 用法: ./scripts/gen_cert.sh [CN]   默认 CN=s3gw.internal
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

CN="${1:-s3gw.internal}"
CERT_DIR="nginx/certs"
mkdir -p "$CERT_DIR"

if [[ -f "$CERT_DIR/server.crt" && -f "$CERT_DIR/server.key" ]]; then
  echo "[gen_cert] 证书已存在,跳过。如需重建请先删除 $CERT_DIR/server.*"
  exit 0
fi

openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "$CERT_DIR/server.key" \
  -out    "$CERT_DIR/server.crt" \
  -days 825 \
  -subj "/CN=${CN}" \
  -addext "subjectAltName=DNS:${CN},DNS:localhost,IP:127.0.0.1" 2>/dev/null

# nginx-unprivileged 镜像以 UID 101 运行；证书目录只读 bind mount 后，
# UID 101 需能读取私钥，否则 nginx 加载 TLS 配置即启动失败。
# 优先把属主改为 101:101 并设 0640(最小可读)；无权限时回退 0644 并告警。
chmod 640 "$CERT_DIR/server.key"
if chown 101:101 "$CERT_DIR/server.key" "$CERT_DIR/server.crt" 2>/dev/null; then
  echo "[gen_cert] 私钥属主已设为 101:101 (nginx-unprivileged 可读), 权限 0640"
else
  chmod 644 "$CERT_DIR/server.key"
  echo "[gen_cert] 警告: 无法 chown 到 101(需 root)。已回退私钥为 0644 以便容器 UID 101 读取。"
  echo "           这是自签【测试】证书；生产请换内部 CA 证书并设 owner=101:101 mode=0640。"
fi
echo "[gen_cert] 已生成自签证书: $CERT_DIR/server.crt (CN=${CN})"

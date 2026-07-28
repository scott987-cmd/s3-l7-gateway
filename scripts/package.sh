#!/usr/bin/env bash
# ============================================================================
# package.sh -- 生成干净交付包，不包含 .git/.env/证书/密钥/日志/临时文件。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

version="${VERSION:-$(date +%Y%m%d-%H%M%S)}"
out_dir="${OUT_DIR:-deliver}"
pkg_name="s3gw-${version}.tgz"
mkdir -p "$out_dir"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/s3gw"
rsync -a \
  --exclude '.git' \
  --exclude '.env' \
  --exclude 'auth/keys.json' \
  --exclude 'auth/keys_audit.log' \
  --exclude 'nginx/certs' \
  --exclude 'support' \
  --exclude 'deliver' \
  --exclude '*.log' \
  --exclude '*.bak' \
  --exclude '.bak-*' \
  ./ "$tmp/s3gw/"
mkdir -p "$tmp/s3gw/auth" "$tmp/s3gw/nginx/certs"
printf '{}\n' > "$tmp/s3gw/auth/keys.json"

echo "[package] build linux/amd64 static binaries..."
mkdir -p "$tmp/gocache"
(cd auth && GOCACHE="$tmp/gocache" CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -buildvcs=false -trimpath -ldflags="-s -w" -o "$tmp/s3gw/auth/authd-linux-amd64" .)
(cd creds && GOCACHE="$tmp/gocache" CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -buildvcs=false -trimpath -ldflags="-s -w" -o "$tmp/s3gw/creds/creds-linux-amd64" .)

ca_src=""
for p in /etc/ssl/cert.pem /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
  if [[ -r "$p" ]]; then ca_src="$p"; break; fi
done
if [[ -z "$ca_src" ]]; then
  echo "[package] cannot find local CA bundle" >&2
  exit 1
fi
cp "$ca_src" "$tmp/s3gw/creds/ca-certificates.crt"

if [[ "$(uname -s)" == "Darwin" ]]; then
  COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -C "$tmp" -czf "$out_dir/$pkg_name" s3gw
else
  tar -C "$tmp" -czf "$out_dir/$pkg_name" s3gw
fi
echo "$out_dir/$pkg_name"

#!/usr/bin/env bash
# ============================================================================
# configure.sh -- 参数化生成/更新 .env，避免客户手工编辑配置文件。
# 用法:
#   ./scripts/configure.sh S3_REGION=... S3_ENDPOINT_HOST=... S3_BUCKET_HOST=... \
#     S3_ACCESS_KEY=... S3_SECRET_KEY=... TEST_BUCKET=... GW_BIND_ADDR=0.0.0.0 GW_LISTEN_PORT=443
#
# 敏感值也可通过环境变量传入，命令行只传非敏感参数。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'USAGE'
usage: ./scripts/configure.sh [KEY=VALUE ...]

Common keys:
  S3_REGION                  SigV4 region, for example cn-beijing/us-east-1
  S3_ENDPOINT_HOST           Upstream S3 endpoint host, without scheme
  S3_BUCKET_HOST             Upstream bucket virtual-hosted host, without scheme
  S3_CREDS_SOURCE            static|auto|imds|sts, default static
  S3_ACCESS_KEY              Real upstream S3 access key
  S3_SECRET_KEY              Real upstream S3 secret key
  S3_SESSION_TOKEN           Optional real upstream S3 session token
  TEST_BUCKET                Bucket used by smoke/speed tests
  GW_BIND_ADDR               Default 127.0.0.1; use 0.0.0.0 behind CLB
  GW_LISTEN_PORT             Default 8443; use 443 behind CLB
  GW_SERVER_NAMES            Space-separated gateway domains accepted by Nginx
  HEALTH_ALLOW_DIRECTIVES    Nginx allow/deny directives for /healthz
  SIGV4_PROXY_MEM_LIMIT      Compose memory limit for sigv4-proxy, default 4g
  TEST_KEY                   Smoke-test object key
  TEST_REQUIRE_DELETE        1 to require DeleteObject permission

Volcengine optional keys for S3_CREDS_SOURCE=imds/sts:
  VOLC_IMDS_ROLE VOLC_IMDS_HOST
  VOLC_ACCESS_KEY VOLC_SECRET_KEY VOLC_ROLE_TRN VOLC_ROLE_SESSION_NAME
  VOLC_STS_DURATION VOLC_STS_HOST VOLC_STS_REGION
USAGE
}

quote_env() {
  local v="$1"
  # .env is consumed by both shell and compose. Single quotes keep special chars literal.
  printf "'%s'" "${v//\'/\'\\\'\'}"
}

write_kv() {
  local key="$1" value="$2"
  printf '%s=%s\n' "$key" "$(quote_env "$value")"
}

args=()
for kv in "$@"; do
  case "$kv" in
    -h|--help|help)
      usage
      exit 0
      ;;
    *=*)
      key="${kv%%=*}"
      value="${kv#*=}"
      [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "[configure] bad key: $key"; exit 2; }
      args+=("$key=$value")
      ;;
    *)
      echo "[configure] bad argument: $kv"
      usage
      exit 2
      ;;
  esac
done

getv() {
  local key="$1" def="${2:-}" v=""
  local kv k
  for kv in "${args[@]}"; do
    k="${kv%%=*}"
    if [[ "$k" == "$key" ]]; then
      v="${kv#*=}"
      printf '%s' "$v"
      return
    fi
  done
  if [[ -n "$(eval "printf '%s' \"\${${key}-}\"")" ]]; then
    v="$(eval "printf '%s' \"\${${key}-}\"")"
  else
    v="$def"
  fi
  printf '%s' "$v"
}

S3_REGION_V="$(getv S3_REGION)"
S3_ENDPOINT_HOST_V="$(getv S3_ENDPOINT_HOST)"
S3_BUCKET_HOST_V="$(getv S3_BUCKET_HOST)"
S3_CREDS_SOURCE_V="$(getv S3_CREDS_SOURCE static)"
S3_ACCESS_KEY_V="$(getv S3_ACCESS_KEY)"
S3_SECRET_KEY_V="$(getv S3_SECRET_KEY)"
S3_SESSION_TOKEN_V="$(getv S3_SESSION_TOKEN)"
TEST_BUCKET_V="$(getv TEST_BUCKET)"
GW_BIND_ADDR_V="$(getv GW_BIND_ADDR 127.0.0.1)"
GW_LISTEN_PORT_V="$(getv GW_LISTEN_PORT 8443)"
TEST_KEY_V="$(getv TEST_KEY s3gw-smoke-test.txt)"
TEST_REQUIRE_DELETE_V="$(getv TEST_REQUIRE_DELETE 0)"
GW_SERVER_NAMES_V="$(getv GW_SERVER_NAMES)"
HEALTH_ALLOW_DIRECTIVES_V="$(getv HEALTH_ALLOW_DIRECTIVES 'allow 127.0.0.1; allow 10.0.0.0/8; allow 100.64.0.0/10; allow 172.16.0.0/12; allow 192.168.0.0/16; deny all;')"
SIGV4_PROXY_MEM_LIMIT_V="$(getv SIGV4_PROXY_MEM_LIMIT 4g)"
AUTHD_MAX_SKEW_V="$(getv AUTHD_MAX_SKEW 300)"
AUTHD_REPLAY_CACHE_V="$(getv AUTHD_REPLAY_CACHE 0)"
AUTHD_REPLAY_WRITES_V="$(getv AUTHD_REPLAY_WRITES 1)"

if [[ -z "$S3_BUCKET_HOST_V" && -n "$TEST_BUCKET_V" && -n "$S3_ENDPOINT_HOST_V" ]]; then
  # 常见误用:把"<bucket>.<endpoint>"这种已带 bucket 的地址填进 S3_ENDPOINT_HOST。
  # 直接拼接会得到 <bucket>.<bucket>.<endpoint>,而对象存储的通配证书通常只覆盖
  # 一级(*.oss-cn-beijing-internal.aliyuncs.com),上游 TLS 校验必然失败 → 502。
  # 这里识别出来并自动拆开,而不是拼成一个必坏的名字。
  if [[ "$S3_ENDPOINT_HOST_V" == "${TEST_BUCKET_V}."* ]]; then
    echo "[configure] 注意: S3_ENDPOINT_HOST 已以 '${TEST_BUCKET_V}.' 开头，按虚拟主机式 bucket host 处理" >&2
    S3_BUCKET_HOST_V="$S3_ENDPOINT_HOST_V"
    S3_ENDPOINT_HOST_V="${S3_ENDPOINT_HOST_V#"${TEST_BUCKET_V}."}"
    echo "[configure]   S3_BUCKET_HOST=$S3_BUCKET_HOST_V" >&2
    echo "[configure]   S3_ENDPOINT_HOST=$S3_ENDPOINT_HOST_V" >&2
  else
    S3_BUCKET_HOST_V="${TEST_BUCKET_V}.${S3_ENDPOINT_HOST_V}"
  fi
fi

missing=()
for pair in \
  "S3_REGION:$S3_REGION_V" \
  "S3_ENDPOINT_HOST:$S3_ENDPOINT_HOST_V" \
  "S3_BUCKET_HOST:$S3_BUCKET_HOST_V" \
  "TEST_BUCKET:$TEST_BUCKET_V"
do
  key="${pair%%:*}"
  value="${pair#*:}"
  [[ -n "$value" ]] || missing+=("$key")
done

if [[ "$S3_CREDS_SOURCE_V" == "static" ]]; then
  [[ -n "$S3_ACCESS_KEY_V" ]] || missing+=("S3_ACCESS_KEY")
  [[ -n "$S3_SECRET_KEY_V" ]] || missing+=("S3_SECRET_KEY")
fi

if [[ "${#missing[@]}" -gt 0 ]]; then
  echo "[configure] missing required keys: ${missing[*]}"
  usage
  exit 2
fi

umask 077
tmp=".env.tmp"
{
  echo "# generated by scripts/configure.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_kv S3_REGION "$S3_REGION_V"
  write_kv S3_ENDPOINT_HOST "$S3_ENDPOINT_HOST_V"
  write_kv S3_BUCKET_HOST "$S3_BUCKET_HOST_V"
  write_kv S3_CREDS_SOURCE "$S3_CREDS_SOURCE_V"
  write_kv S3_ACCESS_KEY "$S3_ACCESS_KEY_V"
  write_kv S3_SECRET_KEY "$S3_SECRET_KEY_V"
  write_kv S3_SESSION_TOKEN "$S3_SESSION_TOKEN_V"
  write_kv S3_STATIC_RENEW "$(getv S3_STATIC_RENEW 43200)"
  write_kv VOLC_IMDS_ROLE "$(getv VOLC_IMDS_ROLE)"
  write_kv VOLC_IMDS_HOST "$(getv VOLC_IMDS_HOST 100.96.0.96)"
  write_kv VOLC_ACCESS_KEY "$(getv VOLC_ACCESS_KEY)"
  write_kv VOLC_SECRET_KEY "$(getv VOLC_SECRET_KEY)"
  write_kv VOLC_ROLE_TRN "$(getv VOLC_ROLE_TRN)"
  write_kv VOLC_ROLE_SESSION_NAME "$(getv VOLC_ROLE_SESSION_NAME s3gw)"
  write_kv VOLC_STS_DURATION "$(getv VOLC_STS_DURATION 3600)"
  write_kv VOLC_STS_HOST "$(getv VOLC_STS_HOST sts.volcengineapi.com)"
  write_kv VOLC_STS_REGION "$(getv VOLC_STS_REGION cn-north-1)"
  write_kv AUTHD_MAX_SKEW "$AUTHD_MAX_SKEW_V"
  write_kv AUTHD_REPLAY_CACHE "$AUTHD_REPLAY_CACHE_V"
  write_kv AUTHD_REPLAY_WRITES "$AUTHD_REPLAY_WRITES_V"
  write_kv GW_SERVER_NAMES "$GW_SERVER_NAMES_V"
  write_kv HEALTH_ALLOW_DIRECTIVES "$HEALTH_ALLOW_DIRECTIVES_V"
  write_kv SIGV4_PROXY_MEM_LIMIT "$SIGV4_PROXY_MEM_LIMIT_V"
  write_kv GW_BIND_ADDR "$GW_BIND_ADDR_V"
  write_kv GW_LISTEN_PORT "$GW_LISTEN_PORT_V"
  write_kv TEST_BUCKET "$TEST_BUCKET_V"
  write_kv TEST_KEY "$TEST_KEY_V"
  write_kv TEST_REQUIRE_DELETE "$TEST_REQUIRE_DELETE_V"
} > "$tmp"
mv "$tmp" .env
chmod 600 .env

mkdir -p auth
if [[ ! -s auth/keys.json ]] || [[ "$(cat auth/keys.json 2>/dev/null || true)" == "{}" ]]; then
  ./scripts/gen_keys.sh >/tmp/s3gw-configure-key.out
  ak="$(awk -F= '/AWS_ACCESS_KEY_ID/{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}' /tmp/s3gw-configure-key.out)"
  sk="$(awk -F= '/AWS_SECRET_ACCESS_KEY/{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}' /tmp/s3gw-configure-key.out)"
  {
    write_kv TEST_VIRT_AK "$ak"
    write_kv TEST_VIRT_SK "$sk"
  } >> .env
  rm -f /tmp/s3gw-configure-key.out
else
  virt_ak="$(getv TEST_VIRT_AK)"
  virt_sk="$(getv TEST_VIRT_SK)"
  if [[ -z "$virt_ak" || -z "$virt_sk" ]]; then
    if command -v jq >/dev/null 2>&1 && jq -e 'length > 0' auth/keys.json >/dev/null 2>&1; then
      virt_ak="$(jq -r 'to_entries[0].key' auth/keys.json)"
      virt_sk="$(jq -r 'to_entries[0].value | if type == "string" then . else .secret end' auth/keys.json)"
    fi
  fi
  if [[ -n "$virt_ak" ]]; then write_kv TEST_VIRT_AK "$virt_ak" >> .env; fi
  if [[ -n "$virt_sk" ]]; then write_kv TEST_VIRT_SK "$virt_sk" >> .env; fi
fi

chmod 600 .env auth/keys.json 2>/dev/null || true
chown 65534:65534 auth/keys.json 2>/dev/null || true

echo "[configure] wrote .env"
echo "[configure] S3_ENDPOINT_HOST=$S3_ENDPOINT_HOST_V"
echo "[configure] S3_BUCKET_HOST=$S3_BUCKET_HOST_V"
echo "[configure] S3_REGION=$S3_REGION_V"
echo "[configure] TEST_BUCKET=$TEST_BUCKET_V"
echo "[configure] GW_BIND_ADDR=$GW_BIND_ADDR_V"
echo "[configure] GW_LISTEN_PORT=$GW_LISTEN_PORT_V"
echo "[configure] S3_CREDS_SOURCE=$S3_CREDS_SOURCE_V"
if grep -q '^TEST_VIRT_AK=' .env; then echo "[configure] virtual client key is configured"; fi

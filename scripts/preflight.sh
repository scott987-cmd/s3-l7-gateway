#!/usr/bin/env bash
# ============================================================================
# preflight.sh -- 部署前自检：配置、依赖、端口、上游 S3 endpoint 解析、compose 语法。
# 不打印任何 AK/SK 明文。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0; WARN=0; FAIL=0
pass(){ echo "  [PASS] $*"; PASS=$((PASS+1)); }
warn(){ echo "  [WARN] $*"; WARN=$((WARN+1)); }
fail(){ echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
title(){ echo ""; echo "== $* =="; }

[[ -f .env ]] || { echo "[FATAL] missing .env; copy .env.example to .env and fill it"; exit 2; }
set -a; . ./.env; set +a
S3_REGION="${S3_REGION:-}"
S3_ENDPOINT_HOST="${S3_ENDPOINT_HOST:-}"
S3_BUCKET_HOST="${S3_BUCKET_HOST:-}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-}"
S3_SECRET_KEY="${S3_SECRET_KEY:-}"
S3_SESSION_TOKEN="${S3_SESSION_TOKEN:-}"
S3_CREDS_SOURCE="${S3_CREDS_SOURCE:-static}"
export S3_REGION S3_ENDPOINT_HOST S3_BUCKET_HOST S3_ACCESS_KEY S3_SECRET_KEY S3_SESSION_TOKEN S3_CREDS_SOURCE

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    return 1
  fi
}

require_env() {
  local key="$1" value
  value="$(eval "printf '%s' \"\${${key}-}\"")"
  if [[ -n "$value" ]]; then pass "$key is set"; else fail "$key is empty"; fi
}

title "config"
for k in S3_REGION S3_ENDPOINT_HOST S3_BUCKET_HOST TEST_BUCKET GW_LISTEN_PORT; do require_env "$k"; done
case "$S3_CREDS_SOURCE" in
  static)
    require_env S3_ACCESS_KEY
    require_env S3_SECRET_KEY
    ;;
  sts)
    require_env VOLC_ACCESS_KEY
    require_env VOLC_SECRET_KEY
    require_env VOLC_ROLE_TRN
    ;;
  imds|auto)
    pass "S3_CREDS_SOURCE=$S3_CREDS_SOURCE"
    ;;
  *)
    fail "unsupported S3_CREDS_SOURCE=$S3_CREDS_SOURCE"
    ;;
esac

if [[ -s auth/keys.json ]] && jq empty auth/keys.json >/dev/null 2>&1; then
  key_count="$(jq 'length' auth/keys.json)"
  if [[ "$key_count" -gt 0 ]]; then pass "auth/keys.json has $key_count virtual key(s)"; else warn "auth/keys.json is empty; deploy.sh will generate one"; fi
else
  warn "auth/keys.json missing or invalid; deploy.sh will generate one if empty"
fi

title "dependencies"
for bin in docker curl openssl jq; do
  command -v "$bin" >/dev/null 2>&1 && pass "$bin found" || fail "$bin not found"
done
if dc="$(compose_cmd)"; then pass "$dc found"; else fail "docker compose or docker-compose not found"; fi
command -v aws >/dev/null 2>&1 && pass "aws-cli found" || warn "aws-cli not found; deploy can run, smoke/speed tests need it"

title "docker"
if docker info >/dev/null 2>&1; then pass "docker daemon reachable"; else fail "docker daemon unreachable"; fi
if [[ -n "${dc:-}" ]] && $dc config --services >/dev/null; then pass "compose config parses"; else fail "compose config failed"; fi

title "network"
if getent hosts "$S3_ENDPOINT_HOST" >/tmp/s3gw_preflight_hosts 2>/dev/null; then
  pass "S3_ENDPOINT_HOST resolves: $S3_ENDPOINT_HOST"
  first_ip="$(awk 'NR==1{print $1}' /tmp/s3gw_preflight_hosts)"
  case "$first_ip" in
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|100.64.*|100.6[5-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*)
      pass "S3 endpoint appears private/internal: $first_ip"
      ;;
    *)
      warn "S3 endpoint resolved to non-private-looking IP: $first_ip"
      ;;
  esac
else
  fail "cannot resolve S3_ENDPOINT_HOST=$S3_ENDPOINT_HOST"
fi

if timeout 5 bash -c "</dev/tcp/${S3_ENDPOINT_HOST}/443" 2>/dev/null; then
  pass "S3 endpoint TCP 443 reachable"
else
  fail "S3 endpoint TCP 443 unreachable"
fi

title "ports"
bind="${GW_BIND_ADDR:-127.0.0.1}"
port="${GW_LISTEN_PORT:-8443}"
if ss -tlnp 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"; then
  if [[ "${ALLOW_PORT_IN_USE:-0}" == "1" ]]; then warn "port $port is already listening; ALLOW_PORT_IN_USE=1"; else fail "port $port is already listening"; fi
else
  pass "port $port is free"
fi
pass "configured listen ${bind}:${port}"

echo ""
echo "== summary =="
echo "  PASS=$PASS WARN=$WARN FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1

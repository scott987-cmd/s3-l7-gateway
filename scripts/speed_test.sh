#!/usr/bin/env bash
# ============================================================================
# speed_test.sh -- S3 网关吞吐压测：标准 aws-cli + 虚拟 AK/SK，经网关 PUT/GET
# 并校验 MD5。默认不强制 DELETE，因为生产桶凭证可能仅授予 Get/Put。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

set -a; [[ -f .env ]] && . ./.env; set +a

GW_PORT="${GW_LISTEN_PORT:-8443}"
ENDPOINT="https://127.0.0.1:${GW_PORT}"
BUCKET="${TEST_BUCKET:?请在 .env 设置 TEST_BUCKET}"
REGION="${S3_REGION:-cn-beijing}"
VIRT_AK="${TEST_VIRT_AK:?请在 .env 设置 TEST_VIRT_AK}"
VIRT_SK="${TEST_VIRT_SK:?请在 .env 设置 TEST_VIRT_SK}"
SIZE_MB="${SIZE_MB:-16}"
KEY="${TEST_SPEED_KEY:-s3gw-speed-$(date +%s).bin}"

command -v aws >/dev/null 2>&1 || { echo "[FATAL] 未找到 aws-cli"; exit 1; }

export AWS_ACCESS_KEY_ID="$VIRT_AK"
export AWS_SECRET_ACCESS_KEY="$VIRT_SK"
export AWS_DEFAULT_REGION="$REGION"
export AWS_S3_ADDRESSING_STYLE=path
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
unset AWS_SESSION_TOKEN

AWS=(aws --endpoint-url "$ENDPOINT" --no-verify-ssl)
TMPDIR_LOCAL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT
UP="$TMPDIR_LOCAL/up.bin"
DOWN="$TMPDIR_LOCAL/down.bin"

md5of() {
  if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | awk '{print $1}'; else md5 -q "$1"; fi
}
human_bps() {
  awk -v b="$1" 'BEGIN { printf "%.2f MB/s", b/1048576 }'
}

echo "==> generating ${SIZE_MB}MB payload"
dd if=/dev/urandom of="$UP" bs=1048576 count="$SIZE_MB" status=none
MD5_UP="$(md5of "$UP")"

echo "==> PUT ${SIZE_MB}MB via gateway ${ENDPOINT}"
start="$(date +%s)"
"${AWS[@]}" s3api put-object --bucket "$BUCKET" --key "$KEY" --body "$UP" >/dev/null
end="$(date +%s)"
put_sec=$((end - start)); [[ "$put_sec" -le 0 ]] && put_sec=1
put_bps=$((SIZE_MB * 1048576 / put_sec))
echo "  [PASS] put-object ${put_sec}s $(human_bps "$put_bps")"

echo "==> GET ${SIZE_MB}MB via gateway ${ENDPOINT}"
start="$(date +%s)"
"${AWS[@]}" s3api get-object --bucket "$BUCKET" --key "$KEY" "$DOWN" >/dev/null
end="$(date +%s)"
get_sec=$((end - start)); [[ "$get_sec" -le 0 ]] && get_sec=1
get_bps=$((SIZE_MB * 1048576 / get_sec))
echo "  [PASS] get-object ${get_sec}s $(human_bps "$get_bps")"

MD5_DOWN="$(md5of "$DOWN")"
if [[ "$MD5_UP" == "$MD5_DOWN" ]]; then
  echo "  [PASS] md5 match $MD5_UP"
else
  echo "  [FAIL] md5 mismatch up=$MD5_UP down=$MD5_DOWN"
  exit 1
fi

DEL_OUT="$("${AWS[@]}" s3api delete-object --bucket "$BUCKET" --key "$KEY" 2>&1 || true)"
if [[ -z "$DEL_OUT" ]]; then
  echo "  [PASS] cleanup delete-object"
elif echo "$DEL_OUT" | grep -Eq 'AccessDenied|Access Denied|403|Forbidden'; then
  echo "  [WARN] cleanup skipped: real S3 credentials do not allow DeleteObject"
else
  echo "  [WARN] cleanup failed: $(echo "$DEL_OUT" | head -1)"
fi

echo "==> SUMMARY PUT=$(human_bps "$put_bps") GET=$(human_bps "$get_bps") SIZE_MB=$SIZE_MB KEY=$KEY"

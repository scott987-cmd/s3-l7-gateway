#!/usr/bin/env bash
# Public-endpoint functional coverage. This is intentionally serial and is not
# a performance test. Credentials stay on the deployed host in .env.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

set -a
[[ -f .env ]] && . ./.env
set +a

: "${GW_ENDPOINT:?Set GW_ENDPOINT, for example https://203.0.113.10:8443}"
: "${TEST_BUCKET:?TEST_BUCKET is not set}"
: "${TEST_VIRT_AK:?TEST_VIRT_AK is not set}"
: "${TEST_VIRT_SK:?TEST_VIRT_SK is not set}"

export AWS_ACCESS_KEY_ID="$TEST_VIRT_AK"
export AWS_SECRET_ACCESS_KEY="$TEST_VIRT_SK"
export AWS_DEFAULT_REGION="${S3_REGION:-cn-beijing}"
export AWS_S3_ADDRESSING_STYLE=path
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
unset AWS_SESSION_TOKEN

AWS=(aws --endpoint-url "$GW_ENDPOINT" --no-verify-ssl)
S3API=("${AWS[@]}" s3api)
PREFIX="s3gw-public-functional/run-$(date +%s)-$$"
EMPTY_KEY="${PREFIX}/empty.bin"
SPECIAL_KEY="${PREFIX}/deep/中文 空格/%25-object.txt"
META_KEY="${PREFIX}/metadata.txt"
COPY_KEY="${PREFIX}/copied.txt"
MULTIPART_KEY="${PREFIX}/multipart-10m.bin"
TMPDIR_TEST="$(mktemp -d /tmp/s3gw-public-functional.XXXXXX)"

cleanup() {
  local key
  for key in "$EMPTY_KEY" "$SPECIAL_KEY" "$META_KEY" "$COPY_KEY" "$MULTIPART_KEY"; do
    "${S3API[@]}" delete-object --bucket "$TEST_BUCKET" --key "$key" >/dev/null 2>&1 || true
  done
  rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

pass() { printf '  [PASS] %s\n' "$1"; }

"${S3API[@]}" head-bucket --bucket "$TEST_BUCKET" >/dev/null
pass "HeadBucket"

"${S3API[@]}" list-objects-v2 --bucket "$TEST_BUCKET" --max-keys 1 >/dev/null
pass "ListObjectsV2"

: >"$TMPDIR_TEST/empty.bin"
"${S3API[@]}" put-object --bucket "$TEST_BUCKET" --key "$EMPTY_KEY" \
  --body "$TMPDIR_TEST/empty.bin" --content-length 0 >/dev/null
size="$("${S3API[@]}" head-object --bucket "$TEST_BUCKET" --key "$EMPTY_KEY" \
  --query ContentLength --output text)"
[[ "$size" == "0" ]]
pass "zero-byte PUT + HEAD"

printf '公网功能测试：中文、空格与%%25\n' >"$TMPDIR_TEST/special.txt"
"${S3API[@]}" put-object --bucket "$TEST_BUCKET" --key "$SPECIAL_KEY" \
  --body "$TMPDIR_TEST/special.txt" >/dev/null
"${S3API[@]}" get-object --bucket "$TEST_BUCKET" --key "$SPECIAL_KEY" \
  "$TMPDIR_TEST/special.out" >/dev/null
cmp "$TMPDIR_TEST/special.txt" "$TMPDIR_TEST/special.out"
pass "Unicode/space/percent key round trip"

printf '0123456789abcdefghijklmnopqrstuvwxyz\n' >"$TMPDIR_TEST/metadata.txt"
"${S3API[@]}" put-object --bucket "$TEST_BUCKET" --key "$META_KEY" \
  --body "$TMPDIR_TEST/metadata.txt" --content-type text/plain \
  --metadata suite=public-functional >/dev/null
content_type="$("${S3API[@]}" head-object --bucket "$TEST_BUCKET" --key "$META_KEY" \
  --query ContentType --output text)"
metadata_value="$("${S3API[@]}" head-object --bucket "$TEST_BUCKET" --key "$META_KEY" \
  --query 'Metadata.Suite' --output text)"
[[ "$content_type" == "text/plain" && "$metadata_value" == "public-functional" ]]
pass "metadata + content type"

"${S3API[@]}" get-object --bucket "$TEST_BUCKET" --key "$META_KEY" \
  --range bytes=5-14 "$TMPDIR_TEST/range.out" >/dev/null
[[ "$(cat "$TMPDIR_TEST/range.out")" == "56789abcde" ]]
pass "Range GET"

"${S3API[@]}" copy-object --bucket "$TEST_BUCKET" --key "$COPY_KEY" \
  --copy-source "${TEST_BUCKET}/${META_KEY}" >/dev/null
"${S3API[@]}" get-object --bucket "$TEST_BUCKET" --key "$COPY_KEY" \
  "$TMPDIR_TEST/copy.out" >/dev/null
cmp "$TMPDIR_TEST/metadata.txt" "$TMPDIR_TEST/copy.out"
pass "server-side CopyObject"

dd if=/dev/urandom of="$TMPDIR_TEST/multipart.bin" bs=1M count=10 status=none
"${AWS[@]}" s3 cp "$TMPDIR_TEST/multipart.bin" \
  "s3://${TEST_BUCKET}/${MULTIPART_KEY}" --only-show-errors
etag="$("${S3API[@]}" head-object --bucket "$TEST_BUCKET" --key "$MULTIPART_KEY" \
  --query ETag --output text)"
[[ "$etag" == *-* ]]
"${AWS[@]}" s3 cp "s3://${TEST_BUCKET}/${MULTIPART_KEY}" \
  "$TMPDIR_TEST/multipart.out" --only-show-errors
cmp "$TMPDIR_TEST/multipart.bin" "$TMPDIR_TEST/multipart.out"
pass "multipart upload/download + content match"

count="$("${S3API[@]}" list-objects-v2 --bucket "$TEST_BUCKET" --prefix "$PREFIX/" \
  --output json | jq '(.Contents // []) | length')"
[[ "$count" -ge 5 ]]
pass "prefix listing contains test objects"

cleanup
trap - EXIT
remaining="$("${S3API[@]}" list-objects-v2 --bucket "$TEST_BUCKET" --prefix "$PREFIX/" \
  --output json | jq '(.Contents // []) | length')"
[[ "$remaining" == "0" ]]
pass "cleanup leaves zero test objects"

printf '\nAll public-endpoint functional checks passed.\n'

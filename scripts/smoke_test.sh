#!/usr/bin/env bash
# ============================================================================
# smoke_test.sh —— S3 网关端到端冒烟：用标准 S3 客户端(aws-cli) + 虚拟 AK/SK
# 完成 PUT/GET/HEAD/DELETE。
#
# 架构：客户端(虚拟 AK/SK, 标准 SigV4 签名)
#          -> nginx (TLS + auth_request -> authd 验签)
#          -> authd (用虚拟 SK 验证客户端签名)
#          -> sigv4-proxy (剥离旧签名, 用真实 S3 凭证重签)
#          -> S3 兼容对象存储
# 客户端零改造：就是一个普通的标准 S3 客户端。
#
# 前置: 已 ./scripts/deploy.sh 起服务; .env 填好 TEST_BUCKET/TEST_KEY;
#       auth/keys.json 已含一对虚拟 AK/SK（./scripts/gen_keys.sh 生成）,
#       将该虚拟 AK/SK 写入 .env 的 TEST_VIRT_AK / TEST_VIRT_SK。
# 用法: ./scripts/smoke_test.sh
# 依赖: aws-cli (v2 推荐)。path-style: 新版 aws-cli 默认 virtual-host,
#       本脚本已强制 AWS_S3_ADDRESSING_STYLE=path。
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

set -a; [[ -f .env ]] && . ./.env; set +a

GW_PORT="${GW_LISTEN_PORT:-8443}"
ENDPOINT="https://127.0.0.1:${GW_PORT}"
BUCKET="${TEST_BUCKET:?请在 .env 设置 TEST_BUCKET}"
KEY="${TEST_KEY:-s3gw-smoke-test.txt}"
VIRT_AK="${TEST_VIRT_AK:?请在 .env 设置 TEST_VIRT_AK（客户端虚拟 AK）}"
VIRT_SK="${TEST_VIRT_SK:?请在 .env 设置 TEST_VIRT_SK（客户端虚拟 SK）}"
REGION="${S3_REGION:-cn-beijing}"

command -v aws >/dev/null 2>&1 || { echo "[FATAL] 未找到 aws-cli，请先安装（brew install awscli）"; exit 1; }

# 标准 S3 客户端配置：仅 endpoint + 凭证 + path-style，零代码改造
export AWS_ACCESS_KEY_ID="$VIRT_AK"
export AWS_SECRET_ACCESS_KEY="$VIRT_SK"
export AWS_DEFAULT_REGION="$REGION"
export AWS_S3_ADDRESSING_STYLE=path
# aws-cli v1/botocore 新版本默认会为 PUT 增加 aws-chunked checksum trailer。
# 网关上游用 UNSIGNED-PAYLOAD 重签时不保留该 trailer，冒烟测试关闭默认 checksum 以验证普通 S3 读写链路。
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
unset AWS_SESSION_TOKEN

AWS=(aws --endpoint-url "$ENDPOINT" --no-verify-ssl)
S3API=("${AWS[@]}" s3api)

PASS=0; WARN=0; FAIL=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
warn(){ echo "  [WARN] $1"; WARN=$((WARN+1)); }
ng(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

TMPDIR_LOCAL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT
SRC="$TMPDIR_LOCAL/src.txt"
DST="$TMPDIR_LOCAL/dst.txt"
STAMP="$(date +%s)"
echo "s3gw smoke test @ $STAMP :: hello S3 via virtual AK/SK" > "$SRC"

echo "== [0] healthz =="
HZ="$(curl -sk -o /dev/null -w '%{http_code}' "${ENDPOINT}/healthz")"
[[ "$HZ" == "200" ]] && ok "healthz=200" || ng "healthz=$HZ"

echo "== [1] 错误凭证应被拒绝(403) =="
BOGUS="$(AWS_ACCESS_KEY_ID=AKBOGUS0000 AWS_SECRET_ACCESS_KEY=bogussecret \
  "${AWS[@]}" s3api list-objects-v2 --bucket "$BUCKET" 2>&1 || true)"
if echo "$BOGUS" | grep -Eq '403|Forbidden|AccessDenied'; then
  ok "bogus creds rejected"
else
  ng "bogus creds NOT rejected -> $(echo "$BOGUS" | head -1)"
fi

echo "== [2] PUT put-object =="
if "${S3API[@]}" put-object --bucket "$BUCKET" --key "$KEY" --body "$SRC" >/dev/null 2>&1; then
  ok "put-object"
else
  ng "put-object"; echo "    重跑看错误:"; "${S3API[@]}" put-object --bucket "$BUCKET" --key "$KEY" --body "$SRC" 2>&1 | sed 's/^/      /' | head -5
fi

echo "== [3] GET get-object + 内容比对 =="
if "${S3API[@]}" get-object --bucket "$BUCKET" --key "$KEY" "$DST" >/dev/null 2>&1; then
  if diff -q "$SRC" "$DST" >/dev/null 2>&1; then ok "get-object + content match"; else ng "content mismatch"; fi
else
  ng "get-object"
fi

echo "== [4] HEAD head-object =="
if "${S3API[@]}" head-object --bucket "$BUCKET" --key "$KEY" >/dev/null 2>&1; then
  ok "head-object"
else
  ng "head-object"
fi

echo "== [5] DELETE delete-object =="
DEL_OUT="$("${S3API[@]}" delete-object --bucket "$BUCKET" --key "$KEY" 2>&1)"
DEL_RC=$?
if [[ "$DEL_RC" -eq 0 ]]; then
  ok "delete-object"
elif [[ "${TEST_REQUIRE_DELETE:-0}" != "1" ]] && echo "$DEL_OUT" | grep -Eq 'AccessDenied|Access Denied|403|Forbidden'; then
  warn "delete-object skipped: real S3 credentials do not allow DeleteObject (set TEST_REQUIRE_DELETE=1 to require it)"
else
  ng "delete-object"; echo "$DEL_OUT" | sed 's/^/      /' | head -5
fi

echo ""
echo "==================== 结果 ===================="
echo "  PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] && { echo "  ✅ 网关链路通过"; exit 0; } || { echo "  ❌ 有失败项"; exit 1; }

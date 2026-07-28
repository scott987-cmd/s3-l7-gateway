#!/usr/bin/env bash
# ============================================================================
# gen_keys.sh —— 生成【只在网关生效的虚拟 AK/SK】并写入 auth/keys.json。
# 客户端拿这对虚拟 AK/SK 当标准 S3 凭证使用(零代码改造);authd 用它验签。
# 真实 S3 凭证另由 sigv4-proxy/creds 持有,与此无关。
#
# 现在委托给 keyctl.sh 统一写入【富元数据格式】(带 owner/enabled/expires/审计),
# 以支持快速吊销(见 scripts/keyctl.sh disable/enable/expire)。
#
# 用法:
#   ./scripts/gen_keys.sh                        # 随机生成 AK/SK
#   ./scripts/gen_keys.sh <access_key>           # 指定 AK,随机 SK
#   ./scripts/gen_keys.sh <access_key> <secret>  # 指定 AK+SK
#   OWNER=team-x NOTE=xxx ./scripts/gen_keys.sh  # 附带归属/备注
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

AK="${1:-}"
SK="${2:-}"
OWNER="${OWNER:-}"
NOTE="${NOTE:-}"

exec scripts/keyctl.sh add ${AK:+"$AK"} ${SK:+"$SK"} \
  ${OWNER:+--owner "$OWNER"} ${NOTE:+--note "$NOTE"}

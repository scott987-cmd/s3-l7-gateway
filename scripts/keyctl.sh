#!/usr/bin/env bash
# ============================================================================
# keyctl.sh —— 虚拟 AK/SK 生命周期与快速吊销 CLI（bash + jq，零 Python 依赖）。
#
# 配合 authd 的富元数据 keys.json:
#   { "<AK>": {"secret": "<SK>", "owner": "...", "enabled": true,
#              "expires": "2026-12-31T23:59:59Z", "note": "..."} }
#
# authd 加载时: enabled=false 或 expires 已过 → 该 AK 立即被拒(等价吊销)。
# 本 CLI 只改本地 keys.json 并(可选)对 authd 发 SIGHUP 热加载，秒级生效、免重启。
# 所有变更追加到 auth/keys_audit.log，保留审计痕迹(吊销用 disable 而非删除)。
#
# 用法:
#   keyctl.sh list
#   keyctl.sh add   [AK] [SK] [--owner O] [--note N] [--expires ISO] [--reload]
#   keyctl.sh disable <AK> [--note 原因] [--reload]
#   keyctl.sh enable  <AK> [--reload]
#   keyctl.sh expire  <AK> [--in 3600 | --at ISO] [--reload]
#   keyctl.sh rm      <AK> [--reload]
#
# 依赖: jq、openssl(仅 add 生成随机凭证时)、docker(仅 --reload)。
# ============================================================================
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "[keyctl] 需要 jq，请先安装(如 apk add jq / yum install jq)"; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYS_FILE="${AUTHD_KEYS_FILE:-$ROOT/auth/keys.json}"
AUDIT_FILE="$ROOT/auth/keys_audit.log"
CONTAINER="${AUTHD_CONTAINER:-s3gw-authd}"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# 读入并规范化(兼容旧的 {ak:"sk"} 扁平格式)；文件缺失/空 → {}
_load() {
  if [[ ! -s "$KEYS_FILE" ]]; then echo '{}'; return; fi
  jq '
    if type=="object" then
      with_entries(.value = (if (.value|type)=="string" then {secret:.value} else .value end))
    else {} end
  ' "$KEYS_FILE" 2>/dev/null || { echo "[keyctl] keys.json 解析失败，请检查文件格式" >&2; exit 1; }
}

# 原子写入(0600)。stdin 为 JSON。
_atomic_write() {
  local dir tmp
  dir="$(dirname "$KEYS_FILE")"; mkdir -p "$dir"
  tmp="$KEYS_FILE.tmp"
  cat > "$tmp"
  chmod 600 "$tmp"
  chown 65534:65534 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$KEYS_FILE"
  chmod 600 "$KEYS_FILE" 2>/dev/null || true
  chown 65534:65534 "$KEYS_FILE" 2>/dev/null || true
}

_audit() {
  local action="$1" ak="$2" detail="${3:-}"
  printf '%s\t%s\t%s\t%s\n' "$(now_iso)" "$action" "$ak" "$detail" >> "$AUDIT_FILE" 2>/dev/null || true
  chmod 600 "$AUDIT_FILE" 2>/dev/null || true
}

_reload() {
  local dc=()
  if docker compose version >/dev/null 2>&1; then
    dc=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    dc=(docker-compose)
  fi
  if [[ "${#dc[@]}" -gt 0 ]] && "${dc[@]}" kill -s HUP authd >/dev/null 2>&1; then
    echo "[keyctl] 已对 compose 服务 authd 发送 SIGHUP，authd 热加载完成"
    return
  fi
  if ! command -v docker >/dev/null 2>&1; then
    echo "[keyctl] 未找到 docker，请手动执行: docker compose kill -s HUP authd"; return
  fi
  if docker kill -s HUP "$CONTAINER" >/dev/null 2>&1; then
    echo "[keyctl] 已对容器 $CONTAINER 发送 SIGHUP，authd 热加载完成"
  else
    echo "[keyctl] SIGHUP 失败(服务未运行?): 请在部署目录执行 docker compose kill -s HUP authd"
  fi
}

_require() {
  local d="$1" ak="$2"
  if [[ "$(jq --arg k "$ak" 'has($k)' <<<"$d")" != "true" ]]; then
    echo "[keyctl] 未找到 AK: $ak"; exit 1
  fi
}

# 生成随机 AK/SK（对齐 Python: "AK"+16位大写hex / 40位 base64url）
_gen_ak() { printf 'AK%s' "$(openssl rand -hex 8 | tr 'a-f' 'A-F')"; }
_gen_sk() { openssl rand -base64 30 | tr '+/' '-_' | tr -d '=\n' | cut -c1-40; }

# ---- 子命令 ----
cmd_list() {
  local d; d="$(_load)"
  if [[ "$(jq 'length' <<<"$d")" -eq 0 ]]; then echo "(空) keys.json 无任何密钥"; return; fi
  printf '%-24s %-9s %-16s %-22s %s\n' "ACCESS_KEY" "STATUS" "OWNER" "EXPIRES" "NOTE"
  local now; now="$(now_iso)"
  jq -r --arg now "$now" '
    to_entries | sort_by(.key)[] |
    .key as $ak | .value as $e |
    (if ($e.enabled // true)==false then "DISABLED"
     elif ($e.expires // "") != "" and ($e.expires < $now) then "EXPIRED"
     else "ACTIVE" end) as $st |
    [$ak, $st, ($e.owner // "-"), ($e.expires // "-"), ($e.note // "")] | @tsv
  ' <<<"$d" | while IFS=$'\t' read -r ak st owner exp note; do
    printf '%-24s %-9s %-16s %-22s %s\n' "$ak" "$st" "$owner" "$exp" "$note"
  done
}

cmd_add() {
  local ak="" sk="" owner="" note="" expires="" reload=0
  local pos=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --owner) owner="$2"; shift 2;;
      --note) note="$2"; shift 2;;
      --expires) expires="$2"; shift 2;;
      --reload) reload=1; shift;;
      *) pos+=("$1"); shift;;
    esac
  done
  ak="${pos[0]:-$(_gen_ak)}"
  sk="${pos[1]:-$(_gen_sk)}"
  local d; d="$(_load)"
  d="$(jq --arg ak "$ak" --arg sk "$sk" --arg owner "$owner" --arg note "$note" \
        --arg expires "$expires" --arg created "$(now_iso)" '
    .[$ak] = ({secret:$sk, enabled:true, created:$created}
      + (if $owner!="" then {owner:$owner} else {} end)
      + (if $note!="" then {note:$note} else {} end)
      + (if $expires!="" then {expires:$expires} else {} end))
  ' <<<"$d")"
  _atomic_write <<<"$d"
  _audit add "$ak" "owner=${owner:--}"
  echo "[keyctl] 已新增虚拟密钥(请妥善保存，仅显示这一次):"
  echo "    AWS_ACCESS_KEY_ID     = $ak"
  echo "    AWS_SECRET_ACCESS_KEY = $sk"
  [[ $reload -eq 1 ]] && _reload || true
}

cmd_disable() {
  local ak="" note="" reload=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --note) note="$2"; shift 2;;
      --reload) reload=1; shift;;
      *) ak="$1"; shift;;
    esac
  done
  [[ -n "$ak" ]] || { echo "[keyctl] disable 需指定 AK"; exit 1; }
  local d; d="$(_load)"; _require "$d" "$ak"
  d="$(jq --arg ak "$ak" --arg t "$(now_iso)" --arg note "$note" '
    .[$ak].enabled=false | .[$ak].disabled_at=$t
    | (if $note!="" then .[$ak].note=$note else . end)
  ' <<<"$d")"
  _atomic_write <<<"$d"
  _audit disable "$ak" "$note"
  echo "[keyctl] 已吊销(禁用) $ak"
  [[ $reload -eq 1 ]] && _reload || true
}

cmd_enable() {
  local ak="" reload=0
  while [[ $# -gt 0 ]]; do
    case "$1" in --reload) reload=1; shift;; *) ak="$1"; shift;; esac
  done
  [[ -n "$ak" ]] || { echo "[keyctl] enable 需指定 AK"; exit 1; }
  local d; d="$(_load)"; _require "$d" "$ak"
  d="$(jq --arg ak "$ak" '.[$ak].enabled=true | del(.[$ak].disabled_at)' <<<"$d")"
  _atomic_write <<<"$d"
  _audit enable "$ak"
  echo "[keyctl] 已恢复启用 $ak"
  [[ $reload -eq 1 ]] && _reload || true
}

cmd_expire() {
  local ak="" at="" in_="" reload=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --at) at="$2"; shift 2;;
      --in) in_="$2"; shift 2;;
      --reload) reload=1; shift;;
      *) ak="$1"; shift;;
    esac
  done
  [[ -n "$ak" ]] || { echo "[keyctl] expire 需指定 AK"; exit 1; }
  local d; d="$(_load)"; _require "$d" "$ak"
  local exp
  if [[ -n "$at" ]]; then
    exp="$at"
  elif [[ -n "$in_" ]]; then
    if date -u -d "@0" >/dev/null 2>&1; then
      exp="$(date -u -d "+${in_} seconds" +%Y-%m-%dT%H:%M:%SZ)"
    else
      exp="$(date -u -v+"${in_}"S +%Y-%m-%dT%H:%M:%SZ)"
    fi
  else
    exp="$(now_iso)"
  fi
  d="$(jq --arg ak "$ak" --arg exp "$exp" '.[$ak].expires=$exp' <<<"$d")"
  _atomic_write <<<"$d"
  _audit expire "$ak" "$exp"
  echo "[keyctl] 已设置 $ak 到期时刻为 $exp"
  [[ $reload -eq 1 ]] && _reload || true
}

cmd_rm() {
  local ak="" reload=0
  while [[ $# -gt 0 ]]; do
    case "$1" in --reload) reload=1; shift;; *) ak="$1"; shift;; esac
  done
  [[ -n "$ak" ]] || { echo "[keyctl] rm 需指定 AK"; exit 1; }
  local d; d="$(_load)"; _require "$d" "$ak"
  d="$(jq --arg ak "$ak" 'del(.[$ak])' <<<"$d")"
  _atomic_write <<<"$d"
  _audit rm "$ak"
  echo "[keyctl] 已彻底删除 $ak(建议优先用 disable 以保留审计)"
  [[ $reload -eq 1 ]] && _reload || true
}

usage() {
  echo "用法: keyctl.sh {list|add|disable|enable|expire|rm} [参数...]"
  echo "  list                                     列出所有密钥及状态"
  echo "  add [AK] [SK] [--owner O] [--note N] [--expires ISO] [--reload]"
  echo "  disable <AK> [--note 原因] [--reload]"
  echo "  enable  <AK> [--reload]"
  echo "  expire  <AK> [--in 秒 | --at ISO] [--reload]"
  echo "  rm      <AK> [--reload]"
}

main() {
  [[ $# -ge 1 ]] || { usage; exit 1; }
  local cmd="$1"; shift
  case "$cmd" in
    list) cmd_list "$@";;
    add) cmd_add "$@";;
    disable) cmd_disable "$@";;
    enable) cmd_enable "$@";;
    expire) cmd_expire "$@";;
    rm) cmd_rm "$@";;
    -h|--help|help) usage;;
    *) echo "[keyctl] 未知子命令: $cmd"; usage; exit 1;;
  esac
}

main "$@"

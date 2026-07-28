#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; [[ -f .env ]] && . ./.env; set +a

MODE="${MODE:-local}"              # local | clb
CLB_IP="${CLB_IP:-}"
SIZE_MB="${SIZE_MB:-64}"
CONCURRENCY_LIST="${CONCURRENCY_LIST:-1 2 4 8 16}"
ROUNDS="${ROUNDS:-1}"
DIRECTION="${DIRECTION:-both}"      # put|get|both
KEY_PREFIX="${KEY_PREFIX:-s3gw-stress}"
WORKDIR="${WORKDIR:-/tmp/s3gw-stress}"

mkdir -p "$WORKDIR"
UP="$WORKDIR/payload-${SIZE_MB}m.bin"
if [[ ! -s "$UP" || "$(stat -c%s "$UP")" -ne $((SIZE_MB*1048576)) ]]; then
  dd if=/dev/urandom of="$UP" bs=1048576 count="$SIZE_MB" status=none
fi
MD5_UP="$(md5sum "$UP" | awk '{print $1}')"

export AWS_ACCESS_KEY_ID="${TEST_VIRT_AK:?missing TEST_VIRT_AK}"
export AWS_SECRET_ACCESS_KEY="${TEST_VIRT_SK:?missing TEST_VIRT_SK}"
export AWS_DEFAULT_REGION="${S3_REGION:-cn-beijing}"
export AWS_S3_ADDRESSING_STYLE=path
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
unset AWS_SESSION_TOKEN

if [[ "$MODE" == "local" ]]; then
  ENDPOINT="https://127.0.0.1:${GW_LISTEN_PORT:-443}"
elif [[ "$MODE" == "clb" ]]; then
  [[ -n "$CLB_IP" ]] || { echo "CLB_IP required for MODE=clb"; exit 2; }
  ENDPOINT="https://${CLB_IP}:443"
else
  echo "bad MODE=$MODE"
  exit 2
fi

AWS=(aws --endpoint-url "$ENDPOINT" --no-verify-ssl)
BUCKET="${TEST_BUCKET:?missing TEST_BUCKET}"
TS="$(date +%s)"
RESULTS="$WORKDIR/results-${MODE}-${TS}.tsv"
ERRDIR="$WORKDIR/errors-${MODE}-${TS}"
mkdir -p "$ERRDIR"
printf 'mode\tdirection\tsize_mb\tconcurrency\trounds\tsuccess\tfail\tseconds\tthroughput_mib_s\n' > "$RESULTS"

echo "== stress mode=$MODE endpoint=$ENDPOINT bucket=$BUCKET size=${SIZE_MB}MB rounds=$ROUNDS directions=$DIRECTION"
echo "== payload_md5=$MD5_UP workdir=$WORKDIR"

run_one() {
  local dir="$1" c="$2" idx="$3" round="$4"
  # 必须分成两条 local：同一条 local 里的 ${c}/${idx} 在赋值生效前就被展开，
  # 会得到空值，导致所有并发 worker 落到同一个 object key 上。
  local key="${KEY_PREFIX}-${MODE}-${SIZE_MB}m-c${c}-i${idx}.bin"
  if [[ "$dir" == "put" ]]; then
    "${AWS[@]}" s3api put-object --bucket "$BUCKET" --key "$key" --body "$UP" >/dev/null
  else
    local out="$WORKDIR/down-${MODE}-${c}-${idx}-${round}.bin"
    "${AWS[@]}" s3api get-object --bucket "$BUCKET" --key "$key" "$out" >/dev/null
    local md5
    md5="$(md5sum "$out" | awk '{print $1}')"
    [[ "$md5" == "$MD5_UP" ]]
    rm -f "$out"
  fi
}

bench_dir() {
  local dir="$1" c="$2"
  local start end elapsed success fail pids=() idx round total_ops mib_s
  success=0
  fail=0
  start="$(date +%s)"
  for round in $(seq 1 "$ROUNDS"); do
    pids=()
    for idx in $(seq 1 "$c"); do
      (run_one "$dir" "$c" "$idx" "$round") >"$ERRDIR/${dir}-c${c}-r${round}-i${idx}.out" 2>"$ERRDIR/${dir}-c${c}-r${round}-i${idx}.err" &
      pids+=("$!")
    done
    for p in "${pids[@]}"; do
      if wait "$p"; then success=$((success+1)); else fail=$((fail+1)); fi
    done
  done
  end="$(date +%s)"
  elapsed=$((end-start))
  [[ "$elapsed" -le 0 ]] && elapsed=1
  total_ops=$((success+fail))
  mib_s="$(awk -v mb="$SIZE_MB" -v ok="$success" -v sec="$elapsed" 'BEGIN{printf "%.2f", (mb*ok)/sec}')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$MODE" "$dir" "$SIZE_MB" "$c" "$ROUNDS" "$success" "$fail" "$elapsed" "$mib_s" | tee -a "$RESULTS"
  if [[ "$fail" -gt 0 ]]; then
    echo "!! first errors for $dir concurrency=$c total_ops=$total_ops"
    find "$ERRDIR" -name "${dir}-c${c}-*.err" -size +0 -print -exec sh -c 'echo "---- $1"; sed -n "1,8p" "$1"' sh {} \; | head -80
  fi
}

for c in $CONCURRENCY_LIST; do
  if [[ "$DIRECTION" == "put" || "$DIRECTION" == "both" ]]; then bench_dir put "$c"; fi
  if [[ "$DIRECTION" == "get" || "$DIRECTION" == "both" ]]; then bench_dir get "$c"; fi
  echo "-- docker stats snapshot --"
  docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}' | grep -E 's3gw-deploy|NAME' || true
  echo "-- ss summary --"
  ss -s | sed -n '1,8p'
  echo
done

echo "== results: $RESULTS"
cat "$RESULTS"

#!/usr/bin/env bash
# ============================================================================
# ops.sh -- 长期运维工具：健康、状态、日志、审计、重载、诊断包。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    echo "docker compose"
  fi
}

DC="$(compose_cmd)"
usage() {
  cat <<'USAGE'
usage: ./scripts/ops.sh <command>

commands:
  health      Check gateway/component health endpoints.
  status      Show compose ps and host port listeners.
  logs        Tail service logs. Set LINES=200 to change length.
  audit       Tail nginx JSON audit log. Set LINES=50.
  reload      SIGHUP authd to reload auth/keys.json.
  restart     Restart compose services.
  doctor      Run health/status/log/audit summary.
  bundle      Write a support bundle under ./support/.
USAGE
}

cmd="${1:-}"; shift || true
LINES="${LINES:-120}"

case "$cmd" in
  health)
    set -a; [[ -f .env ]] && . ./.env; set +a
    port="${GW_LISTEN_PORT:-8443}"
    echo "gateway health:"
    curl -sk -o /dev/null -w "  https://127.0.0.1:${port}/healthz -> %{http_code} (%{time_total}s)\n" "https://127.0.0.1:${port}/healthz" || true
    echo "component health:"
    $DC exec -T authd /authd -health && echo "  authd ok" || echo "  authd failed"
    $DC exec -T creds /creds -health -listen=127.0.0.1:8181 && echo "  creds ok" || echo "  creds failed"
    ;;
  status)
    $DC ps
    echo ""
    ss -tlnp 2>/dev/null | grep -E ':(443|8443)\b' || true
    ;;
  logs)
    $DC logs --tail="$LINES" authd creds sigv4-proxy nginx
    ;;
  audit)
    $DC exec -T nginx sh -c "tail -n ${LINES} /var/log/nginx/s3audit.log" || true
    ;;
  reload)
    $DC kill -s HUP authd
    ;;
  restart)
    $DC restart
    ;;
  doctor)
    "$0" health
    echo ""
    "$0" status
    echo ""
    LINES=40 "$0" logs
    echo ""
    LINES=20 "$0" audit
    ;;
  bundle)
    ts="$(date +%Y%m%d-%H%M%S)"
    out="support/s3gw-support-${ts}"
    mkdir -p "$out"
    {
      echo "date=$(date -Is)"
      echo "host=$(hostname)"
      uname -a
      echo ""
      docker --version || true
      docker compose version || docker-compose version || true
    } >"$out/host.txt" 2>&1
    $DC config >"$out/compose.config.yml" 2>&1 || true
    $DC ps >"$out/compose.ps.txt" 2>&1 || true
    $DC logs --tail=500 authd creds sigv4-proxy nginx >"$out/compose.logs.txt" 2>&1 || true
    $DC exec -T nginx sh -c 'tail -n 500 /var/log/nginx/s3audit.log' >"$out/s3audit.tail.jsonl" 2>&1 || true
    ss -s >"$out/ss-summary.txt" 2>&1 || true
    ss -tlnp >"$out/listeners.txt" 2>&1 || true
    df -h >"$out/df.txt" 2>&1 || true
    free -h >"$out/free.txt" 2>&1 || true
    tar -C support -czf "${out}.tgz" "$(basename "$out")"
    echo "support bundle: ${out}.tgz"
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    echo "unknown command: $cmd"
    usage
    exit 2
    ;;
esac

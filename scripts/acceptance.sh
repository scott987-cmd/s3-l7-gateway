#!/usr/bin/env bash
# ============================================================================
# acceptance.sh -- 一键验收：preflight -> deploy -> component health -> smoke.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$#" -gt 0 ]]; then
  echo "== [0/5] configure =="
  ./scripts/configure.sh "$@"
  echo ""
fi

echo "== [1/4] preflight =="
./scripts/preflight.sh

echo ""
echo "== [2/4] deploy =="
./scripts/deploy.sh

echo ""
echo "== [3/4] component health =="
./scripts/ops.sh health

echo ""
echo "== [4/4] smoke =="
./scripts/smoke_test.sh

echo ""
echo "== acceptance passed =="

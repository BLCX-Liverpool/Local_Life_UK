#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source "${SCRIPT_DIR}/common.sh"

if [[ "${HMDP_PERF_CONFIRM_FORMAL_RUN:-}" != "yes" ]]; then
  echo "Set HMDP_PERF_CONFIRM_FORMAL_RUN=yes before the formal suite." >&2
  exit 2
fi

"${SCRIPT_DIR}/start-stack.sh"
"${SCRIPT_DIR}/run-cache-ab.sh"

for scenario in L1 L2 L3 L4A L4B DUPLICATE STOCK LIMIT; do
  "${SCRIPT_DIR}/run-seckill-tier.sh" "${scenario}"
done

echo "Formal suite completed. Review perf/results and fill perf/report-template.md."


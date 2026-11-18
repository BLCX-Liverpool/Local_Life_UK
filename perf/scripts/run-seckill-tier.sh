#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source "${SCRIPT_DIR}/common.sh"

SCENARIO=$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')
case "${SCENARIO}" in
  L1) USERS=1000; STOCK=1000; RPS=100; COPIES=1 ;;
  L2) USERS=2000; STOCK=2000; RPS=200; COPIES=1 ;;
  L3) USERS=5000; STOCK=5000; RPS=500; COPIES=1 ;;
  L4A) USERS=10000; STOCK=10000; RPS=800; COPIES=1 ;;
  L4B) USERS=10000; STOCK=10000; RPS=1000; COPIES=1 ;;
  DUPLICATE) USERS=1000; STOCK=1000; RPS=200; COPIES=2 ;;
  STOCK) USERS=5000; STOCK=3000; RPS=500; COPIES=1 ;;
  LIMIT) USERS=2000; STOCK=2000; RPS=1500; COPIES=1 ;;
  SMOKE) USERS=20; STOCK=20; RPS=10; COPIES=1 ;;
  *)
    echo "Usage: $0 L1|L2|L3|L4A|L4B|DUPLICATE|STOCK|LIMIT|SMOKE" >&2
    exit 2
    ;;
esac

if [[ "${SCENARIO}" != "SMOKE" && "${HMDP_PERF_CONFIRM_FORMAL_RUN:-}" != "yes" ]]; then
  echo "Set HMDP_PERF_CONFIRM_FORMAL_RUN=yes before a formal load run." >&2
  exit 2
fi

export HMDP_PERF_ALLOW_RESET=yes
base_tokens=${PERF_ROOT}/perf/generated/users-${USERS}.csv
"${SCRIPT_DIR}/prepare-fixture.sh" "${USERS}" "${STOCK}" "${base_tokens}"

tokens=${base_tokens}
if (( COPIES > 1 )); then
  tokens=${PERF_ROOT}/perf/generated/users-${USERS}-duplicate.csv
  awk 'NR == 1 {print; next} {print; print}' "${base_tokens}" >"${tokens}"
fi

timestamp=$(date '+%Y%m%d-%H%M%S')
result_dir=${PERF_ROOT}/perf/results/${timestamp}-${SCENARIO}
requests=$((USERS * COPIES))
schedule_seconds=$(((requests + RPS - 1) / RPS))
threads=${USERS}
if (( threads > 200 )); then
  threads=200
fi

"${SCRIPT_DIR}/run-jmeter.sh" \
  "${PERF_ROOT}/perf/jmeter/seckill.jmx" \
  "${result_dir}" \
  -Jhost=127.0.0.1 \
  -Jport="${PERF_API_PORT}" \
  -Jvoucher_id="${PERF_VOUCHER_ID}" \
  -Jtokens_csv="${tokens}" \
  -Jthreads="${threads}" \
  -Jtarget_rps="${RPS}" \
  -Jschedule_seconds="${schedule_seconds}"

python3 "${SCRIPT_DIR}/analyze_jtl.py" \
  "${result_dir}/results.jtl" \
  "${result_dir}/http-summary.json" \
  --target-rps "${RPS}"

"${SCRIPT_DIR}/wait-for-drain.sh" "${result_dir}/final-state.json" 300

python3 "${SCRIPT_DIR}/verify_run.py" \
  --scenario "${SCENARIO}" \
  --users "${USERS}" \
  --stock "${STOCK}" \
  --http "${result_dir}/http-summary.json" \
  --state "${result_dir}/final-state.json" \
  --output "${result_dir}/verification.json"

echo "Result: ${result_dir}"


#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source "${SCRIPT_DIR}/common.sh"

if [[ "${HMDP_PERF_CONFIRM_FORMAL_RUN:-}" != "yes" ]]; then
  echo "Set HMDP_PERF_CONFIRM_FORMAL_RUN=yes before the five-round cache A/B test." >&2
  exit 2
fi

RPS=${HMDP_PERF_CACHE_RPS:-500}
DURATION=${HMDP_PERF_CACHE_DURATION_SECONDS:-180}
WARMUP=${HMDP_PERF_CACHE_WARMUP_SECONDS:-30}
timestamp=$(date '+%Y%m%d-%H%M%S')
root_result=${PERF_ROOT}/perf/results/${timestamp}-cache-ab
ensure_dir "${root_result}"

# Counterbalanced execution reduces JIT, host-load and warmup ordering effects.
sequence=(A B C C B A A B C C B A A B C)
round_a=0
round_b=0
round_c=0

for mode in "${sequence[@]}"; do
  case "${mode}" in
    A) cache_enabled=false; memcache_enabled=false; round_a=$((round_a + 1)); round=${round_a} ;;
    B) cache_enabled=true; memcache_enabled=false; round_b=$((round_b + 1)); round=${round_b} ;;
    C) cache_enabled=true; memcache_enabled=true; round_c=$((round_c + 1)); round=${round_c} ;;
  esac

  phase=${root_result}/${mode}${round}
  export HMDP_PERF_CACHE_ENABLED=${cache_enabled}
  export HMDP_PERF_MEMCACHE_ENABLED=${memcache_enabled}

  perf_compose restart memcached >/dev/null
  "${SCRIPT_DIR}/clear-read-caches.sh" >/dev/null
  perf_compose up -d --force-recreate api >/dev/null
  wait_for_api

  "${SCRIPT_DIR}/run-jmeter.sh" \
    "${PERF_ROOT}/perf/jmeter/cache-read.jmx" \
    "${phase}-warmup" \
    -Jhost=127.0.0.1 \
    -Jport="${PERF_API_PORT}" \
    -Jduration_seconds="${WARMUP}" \
    -Jthreads=100 \
    -Jtarget_rps=200

  "${SCRIPT_DIR}/run-jmeter.sh" \
    "${PERF_ROOT}/perf/jmeter/cache-read.jmx" \
    "${phase}" \
    -Jhost=127.0.0.1 \
    -Jport="${PERF_API_PORT}" \
    -Jduration_seconds="${DURATION}" \
    -Jthreads=200 \
    -Jtarget_rps="${RPS}"

  python3 "${SCRIPT_DIR}/analyze_jtl.py" \
    "${phase}/results.jtl" \
    "${phase}/http-summary.json" \
    --target-rps "${RPS}" \
    --mode cache >/dev/null

  cat >"${phase}/metadata.json" <<EOF
{"mode":"${mode}","round":${round},"cache_enabled":${cache_enabled},"memcache_enabled":${memcache_enabled}}
EOF
done

python3 "${SCRIPT_DIR}/aggregate_cache_ab.py" \
  "${root_result}" \
  "${root_result}/verification.json"

echo "Result: ${root_result}"


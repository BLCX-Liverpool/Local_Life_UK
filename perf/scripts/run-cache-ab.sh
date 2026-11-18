#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source "${SCRIPT_DIR}/common.sh"

if [[ "${HMDP_PERF_CONFIRM_FORMAL_RUN:-}" != "yes" ]]; then
  echo "Set HMDP_PERF_CONFIRM_FORMAL_RUN=yes before the cache A/B tiers." >&2
  exit 2
fi

SELECTION=$(printf '%s' "${1:-ALL}" | tr '[:lower:]' '[:upper:]')
case "${SELECTION}" in
  C1|C2|C3|C4|C5) tiers=("${SELECTION}") ;;
  ALL) tiers=(C1 C2 C3 C4 C5) ;;
  *)
    echo "Usage: $0 [C1|C2|C3|C4|C5|ALL]" >&2
    exit 2
    ;;
esac

DURATION=${HMDP_PERF_CACHE_DURATION_SECONDS:-60}
WARMUP=${HMDP_PERF_CACHE_WARMUP_SECONDS:-30}
TAIL=${HMDP_PERF_CACHE_TAIL_SECONDS:-10}
if ! [[ "${DURATION}" =~ ^[1-9][0-9]*$ && "${WARMUP}" =~ ^[1-9][0-9]*$ && "${TAIL}" =~ ^[1-9][0-9]*$ ]]; then
  echo "Cache warmup and duration must be positive integer seconds." >&2
  exit 2
fi

timestamp=$(date '+%Y%m%d-%H%M%S')
root_result=${PERF_ROOT}/perf/results/${timestamp}-cache-ab-${SELECTION}
ensure_dir "${root_result}"

# Memcached is deliberately excluded from both groups and stopped so it does
# not consume resources on the single-host performance server.
perf_compose stop memcached >/dev/null 2>&1 || true

# Five rounds per mode, counterbalanced as AB / BA / AB / BA / AB.
sequence=(A B B A A B B A A B)

for tier in "${tiers[@]}"; do
  case "${tier}" in
    C1) RPS=100 ;;
    C2) RPS=200 ;;
    C3) RPS=500 ;;
    C4) RPS=800 ;;
    C5) RPS=1000 ;;
  esac
  load_duration=$((WARMUP + DURATION + TAIL))
  round_a=0
  round_b=0

  for mode in "${sequence[@]}"; do
    case "${mode}" in
      A)
        cache_enabled=false
        round_a=$((round_a + 1))
        round=${round_a}
        ;;
      B)
        cache_enabled=true
        round_b=$((round_b + 1))
        round=${round_b}
        ;;
    esac

    phase=${root_result}/${tier}-${mode}${round}
    export HMDP_PERF_CACHE_ENABLED=${cache_enabled}

    "${SCRIPT_DIR}/clear-read-caches.sh" >/dev/null
    perf_compose up -d --force-recreate api >/dev/null
    wait_for_api

    HMDP_JMETER_GENERATE_DASHBOARD=false \
      "${SCRIPT_DIR}/run-jmeter.sh" \
      "${PERF_ROOT}/perf/jmeter/cache-read.jmx" \
      "${phase}" \
      -Jhost=127.0.0.1 \
      -Jport="${PERF_API_PORT}" \
      -Jduration_seconds="${load_duration}" \
      -Jthreads=200 \
      -Jtarget_rps="${RPS}" &
    jmeter_pid=$!

    if ! wait_for_jtl_sample "${phase}/results.jtl" "${jmeter_pid}"; then
      wait "${jmeter_pid}" || true
      echo "JMeter ended before producing a cache sample: ${phase}" >&2
      exit 1
    fi
    first_sample_ms=$(awk -F, 'NR == 2 {print $1; exit}' "${phase}/results.jtl")
    measurement_start_ms=$((first_sample_ms + WARMUP * 1000))
    measurement_end_ms=$((measurement_start_ms + DURATION * 1000))

    wait_until_epoch_ms "${measurement_start_ms}"
    fetch_metrics "${phase}/metrics-before.prom"
    wait_until_epoch_ms "${measurement_end_ms}"
    fetch_metrics "${phase}/metrics-after.prom"
    wait "${jmeter_pid}"

    python3 "${SCRIPT_DIR}/analyze_cache_metrics.py" \
      "${phase}/metrics-before.prom" \
      "${phase}/metrics-after.prom" \
      "${phase}/cache-metrics.json" \
      --duration-seconds "${DURATION}" >/dev/null

    python3 "${SCRIPT_DIR}/analyze_jtl.py" \
      "${phase}/results.jtl" \
      "${phase}/http-summary.json" \
      --target-rps "${RPS}" \
      --planned-duration-seconds "${DURATION}" \
      --discard-first-seconds "${WARMUP}" \
      --measurement-duration-seconds "${DURATION}" \
      --filtered-jtl-output "${phase}/measurement.jtl" \
      --buckets-output "${phase}/latency-by-second.csv" \
      --mode cache >/dev/null

    "${SCRIPT_DIR}/generate-jmeter-dashboard.sh" \
      "${phase}/measurement.jtl" \
      "${phase}/dashboard" >/dev/null

    printf '%s\n' \
      "{\"tier\":\"${tier}\",\"target_rps\":${RPS},\"mode\":\"${mode}\",\"round\":${round},\"cache_enabled\":${cache_enabled},\"memcache_enabled\":false,\"warmup_seconds\":${WARMUP},\"duration_seconds\":${DURATION},\"tail_seconds\":${TAIL},\"load_duration_seconds\":${load_duration}}" \
      >"${phase}/metadata.json"
  done
done

python3 "${SCRIPT_DIR}/aggregate_cache_ab.py" \
  "${root_result}" \
  "${root_result}/verification.json"

echo "Result: ${root_result}"

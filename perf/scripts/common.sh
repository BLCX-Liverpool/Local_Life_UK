#!/usr/bin/env bash
set -euo pipefail

PERF_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PERF_ROOT=$(CDPATH= cd -- "${PERF_SCRIPT_DIR}/../.." && pwd)
PERF_PROJECT=${HMDP_PERF_PROJECT:-hmdp-perf}
PERF_API_PORT=${HMDP_PERF_API_PORT:-18081}
PERF_API_BASE=${HMDP_PERF_API_BASE:-http://127.0.0.1:${PERF_API_PORT}}
PERF_VOUCHER_ID=${HMDP_PERF_VOUCHER_ID:-990001}
PERF_COMPOSE_BASE=${PERF_ROOT}/dev/docker-compose.test.yml
PERF_COMPOSE_OVERLAY=${PERF_ROOT}/perf/docker-compose.perf.yml

if [[ "${PERF_PROJECT}" != "hmdp-perf" ]]; then
  echo "Refusing to use unexpected Compose project: ${PERF_PROJECT}" >&2
  exit 2
fi

perf_compose() {
  docker compose \
    -p "${PERF_PROJECT}" \
    -f "${PERF_COMPOSE_BASE}" \
    -f "${PERF_COMPOSE_OVERLAY}" \
    "$@"
}

require_docker() {
  docker info >/dev/null 2>&1 || {
    echo "Docker daemon is unavailable." >&2
    return 1
  }
}

wait_for_api() {
  local attempts=${1:-90}
  local i=1
  while (( i <= attempts )); do
    if curl -fsS "${PERF_API_BASE}/actuator/health" 2>/dev/null \
      | grep -q '"status":"UP"'; then
      return 0
    fi
    sleep 2
    i=$((i + 1))
  done
  echo "API did not become healthy at ${PERF_API_BASE}" >&2
  perf_compose logs --tail=120 api >&2 || true
  return 1
}

mysql_exec() {
  perf_compose exec -T mysql \
    mysql -uroot -pisolation_test_only --default-character-set=utf8mb4 hmdp_optimization_test "$@"
}

mysql_scalar() {
  local sql=$1
  mysql_exec --batch --skip-column-names --execute "${sql}" | tail -n 1
}

redis_exec() {
  perf_compose exec -T redis redis-cli --raw "$@"
}

metric_value() {
  local metric=$1
  local value
  value=$(curl -fsS \
    -H 'Authorization: Bearer hmdp_perf_metrics' \
    "${PERF_API_BASE}/actuator/prometheus" \
    | awk -v name="${metric}" '$1 == name && !found {print $2; found = 1}')
  printf '%s\n' "${value:-0}"
}

fetch_metrics() {
  local output=$1
  curl -fsS \
    -H 'Authorization: Bearer hmdp_perf_metrics' \
    "${PERF_API_BASE}/actuator/prometheus" \
    -o "${output}"
}

wait_for_jtl_sample() {
  local jtl=$1
  local process_id=$2
  local attempts=${3:-90}
  local i=1
  while (( i <= attempts )); do
    if [[ -f "${jtl}" ]] && awk -F, 'NR == 2 {valid = ($1 ~ /^[0-9]+$/)} END {exit valid ? 0 : 1}' "${jtl}"; then
      return 0
    fi
    if ! kill -0 "${process_id}" 2>/dev/null; then
      return 1
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

wait_until_epoch_ms() {
  local target_ms=$1
  python3 -c 'import sys,time; time.sleep(max(0.0, (int(sys.argv[1]) - time.time_ns() // 1000000) / 1000.0))' "${target_ms}"
}

ensure_dir() {
  mkdir -p "$1"
}


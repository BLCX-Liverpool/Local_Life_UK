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
    if curl -fsS "${PERF_API_BASE}/actuator/health" | grep -q '"status":"UP"'; then
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
    | awk -v name="${metric}" '$1 == name {print $2; exit}')
  printf '%s\n' "${value:-0}"
}

ensure_dir() {
  mkdir -p "$1"
}


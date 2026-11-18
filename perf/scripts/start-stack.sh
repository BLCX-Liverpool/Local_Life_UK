#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source "${SCRIPT_DIR}/common.sh"

require_docker

export HMDP_PERF_CACHE_ENABLED=${HMDP_PERF_CACHE_ENABLED:-true}

perf_compose stop memcached >/dev/null 2>&1 || true
perf_compose up -d mysql redis rabbitmq api
wait_for_api
echo "Performance stack is healthy at ${PERF_API_BASE}"


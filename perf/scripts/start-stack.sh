#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source "${SCRIPT_DIR}/common.sh"

require_docker

export HMDP_PERF_CACHE_ENABLED=${HMDP_PERF_CACHE_ENABLED:-true}
export HMDP_PERF_MEMCACHE_ENABLED=${HMDP_PERF_MEMCACHE_ENABLED:-true}

perf_compose up -d mysql redis memcached rabbitmq api
wait_for_api
echo "Performance stack is healthy at ${PERF_API_BASE}"


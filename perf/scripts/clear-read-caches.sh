#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source "${SCRIPT_DIR}/common.sh"

redis_exec EVAL \
  "local cursor='0'; local removed=0; repeat local result=redis.call('SCAN',cursor,'MATCH','cache:*','COUNT',500); cursor=result[1]; local keys=result[2]; if #keys>0 then removed=removed+redis.call('DEL',unpack(keys)); end until cursor=='0'; return removed" \
  0


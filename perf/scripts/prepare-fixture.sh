#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source "${SCRIPT_DIR}/common.sh"

USERS=${1:-}
STOCK=${2:-${USERS}}
TOKENS_FILE=${3:-${PERF_ROOT}/perf/generated/users-${USERS}.csv}

if [[ "${HMDP_PERF_ALLOW_RESET:-}" != "yes" ]]; then
  echo "Set HMDP_PERF_ALLOW_RESET=yes to reset the isolated hmdp-perf database." >&2
  exit 2
fi
if ! [[ "${USERS}" =~ ^[0-9]+$ ]] || (( USERS < 1 || USERS > 10000 )); then
  echo "User count must be between 1 and 10000" >&2
  exit 2
fi
if ! [[ "${STOCK}" =~ ^[0-9]+$ ]] || (( STOCK < 1 || STOCK > 100000 )); then
  echo "Stock must be between 1 and 100000" >&2
  exit 2
fi

require_docker

# Start once so Flyway has created the complete schema, then stop the API before resetting Redis.
perf_compose up -d mysql redis memcached rabbitmq api
wait_for_api
perf_compose stop api

database_name=$(mysql_scalar 'SELECT DATABASE()')
if [[ "${database_name}" != "hmdp_optimization_test" ]]; then
  echo "Refusing to reset database ${database_name}" >&2
  exit 2
fi

redis_exec FLUSHDB >/dev/null

{
  printf 'SET @perf_user_count=%s; SET @perf_stock=%s; SET @perf_voucher_id=%s;\n' \
    "${USERS}" "${STOCK}" "${PERF_VOUCHER_ID}"
  sed -n '1,$p' "${PERF_ROOT}/perf/sql/prepare-fixture.sql"
} | mysql_exec

ensure_dir "$(dirname -- "${TOKENS_FILE}")"
{
  echo 'token,user_id'
  awk -v count="${USERS}" 'BEGIN {
    for (i = 1; i <= count; i++) {
      printf "perf-token-%06d,%d\n", i, 900000 + i
    }
  }'
} >"${TOKENS_FILE}"

batch_start=1
while (( batch_start <= USERS )); do
  batch_end=$((batch_start + 499))
  if (( batch_end > USERS )); then
    batch_end=${USERS}
  fi
  redis_exec EVAL \
    "for i=tonumber(ARGV[1]),tonumber(ARGV[2]) do local token=string.format('perf-token-%06d',i); local key='login:token:'..token; redis.call('HSET',key,'id',900000+i,'nickName',string.format('perf-user-%05d',i),'icon',''); redis.call('EXPIRE',key,2160000); end; return tonumber(ARGV[2])-tonumber(ARGV[1])+1" \
    0 "${batch_start}" "${batch_end}" >/dev/null
  batch_start=$((batch_end + 1))
done

# Recreating the API also recreates the Redis Stream group and auto-publishes the unused activity.
perf_compose up -d api
wait_for_api

published=$(redis_exec HGET "seckill:activity:${PERF_VOUCHER_ID}" state)
redis_stock=$(redis_exec GET "seckill:stock:${PERF_VOUCHER_ID}")
if [[ "${published}" != "ACTIVE" || "${redis_stock}" != "${STOCK}" ]]; then
  echo "Fixture publication failed: state=${published}, redis_stock=${redis_stock}" >&2
  exit 1
fi

echo "Prepared ${USERS} users, stock ${STOCK}, voucher ${PERF_VOUCHER_ID}"
echo "Tokens: ${TOKENS_FILE}"


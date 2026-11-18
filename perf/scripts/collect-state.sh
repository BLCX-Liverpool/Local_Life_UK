#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source "${SCRIPT_DIR}/common.sh"

OUTPUT=${1:-}
if [[ -z "${OUTPUT}" ]]; then
  echo "Usage: $0 OUTPUT.json" >&2
  exit 2
fi

ensure_dir "$(dirname -- "${OUTPUT}")"

state_tsv=$(
  {
    printf 'SET @perf_voucher_id=%s;\n' "${PERF_VOUCHER_ID}"
    sed -n '1,$p' "${PERF_ROOT}/perf/sql/final-state.sql"
  } | mysql_exec --batch --skip-column-names
)

IFS=$'\t' read -r initial_stock database_remaining successful_orders \
  processing failed review unresolved duplicate_violations outbox_pending \
  outbox_review dead_letters message_failures <<<"${state_tsv}"

redis_remaining=$(redis_exec GET "seckill:stock:${PERF_VOUCHER_ID}")
redis_remaining=${redis_remaining:-null}

rabbit=$(
  perf_compose exec -T rabbitmq \
    rabbitmqctl list_queues --quiet name messages_ready messages_unacknowledged
)
rabbit_ready=$(printf '%s\n' "${rabbit}" | awk '{ready += $2} END {print ready + 0}')
rabbit_unacked=$(printf '%s\n' "${rabbit}" | awk '{unacked += $3} END {print unacked + 0}')

stream_lag=$(metric_value hmdp_seckill_lag)
stream_pending=$(metric_value hmdp_seckill_pending)
stream_review=$(metric_value hmdp_seckill_review)

cat >"${OUTPUT}" <<EOF
{
  "voucher_id": ${PERF_VOUCHER_ID},
  "initial_stock": ${initial_stock},
  "database_remaining": ${database_remaining},
  "redis_remaining": ${redis_remaining},
  "successful_orders": ${successful_orders},
  "processing_reservations": ${processing},
  "failed_reservations": ${failed},
  "review_reservations": ${review},
  "unresolved_reservations": ${unresolved},
  "one_user_multiple_order_violations": ${duplicate_violations},
  "stream_lag": ${stream_lag},
  "stream_pending": ${stream_pending},
  "stream_review": ${stream_review},
  "outbox_pending_or_inflight": ${outbox_pending},
  "outbox_review": ${outbox_review},
  "rabbit_ready": ${rabbit_ready},
  "rabbit_unacked": ${rabbit_unacked},
  "seckill_dead_letters": ${dead_letters},
  "message_failures": ${message_failures}
}
EOF

cat "${OUTPUT}"


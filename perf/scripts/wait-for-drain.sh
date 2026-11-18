#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source "${SCRIPT_DIR}/common.sh"

OUTPUT=${1:-}
TIMEOUT_SECONDS=${2:-300}
if [[ -z "${OUTPUT}" ]]; then
  echo "Usage: $0 OUTPUT.json [TIMEOUT_SECONDS]" >&2
  exit 2
fi

deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
while (( $(date +%s) <= deadline )); do
  "${SCRIPT_DIR}/collect-state.sh" "${OUTPUT}" >/dev/null
  if python3 - "${OUTPUT}" <<'PY'
import json
import sys

state = json.load(open(sys.argv[1], encoding="utf-8"))
keys = (
    "processing_reservations",
    "review_reservations",
    "unresolved_reservations",
    "stream_lag",
    "stream_pending",
    "stream_review",
    "outbox_pending_or_inflight",
    "outbox_review",
    "rabbit_ready",
    "rabbit_unacked",
)
raise SystemExit(0 if all(float(state.get(key, 0)) == 0 for key in keys) else 1)
PY
  then
    echo "Asynchronous chain drained successfully"
    cat "${OUTPUT}"
    exit 0
  fi
  sleep 5
done

echo "Asynchronous chain did not drain within ${TIMEOUT_SECONDS}s" >&2
cat "${OUTPUT}" >&2
exit 1


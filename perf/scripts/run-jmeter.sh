#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source "${SCRIPT_DIR}/common.sh"

if (( $# < 2 )); then
  echo "Usage: $0 TEST_PLAN.jmx OUTPUT_DIR [JMeter -J options...]" >&2
  exit 2
fi

PLAN=$1
OUTPUT_DIR=$2
shift 2

if [[ -e "${OUTPUT_DIR}" ]]; then
  echo "Output directory already exists: ${OUTPUT_DIR}" >&2
  exit 2
fi

if command -v jmeter >/dev/null 2>&1; then
  JMETER=$(command -v jmeter)
elif [[ -x "${PERF_ROOT}/perf/.tools/apache-jmeter-5.6.3/bin/jmeter" ]]; then
  JMETER=${PERF_ROOT}/perf/.tools/apache-jmeter-5.6.3/bin/jmeter
else
  echo "JMeter is not installed. Run perf/scripts/install-jmeter.sh first." >&2
  exit 2
fi

mkdir -p "${OUTPUT_DIR}"

"${JMETER}" \
  -n \
  -t "${PLAN}" \
  -l "${OUTPUT_DIR}/results.jtl" \
  -j "${OUTPUT_DIR}/jmeter.log" \
  -e \
  -o "${OUTPUT_DIR}/dashboard" \
  -Jjmeter.save.saveservice.output_format=csv \
  -Jjmeter.save.saveservice.print_field_names=true \
  -Jjmeter.save.saveservice.timestamp_format=ms \
  -Jjmeter.save.saveservice.time=true \
  -Jjmeter.save.saveservice.label=true \
  -Jjmeter.save.saveservice.response_code=true \
  -Jjmeter.save.saveservice.response_message=true \
  -Jjmeter.save.saveservice.successful=true \
  -Jjmeter.save.saveservice.thread_name=true \
  -Jjmeter.save.saveservice.failure_message=true \
  -Jjmeter.save.saveservice.latency=true \
  -Jjmeter.save.saveservice.connect_time=true \
  -Jsample_variables=user_id,business_success,business_data,business_error \
  "$@"


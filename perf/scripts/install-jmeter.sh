#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
VERSION=${JMETER_VERSION:-5.6.3}
TOOLS_DIR=${ROOT}/perf/.tools
ARCHIVE=${TOOLS_DIR}/apache-jmeter-${VERSION}.tgz
INSTALL_DIR=${TOOLS_DIR}/apache-jmeter-${VERSION}
BASE_URL=${JMETER_BASE_URL:-https://dlcdn.apache.org/jmeter/binaries}
CHECKSUM_BASE_URL=${JMETER_CHECKSUM_BASE_URL:-https://dlcdn.apache.org/jmeter/binaries}

sha512_file() {
  if command -v sha512sum >/dev/null 2>&1; then
    sha512sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 512 "$1" | awk '{print $1}'
  else
    echo "Neither sha512sum nor shasum is installed." >&2
    return 1
  fi
}

if [[ -x "${INSTALL_DIR}/bin/jmeter" ]]; then
  printf '%s\n' "${INSTALL_DIR}/bin/jmeter"
  exit 0
fi

mkdir -p "${TOOLS_DIR}"
curl -fsSL --retry 3 \
  "${CHECKSUM_BASE_URL}/apache-jmeter-${VERSION}.tgz.sha512" -o "${ARCHIVE}.sha512"

expected=$(awk '{print $1}' "${ARCHIVE}.sha512")
actual=''
if [[ -f "${ARCHIVE}" ]]; then
  actual=$(sha512_file "${ARCHIVE}")
fi
if [[ "${expected}" != "${actual}" ]]; then
  if ! curl -fL --retry 3 --continue-at - \
    "${BASE_URL}/apache-jmeter-${VERSION}.tgz" -o "${ARCHIVE}"; then
    rm -f "${ARCHIVE}"
    curl -fL --retry 3 \
      "${BASE_URL}/apache-jmeter-${VERSION}.tgz" -o "${ARCHIVE}"
  fi
  actual=$(sha512_file "${ARCHIVE}")
fi
if [[ "${expected}" != "${actual}" ]]; then
  echo "JMeter archive checksum mismatch" >&2
  exit 1
fi

tar -xzf "${ARCHIVE}" -C "${TOOLS_DIR}"
printf '%s\n' "${INSTALL_DIR}/bin/jmeter"


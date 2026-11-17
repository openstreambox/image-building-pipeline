#!/usr/bin/env bash
#
# verify-licence-notices.sh — re-fetch every pinned licence text named in
# mkosi/runtime/licence-notices/notices.tsv from its source at the pinned commit
# and compare it with the vendored copy. Needs network; not part of ./run-tests.
# Run it when adding or refreshing a row.
#
# Usage: tools/verify-licence-notices.sh [notices.tsv]

set -euo pipefail

HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TABLE="${1:-${HERE}/../mkosi/runtime/licence-notices/notices.tsv}"
BASE="$(dirname -- "${TABLE}")"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

failures=0
while IFS=$'\t' read -r pkg _ver component source commit path text sha _extra || [[ -n "${pkg:-}" ]]; do
  [[ -z "${pkg}" || "${pkg}" == \#* || "${text}" == "-" ]] && continue
  [[ "${source}" == https://github.com/* ]] || { echo "SKIP ${pkg}: not a GitHub source (${source})"; continue; }
  url="https://raw.githubusercontent.com/${source#https://github.com/}/${commit}/${path%%#*}"
  if ! curl -fsSL --retry 3 -o "${WORK}/text" "${url}"; then
    echo "FAIL ${pkg} (${component}): cannot fetch ${url}"; failures=$((failures + 1)); continue
  fi
  if [[ "${path}" == *'#'* ]]; then
    range="${path#*#}"
    [[ "${range}" =~ ^L([0-9]+)-L([0-9]+)$ ]] || { echo "FAIL ${pkg}: invalid source range"; exit 1; }
    sed -n "${BASH_REMATCH[1]},${BASH_REMATCH[2]}p" "${WORK}/text" > "${WORK}/excerpt"
    mv "${WORK}/excerpt" "${WORK}/text"
  fi
  upstream="$(sha256sum "${WORK}/text" | awk '{print $1}')"
  vendored="$(sha256sum "${BASE}/${text}" | awk '{print $1}')"
  if [[ "${upstream}" == "${sha}" && "${vendored}" == "${sha}" ]]; then
    echo "OK   ${pkg} (${component}): ${path} at ${commit:0:12}"
  else
    echo "FAIL ${pkg} (${component}): pinned ${sha}, upstream ${upstream}, vendored ${vendored}"
    failures=$((failures + 1))
  fi
done < "${TABLE}"
exit $(( failures > 0 ))

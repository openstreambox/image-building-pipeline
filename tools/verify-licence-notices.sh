#!/usr/bin/env bash
#
# verify-licence-notices.sh — re-fetch every pinned licence text named in
# mkosi/runtime/licence-notices/notices.tsv and image-notices.tsv from its source
# at the pinned commit
# and compare it with the vendored copy. Needs network; not part of ./run-tests.
# Run it when adding or refreshing a row.
#
# Usage: tools/verify-licence-notices.sh [notices.tsv [image-notices.tsv]]

set -euo pipefail

HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TABLE="${1:-${HERE}/../mkosi/runtime/licence-notices/notices.tsv}"
IMAGE_TABLE="${2:-${HERE}/../mkosi/runtime/licence-notices/image-notices.tsv}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

failures=0
# verify_text <label> <source> <commit> <path> <text> <sha256> <base dir>
verify_text() {
  local label="$1" source="$2" commit="$3" path="$4" text="$5" sha="$6" base="$7" url range upstream vendored
  [[ "${source}" == https://github.com/* ]] || { echo "SKIP ${label}: not a GitHub source (${source})"; return 0; }
  url="https://raw.githubusercontent.com/${source#https://github.com/}/${commit}/${path%%#*}"
  if ! curl -fsSL --retry 3 -o "${WORK}/text" "${url}"; then
    echo "FAIL ${label}: cannot fetch ${url}"; failures=$((failures + 1)); return 0
  fi
  if [[ "${path}" == *'#'* ]]; then
    range="${path#*#}"
    [[ "${range}" =~ ^L([0-9]+)-L([0-9]+)$ ]] || { echo "FAIL ${label}: invalid source range"; exit 1; }
    sed -n "${BASH_REMATCH[1]},${BASH_REMATCH[2]}p" "${WORK}/text" > "${WORK}/excerpt"
    mv "${WORK}/excerpt" "${WORK}/text"
  fi
  upstream="$(sha256sum "${WORK}/text" | awk '{print $1}')"
  vendored="$(sha256sum "${base}/${text}" | awk '{print $1}')"
  if [[ "${upstream}" == "${sha}" && "${vendored}" == "${sha}" ]]; then
    echo "OK   ${label}: ${path} at ${commit:0:12}"
  else
    echo "FAIL ${label}: pinned ${sha}, upstream ${upstream}, vendored ${vendored}"
    failures=$((failures + 1))
  fi
}

BASE="$(dirname -- "${TABLE}")"
while IFS=$'\t' read -r pkg _ver component source commit path text sha _extra || [[ -n "${pkg:-}" ]]; do
  [[ -z "${pkg}" || "${pkg}" == \#* || "${text}" == "-" ]] && continue
  verify_text "${pkg} (${component})" "${source}" "${commit}" "${path}" "${text}" "${sha}" "${BASE}"
done < "${TABLE}"

if [[ -f "${IMAGE_TABLE}" ]]; then
  BASE="$(dirname -- "${IMAGE_TABLE}")"
  while IFS=$'\t' read -r dest source commit path text sha _extra || [[ -n "${dest:-}" ]]; do
    [[ -z "${dest}" || "${dest}" == \#* ]] && continue
    verify_text "${dest}" "${source}" "${commit}" "${path}" "${text}" "${sha}" "${BASE}"
  done < "${IMAGE_TABLE}"
fi
exit $(( failures > 0 ))

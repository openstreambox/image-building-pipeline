#!/usr/bin/env bash
#
# fetch-boot-firmware-notice-sources.sh: download what
# tools/generate-boot-firmware-notices.py reads, from the pins in
# mkosi/runtime/licence-notices/boot-firmware/inputs.json. Needs network; not part
# of ./run-tests.
#
#   <dir>/sources/<key>.git  bare, shallow, blobless repository holding exactly the
#                            pinned commit; git fetches the few text blobs the
#                            generator reads on demand, never the firmware itself
#   <dir>/debs/<archive>     each pinned archive, checked against its sha256
#
# Usage: tools/fetch-boot-firmware-notice-sources.sh <dir>
# Then:  tools/generate-boot-firmware-notices.py --sources <dir>/sources --debs <dir>/debs [--check]

set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 <dir>" >&2; exit 2; }
HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INPUTS="${HERE}/../mkosi/runtime/licence-notices/boot-firmware/inputs.json"
OUT="$1"
mkdir -p "${OUT}/sources" "${OUT}/debs"

while IFS=$'\t' read -r key fetch commit; do
  repo="${OUT}/sources/${key}.git"
  if [[ ! -d "${repo}" ]]; then
    git init -q --bare "${repo}"
    git --git-dir "${repo}" remote add origin "${fetch}"
    git --git-dir "${repo}" config remote.origin.promisor true
    git --git-dir "${repo}" config remote.origin.partialclonefilter blob:none
  fi
  git --git-dir "${repo}" fetch -q --depth 1 --filter=blob:none origin "${commit}"
  [[ "$(git --git-dir "${repo}" rev-parse --verify "${commit}^{commit}")" == "${commit}" ]]
  echo "ok   ${key} ${commit}"
done < <(python3 -c 'import json,sys
for k, v in sorted(json.load(open(sys.argv[1]))["sources"].items()):
    print(k, v["fetch"], v["commit"], sep="\t")' "${INPUTS}")

while IFS=$'\t' read -r url sha; do
  deb="${OUT}/debs/${url##*/}"
  if [[ ! -f "${deb}" ]] || [[ "$(sha256sum < "${deb}" | awk '{print $1}')" != "${sha}" ]]; then
    curl -fsSL --retry 3 -o "${deb}.part" "${url}"
    [[ "$(sha256sum < "${deb}.part" | awk '{print $1}')" == "${sha}" ]] \
      || { rm -f "${deb}.part"; echo "FAIL ${url}: sha256 differs from the pin" >&2; exit 1; }
    mv "${deb}.part" "${deb}"
  fi
  echo "ok   ${url##*/}"
done < <(python3 -c 'import json,sys
for v in json.load(open(sys.argv[1]))["packages"].values():
    print(v["url"], v["sha256"], sep="\t")' "${INPUTS}")

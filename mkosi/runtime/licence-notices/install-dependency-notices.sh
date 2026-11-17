#!/usr/bin/env bash
# App-layer additive notices. No fetching, target execution or first-boot work.
set -euo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE="${DEPENDENCY_NOTICES_BASE:-${HERE}/dependencies}"
DEST="${LICENCE_NOTICES_DESTROOT:-}"
QUERY="${LICENCE_NOTICES_DPKG_QUERY:-dpkg-query}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
(cd "${BASE}" && sha256sum --check --strict SHA256SUMS)
"${QUERY}" -W -f='${Package} ${db:Status-Status} ${Version}\n' > "${WORK}/installed"
version="$(awk '$1 == "srtla" && $2 == "installed" {print $3}' "${WORK}/installed")"
packages=()
if [[ -n "${version}" ]]; then
  [[ "${version}" == 4.2.0 ]] || { echo 'uncovered srtla version' >&2; exit 1; }
  packages+=(srtla)
fi
if [[ -e "${DEST}/usr/local/bin/mediamtx" ]]; then
  file="${DEST}/usr/share/doc/mediamtx/copyright"
  grep -Fxq 'MediaMTX v1.19.2, installed as /usr/local/bin/mediamtx' "${file}"
  # Both pinned architectures have the same source release; measured module
  # membership in the payload is explicitly arm64-only.
  grep -Eq '^Release tarball sha256: (562f419912a8668c18216a9e8c95359ec82fbb754e4a44e2953ef62b98eec688|f9c601cc303ceca8fad2883917b022882672c5bc56311e92dbceb16e5f20c60c)$' "${file}"
  packages+=(mediamtx)
fi
# Preflight all destinations before changing any. Preserve the exact parent
# copyright bytes, appending the verified source notice payload once only.
for pkg in "${packages[@]}"; do
  file="${DEST}/usr/share/doc/${pkg}/copyright"
  [[ -s "${file}" && ! -L "${file}" && ! -L "$(dirname "${file}")" ]]
  if grep -Fq 'SOURCE DEPENDENCY NOTICES (' "${file}"; then
    echo "dependency notices already present for ${pkg}" >&2
    exit 1
  fi
  cat "${file}" "${BASE}/${pkg}.txt" > "${WORK}/${pkg}"
done
for pkg in "${packages[@]}"; do
  install -m 0644 "${WORK}/${pkg}" "${DEST}/usr/share/doc/${pkg}/copyright"
done

#!/usr/bin/env bash
#
# image-notices.test.sh — the licence files of this repository and the portal
# brand notice ship in the image, verbatim.
#
# WHY: the runtime layer installs this repository's scripts, units and
# configuration and the portal brand mark (/usr/share/ceralive/brand) into the
# rootfs. No package owns them, so no copyright file covered them, and the brand
# mark shipped without the notice that says it is not under this repository's
# licence.
#
# Part A — the committed table: every text is byte-identical to this
#          repository's own file and matches its pin, the pinned commit carries
#          the same bytes (when git history is available), and the brand lock
#          records the committed brand mark.
# Part B — the REAL install-image-notices.sh into a scratch root: verbatim
#          copies at their destinations, mode 0644, a README that names the
#          source and grants nothing, and the brand mark checked against the lock.
# Part C — failure: a changed, missing or malformed text, a symlinked
#          destination and a brand mark that is not the pinned one fail the build.
# Part D — wiring: the app layer runs it; no prune touches the destinations.
#
# Offline and rootless.
# Profile: contract-test (docs/shell-profiles.md).
# shellcheck shell=bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
NOTICES="${REPO}/mkosi/runtime/licence-notices"
SCRIPT="${NOTICES}/install-image-notices.sh"
TABLE="${NOTICES}/image-notices.tsv"
MARK="${REPO}/mkosi/runtime/brand/ceralive-mark-small-dark.svg"
# shellcheck source=tests/lib/assertions.sh
source "${HERE}/lib/assertions.sh"

WORK="$(mktemp -d)"
finish() {
  rm -rf "${WORK}"
  printf ' RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
  [[ "${FAIL}" -eq 0 ]]
}
trap 'finish; exit $?' EXIT

[[ -x "${SCRIPT}" ]] || { bad "installer missing or not executable: ${SCRIPT}"; exit 1; }

# --- Part A: the committed table ---------------------------------------------
declare -A want=(
  [/usr/share/licenses/image-building-pipeline/LICENSE]=LICENSE
  [/usr/share/licenses/image-building-pipeline/LICENSE-MIT]=LICENSE-MIT
  [/usr/share/licenses/image-building-pipeline/LICENSE-APACHE]=LICENSE-APACHE
  [/usr/share/ceralive/brand/BRAND-ASSETS-NOTICE.md]=BRAND-ASSETS-NOTICE.md
  [/usr/share/ceralive/brand/brand-assets.lock.json]=brand-assets.lock.json
)
rows=0
while IFS=$'\t' read -r dest source commit path text sha extra || [[ -n "${dest:-}" ]]; do
  [[ -z "${dest}" || "${dest}" == \#* ]] && continue
  rows=$((rows + 1))
  [[ "${want[${dest}]:-}" == "${path}" ]] || bad "unexpected row ${dest} -> ${path}"
  assert_eq "${dest}: source" 'https://github.com/CERALIVE/image-building-pipeline' "${source}"
  cmp -s "${NOTICES}/${text}" "${REPO}/${path}" \
    && ok "${dest}: vendored text equals this repository's ${path}" \
    || bad "${dest}: vendored text differs from ${path}; refresh texts/ and the pin together"
  assert_eq "${dest}: pin" "${sha}" "$(sha256sum "${NOTICES}/${text}" | cut -d' ' -f1)"
  if git -C "${REPO}" cat-file -e "${commit}^{commit}" 2>/dev/null; then
    [[ "$(git -C "${REPO}" show "${commit}:${path}" | sha256sum | cut -d' ' -f1)" == "${sha}" ]] \
      && ok "${dest}: ${path} at ${commit:0:12} has the pinned bytes" \
      || bad "${dest}: ${path} at ${commit:0:12} does not match the pin"
  fi
  [[ -z "${extra}" ]] || bad "${dest}: extra column"
done <"${TABLE}"
assert_eq 'one row per licence and notice file' "${#want[@]}" "${rows}"
lock_sha="$(sed -n 's/.*"sha256": "\([0-9a-f]\{64\}\)".*/\1/p' "${REPO}/brand-assets.lock.json")"
assert_eq 'the brand lock records the committed brand mark' "$(sha256sum "${MARK}" | cut -d' ' -f1)" "${lock_sha}"

# --- Part B: the real installer ---------------------------------------------
install_into() { # <root> [table]
  IMAGE_NOTICES_DESTROOT="$1" IMAGE_NOTICES_TABLE="${2:-${TABLE}}" bash "${SCRIPT}"
}
root="${WORK}/root"
install -D -m 0644 "${MARK}" "${root}/usr/share/ceralive/brand/ceralive-mark-small-dark.svg"
if install_into "${root}" >"${WORK}/install.log" 2>&1; then
  ok 'install-image-notices.sh succeeds with the brand mark installed'
else
  bad "install-image-notices.sh failed: $(cat "${WORK}/install.log")"
fi
for dest in "${!want[@]}"; do
  if cmp -s "${root}${dest}" "${REPO}/${want[${dest}]}" && [[ "$(stat -c %a "${root}${dest}")" == 644 ]]; then
    ok "${dest} is a verbatim 0644 copy"
  else
    bad "${dest} is missing, changed or not 0644"
  fi
done
readme="${root}/usr/share/licenses/image-building-pipeline/README"
grep -Fq 'copied verbatim from https://github.com/CERALIVE/image-building-pipeline at' "${readme}" \
  && grep -Eq '^[0-9a-f]{40}\. ' "${readme}" \
  && ok 'the README names the source repository and commit' || bad 'README provenance missing'
grep -Fq 'brand mark under /usr/share/ceralive/brand is not covered by these licence' "${readme}" \
  && ok 'the README points the brand mark at its own notice' || bad 'README does not exclude the brand mark'
if grep -Eiq 'permission is hereby granted|licensed under|you may' "${readme}"; then
  bad 'the README states licence terms of its own'
else
  ok 'the README grants nothing of its own'
fi
grep -q "${WORK}" "${readme}" && bad 'a build path leaked into the README' || ok 'no build path in the README'
# Without the brand mark (a build that does not install the portal) the texts
# still install; the check only applies to a mark that is there.
install_into "${WORK}/nomark" >/dev/null 2>&1 && [[ -f "${WORK}/nomark/usr/share/ceralive/brand/BRAND-ASSETS-NOTICE.md" ]] \
  && ok 'texts install without the brand mark' || bad 'install failed without the brand mark'

# --- Part C: failures --------------------------------------------------------
expect_failure() { # <label> <regex> <root> [table]
  if install_into "$3" "${4:-}" >"${WORK}/fail.log" 2>&1; then
    bad "$1: accepted"
  elif grep -Eq "$2" "${WORK}/fail.log"; then
    ok "$1"
  else
    bad "$1: unexpected output: $(cat "${WORK}/fail.log")"
  fi
}
copy_table() { # <dir> — the committed table and texts in a scratch copy
  mkdir -p "$1"; cp "${TABLE}" "$1/"; cp -r "${NOTICES}/texts" "$1/"
}
copy_table "${WORK}/changed"
printf 'edited\n' >>"${WORK}/changed/texts/image-building-pipeline-7188c790-LICENSE-MIT"
expect_failure 'a changed text fails' 'pinned notice text changed' "${WORK}/r1" "${WORK}/changed/image-notices.tsv"
copy_table "${WORK}/missing"
rm "${WORK}/missing/texts/image-building-pipeline-7188c790-BRAND-ASSETS-NOTICE.md"
expect_failure 'a missing text fails' 'pinned notice text missing' "${WORK}/r2" "${WORK}/missing/image-notices.tsv"
copy_table "${WORK}/malformed"
printf '../etc/escape\thttps://example.invalid\t%s\tLICENSE\ttexts/x\t%s\n' \
  "$(printf 'a%.0s' {1..40})" "$(printf 'b%.0s' {1..64})" >>"${WORK}/malformed/image-notices.tsv"
expect_failure 'a relative or escaping destination fails' 'malformed row' "${WORK}/r3" "${WORK}/malformed/image-notices.tsv"
mkdir -p "${WORK}/r4/usr/share/ceralive" "${WORK}/elsewhere"
ln -s "${WORK}/elsewhere" "${WORK}/r4/usr/share/ceralive/brand"
expect_failure 'a symlinked destination directory fails' 'through a symlink' "${WORK}/r4"
[[ -z "$(ls -A "${WORK}/elsewhere")" ]] && ok 'nothing was written through the symlink' \
  || bad 'a notice was written through a symlink'
install -D -m 0644 /dev/null "${WORK}/r5/usr/share/ceralive/brand/ceralive-mark-small-dark.svg"
printf '<svg/>\n' >"${WORK}/r5/usr/share/ceralive/brand/ceralive-mark-small-dark.svg"
expect_failure 'a brand mark that is not the pinned asset fails' 'is not the pinned brand asset' "${WORK}/r5"

# --- Part D: wiring ----------------------------------------------------------
app="${REPO}/mkosi/mkosi.images/app/mkosi.postinst.chroot"
grep -Eq '^  bash "\$\{SRCDIR:\?\}/runtime/licence-notices/install-image-notices.sh"$' "${app}" \
  && ok 'the app layer runs install-image-notices.sh' || bad 'the app layer does not run the installer'
# Neither the payload prune nor the device prune list may remove the destinations.
payload="$(awk '/^prune_final_image_payload\(\) \{/{f=1} f{print} f && /^\}/{exit}' "${app}")"
if grep -Eq '/usr/share/(licenses|ceralive)' <<<"${payload}" \
    || grep -Ev '^[[:space:]]*(#|$)' "${REPO}/manifests/prune-paths.list" | grep -Eq '^/usr/share/(licenses|ceralive|\*)'; then
  bad 'a prune removes /usr/share/licenses or /usr/share/ceralive'
else
  ok 'no prune removes the installed notices'
fi

[[ "${FAIL}" -eq 0 ]]

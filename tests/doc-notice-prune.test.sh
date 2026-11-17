#!/usr/bin/env bash
#
# doc-notice-prune.test.sh — the /usr/share/doc prune keeps licence, notice and
# authorship files, byte for byte, on the build and on the device alike.
#
# WHY: the app layer's prune_package_docs() and the on-device apt hook
# ceralive-reprune both deleted every doc file not literally named `copyright`.
# That removed Apache NOTICE files, second copyright files (copyright.fonts.gz),
# COPYING, AUTHORS and CREDITS texts that several packages carry only there.
#
# Part A — the policy itself: which names and directories are kept.
# Part B — the REAL app-layer prune_package_docs() and the REAL ceralive-reprune
#          script, each over the same synthetic doc tree: kept files keep their
#          bytes and modes, ordinary docs (compressed, mixed case, odd names)
#          go, and both leave identical trees.
# Part C — path safety: no symlink keeps a document or leads the delete outside
#          the doc root; a symlinked or relative doc root is refused.
# Part D — failure semantics: the build fails, the apt hook logs and exits 0.
#
# Offline and rootless; synthetic texts only.
# Profile: contract-test (docs/shell-profiles.md).
# shellcheck shell=bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
MKOSI_DIR="${PIPELINE_DIR}/mkosi"
APP_POSTINST="${MKOSI_DIR}/mkosi.images/app/mkosi.postinst.chroot"
REPRUNE="${MKOSI_DIR}/runtime/ceralive-reprune.sh"
POLICY="${MKOSI_DIR}/runtime/doc-notice-policy.sh"
# shellcheck source=tests/lib/assertions.sh
source "${HERE}/lib/assertions.sh"

WORK="$(mktemp -d)"
finish() {
  chmod -R u+w "${WORK}" 2>/dev/null
  rm -rf "${WORK}"
  printf ' RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
  [[ "${FAIL}" -eq 0 ]]
}
trap 'finish; exit $?' EXIT

[[ -f "${POLICY}" ]] || { bad "shared doc-notice policy missing: ${POLICY}"; exit 1; }

# --- Part A: the policy ------------------------------------------------------
# shellcheck source=mkosi/runtime/doc-notice-policy.sh
source "${POLICY}"
kept=(
  pkg/copyright pkg/copyright.fonts.gz pkg/copyright.xkb.gz pkg/COPYRIGHT.txt
  pkg/NOTICE pkg/NOTICE.gz pkg/NOTICE.amrwbenc.gz pkg/notice.txt pkg/NOTICES.md
  pkg/COPYING pkg/COPYING.LIB pkg/COPYING3 pkg/copying.gz
  pkg/LICENSE pkg/License.TXT pkg/LICENCE.md pkg/MIT-LICENSE pkg/LICENSE-APACHE.gz pkg/licenses.txt
  pkg/AUTHORS pkg/Authors.md pkg/AUTHORS.gz pkg/author.txt pkg/CREDITS.txt pkg/CONTRIBUTORS
  pkg/PATENTS pkg/WHENCE.gz pkg/EULA.txt
  pkg/ThirdPartyNotices.txt pkg/third-party-licenses.html pkg/THIRD_PARTY.md pkg/ATTRIBUTIONS.md
  pkg/licenses/MIT.txt pkg/third_party/zlib/README pkg/sub/NOTICE
  NOTICE
)
dropped=(
  pkg/changelog.Debian.gz pkg/changelog.gz pkg/NEWS.gz pkg/README pkg/README.Debian pkg/readme.md
  pkg/examples/demo.c pkg/TODO pkg/noticeboard.txt pkg/authorship-guide.html pkg/html/index.html
  license-reconcile/README notice-tool/changelog.gz README
)
policy_ok=1
for rel in "${kept[@]}"; do
  doc_notice_path_kept "${rel}" || { bad "policy drops ${rel}"; policy_ok=0; }
done
for rel in "${dropped[@]}"; do
  if doc_notice_path_kept "${rel}"; then bad "policy keeps ${rel}"; policy_ok=0; fi
done
(( policy_ok )) && ok "policy keeps ${#kept[@]} notice names and drops ${#dropped[@]} ordinary docs"
unset -f doc_notice_name_kept doc_notice_path_kept doc_notice_prune

# --- Part B: both production paths over the same tree ------------------------
# make_tree <doc root> <outside dir>: a doc tree shaped like the measured image,
# with gzip-compressed notices, mixed case, an empty-after directory, Debian's
# directory symlink and odd file names.
make_tree() {
  local r="$1" o="$2"
  mkdir -p "${r}"/{liblerc4,libvo-amrwbenc0,keyboard-configuration,librga2,libsdl2,libfoo1,license-reconcile} \
    "${r}/bar/examples" "${r}/bar/third_party" "${o}"
  printf 'Apache-style NOTICE for a synthetic library\n' >"${r}/liblerc4/NOTICE"
  printf 'Synthetic copyright\n' >"${r}/liblerc4/copyright"
  printf '# readme\n' >"${r}/liblerc4/README.md"
  printf 'changes\n' | gzip -n >"${r}/liblerc4/changelog.Debian.gz"
  printf 'NOTICE text one\n' | gzip -n >"${r}/libvo-amrwbenc0/NOTICE.gz"
  printf 'NOTICE text two\n' | gzip -n >"${r}/libvo-amrwbenc0/NOTICE.amrwbenc.gz"
  printf 'Synthetic copyright\n' >"${r}/libvo-amrwbenc0/copyright"
  printf 'fonts copyright\n' | gzip -n >"${r}/keyboard-configuration/copyright.fonts.gz"
  printf 'xkb copyright\n' | gzip -n >"${r}/keyboard-configuration/copyright.xkb.gz"
  printf 'Synthetic copyright\n' >"${r}/keyboard-configuration/copyright"
  printf 'news\n' | gzip -n >"${r}/keyboard-configuration/NEWS.Debian.gz"
  printf 'GPL-ish synthetic text\n' >"${r}/librga2/COPYING"
  printf 'credits\n' >"${r}/libsdl2/CREDITS.txt"
  printf 'readme\n' >"${r}/libsdl2/README-SDL.txt"
  printf 'authors\n' >"${r}/libfoo1/AUTHORS"
  printf 'authors\n' >"${r}/libfoo1/Authors.md"
  printf 'copyright\n' >"${r}/libfoo1/copyright"
  printf 'readme\n' >"${r}/license-reconcile/README"
  printf 'copyright\n' >"${r}/license-reconcile/copyright"
  printf 'example\n' >"${r}/bar/examples/demo.c"
  printf 'zlib licence\n' >"${r}/bar/third_party/README"
  printf 'notices\n' >"${r}/bar/ThirdPartyNotices.txt"
  printf 'licence\n' >"${r}/bar/License.TXT"
  printf 'spaced notice\n' >"${r}/bar/my NOTICE file"
  printf 'odd\n' >"${r}/bar/weird"$'\n'"name.txt"
  printf 'top readme\n' >"${r}/README"
  chmod 0600 "${r}/bar/License.TXT"
  ln -s libfoo1 "${r}/libfoo1-udeb"
  # A notice-NAMED link to an ordinary doc must not preserve that doc.
  ln -s ../liblerc4/README.md "${r}/bar/NOTICE.link"
  # Links out of the doc root: neither followed nor descended.
  printf 'outside changelog\n' >"${o}/changelog.gz"
  ln -s "${o}" "${r}/bar/outside-dir"
  ln -s "${o}/changelog.gz" "${r}/bar/changelog.gz"
}
expect_kept=(
  liblerc4/NOTICE liblerc4/copyright libvo-amrwbenc0/NOTICE.gz libvo-amrwbenc0/NOTICE.amrwbenc.gz
  libvo-amrwbenc0/copyright keyboard-configuration/copyright.fonts.gz keyboard-configuration/copyright.xkb.gz
  keyboard-configuration/copyright librga2/COPYING libsdl2/CREDITS.txt libfoo1/AUTHORS libfoo1/Authors.md
  libfoo1/copyright license-reconcile/copyright bar/third_party/README bar/ThirdPartyNotices.txt
  bar/License.TXT "bar/my NOTICE file"
)
expect_gone=(
  liblerc4/README.md liblerc4/changelog.Debian.gz keyboard-configuration/NEWS.Debian.gz
  libsdl2/README-SDL.txt license-reconcile/README bar/examples/demo.c bar/examples
  "bar/weird"$'\n'"name.txt" README
)
# snapshot <root>: type, mode, sha256 and relative path of every entry, sorted.
snapshot() {
  (cd "$1" && find . -mindepth 1 -print0 | sort -z | while IFS= read -r -d '' p; do
    if [[ -L "${p}" ]]; then printf 'l %s -> %s\n' "${p}" "$(readlink "${p}")"
    elif [[ -d "${p}" ]]; then printf 'd %s %s\n' "$(stat -c %a "${p}")" "${p}"
    else printf 'f %s %s %s\n' "$(stat -c %a "${p}")" "$(sha256sum <"${p}" | cut -d' ' -f1)" "${p}"; fi
  done)
}
check_result() { # <label> <doc root> <before snapshot> <outside dir> <outside snapshot>
  local label="$1" r="$2" before="$3" o="$4" o_before="$5" rel line all=1
  for rel in "${expect_kept[@]}"; do
    line="$(grep -F " ./${rel}" "${before}" | head -n 1)"
    if [[ -z "${line}" ]] || ! grep -Fxq -- "${line}" <(snapshot "${r}"); then
      bad "${label}: ${rel} not kept byte for byte with its mode"; all=0
    fi
  done
  (( all )) && ok "${label}: ${#expect_kept[@]} notice files keep their bytes and modes"
  all=1
  for rel in "${expect_gone[@]}"; do
    [[ ! -e "${r}/${rel}" ]] || { bad "${label}: ordinary doc ${rel} survived"; all=0; }
  done
  (( all )) && ok "${label}: changelogs, READMEs, examples and odd names are removed"
  [[ -L "${r}/libfoo1-udeb" && "$(readlink "${r}/libfoo1-udeb")" == libfoo1 ]] \
    && ok "${label}: Debian's directory symlink is kept" || bad "${label}: directory symlink lost"
  [[ -L "${r}/bar/NOTICE.link" && ! -e "${r}/liblerc4/README.md" ]] \
    && ok "${label}: a notice-named symlink does not preserve the document it points at" \
    || bad "${label}: a symlink decided the fate of its target"
  [[ "$(snapshot "${o}")" == "$(cat "${o_before}")" ]] \
    && ok "${label}: nothing outside the doc root changed" || bad "${label}: bytes outside the doc root changed"
}

APP_ROOT="${WORK}/app/doc" APP_OUT="${WORK}/app/outside"
DEV_ROOT="${WORK}/dev/doc" DEV_OUT="${WORK}/dev/outside"
make_tree "${APP_ROOT}" "${APP_OUT}"
make_tree "${DEV_ROOT}" "${DEV_OUT}"
snapshot "${APP_ROOT}" >"${WORK}/app.before"; snapshot "${APP_OUT}" >"${WORK}/app.out"
snapshot "${DEV_ROOT}" >"${WORK}/dev.before"; snapshot "${DEV_OUT}" >"${WORK}/dev.out"

if SRCDIR="${MKOSI_DIR}" CERALIVE_DOC_ROOT="${APP_ROOT}" CERALIVE_PRUNE_PATHS_LIST="${WORK}/absent.list" \
    bash -c 'source "$1"; prune_package_docs' bash "${APP_POSTINST}" >"${WORK}/app.log" 2>&1; then
  ok 'build: prune_package_docs succeeds'
else
  bad "build: prune_package_docs failed: $(cat "${WORK}/app.log")"
fi
check_result build "${APP_ROOT}" "${WORK}/app.before" "${APP_OUT}" "${WORK}/app.out"

CERALIVE_DOC_ROOT="${DEV_ROOT}" CERALIVE_PRUNE_PATHS_LIST="${WORK}/absent.list" CERALIVE_DOC_POLICY="${POLICY}" \
  "${REPRUNE}" >"${WORK}/dev.log" 2>&1
assert_eq 'device: ceralive-reprune exits 0' 0 "$?"
check_result device "${DEV_ROOT}" "${WORK}/dev.before" "${DEV_OUT}" "${WORK}/dev.out"

# Parity: the two consumers leave the same tree (modulo the outside-link target,
# which differs only by fixture directory).
normalise() { snapshot "$1" | sed "s|$2|OUTSIDE|g"; }
if [[ "$(normalise "${APP_ROOT}" "${APP_OUT}")" == "$(normalise "${DEV_ROOT}" "${DEV_OUT}")" ]]; then
  ok 'build and device prunes leave identical doc trees'
else
  bad 'build and device prunes disagree'
  diff <(normalise "${APP_ROOT}" "${APP_OUT}") <(normalise "${DEV_ROOT}" "${DEV_OUT}") | head -20
fi
# One policy file, sourced by both; neither carries its own rule any more.
if grep -Eq 'find .*-name copyright|! -name copyright' "${APP_POSTINST}" "${REPRUNE}"; then
  bad 'a consumer still carries its own copyright-only find rule'
else
  ok 'neither consumer carries a private copy of the doc rule'
fi
grep -Fq '/runtime/doc-notice-policy.sh"' "${APP_POSTINST}" \
  && ok 'the app layer sources runtime/doc-notice-policy.sh' || bad 'the app layer does not source the shared policy'

# --- Part C: unsafe roots ----------------------------------------------------
target="${WORK}/link-target"
mkdir -p "${target}/pkg"
printf 'must survive\n' >"${target}/pkg/changelog.gz"
ln -s "${target}" "${WORK}/linked-doc"
if SRCDIR="${MKOSI_DIR}" CERALIVE_DOC_ROOT="${WORK}/linked-doc" CERALIVE_PRUNE_PATHS_LIST="${WORK}/absent.list" \
    bash -c 'source "$1"; prune_package_docs' bash "${APP_POSTINST}" >"${WORK}/c1.log" 2>&1; then
  bad 'build: a symlinked doc root was accepted'
else
  grep -q 'refusing symlinked doc root' "${WORK}/c1.log" \
    && ok 'build: a symlinked doc root fails the build' || bad "build: unexpected failure: $(cat "${WORK}/c1.log")"
fi
out="$(CERALIVE_DOC_ROOT="${WORK}/linked-doc" CERALIVE_PRUNE_PATHS_LIST="${WORK}/absent.list" \
  CERALIVE_DOC_POLICY="${POLICY}" "${REPRUNE}" 2>&1)"
assert_eq 'device: a symlinked doc root still exits 0' 0 "$?"
assert_contains_text() { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1 (got: $2)"; }
assert_contains_text 'device: a symlinked doc root is logged as skipped' "${out}" 'unsafe doc root'
[[ "$(cat "${target}/pkg/changelog.gz")" == 'must survive' ]] \
  && ok 'a symlinked doc root leads no delete to its target' || bad 'the symlink target was pruned'

mkdir -p "${WORK}/cwd/pkg"
printf 'keep\n' >"${WORK}/cwd/pkg/changelog.gz"
# shellcheck source=mkosi/runtime/doc-notice-policy.sh
( cd "${WORK}/cwd" && source "${POLICY}" && doc_notice_prune pkg ) >/dev/null 2>&1
assert_eq 'a relative doc root is refused' 2 "$?"
[[ -f "${WORK}/cwd/pkg/changelog.gz" ]] && ok 'a refused relative root is left untouched' || bad 'relative root pruned'

# --- Part D: a file that cannot be removed -----------------------------------
if [[ "$(id -u)" -eq 0 ]]; then
  echo 'doc-notice-prune: running as root, unremovable-file leg skipped'
else
  for side in build device; do
    r="${WORK}/ro-${side}/doc"
    mkdir -p "${r}/pkg"
    printf 'readme\n' >"${r}/pkg/README"
    printf 'notice\n' >"${r}/pkg/NOTICE"
    chmod 0555 "${r}/pkg"
  done
  if SRCDIR="${MKOSI_DIR}" CERALIVE_DOC_ROOT="${WORK}/ro-build/doc" CERALIVE_PRUNE_PATHS_LIST="${WORK}/absent.list" \
      bash -c 'source "$1"; prune_package_docs' bash "${APP_POSTINST}" >"${WORK}/d1.log" 2>&1; then
    bad 'build: an unremovable doc file did not fail the build'
  else
    grep -q 'could not prune' "${WORK}/d1.log" \
      && ok 'build: an unremovable doc file fails the build' || bad "build: unexpected output: $(cat "${WORK}/d1.log")"
  fi
  out="$(CERALIVE_DOC_ROOT="${WORK}/ro-device/doc" CERALIVE_PRUNE_PATHS_LIST="${WORK}/absent.list" \
    CERALIVE_DOC_POLICY="${POLICY}" "${REPRUNE}" 2>&1)"
  assert_eq 'device: an unremovable doc file still exits 0' 0 "$?"
  assert_contains_text 'device: the unremovable file is logged' "${out}" 'could not be removed (non-fatal)'
  [[ -f "${WORK}/ro-device/doc/pkg/NOTICE" ]] && ok 'device: the notice survives a partial failure' \
    || bad 'device: notice lost on partial failure'
fi

[[ "${FAIL}" -eq 0 ]]

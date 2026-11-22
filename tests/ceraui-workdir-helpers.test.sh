#!/usr/bin/env bash
#
# ceraui-workdir-helpers.test.sh — CeraUI's captive-portal helper stays reachable
# through the /data/ceralive bind over /opt/ceralive.
#
# THE BUG. The CeraUI .deb installs captive-portal-window.py in /opt/ceralive and
# the backend runs it as `python3 -I /opt/ceralive/captive-portal-window.py`
# (its WorkingDirectory). On the device /data/ceralive is bind-mounted over
# /opt/ceralive, and ceralive-migrate-data seeded only *.json, revision and the
# public link onto /data. The helper was hidden on every booted box: CeraUI logged
# "portal-reconcile failed" at each start and the setup-hotspot sign-in window
# could never open.
#
# THE FIX. The app layer keeps a copy outside the bind
# (keep_ceraui_workdir_helpers -> /usr/libexec/ceralive/ceraui-workdir/), and
# ceralive-migrate-data links /data/ceralive/<name> to it on every boot, so the
# helper also follows OTAs. Absent and dangling entries are (re)linked.
#
# THE SECOND BUG. A regular file there was always left alone, on the theory that
# only a later CeraUI package upgrade writes one. After an image 4 -> 5 RAUC
# update the file was image 4's CeraUI copy (written through the bind by an
# earlier package upgrade), so image 5's CeraUI ran image 4's helper and the
# captive-portal fix the update carried never took effect. Now, when the kept
# copy matches the installed ceralive-device's md5sums entry, any entry but a
# real directory is replaced by the link; otherwise a regular file still stays
# (an in-place upgrade on this slot wrote it).
#
# Part A — the app layer keeps the copy (sourced function, synthetic root).
# Part B — the migrate-data block, extracted verbatim and run on synthetic trees.
# Part C — the two halves name the same directory.
#
# shellcheck disable=SC2016

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
APP_POSTINST="${PIPELINE_DIR}/mkosi/mkosi.images/app/mkosi.postinst.chroot"
PERSISTENCE="${PIPELINE_DIR}/mkosi/customize/postinst.d/persistence.sh"
HELPER=captive-portal-window.py
HELPERS_REL=usr/libexec/ceralive/ceraui-workdir

fail() { printf 'ceraui-workdir-helpers regression: %s\n' "$1" >&2; exit 1; }

[[ -f "${APP_POSTINST}" ]] || fail "missing app postinst: ${APP_POSTINST}"
[[ -f "${PERSISTENCE}" ]] || fail "missing persistence module: ${PERSISTENCE}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ceraui-workdir-helpers.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

# dpkg-query stub: --control-show ceralive-device md5sums prints $STUB_MD5SUMS
# (the installed instance's md5sums) and fails when it is unset or missing, as
# for a package that is not installed or not one instance. Anything else fails.
mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/dpkg-query" <<'STUB'
#!/usr/bin/env bash
[[ " $* " == *" --control-show ceralive-device md5sums "* && -f "${STUB_MD5SUMS:-}" ]] || exit 1
exec cat "${STUB_MD5SUMS}"
STUB
chmod +x "${TMP}/bin/dpkg-query"

# ---------------------------------------------------------------------------
# Part A — app layer
# ---------------------------------------------------------------------------
# Sourcing leaves main unrun (BASH_SOURCE guard), so nothing on the host changes.
run_keep() { # $1=root
  bash -c 'set -euo pipefail; source "$1"; keep_ceraui_workdir_helpers "$2"' _ "${APP_POSTINST}" "$1" 2>"${TMP}/keep.log"
}

A1="${TMP}/a1"; mkdir -p "${A1}/opt/ceralive"
printf '#!/usr/bin/env python3\nprint("portal")\n' >"${A1}/opt/ceralive/${HELPER}"
chmod 0644 "${A1}/opt/ceralive/${HELPER}"
run_keep "${A1}" || fail "A1: keep_ceraui_workdir_helpers failed: $(<"${TMP}/keep.log")"
[[ -f "${A1}/${HELPERS_REL}/${HELPER}" ]] \
  || fail "A1: no image copy at /${HELPERS_REL}/${HELPER}"
cmp -s "${A1}/opt/ceralive/${HELPER}" "${A1}/${HELPERS_REL}/${HELPER}" \
  || fail "A1: the image copy differs from the .deb's file"
[[ "$(stat -c '%a' "${A1}/${HELPERS_REL}/${HELPER}")" == 755 ]] \
  || fail "A1: the image copy is mode $(stat -c '%a' "${A1}/${HELPERS_REL}/${HELPER}"), expected 755"
[[ -f "${A1}/opt/ceralive/${HELPER}" ]] \
  || fail "A1: the .deb's own file was moved; dpkg would report it missing"
echo "ceraui-workdir-helpers: A1 app layer keeps the copy OK"

# A CeraUI without the helper is not an error and leaves no copy behind.
A2="${TMP}/a2"; mkdir -p "${A2}/opt/ceralive"
run_keep "${A2}" || fail "A2: a .deb without the helper failed the layer: $(<"${TMP}/keep.log")"
[[ ! -e "${A2}/${HELPERS_REL}/${HELPER}" ]] || fail "A2: copy created without a source"
echo "ceraui-workdir-helpers: A2 no helper, no copy OK"

# ---------------------------------------------------------------------------
# Part B — the migrate-data block
# ---------------------------------------------------------------------------
block="$(awk '
  index($0, "if [ -d \"$WORKDIR\" ] && ! mountpoint -q \"$WORKDIR\"; then") { f=1 }
  f { print }
  f && $0 ~ /^fi$/ { exit }
' "${PERSISTENCE}")"
[[ -n "${block}" ]] || fail "could not extract the WORKDIR seeding block from ${PERSISTENCE}"
grep -Fq '"$CERAUI_HELPERS"/*' <<<"${block}" \
  || fail "the WORKDIR block no longer links the CeraUI working-dir helpers"

run_block() { # $1=DATA $2=WORKDIR $3=CERAUI_HELPERS
  local runner="${TMP}/runner.sh"
  {
    echo 'set -euo pipefail'
    echo 'mountpoint() { return 1; }'
    echo 'log() { :; }'
    printf 'DATA=%q\nWORKDIR=%q\nCERAUI_HELPERS=%q\n' "$1" "$2" "$3"
    printf '%s\n' "${RUN_PRELUDE:-}"
    printf '%s\n' "${block}"
    # The rest of ceralive-migrate-data (and the binds that need it) runs on.
    printf 'echo continued >%q\n' "$1/.migrate-continued"
  } >"${runner}"
  PATH="${TMP}/bin:${PATH}" bash "${runner}"
}

# A box tree: rootfs /opt/ceralive as the .deb leaves it, the app layer's copy,
# and an empty /data.
new_box() { # $1=dir
  mkdir -p "$1/opt/ceralive" "$1/data/ceralive" "$1/${HELPERS_REL}"
  printf '{"engine":"cerastream"}\n' >"$1/opt/ceralive/setup.json"
  printf 'deadbeef\n' >"$1/opt/ceralive/revision"
  printf 'print("image helper")\n' >"$1/opt/ceralive/${HELPER}"
  install -m 0755 "$1/opt/ceralive/${HELPER}" "$1/${HELPERS_REL}/${HELPER}"
}

# B1: first boot links the helper, and it resolves to the image copy.
B1="${TMP}/b1"; new_box "${B1}"
run_block "${B1}/data" "${B1}/opt/ceralive" "${B1}/${HELPERS_REL}"
[[ -L "${B1}/data/ceralive/${HELPER}" ]] \
  || fail "B1: /data/ceralive/${HELPER} is not a link; the bind would hide the helper"
[[ "$(readlink "${B1}/data/ceralive/${HELPER}")" == "${B1}/${HELPERS_REL}/${HELPER}" ]] \
  || fail "B1: link points at $(readlink "${B1}/data/ceralive/${HELPER}")"
# What CeraUI runs after the bind: /opt/ceralive is now /data/ceralive.
[[ "$(python3 -I "${B1}/data/ceralive/${HELPER}")" == "image helper" ]] \
  || fail "B1: python3 -I on the bound path does not run the image helper"
[[ -f "${B1}/data/ceralive/setup.json" && -f "${B1}/data/ceralive/revision" ]] \
  || fail "B1: the existing *.json/revision seeding regressed"
echo "ceraui-workdir-helpers: B1 first boot links the helper OK"

# B2: every later boot is a no-op.
run_block "${B1}/data" "${B1}/opt/ceralive" "${B1}/${HELPERS_REL}"
run_block "${B1}/data" "${B1}/opt/ceralive" "${B1}/${HELPERS_REL}"
[[ "$(readlink "${B1}/data/ceralive/${HELPER}")" == "${B1}/${HELPERS_REL}/${HELPER}" ]] \
  || fail "B2: a re-run changed the link"
echo "ceraui-workdir-helpers: B2 re-run is a no-op OK"

# B3: a box that was seeded by an older image (no helper on /data) gets the link
# on the first boot after the OTA, and an OTA'd helper is what runs.
B3="${TMP}/b3"; new_box "${B3}"
printf '{"engine":"cerastream"}\n' >"${B3}/data/ceralive/setup.json"
printf 'oldbuild\n' >"${B3}/data/ceralive/revision"
printf 'print("ota helper")\n' >"${B3}/${HELPERS_REL}/${HELPER}"
run_block "${B3}/data" "${B3}/opt/ceralive" "${B3}/${HELPERS_REL}"
[[ "$(python3 -I "${B3}/data/ceralive/${HELPER}")" == "ota helper" ]] \
  || fail "B3: a box seeded by an older image does not run the current slot's helper"
[[ "$(<"${B3}/data/ceralive/revision")" == oldbuild ]] \
  || fail "B3: an existing /data entry was overwritten"
echo "ceraui-workdir-helpers: B3 older /data gets the link OK"

# B4: a dangling link (an image that kept the helper elsewhere) is replaced.
B4="${TMP}/b4"; new_box "${B4}"
ln -s /nonexistent/old-place/${HELPER} "${B4}/data/ceralive/${HELPER}"
run_block "${B4}/data" "${B4}/opt/ceralive" "${B4}/${HELPERS_REL}"
[[ "$(readlink "${B4}/data/ceralive/${HELPER}")" == "${B4}/${HELPERS_REL}/${HELPER}" ]] \
  || fail "B4: a dangling link was not replaced"
echo "ceraui-workdir-helpers: B4 dangling link relinked OK"

# B5: a regular file is left alone when dpkg has no md5sums for the package (it
# cannot tell whose file it is).
B5="${TMP}/b5"; new_box "${B5}"
printf 'print("package helper")\n' >"${B5}/data/ceralive/${HELPER}"
run_block "${B5}/data" "${B5}/opt/ceralive" "${B5}/${HELPERS_REL}"
[[ -f "${B5}/data/ceralive/${HELPER}" && ! -L "${B5}/data/ceralive/${HELPER}" ]] \
  || fail "B5: a package-written helper was replaced"
[[ "$(python3 -I "${B5}/data/ceralive/${HELPER}")" == "package helper" ]] \
  || fail "B5: a package-written helper was changed"
echo "ceraui-workdir-helpers: B5 package file kept OK"

# B6: an image without any kept helper (dev build without CeraUI) links nothing.
B6="${TMP}/b6"; new_box "${B6}"
rm -f "${B6}/${HELPERS_REL}/${HELPER}"
run_block "${B6}/data" "${B6}/opt/ceralive" "${B6}/${HELPERS_REL}"
run_block "${B6}/data" "${B6}/opt/ceralive" "${B6}/missing-dir"
[[ ! -e "${B6}/data/ceralive/${HELPER}" && ! -L "${B6}/data/ceralive/${HELPER}" ]] \
  || fail "B6: a link was created without an image copy"
[[ ! -e "${B6}/data/ceralive/*" ]] || fail "B6: an unmatched glob became a /data entry"
echo "ceraui-workdir-helpers: B6 nothing kept, nothing linked OK"

# B7: the dangling link cannot be removed. Logged, skipped, migration goes on.
B7="${TMP}/b7"; new_box "${B7}"
ln -s /nonexistent/old-place/${HELPER} "${B7}/data/ceralive/${HELPER}"
RUN_PRELUDE='rm() { return 1; }' run_block "${B7}/data" "${B7}/opt/ceralive" "${B7}/${HELPERS_REL}" \
  || fail "B7: a failed unlink failed ceralive-migrate-data (every bind would stop)"
[[ -f "${B7}/data/.migrate-continued" ]] || fail "B7: migration stopped after a failed unlink"
[[ "$(readlink "${B7}/data/ceralive/${HELPER}")" == /nonexistent/old-place/${HELPER} ]] \
  || fail "B7: the entry changed although it could not be removed"
echo "ceraui-workdir-helpers: B7 a failed unlink is non-fatal OK"

# B8: the link cannot be created. Logged, migration goes on.
B8="${TMP}/b8"; new_box "${B8}"
RUN_PRELUDE='ln() { return 1; }' run_block "${B8}/data" "${B8}/opt/ceralive" "${B8}/${HELPERS_REL}" \
  || fail "B8: a failed link failed ceralive-migrate-data (every bind would stop)"
[[ -f "${B8}/data/.migrate-continued" ]] || fail "B8: migration stopped after a failed link"
[[ ! -e "${B8}/data/ceralive/${HELPER}" && ! -L "${B8}/data/ceralive/${HELPER}" ]] \
  || fail "B8: an entry appeared although ln failed"
[[ -f "${B8}/data/ceralive/setup.json" ]] || fail "B8: the *.json seeding regressed"
echo "ceraui-workdir-helpers: B8 a failed link is non-fatal OK"

# B9: a directory in the way (ln -sT must not create the link inside it).
B9="${TMP}/b9"; new_box "${B9}"
mkdir -p "${B9}/data/ceralive/${HELPER}"
run_block "${B9}/data" "${B9}/opt/ceralive" "${B9}/${HELPERS_REL}" \
  || fail "B9: a directory in the way failed ceralive-migrate-data"
[[ -d "${B9}/data/ceralive/${HELPER}" && -z "$(ls -A "${B9}/data/ceralive/${HELPER}")" ]] \
  || fail "B9: something was written into a directory in the way"
echo "ceraui-workdir-helpers: B9 a directory in the way is left alone OK"

# ---------------------------------------------------------------------------
# Part B, continued — the installed package's md5sums decide about the rest
# ---------------------------------------------------------------------------
md5_of() { md5sum <"$1" | awk '{print $1}'; }
# The installed ceralive-device's md5sums, as dpkg keeps them: $2 is the file
# whose bytes the package's helper entry has; more lines follow it.
pkg_sums() { # $1=box $2=file-with-package-bytes
  printf '%s  opt/ceralive/setup.json\n%s  opt/ceralive/%s\n%s  usr/local/bin/ceralive\n' \
    "$(printf x | md5sum | awk '{print $1}')" "$(md5_of "$2")" "${HELPER}" \
    "$(printf y | md5sum | awk '{print $1}')" >"$1/ceralive-device.md5sums"
}
assert_linked() { # $1=box $2=label
  [[ -L "$1/data/ceralive/${HELPER}" ]] || fail "$2: /data/ceralive/${HELPER} is not a link"
  [[ "$(readlink "$1/data/ceralive/${HELPER}")" == "$1/${HELPERS_REL}/${HELPER}" ]] \
    || fail "$2: the link points at $(readlink "$1/data/ceralive/${HELPER}")"
  [[ "$(python3 -I "$1/data/ceralive/${HELPER}")" == "image helper" ]] \
    || fail "$2: the bound path does not run this slot's helper"
  [[ ! -e "$1/data/ceralive/${HELPER}.helper-link" && ! -L "$1/data/ceralive/${HELPER}.helper-link" ]] \
    || fail "$2: a temporary link was left behind"
}
# A box whose installed package is the one this slot's image was built with.
slot_box() { # $1=dir
  new_box "$1"
  pkg_sums "$1" "$1/${HELPERS_REL}/${HELPER}"
}

# M1: the 4 -> 5 OTA case. /data holds an older CeraUI's helper as a regular
# file; the installed package is this slot's, so the stale file gives way.
M1="${TMP}/m1"; slot_box "${M1}"
printf 'print("image 4 helper")\n' >"${M1}/data/ceralive/${HELPER}"
STUB_MD5SUMS="${M1}/ceralive-device.md5sums" run_block "${M1}/data" "${M1}/opt/ceralive" "${M1}/${HELPERS_REL}"
assert_linked "${M1}" M1
[[ -f "${M1}/data/.migrate-continued" ]] || fail "M1: migration did not go on"
# ...and every later boot is a no-op.
STUB_MD5SUMS="${M1}/ceralive-device.md5sums" run_block "${M1}/data" "${M1}/opt/ceralive" "${M1}/${HELPERS_REL}"
assert_linked "${M1}" M1-rerun
echo "ceraui-workdir-helpers: M1 stale regular file after an OTA is replaced OK"

# M2: a regular file with the package's own bytes becomes the link too, so the
# next OTA cannot leave it behind.
M2="${TMP}/m2"; slot_box "${M2}"
cp "${M2}/${HELPERS_REL}/${HELPER}" "${M2}/data/ceralive/${HELPER}"
STUB_MD5SUMS="${M2}/ceralive-device.md5sums" run_block "${M2}/data" "${M2}/opt/ceralive" "${M2}/${HELPERS_REL}"
assert_linked "${M2}" M2
echo "ceraui-workdir-helpers: M2 matching regular file becomes the link OK"

# M3: absent and dangling entries are linked with md5sums present as well.
M3="${TMP}/m3"; slot_box "${M3}"
STUB_MD5SUMS="${M3}/ceralive-device.md5sums" run_block "${M3}/data" "${M3}/opt/ceralive" "${M3}/${HELPERS_REL}"
assert_linked "${M3}" M3-absent
M3b="${TMP}/m3b"; slot_box "${M3b}"
ln -s /nonexistent/old-place/${HELPER} "${M3b}/data/ceralive/${HELPER}"
STUB_MD5SUMS="${M3b}/ceralive-device.md5sums" run_block "${M3b}/data" "${M3b}/opt/ceralive" "${M3b}/${HELPERS_REL}"
assert_linked "${M3b}" M3-dangling
echo "ceraui-workdir-helpers: M3 absent and dangling entries linked OK"

# M4: an in-place CeraUI upgrade on this slot wrote a newer helper through the
# bind. The installed package's entry names that file, not the kept copy, so
# the file stays.
M4="${TMP}/m4"; new_box "${M4}"
printf 'print("newer package helper")\n' >"${M4}/data/ceralive/${HELPER}"
pkg_sums "${M4}" "${M4}/data/ceralive/${HELPER}"
STUB_MD5SUMS="${M4}/ceralive-device.md5sums" run_block "${M4}/data" "${M4}/opt/ceralive" "${M4}/${HELPERS_REL}"
[[ -f "${M4}/data/ceralive/${HELPER}" && ! -L "${M4}/data/ceralive/${HELPER}" ]] \
  || fail "M4: the newer package's helper was replaced"
[[ "$(python3 -I "${M4}/data/ceralive/${HELPER}")" == "newer package helper" ]] \
  || fail "M4: the newer package's helper was changed"
# Without a helper on /data at all, that slot still gets the kept copy rather
# than nothing (the pre-existing absent rule).
rm -f "${M4}/data/ceralive/${HELPER}"
STUB_MD5SUMS="${M4}/ceralive-device.md5sums" run_block "${M4}/data" "${M4}/opt/ceralive" "${M4}/${HELPERS_REL}"
[[ "$(readlink "${M4}/data/ceralive/${HELPER}")" == "${M4}/${HELPERS_REL}/${HELPER}" ]] \
  || fail "M4: an absent helper was not linked after an in-place upgrade"
echo "ceraui-workdir-helpers: M4 newer package's regular file kept OK"

# M5: no single valid entry for the helper (absent, duplicated, or the package
# ships none) keeps the old rule: a regular file stays.
for variant in none dup; do
  M5="${TMP}/m5-${variant}"; slot_box "${M5}"
  case "${variant}" in
    none) grep -Fv "opt/ceralive/${HELPER}" "${M5}/ceralive-device.md5sums" >"${M5}/s" ;;
    dup)  { cat "${M5}/ceralive-device.md5sums"; grep -F "opt/ceralive/${HELPER}" "${M5}/ceralive-device.md5sums"; } >"${M5}/s" ;;
  esac
  mv "${M5}/s" "${M5}/ceralive-device.md5sums"
  printf 'print("image 4 helper")\n' >"${M5}/data/ceralive/${HELPER}"
  STUB_MD5SUMS="${M5}/ceralive-device.md5sums" run_block "${M5}/data" "${M5}/opt/ceralive" "${M5}/${HELPERS_REL}"
  [[ -f "${M5}/data/ceralive/${HELPER}" && ! -L "${M5}/data/ceralive/${HELPER}" ]] \
    || fail "M5-${variant}: a regular file was replaced without one valid md5sums entry"
done
echo "ceraui-workdir-helpers: M5 no single entry, regular file kept OK"

# M6: a link to some other existing file gives way to this slot's copy.
M6="${TMP}/m6"; slot_box "${M6}"
printf 'print("elsewhere")\n' >"${M6}/elsewhere.py"
ln -s "${M6}/elsewhere.py" "${M6}/data/ceralive/${HELPER}"
STUB_MD5SUMS="${M6}/ceralive-device.md5sums" run_block "${M6}/data" "${M6}/opt/ceralive" "${M6}/${HELPERS_REL}"
assert_linked "${M6}" M6
[[ "$(<"${M6}/elsewhere.py")" == 'print("elsewhere")' ]] || fail "M6: the old link's target was written"
echo "ceraui-workdir-helpers: M6 foreign link replaced OK"

# M7: a real directory in the way is never touched.
M7="${TMP}/m7"; slot_box "${M7}"
mkdir -p "${M7}/data/ceralive/${HELPER}"
STUB_MD5SUMS="${M7}/ceralive-device.md5sums" run_block "${M7}/data" "${M7}/opt/ceralive" "${M7}/${HELPERS_REL}" \
  || fail "M7: a directory in the way failed ceralive-migrate-data"
[[ -d "${M7}/data/ceralive/${HELPER}" && ! -L "${M7}/data/ceralive/${HELPER}" \
   && -z "$(ls -A "${M7}/data/ceralive/${HELPER}")" ]] || fail "M7: a directory in the way was changed"
echo "ceraui-workdir-helpers: M7 a directory in the way is left alone OK"

# M8: the replacement fails (mv cannot rename). Logged, the stale file stays,
# no temporary link is left, and the migration goes on.
M8="${TMP}/m8"; slot_box "${M8}"
printf 'print("image 4 helper")\n' >"${M8}/data/ceralive/${HELPER}"
STUB_MD5SUMS="${M8}/ceralive-device.md5sums" RUN_PRELUDE='mv() { return 1; }' \
  run_block "${M8}/data" "${M8}/opt/ceralive" "${M8}/${HELPERS_REL}" \
  || fail "M8: a failed replacement failed ceralive-migrate-data (every bind would stop)"
[[ -f "${M8}/data/.migrate-continued" ]] || fail "M8: migration stopped after a failed replacement"
[[ "$(python3 -I "${M8}/data/ceralive/${HELPER}")" == "image 4 helper" ]] \
  || fail "M8: the entry changed although the rename failed"
[[ ! -e "${M8}/data/ceralive/${HELPER}.helper-link" && ! -L "${M8}/data/ceralive/${HELPER}.helper-link" ]] \
  || fail "M8: the temporary link was left behind"
echo "ceraui-workdir-helpers: M8 a failed replacement is non-fatal OK"

# M9: the replacement is a rename, so the entry is never absent in between.
grep -Fq 'mv -fT -- "$dest.helper-link" "$dest"' <<<"${block}" \
  || fail "M9: the stale helper is no longer replaced by an atomic rename"
echo "ceraui-workdir-helpers: M9 atomic replacement OK"

# ---------------------------------------------------------------------------
# Part C — both halves name the same directory
# ---------------------------------------------------------------------------
grep -Fq "CERAUI_WORKDIR_HELPERS_DIR=\"/${HELPERS_REL}\"" "${APP_POSTINST}" \
  || fail "C: the app layer no longer keeps helpers in /${HELPERS_REL}"
grep -Fq "local ceraui_helpers=\"/${HELPERS_REL}\"" "${PERSISTENCE}" \
  || fail "C: ceralive-migrate-data no longer links from /${HELPERS_REL}"
grep -Fq 'CERAUI_HELPERS="${ceraui_helpers}"' "${PERSISTENCE}" \
  || fail "C: the generated ceralive-migrate-data does not carry CERAUI_HELPERS"
grep -Eq "^CERAUI_WORKDIR_HELPERS=\(.*\b${HELPER//./\\.}\b.*\)" "${APP_POSTINST}" \
  || fail "C: ${HELPER} is no longer in the app layer's helper list"
echo "ceraui-workdir-helpers: C shared directory OK"

echo "ceraui-workdir-helpers regression: PASS"

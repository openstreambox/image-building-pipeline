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
# copy matches the installed ceralive-device's md5sums record, any entry but a
# real directory is replaced by the link (a replaced regular file with other
# bytes is kept as .<name>.pre-link.<md5> for a rollback to an image without a
# kept copy, written first under that final no-clobber name); otherwise a
# regular file still stays (an in-place upgrade on this slot wrote it), logged.
# The block acts only in a $DATA/ceralive no other user can write or swap, and
# swaps by renaming a fresh no-clobber symlink over the entry.
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

# CERAUI_HELPERS_KEEP_GOING=1 reports every failing case instead of the first
# (used to show which cases fail on an older persistence.sh).
FAILED=0
fail() {
  printf 'ceraui-workdir-helpers regression: %s\n' "$1" >&2
  [[ "${CERAUI_HELPERS_KEEP_GOING:-}" == 1 ]] || exit 1
  FAILED=$((FAILED + 1))
}

[[ -f "${APP_POSTINST}" ]] || fail "missing app postinst: ${APP_POSTINST}"
[[ -f "${PERSISTENCE}" ]] || fail "missing persistence module: ${PERSISTENCE}"

# Canonical, so the symlinked-parent guard sees only the parents a case plants.
TMP="$(realpath -e -- "$(mktemp -d "${TMPDIR:-/tmp}/ceraui-workdir-helpers.XXXXXX")")"
trap 'rm -rf "${TMP}"' EXIT

# dpkg-query stub: --control-show ceralive-device md5sums prints $STUB_MD5SUMS
# (the installed instance's md5sums) and fails when it is unset or missing, as
# for a package that is not installed or not one instance. Anything else fails.
# STUB_DPKG_FAIL=1 prints the file and still exits 1 (output of a failed query).
mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/dpkg-query" <<'STUB'
#!/usr/bin/env bash
[[ " $* " == *" --control-show ceralive-device md5sums "* && -f "${STUB_MD5SUMS:-}" ]] || exit 1
cat "${STUB_MD5SUMS}"
[[ -z "${STUB_DPKG_FAIL:-}" ]] || exit 1
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
    # Every log line of the block lands next to the box, for the log checks.
    printf 'log() { printf "%%s\\n" "$*" >>%q; }\n' "$1/.migrate.log"
    printf 'DATA=%q\nWORKDIR=%q\nCERAUI_HELPERS=%q\n' "$1" "$2" "$3"
    printf '%s\n' "${RUN_PRELUDE:-}"
    printf '%s\n' "${block}"
    # The rest of ceralive-migrate-data (and the binds that need it) runs on.
    printf 'echo continued >%q\n' "$1/.migrate-continued"
  } >"${runner}"
  PATH="${TMP}/bin:${PATH}" bash "${runner}"
}

no_stage() { # $1=box $2=label
  local left
  left="$(find "$1/data/ceralive" -maxdepth 1 -name ".${HELPER}.link-*" -print -quit)"
  [[ -z "${left}" ]] || fail "$2: a temporary link was left behind: ${left}"
}
assert_kept_regular() { # $1=box $2=label $3=expected output
  [[ -f "$1/data/ceralive/${HELPER}" && ! -L "$1/data/ceralive/${HELPER}" ]] \
    || fail "$2: the regular file was replaced"
  [[ "$(python3 -I "$1/data/ceralive/${HELPER}")" == "$3" ]] || fail "$2: the regular file was changed"
}
assert_logged() { # $1=box $2=label $3=fixed string
  grep -Fq -- "$3" "$1/data/.migrate.log" 2>/dev/null || fail "$2: no log line containing: $3"
}

# A box tree: rootfs /opt/ceralive as the .deb leaves it, the app layer's copy,
# and an empty /data.
new_box() { # $1=dir
  mkdir -p "$1/opt/ceralive" "$1/data/ceralive" "$1/${HELPERS_REL}"
  # Explicit modes: the guard refuses a group-writable /data, whatever the umask.
  chmod 0755 "$1" "$1/data" "$1/data/ceralive"
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
assert_logged "${B5}" B5 "keeping the regular file ${B5}/data/ceralive/${HELPER}: dpkg-query has no md5sums"
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
  no_stage "$1" "$2"
}
# A box whose installed package is the one this slot's image was built with.
slot_box() { # $1=dir
  new_box "$1"
  pkg_sums "$1" "$1/${HELPERS_REL}/${HELPER}"
}

# M1: the update case. /data holds an older CeraUI's helper as a regular
# file; the installed package is this slot's, so the stale file gives way.
M1="${TMP}/m1"; slot_box "${M1}"
printf 'print("image 4 helper")\n' >"${M1}/data/ceralive/${HELPER}"
STUB_MD5SUMS="${M1}/ceralive-device.md5sums" run_block "${M1}/data" "${M1}/opt/ceralive" "${M1}/${HELPERS_REL}"
assert_linked "${M1}" M1
[[ -f "${M1}/data/.migrate-continued" ]] || fail "M1: migration did not go on"
# The replaced file is kept for a rollback to an image without a kept copy,
# under the md5 that image's package records for it.
m1_kept="${M1}/data/ceralive/.${HELPER}.pre-link.$(printf 'print("image 4 helper")\n' | md5sum | awk '{print $1}')"
[[ -f "${m1_kept}" && ! -L "${m1_kept}" ]] || fail "M1: the replaced regular file was not kept as ${m1_kept##*/}"
[[ "$(python3 -I "${m1_kept}")" == "image 4 helper" ]] || fail "M1: ${m1_kept##*/} does not hold the replaced file"
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
assert_logged "${M4}" M4 "keeping the regular file ${M4}/data/ceralive/${HELPER}: the image copy"
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
  assert_logged "${M5}" "M5-${variant}" "has no single md5sums record for opt/ceralive/${HELPER}"
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
# the temporary link is removed, and the migration goes on. The old bytes were
# already kept under their final name (step 1); that file is a second name for
# bytes still at the entry, so nothing is lost or overwritten.
M8="${TMP}/m8"; slot_box "${M8}"
printf 'print("image 4 helper")\n' >"${M8}/data/ceralive/${HELPER}"
STUB_MD5SUMS="${M8}/ceralive-device.md5sums" RUN_PRELUDE='mv() { return 1; }' \
  run_block "${M8}/data" "${M8}/opt/ceralive" "${M8}/${HELPERS_REL}" \
  || fail "M8: a failed replacement failed ceralive-migrate-data (every bind would stop)"
[[ -f "${M8}/data/.migrate-continued" ]] || fail "M8: migration stopped after a failed replacement"
assert_kept_regular "${M8}" M8 "image 4 helper"
no_stage "${M8}" M8
assert_logged "${M8}" M8 "WARNING: cannot replace ${M8}/data/ceralive/${HELPER}"
m8_kept="${M8}/data/ceralive/.${HELPER}.pre-link.$(md5_of "${M8}/data/ceralive/${HELPER}")"
[[ "$(md5_of "${m8_kept}")" == "$(md5_of "${M8}/data/ceralive/${HELPER}")" ]] \
  || fail "M8: the kept file does not hold the bytes still at the entry"
echo "ceraui-workdir-helpers: M8 a failed replacement is non-fatal OK"

# I1: a stop after step 1 (kept, not yet swapped) is finished by the next boot:
# the kept file is found, not duplicated, and the link goes in.
I1="${TMP}/i1"; slot_box "${I1}"
printf 'print("image 4 helper")\n' >"${I1}/data/ceralive/${HELPER}"
ln "${I1}/data/ceralive/${HELPER}" "${I1}/data/ceralive/.${HELPER}.pre-link.$(md5_of "${I1}/data/ceralive/${HELPER}")"
STUB_MD5SUMS="${I1}/ceralive-device.md5sums" run_block "${I1}/data" "${I1}/opt/ceralive" "${I1}/${HELPERS_REL}"
assert_linked "${I1}" I1
assert_logged "${I1}" I1 "is already kept as"
[[ "$(find "${I1}/data/ceralive" -maxdepth 1 -name ".${HELPER}.pre-link*" | wc -l)" -eq 1 ]] || fail "I1: the kept file was duplicated"
[[ "$(python3 -I "${I1}/data/ceralive/.${HELPER}.pre-link.$(printf 'print("image 4 helper")\n' | md5sum | awk '{print $1}')")" == "image 4 helper" ]] \
  || fail "I1: the kept file changed"
echo "ceraui-workdir-helpers: I1 stop after keeping, finished next boot OK"

# I2: a stop after step 2 (temporary link made, not renamed) leaves a symlink to
# the kept copy; the next boot removes it and finishes. Only symlinks with that
# name whose target is exactly the kept copy are removed: a regular file, a
# directory, a symlink elsewhere or to the kept path plus a newline stay.
I2="${TMP}/i2"; slot_box "${I2}"; c="${I2}/data/ceralive"
printf 'print("image 4 helper")\n' >"${c}/${HELPER}"
ln "${c}/${HELPER}" "${c}/.${HELPER}.pre-link.$(md5_of "${c}/${HELPER}")"
ln -s "${I2}/${HELPERS_REL}/${HELPER}" "${c}/.${HELPER}.link-q1w2e3"
printf 'theirs\n' >"${c}/.${HELPER}.link-regular"
mkdir "${c}/.${HELPER}.link-dir"
ln -s /elsewhere "${c}/.${HELPER}.link-other"
ln -s "${I2}/${HELPERS_REL}/${HELPER}"$'\n' "${c}/.${HELPER}.link-newline"
STUB_MD5SUMS="${I2}/ceralive-device.md5sums" run_block "${I2}/data" "${I2}/opt/ceralive" "${I2}/${HELPERS_REL}"
[[ -L "${c}/${HELPER}" && "$(readlink "${c}/${HELPER}")" == "${I2}/${HELPERS_REL}/${HELPER}" ]] || fail "I2: the replacement was not finished"
[[ ! -e "${c}/.${HELPER}.link-q1w2e3" && ! -L "${c}/.${HELPER}.link-q1w2e3" ]] || fail "I2: our leftover link stayed"
[[ "$(<"${c}/.${HELPER}.link-regular")" == theirs && -d "${c}/.${HELPER}.link-dir" \
   && "$(readlink "${c}/.${HELPER}.link-other")" == /elsewhere && -L "${c}/.${HELPER}.link-newline" ]] \
  || fail "I2: a foreign entry with the temporary name pattern was touched"
echo "ceraui-workdir-helpers: I2 stop after the temporary link, cleaned and finished OK"

# M9: the link is renamed into place over the entry, so the entry is never
# absent in between (static check of the rename; the temporary link's
# behaviour is covered by I2, S2 and S3).
grep -Fq 'mv -fT -- "$tmp" "$dest"' <<<"${block}" \
  || fail "M9: the stale helper is no longer replaced by renaming a temporary link over it"
echo "ceraui-workdir-helpers: M9 rename into place OK"

# M10: a directory at the kept name stops only the keeping, never the fix.
M10="${TMP}/m10"; slot_box "${M10}"
printf 'print("image 4 helper")\n' >"${M10}/data/ceralive/${HELPER}"
m10_kept="${M10}/data/ceralive/.${HELPER}.pre-link.$(md5_of "${M10}/data/ceralive/${HELPER}")"
mkdir -p "${m10_kept}"
STUB_MD5SUMS="${M10}/ceralive-device.md5sums" run_block "${M10}/data" "${M10}/opt/ceralive" "${M10}/${HELPERS_REL}"
assert_linked "${M10}" M10
[[ -d "${m10_kept}" && -z "$(ls -A "${m10_kept}")" ]] || fail "M10: the directory at the kept name was changed"
assert_logged "${M10}" M10 "WARNING: cannot keep the replaced"
echo "ceraui-workdir-helpers: M10 keeping fails, the fix still applies OK"

# K1: a regular file with the image copy's own bytes (a same-version
# reinstall) is replaced without keeping anything; earlier kept files stay.
K1="${TMP}/k1"; slot_box "${K1}"
cp "${K1}/${HELPERS_REL}/${HELPER}" "${K1}/data/ceralive/${HELPER}"
printf 'print("older helper")\n' >"${K1}/data/ceralive/.${HELPER}.pre-link.0123456789abcdef0123456789abcdef"
STUB_MD5SUMS="${K1}/ceralive-device.md5sums" run_block "${K1}/data" "${K1}/opt/ceralive" "${K1}/${HELPERS_REL}"
assert_linked "${K1}" K1
[[ "$(find "${K1}/data/ceralive" -maxdepth 1 -name ".${HELPER}.pre-link*" | wc -l)" -eq 1 ]] \
  || fail "K1: a same-bytes copy was kept"
[[ "$(python3 -I "${K1}/data/ceralive/.${HELPER}.pre-link.0123456789abcdef0123456789abcdef")" == "older helper" ]] \
  || fail "K1: an earlier kept file changed"
echo "ceraui-workdir-helpers: K1 same bytes, nothing kept OK"

# K2: an existing file at the kept name is never overwritten. Same bytes: noted;
# other bytes (not ours): warned. The fix applies either way.
for variant in same other; do
  K2="${TMP}/k2-${variant}"; slot_box "${K2}"
  printf 'print("image 4 helper")\n' >"${K2}/data/ceralive/${HELPER}"
  k2_kept="${K2}/data/ceralive/.${HELPER}.pre-link.$(md5_of "${K2}/data/ceralive/${HELPER}")"
  case "${variant}" in
    same)  cp "${K2}/data/ceralive/${HELPER}" "${k2_kept}" ;;
    other) printf 'print("someone else")\n' >"${k2_kept}" ;;
  esac
  before="$(md5_of "${k2_kept}")"
  STUB_MD5SUMS="${K2}/ceralive-device.md5sums" run_block "${K2}/data" "${K2}/opt/ceralive" "${K2}/${HELPERS_REL}"
  assert_linked "${K2}" "K2-${variant}"
  [[ "$(md5_of "${k2_kept}")" == "${before}" ]] || fail "K2-${variant}: an existing kept name was overwritten"
  case "${variant}" in
    same)  assert_logged "${K2}" K2-same "is already kept as" ;;
    other) assert_logged "${K2}" K2-other "WARNING: cannot keep the replaced" ;;
  esac
done
echo "ceraui-workdir-helpers: K2 existing kept name never overwritten OK"

# K3: two different replaced files over time (two updates) are both kept, each
# under its own md5, so the restore can pick the one the rolled-back slot needs.
K3="${TMP}/k3"; slot_box "${K3}"
printf 'print("first old helper")\n' >"${K3}/data/ceralive/${HELPER}"
STUB_MD5SUMS="${K3}/ceralive-device.md5sums" run_block "${K3}/data" "${K3}/opt/ceralive" "${K3}/${HELPERS_REL}"
rm -f "${K3}/data/ceralive/${HELPER}"; printf 'print("second old helper")\n' >"${K3}/data/ceralive/${HELPER}"
STUB_MD5SUMS="${K3}/ceralive-device.md5sums" run_block "${K3}/data" "${K3}/opt/ceralive" "${K3}/${HELPERS_REL}"
assert_linked "${K3}" K3
for content in 'first old helper' 'second old helper'; do
  k="${K3}/data/ceralive/.${HELPER}.pre-link.$(printf 'print("%s")\n' "${content}" | md5sum | awk '{print $1}')"
  [[ "$(python3 -I "${k}" 2>/dev/null)" == "${content}" ]] || fail "K3: '${content}' was not kept under its md5"
done
echo "ceraui-workdir-helpers: K3 each replaced content kept once OK"

# C1: a failed query's output never counts, even when it looks like a record.
C1="${TMP}/c1"; slot_box "${C1}"
printf 'print("image 4 helper")\n' >"${C1}/data/ceralive/${HELPER}"
STUB_DPKG_FAIL=1 STUB_MD5SUMS="${C1}/ceralive-device.md5sums" \
  run_block "${C1}/data" "${C1}/opt/ceralive" "${C1}/${HELPERS_REL}"
assert_kept_regular "${C1}" C1 "image 4 helper"
assert_logged "${C1}" C1 "dpkg-query has no md5sums"
echo "ceraui-workdir-helpers: C1 failed query output ignored OK"

# C2: only the exact pathname counts: a longer name, a name with a space and
# more after it, or a prefix are other files.
for variant in suffix space prefix; do
  C2="${TMP}/c2-${variant}"; slot_box "${C2}"
  sum="$(md5_of "${C2}/${HELPERS_REL}/${HELPER}")"
  case "${variant}" in
    suffix) rec="opt/ceralive/${HELPER}.orig" ;;
    space)  rec="opt/ceralive/${HELPER} other" ;;
    prefix) rec="srv/opt/ceralive/${HELPER}" ;;
  esac
  printf '%s  %s\n' "${sum}" "${rec}" >"${C2}/ceralive-device.md5sums"
  printf 'print("image 4 helper")\n' >"${C2}/data/ceralive/${HELPER}"
  STUB_MD5SUMS="${C2}/ceralive-device.md5sums" run_block "${C2}/data" "${C2}/opt/ceralive" "${C2}/${HELPERS_REL}"
  assert_kept_regular "${C2}" "C2-${variant}" "image 4 helper"
done
echo "ceraui-workdir-helpers: C2 exact pathname record only OK"

# T1: a link whose target is the image copy plus a trailing newline dangles; it
# is repaired, not mistaken for the right link.
T1="${TMP}/t1"; slot_box "${T1}"
ln -sT "${T1}/${HELPERS_REL}/${HELPER}"$'\n' "${T1}/data/ceralive/${HELPER}"
run_block "${T1}/data" "${T1}/opt/ceralive" "${T1}/${HELPERS_REL}"
[[ "$(readlink "${T1}/data/ceralive/${HELPER}"; printf x)" == "${T1}/${HELPERS_REL}/${HELPER}"$'\nx' ]] \
  || fail "T1: a target with a trailing newline was kept"
T1b="${TMP}/t1b"; slot_box "${T1b}"
ln -sT "${T1b}/${HELPERS_REL}/${HELPER}"$'\n' "${T1b}/data/ceralive/${HELPER}"
STUB_MD5SUMS="${T1b}/ceralive-device.md5sums" run_block "${T1b}/data" "${T1b}/opt/ceralive" "${T1b}/${HELPERS_REL}"
assert_linked "${T1b}" T1b
echo "ceraui-workdir-helpers: T1 trailing-newline target repaired OK"

# S1: $DATA/ceralive or $DATA is a symlink: nothing is written through it, the
# refusal is logged, and the migration goes on.
for variant in workdir data; do
  S1="${TMP}/s1-${variant}"; slot_box "${S1}"
  printf 'print("image 4 helper")\n' >"${S1}/data/ceralive/${HELPER}"
  mkdir -p "${S1}/elsewhere"
  case "${variant}" in
    workdir) mv "${S1}/data/ceralive" "${S1}/elsewhere/ceralive"
             ln -s "${S1}/elsewhere/ceralive" "${S1}/data/ceralive"
             data="${S1}/data" ;;
    data)    mv "${S1}/data" "${S1}/elsewhere/data"
             ln -s "${S1}/elsewhere/data" "${S1}/data-link"
             data="${S1}/data-link" ;;
  esac
  STUB_MD5SUMS="${S1}/ceralive-device.md5sums" run_block "${data}" "${S1}/opt/ceralive" "${S1}/${HELPERS_REL}" \
    || fail "S1-${variant}: a symlinked parent failed ceralive-migrate-data"
  real="${S1}/elsewhere/${variant/workdir/ceralive}"; [[ "${variant}" == data ]] && real="${S1}/elsewhere/data/ceralive"
  [[ -f "${real}/${HELPER}" && ! -L "${real}/${HELPER}" ]] || fail "S1-${variant}: a file was written through a symlinked parent"
  [[ "$(python3 -I "${real}/${HELPER}")" == "image 4 helper" ]] || fail "S1-${variant}: the file behind the symlink changed"
  [[ -z "$(find "${real}" -maxdepth 1 \( -name ".${HELPER}.link-*" -o -name ".${HELPER}.pre-link*" \) -print -quit)" ]] \
    || fail "S1-${variant}: a temporary link or kept file was written through a symlinked parent"
  grep -Fq "or a parent is a symlink, not a directory, or writable by another user" "${data}/.migrate.log" || fail "S1-${variant}: the refusal was not logged"
  [[ -f "${data}/.migrate-continued" ]] || fail "S1-${variant}: migration stopped"
done
echo "ceraui-workdir-helpers: S1 symlinked parent refused OK"

# S2: the temporary name is taken (here mktemp -u names an existing file): ln
# without -f refuses, nothing is overwritten, the entry stays, logged. Names the
# block never uses (old staging names) are left alone.
S2="${TMP}/s2"; slot_box "${S2}"; c="${S2}/data/ceralive"
printf 'print("image 4 helper")\n' >"${c}/${HELPER}"
printf 'theirs\n' >"${c}/.${HELPER}.link-AAAAAA"
printf 'not ours\n' >"${c}/${HELPER}.helper-link"
mkdir -p "${c}/.helper-stage.old"; printf 'theirs\n' >"${c}/.helper-stage.old/keep"
STUB_MD5SUMS="${S2}/ceralive-device.md5sums" RUN_PRELUDE="mktemp() { echo '${c}/.${HELPER}.link-AAAAAA'; }" \
  run_block "${S2}/data" "${S2}/opt/ceralive" "${S2}/${HELPERS_REL}"
assert_kept_regular "${S2}" S2 "image 4 helper"
[[ "$(<"${c}/.${HELPER}.link-AAAAAA")" == theirs ]] || fail "S2: an occupied temporary name was overwritten"
[[ "$(<"${c}/${HELPER}.helper-link")" == "not ours" && "$(<"${c}/.helper-stage.old/keep")" == theirs ]] \
  || fail "S2: an unrelated name was touched"
assert_logged "${S2}" S2 "WARNING: cannot create the temporary link"
# The next boot with a free name finishes the job.
STUB_MD5SUMS="${S2}/ceralive-device.md5sums" run_block "${S2}/data" "${S2}/opt/ceralive" "${S2}/${HELPERS_REL}"
[[ -L "${c}/${HELPER}" ]] || fail "S2: the next boot did not finish the replacement"
echo "ceraui-workdir-helpers: S2 occupied temporary name OK"

# S3: no temporary name (mktemp fails, or names something outside the pattern):
# a regular file stays and the reason is logged; an absent or dangling entry
# still gets the plain link, so a fresh install keeps its helper.
for variant in fails elsewhere; do
  case "${variant}" in
    fails)     prelude='mktemp() { return 1; }' ;;
    elsewhere) prelude='mktemp() { echo /tmp/somewhere-else; }' ;;
  esac
  S3="${TMP}/s3-${variant}"; slot_box "${S3}"
  printf 'print("image 4 helper")\n' >"${S3}/data/ceralive/${HELPER}"
  STUB_MD5SUMS="${S3}/ceralive-device.md5sums" RUN_PRELUDE="${prelude}" \
    run_block "${S3}/data" "${S3}/opt/ceralive" "${S3}/${HELPERS_REL}" || fail "S3-${variant}: failed naming failed ceralive-migrate-data"
  assert_kept_regular "${S3}" "S3-${variant}" "image 4 helper"
  assert_logged "${S3}" "S3-${variant}" "WARNING: cannot name a temporary link"
  assert_logged "${S3}" "S3-${variant}" "keeping the regular file ${S3}/data/ceralive/${HELPER}: no temporary name"
  [[ ! -e /tmp/somewhere-else ]] || fail "S3-${variant}: something was written outside the directory"
  [[ -f "${S3}/data/.migrate-continued" ]] || fail "S3-${variant}: migration stopped"
  for entry in absent dangling; do
    S3b="${TMP}/s3-${variant}-${entry}"; slot_box "${S3b}"
    [[ "${entry}" == absent ]] || ln -s /nonexistent/old "${S3b}/data/ceralive/${HELPER}"
    STUB_MD5SUMS="${S3b}/ceralive-device.md5sums" RUN_PRELUDE="${prelude}" \
      run_block "${S3b}/data" "${S3b}/opt/ceralive" "${S3b}/${HELPERS_REL}"
    assert_linked "${S3b}" "S3-${variant}-${entry}"
  done
done
echo "ceraui-workdir-helpers: S3 no temporary name is non-fatal, fresh entries still linked OK"

# S4: $DATA/ceralive or $DATA writable by group or others: refused, nothing
# written, logged, migration goes on.
for variant in workdir data; do
  S4="${TMP}/s4-${variant}"; slot_box "${S4}"
  printf 'print("image 4 helper")\n' >"${S4}/data/ceralive/${HELPER}"
  case "${variant}" in
    workdir) chmod 0775 "${S4}/data/ceralive" ;;
    data)    chmod 0757 "${S4}/data" ;;
  esac
  STUB_MD5SUMS="${S4}/ceralive-device.md5sums" run_block "${S4}/data" "${S4}/opt/ceralive" "${S4}/${HELPERS_REL}" \
    || fail "S4-${variant}: a writable parent failed ceralive-migrate-data"
  assert_kept_regular "${S4}" "S4-${variant}" "image 4 helper"
  [[ -z "$(find "${S4}/data/ceralive" -maxdepth 1 \( -name ".${HELPER}.link-*" -o -name ".${HELPER}.pre-link*" \) -print -quit)" ]] \
    || fail "S4-${variant}: a temporary link or kept file was written in a writable parent"
  assert_logged "${S4}" "S4-${variant}" "writable by another user"
  [[ -f "${S4}/data/.migrate-continued" ]] || fail "S4-${variant}: migration stopped"
done
echo "ceraui-workdir-helpers: S4 parent writable by others refused OK"

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

(( FAILED == 0 )) || { echo "ceraui-workdir-helpers regression: ${FAILED} failure(s)" >&2; exit 1; }
echo "ceraui-workdir-helpers regression: PASS"

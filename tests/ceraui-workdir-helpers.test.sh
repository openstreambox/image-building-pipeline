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
# helper also follows OTAs. Absent and dangling entries are (re)linked; a regular
# file (written by a later CeraUI package upgrade) is left alone.
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
  bash "${runner}"
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

# B5: a regular file (a CeraUI package upgrade wrote it) is left alone.
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

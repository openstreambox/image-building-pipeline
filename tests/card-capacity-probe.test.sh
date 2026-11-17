#!/usr/bin/env bash
#
# tests/card-capacity-probe.test.sh — host contract for the card size and
# fake-capacity probe core (mkosi/runtime/ceralive-card-probe.sh).
#
# Everything here uses disposable regular files under a private temporary
# directory and, for fake cards, functions that model a card in memory over a
# smaller backing file. No block device is opened, written or read. The block
# device refusal is checked with the storage functions replaced by tripwires, so
# that a broken refusal would record a call instead of touching the device.
#
# Fixture geometry (scaled down from a real card; the probe's logic is size
# independent): a 32 MiB GPT image whose first partition starts at 16 MiB, like
# the RK3588 layout, and a card that claims 1 GiB.
#
# Needs sgdisk (the default gate already does). No root, no hardware.
#
# contract-test profile (docs/shell-profiles.md): `set -uo pipefail`, no `-e`.
#
# shellcheck shell=bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=lib/assertions.sh
source "${HERE}/lib/assertions.sh"

PROBE="${ROOT}/mkosi/runtime/ceralive-card-probe.sh"
MIB=1048576

command -v sgdisk >/dev/null 2>&1 || { printf 'FAIL: sgdisk is required\n' >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

IMAGE="${WORK}/image.raw"
REF="${WORK}/reference"
IMAGE_BYTES=$(( 32 * MIB ))
CLAIMED=$(( 1024 * MIB ))

sum_range() { # file offset length
  dd if="$1" bs=512 skip=$(( $2 / 512 )) count=$(( $3 / 512 )) status=none | sha256sum | cut -d' ' -f1
}

# --- pristine image ----------------------------------------------------------
truncate -s "${IMAGE_BYTES}" "${IMAGE}"
sgdisk -o -n 1:32768:+8M -c 1:boot -n 2:49152:65502 -c 2:rootfs "${IMAGE}" >"${WORK}/sgdisk.log" 2>&1 \
  || { printf "FAIL: sgdisk could not build the fixture: %s\n" "$(cat "${WORK}/sgdisk.log")" >&2; exit 1; }
# A recognisable "loader" between the primary GPT and the first partition.
head -c $(( 2 * MIB )) /dev/urandom | dd of="${IMAGE}" bs=512 seek=64 conv=notrunc status=none
# Some "rootfs" content.
head -c "${MIB}" /dev/urandom | dd of="${IMAGE}" bs="${MIB}" seek=25 conv=notrunc status=none

bash "${PROBE}" reference "${IMAGE}" --min-media-bytes $(( 512 * MIB )) >"${REF}" 2>"${WORK}/ref.err"
rc=$?

echo "== reference"

[[ ${rc} -eq 0 ]] && ok "reference exits 0 on a GPT image" || bad "reference rc=${rc}: $(cat "${WORK}/ref.err")"
grep -qx 'format=ceralive-card-probe-reference/1' "${REF}" && ok "reference names its format" || bad "format line: $(cat "${REF}")"
grep -qx "image_bytes=${IMAGE_BYTES}" "${REF}" && ok "image_bytes is the image length" || bad "image_bytes: $(cat "${REF}")"
grep -qx "min_media_bytes=$(( 512 * MIB ))" "${REF}" && ok "the minimum is carried through" || bad "min_media_bytes: $(cat "${REF}")"
loader_sum=$(sum_range "${IMAGE}" 0 $(( 16 * MIB )))
grep -qx "region=loader 0 $(( 16 * MIB )) ${loader_sum}" "${REF}" \
  && ok "loader region is exactly [0, first partition) with its sha256" \
  || bad "loader region: $(grep loader "${REF}")"
backup_off=$(( IMAGE_BYTES - 33 * 512 ))
backup_sum=$(sum_range "${IMAGE}" "${backup_off}" $(( 33 * 512 )))
grep -qx "region=backup-gpt ${backup_off} $(( 33 * 512 )) ${backup_sum}" "${REF}" \
  && ok "backup-gpt region is the entry array plus header at the image end" \
  || bad "backup region: $(grep backup "${REF}")"
[[ $(grep -c '^region=' "${REF}") -eq 2 ]] && ok "no other region is hashed (boot partition files never are)" || bad "regions: $(cat "${REF}")"

truncate -s "${IMAGE_BYTES}" "${WORK}/blank.raw"
bash "${PROBE}" reference "${WORK}/blank.raw" >/dev/null 2>&1; rc=$?
[[ ${rc} -eq 2 ]] && ok "an image without a GPT is refused (2)" || bad "blank image rc=${rc}"
bash "${PROBE}" reference "${IMAGE}" --min-media-bytes 12x >/dev/null 2>&1; rc=$?
[[ ${rc} -eq 2 ]] && ok "a non-numeric minimum is refused (2)" || bad "bad minimum rc=${rc}"

# --- helpers for probe runs ---------------------------------------------------

# new_card NAME: a genuine card file claiming CLAIMED bytes holding the image.
new_card() {
  local card="${WORK}/$1.card"
  cp --sparse=always "${IMAGE}" "${card}"
  truncate -s "${CLAIMED}" "${card}"
  printf '%s' "${card}"
}

run_probe() { # out-prefix args...
  local pfx=$1; shift
  bash "${PROBE}" probe "$@" >"${pfx}.out" 2>"${pfx}.err"
}

field() { grep -m1 "^$1=" "$2" | cut -d= -f2-; }

# fake_run OUT MODEL REAL [MARKS] [EXTRA]: probe a modelled card in a subshell.
# MODEL selects how the card behaves past REAL bytes of real storage:
#   wrap     writes and reads map to (offset mod REAL)
#   drop     writes past REAL are lost; reads there return zeros
#   stale    writes past REAL are lost; reads return what EXTRA (an earlier
#            genuine card file) holds at that offset
#   flip     genuine, but the read of the mark at offset EXTRA returns one
#            flipped byte
#   werr     genuine, but the write at offset EXTRA fails
# The backing file holds REAL bytes and starts as a copy of the image. Every
# card_io_write offset is logged to OUT.writes.
fake_run() {
  local out=$1 model=$2 real=$3 marks=${4:-64} extra=${5:-}
  local back="${out}.back"
  cp --sparse=always "${IMAGE}" "${back}"
  truncate -s "${real}" "${back}"
  : >"${out}.writes"
  (
    # shellcheck source=mkosi/runtime/ceralive-card-probe.sh
    source "${PROBE}"
    card_io_size() { printf '%s\n' "${CLAIMED}"; }
    phys_read() { # offset length, within the backing file
      dd if="${back}" bs=512 skip=$(( $1 / 512 )) count=$(( $2 / 512 )) status=none
    }
    card_io_read() {
      local off=$1 len=$2 head
      case "${model}" in
        wrap)
          local p=$(( off % real ))
          if (( p + len > real )); then
            head=$(( real - p ))
            phys_read "${p}" "${head}"; phys_read 0 $(( len - head ))
          else
            phys_read "${p}" "${len}"
          fi ;;
        drop) if (( off >= real )); then head -c "${len}" /dev/zero; else phys_read "${off}" "${len}"; fi ;;
        stale)
          if (( off >= real )); then
            dd if="${extra}" bs=512 skip=$(( off / 512 )) count=$(( len / 512 )) status=none
          else phys_read "${off}" "${len}"; fi ;;
        flip)
          if (( off == extra )); then
            phys_read "${off}" "${len}" >"${out}.flip"
            printf '\377' | dd of="${out}.flip" bs=1 seek=100 conv=notrunc status=none
            cat "${out}.flip"
          else phys_read "${off}" "${len}"; fi ;;
        *) phys_read "${off}" "${len}" ;;
      esac
    }
    card_io_write() {
      local off=$1 len=$2
      printf '%s\n' "${off}" >>"${out}.writes"
      case "${model}" in
        wrap) dd of="${back}" bs="${MIB}" seek=$(( (off % real) / MIB )) count=$(( len / MIB )) iflag=fullblock conv=notrunc status=none ;;
        drop|stale) if (( off >= real )); then cat >/dev/null; else
                      dd of="${back}" bs="${MIB}" seek=$(( off / MIB )) count=$(( len / MIB )) iflag=fullblock conv=notrunc status=none; fi ;;
        werr) if (( off == extra )); then cat >/dev/null; return 1; fi
              dd of="${back}" bs="${MIB}" seek=$(( off / MIB )) count=$(( len / MIB )) iflag=fullblock conv=notrunc status=none ;;
        *) dd of="${back}" bs="${MIB}" seek=$(( off / MIB )) count=$(( len / MIB )) iflag=fullblock conv=notrunc status=none ;;
      esac
    }
    card_io_flush() { :; }
    card_probe_core "${REF}" "${marks}"
  ) >"${out}.out" 2>"${out}.err"
}

echo "== genuine regular-file card"

CARD=$(new_card genuine)
# A setup tool may add a file inside the boot partition after writing.
printf '{"example":"setup"}\n' | dd of="${CARD}" bs=512 seek=$(( 16 * MIB / 512 + 100 )) conv=notrunc status=none
image_area_before=$(sum_range "${CARD}" 0 "${IMAGE_BYTES}")
run_probe "${WORK}/genuine" "${CARD}" "${REF}"; rc=$?
[[ ${rc} -eq 0 ]] && ok "a genuine card passes (0)" || bad "genuine rc=${rc}: $(cat "${WORK}/genuine.out" "${WORK}/genuine.err")"
[[ "$(field result "${WORK}/genuine.out")" == pass ]] && ok "result=pass" || bad "result: $(cat "${WORK}/genuine.out")"
[[ "$(field size_bytes "${WORK}/genuine.out")" == "${CLAIMED}" ]] && ok "reports the card's size" || bad "size_bytes"
[[ "$(field probe_start "${WORK}/genuine.out")" == "${IMAGE_BYTES}" ]] && ok "marks start at the first MiB after the image" || bad "probe_start"
# 64 spread marks plus power-of-two offsets 32, 64, 128, 256, 512 MiB, of which
# 32 MiB coincides with the first spread mark: 64 + 4 = 68.
[[ "$(field marks_written "${WORK}/genuine.out")" == 68 ]] && ok "68 marks: 64 spread plus 4 extra power-of-two offsets" || bad "marks_written=$(field marks_written "${WORK}/genuine.out")"
[[ "$(field mismatches "${WORK}/genuine.out")" == 0 ]] && ok "no mismatches" || bad "mismatches"
[[ "$(sum_range "${CARD}" 0 "${IMAGE_BYTES}")" == "${image_area_before}" ]] \
  && ok "the image area, added boot file included, is byte-identical afterwards" || bad "image area changed on a genuine card"
last_mark=$(( CLAIMED - MIB ))
dd if="${CARD}" bs=512 skip=$(( last_mark / 512 )) count=1 status=none >"${WORK}/last-sector"
grep -aq '^CERALIVE-CARD-PROBE v1 run=[0-9a-f]\{32\} mark='"${last_mark}"' sector=0000 ' "${WORK}/last-sector" \
  && ok "the last MiB of the card carries a mark" || bad "no mark in the last MiB"
[[ "$(stat -c %s "${CARD}")" == "${CLAIMED}" ]] && ok "the card file did not grow" || bad "card size changed"

run_probe "${WORK}/genuine-small" "${CARD}" "${REF}" --marks 2; rc=$?
[[ ${rc} -eq 0 && "$(field marks_written "${WORK}/genuine-small.out")" == 6 ]] \
  && ok "--marks 2 still adds the power-of-two marks (2 + 4)" || bad "marks 2 rc=${rc}: $(cat "${WORK}/genuine-small.out")"

echo "== fake cards"

fake_run "${WORK}/wrap" wrap $(( 64 * MIB )); rc=$?
[[ ${rc} -eq 1 && "$(field result "${WORK}/wrap.out")" == fake-or-faulty ]] \
  && ok "a 64 MiB card claiming 1 GiB that wraps fails as fake-or-faulty (1)" || bad "wrap rc=${rc}: $(cat "${WORK}/wrap.out")"
grep -q '^mismatch_offset=' "${WORK}/wrap.out" && ok "the wrapped marks are logged by offset" || bad "no mismatch offsets logged"
grep -qx 'region_changed=loader' "${WORK}/wrap.out" && ok "the wrap onto offset zero shows as a changed loader area" || bad "loader change not reported"
[[ $(grep -c '^mismatch_offset=' "${WORK}/wrap.out") -le 16 ]] && ok "at most 16 offsets are logged" || bad "too many offsets logged"

fake_run "${WORK}/wrap2" wrap $(( 64 * MIB )) 2; rc=$?
[[ ${rc} -eq 1 ]] && ok "the wrap is caught with only 2 spread marks (power-of-two marks collide)" || bad "wrap marks=2 rc=${rc}: $(cat "${WORK}/wrap2.out")"

fake_run "${WORK}/wrap512" wrap $(( 512 * MIB )); rc=$?
[[ ${rc} -eq 1 ]] && ok "a 512 MiB card claiming 1 GiB that wraps fails" || bad "wrap512 rc=${rc}: $(cat "${WORK}/wrap512.out")"

fake_run "${WORK}/drop" drop $(( 256 * MIB )); rc=$?
[[ ${rc} -eq 1 && "$(field reason "${WORK}/drop.out")" == mark-mismatch ]] \
  && ok "a card that drops writes past its real size fails" || bad "drop rc=${rc}: $(cat "${WORK}/drop.out")"
grep -q '^region_changed=' "${WORK}/drop.out" && bad "drop: image area reported changed" || ok "dropping writes leaves the image area intact"

fake_run "${WORK}/stale" stale $(( 256 * MIB )) 64 "${CARD}"; rc=$?
[[ ${rc} -eq 1 ]] && ok "marks left by an earlier run do not pass a new run" || bad "stale rc=${rc}: $(cat "${WORK}/stale.out")"

flip_at=$(( 512 * MIB ))
fake_run "${WORK}/flip" flip "${CLAIMED}" 64 "${flip_at}"; rc=$?
[[ ${rc} -eq 1 && "$(field mismatches "${WORK}/flip.out")" == 1 \
   && "$(field mismatch_offset "${WORK}/flip.out")" == "${flip_at}" ]] \
  && ok "one corrupted byte in one mark fails and names that offset" || bad "flip rc=${rc}: $(cat "${WORK}/flip.out")"

fake_run "${WORK}/clean" plain "${CLAIMED}"; rc=$?
[[ ${rc} -eq 0 ]] && ok "the modelled genuine card passes (the model itself is sound)" || bad "modelled genuine rc=${rc}: $(cat "${WORK}/clean.out" "${WORK}/clean.err")"

echo "== bounds"

bad_write=0
while read -r off; do
  (( off % MIB == 0 && off >= IMAGE_BYTES && off + MIB <= CLAIMED )) || bad_write=$(( bad_write + 1 ))
done <"${WORK}/clean.writes"
[[ ${bad_write} -eq 0 && $(wc -l <"${WORK}/clean.writes") -eq 68 ]] \
  && ok "every write is one aligned MiB in [image end, card size): 68 writes" || bad "out-of-bounds writes=${bad_write}, count=$(wc -l <"${WORK}/clean.writes")"
[[ $(sort -n "${WORK}/clean.writes" | uniq -d | wc -l) -eq 0 ]] && ok "no offset is written twice" || bad "duplicate writes"

# Image area already changed (e.g. the image itself was written onto a wrapping
# card): nothing may be written.
PRE=$(new_card pre)
printf 'X' | dd of="${PRE}" bs=1 seek=40000 conv=notrunc status=none
(
  # shellcheck source=mkosi/runtime/ceralive-card-probe.sh
  source "${PROBE}"
  CARD_PROBE_TARGET="${PRE}"
  card_io_size() { printf '%s\n' "${CLAIMED}"; }
  card_io_write() { printf '%s\n' "$1" >>"${WORK}/pre2.writes"; cat >/dev/null; }
  card_probe_core "${REF}" 64
) >"${WORK}/pre2.out" 2>&1; rc=$?
[[ ${rc} -eq 1 && "$(field reason "${WORK}/pre2.out")" == image-changed-before-probe && ! -s "${WORK}/pre2.writes" ]] \
  && ok "a changed loader area fails before any write" || bad "pre-check rc=${rc}: $(cat "${WORK}/pre2.out")"

fake_run "${WORK}/werr" werr "${CLAIMED}" 64 $(( 256 * MIB )); rc=$?
[[ ${rc} -eq 3 && "$(field result "${WORK}/werr.out")" == io-error \
   && "$(field io_error_offset "${WORK}/werr.out")" == $(( 256 * MIB )) ]] \
  && ok "a failed write is an io-error (3) naming its offset, not a verdict" || bad "werr rc=${rc}: $(cat "${WORK}/werr.out")"

# The core keeps its own bounds when called directly, and an empty offset list
# (for example a failed sort) is refused rather than passing with no marks.
(
  # shellcheck source=mkosi/runtime/ceralive-card-probe.sh
  source "${PROBE}"
  CARD_PROBE_TARGET="${CARD}"
  card_probe_core "${REF}" 65
) >"${WORK}/core65.out" 2>&1; rc=$?
[[ ${rc} -eq 2 && "$(field reason "${WORK}/core65.out")" == bad-arguments ]] \
  && ok "the core refuses 65 marks by itself" || bad "core 65 rc=${rc}: $(cat "${WORK}/core65.out")"
(
  # shellcheck source=mkosi/runtime/ceralive-card-probe.sh
  source "${PROBE}"
  CARD_PROBE_TARGET="${CARD}"
  card_probe_offsets() { :; }
  card_io_write() { printf '%s\n' "$1" >>"${WORK}/empty.writes"; cat >/dev/null; }
  card_probe_core "${REF}" 64
) >"${WORK}/empty.out" 2>&1; rc=$?
[[ ${rc} -eq 2 && "$(field reason "${WORK}/empty.out")" == mark-count-out-of-bounds && ! -e "${WORK}/empty.writes" ]] \
  && ok "an empty mark list is refused, never a pass" || bad "empty offsets rc=${rc}: $(cat "${WORK}/empty.out")"

echo "== size"

SMALL="${WORK}/small.card"
cp --sparse=always "${IMAGE}" "${SMALL}"; truncate -s $(( 256 * MIB )) "${SMALL}"
small_before=$(sha256sum <"${SMALL}")
run_probe "${WORK}/small" "${SMALL}" "${REF}"; rc=$?
[[ ${rc} -eq 4 && "$(field reason "${WORK}/small.out")" == below-minimum ]] \
  && ok "a card below the reference minimum is too-small (4)" || bad "small rc=${rc}: $(cat "${WORK}/small.out")"
[[ "$(sha256sum <"${SMALL}")" == "${small_before}" ]] && ok "nothing is written to a too-small card" || bad "too-small card was written"

grep -v '^min_media_bytes=' "${REF}" >"${WORK}/ref-nomin"
TIGHT="${WORK}/tight.card"
cp --sparse=always "${IMAGE}" "${TIGHT}"; truncate -s $(( IMAGE_BYTES + MIB )) "${TIGHT}"
run_probe "${WORK}/tight" "${TIGHT}" "${WORK}/ref-nomin"; rc=$?
[[ ${rc} -eq 4 && "$(field reason "${WORK}/tight.out")" == no-room-after-image ]] \
  && ok "no room for two marks after the image is too-small (4)" || bad "tight rc=${rc}: $(cat "${WORK}/tight.out")"

echo "== refusals"

ln -s "${CARD}" "${WORK}/link.card"
run_probe "${WORK}/sym" "${WORK}/link.card" "${REF}"; rc=$?
[[ ${rc} -eq 2 ]] && ok "a symlink target is refused (2)" || bad "symlink rc=${rc}"
ln "${SMALL}" "${WORK}/hard.card"
run_probe "${WORK}/hard" "${SMALL}" "${REF}"; rc=$?
[[ ${rc} -eq 2 ]] && ok "a target with another hard link is refused (2)" || bad "hardlink rc=${rc}"
rm -f "${WORK}/hard.card"
run_probe "${WORK}/dir" "${WORK}" "${REF}"; rc=$?
[[ ${rc} -eq 2 ]] && ok "a directory is refused (2)" || bad "dir rc=${rc}"
mkfifo "${WORK}/fifo"
run_probe "${WORK}/fifo" "${WORK}/fifo" "${REF}"; rc=$?
[[ ${rc} -eq 2 ]] && ok "a FIFO is refused (2)" || bad "fifo rc=${rc}"

for m in 1 65 x 064; do
  run_probe "${WORK}/m" "${CARD}" "${REF}" --marks "${m}"; rc=$?
  [[ ${rc} -eq 2 ]] && ok "--marks ${m} is refused (2)" || bad "--marks ${m} rc=${rc}"
done
run_probe "${WORK}/args" "${CARD}"; rc=$?
[[ ${rc} -eq 2 ]] && ok "a missing reference argument is refused (2)" || bad "args rc=${rc}"

for mutate in 's/^format=.*/format=other/' 's/^region=loader 0 [0-9]*/region=loader 0 999999999/' \
              's/^region=loader \(.*\) [0-9a-f]*$/region=loader \1 nothex/' '$a extra=1' '/^format=/d'; do
  sed "${mutate}" "${REF}" >"${WORK}/ref-bad"
  run_probe "${WORK}/rb" "${CARD}" "${WORK}/ref-bad"; rc=$?
  [[ ${rc} -eq 2 && "$(field reason "${WORK}/rb.out")" == invalid-reference ]] \
    && ok "an invalid reference is refused (${mutate})" || bad "reference '${mutate}' rc=${rc}: $(cat "${WORK}/rb.out")"
done

# Block devices: refused before any storage call. The storage functions are
# replaced by tripwires so that a broken refusal records a call rather than
# reading or writing the device.
BLOCK=$(find /dev -maxdepth 2 -type b -print -quit 2>/dev/null)
if [[ -n "${BLOCK}" ]]; then
  (
    # shellcheck source=mkosi/runtime/ceralive-card-probe.sh
    source "${PROBE}"
    trip() { printf 'TOUCHED %s\n' "$*" >>"${WORK}/trip"; return 1; }
    card_io_size() { trip size; }
    card_io_read() { trip read "$@"; }
    card_io_write() { trip write "$@"; }
    card_io_flush() { trip flush; }
    card_probe_main probe "${BLOCK}" "${REF}"
  ) >"${WORK}/blk.out" 2>"${WORK}/blk.err"; rc=$?
  [[ ${rc} -eq 2 && "$(field reason "${WORK}/blk.out")" == unsupported-target && ! -e "${WORK}/trip" ]] \
    && ok "a block device is refused (2) before any storage call" || bad "block rc=${rc}: $(cat "${WORK}/blk.out" "${WORK}/blk.err" "${WORK}/trip" 2>/dev/null)"
  grep -q 'not qualified on real cards' "${WORK}/blk.err" && ok "the refusal says real cards are not qualified yet" || bad "block refusal text"
else
  ok "no block device node visible; block refusal covered by the static check below"
fi
grep -q '\[\[ -b "${path}" \]\]' "${PROBE}" && ok "the helper tests for block devices explicitly" || bad "no explicit block-device test"

echo "== pattern"

(
  # shellcheck source=mkosi/runtime/ceralive-card-probe.sh
  source "${PROBE}"
  a=$(card_probe_pattern 00 1048576 | wc -c)
  b=$(card_probe_pattern 00 1048576 | sha256sum)
  c=$(card_probe_pattern 00 2097152 | sha256sum)
  d=$(card_probe_pattern 01 1048576 | sha256sum)
  e=$(card_probe_pattern 00 1048576 | sed -n '2048p' | cut -c1-60)
  printf '%s|%s|%s|%s\n' "${a}" "$([[ "${b}" != "${c}" ]] && echo off-unique)" "$([[ "${b}" != "${d}" ]] && echo run-unique)" "${e}"
) >"${WORK}/pat.out"
IFS='|' read -r plen pu ru last_line <"${WORK}/pat.out"
[[ ${plen} -eq ${MIB} ]] && ok "a mark is exactly 1 MiB" || bad "mark length ${plen}"
[[ "${pu}" == off-unique && "${ru}" == run-unique ]] && ok "marks differ by offset and by run" || bad "pattern uniqueness: ${pu} ${ru}"
[[ "${last_line}" == *"sector=2047"* ]] && ok "every sector carries its own index" || bad "last sector: ${last_line}"

echo "== not wired"

# The helper must stay out of the image until real cards qualify it. Search the
# build, image and CI trees; the helper's own file is the only hit allowed.
(cd "${ROOT}" && grep -rIl --exclude-dir=.git -e 'ceralive-card-probe' -- mkosi lib ci build dev-push dev-sync manifests tools fleet 2>/dev/null) >"${WORK}/wired" || true
grep -vx 'mkosi/runtime/ceralive-card-probe.sh' "${WORK}/wired" >"${WORK}/wired-other" || true
[[ ! -s "${WORK}/wired-other" ]] && ok "nothing in the build, image or CI trees references the probe" || bad "probe referenced by: $(tr '\n' ' ' <"${WORK}/wired-other")"
grep -qx 'mkosi/runtime/ceralive-card-probe.sh' "${WORK}/wired" && ok "non-vacuous: the search does find the helper itself" || bad "wiring search found nothing at all"

printf '\n RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]

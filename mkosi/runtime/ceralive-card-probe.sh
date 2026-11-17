#!/usr/bin/env bash
#
# ceralive-card-probe.sh — bounded card size and fake-capacity probe (core only).
#
# STATUS: NOT INSTALLED AND NOT INVOKED. No unit, postinst module, build step or
# image layer references this file, and tests/card-capacity-probe.test.sh fails
# if one starts to. It is the host-tested core of a first-boot check that still
# needs qualification on real cards before anything may call it on a device.
# Until then it accepts only an owned regular file and refuses block devices.
#
# WHAT IT CHECKS
#
# A card that claims more space than it has usually maps writes past its real
# size back onto lower addresses ("wraps"), or drops them. The probe runs before
# the data partition grows, while nothing of the user's is on the card:
#
#   1. size: the target's reported size must reach the reference minimum (when
#      the reference sets one) and leave room for marks after the image;
#   2. image area, before writing: the loader area (everything before the first
#      partition, which includes the protective MBR and primary GPT) and the
#      backup GPT must still match the hashes recorded from the pristine image.
#      Files inside the boot partition are never hashed: setup tools may add
#      configuration files there and some hosts add folders after writing;
#   3. marks: a 1 MiB pattern, unique to this run and to its offset, is written
#      at up to 64 evenly spread offsets after the image, plus every
#      power-of-two offset in that space. All marks are written before any is
#      read; the target is then flushed and its cached pages dropped;
#   4. readback: every mark must read back exactly;
#   5. image area, after: the step 2 hashes must still match.
#
# Power-of-two offsets matter because the common fake wraps at a power-of-two
# real size: those marks then land on each other and on offset zero, so a later
# mark overwrites an earlier one and the loader-area hash changes. Evenly spread
# marks alone can each land somewhere distinct and all read back fine.
#
# Requested offsets never fall below the first MiB boundary at or after the
# reference image end or past the reported size. A wrapping target can redirect
# those writes into the image, including the loader and running rootfs. It writes at most
# (64 + number of power-of-two offsets) MiB. It runs no speed test and makes no
# whole-card check; a full check (f3, H2testw) remains a separate, offline step.
#
# KNOWN LIMIT: most non-power-of-two wrap sizes can evade this sampling when
# the image is large relative to the real capacity. Marks may overwrite boot
# or rootfs contents outside the hashed regions and still produce exit 0 pass.
# The small host fixture does not represent that blind spot. A pass proves only
# the sampled marks and regions matched, never genuine capacity or image safety.
# The reference is trusted, including image_bytes and its region list. I/O also
# reopens the target path; a mid-run replacement can receive writes before the
# final identity check refuses it. Both require hardening before any caller.
#
# USAGE
#
#   ceralive-card-probe.sh reference IMAGE [--min-media-bytes N]
#       Print the reference record for a pristine GPT image (build side).
#   ceralive-card-probe.sh probe TARGET REFERENCE [--marks N]
#       Probe TARGET against REFERENCE. N is 2..64 (default 64).
#
# Output is key=value lines on stdout; explanations go to stderr.
#
# EXIT STATUS
#   0  pass
#   1  fake-or-faulty: a mark read back wrong, or the image area changed
#   2  refused: bad arguments, invalid reference or unsupported target
#   3  io-error: a read, write or flush failed; the probe could not finish
#   4  too-small: below the reference minimum, or no room after the image
#
# STORAGE SEAM
#
# All target I/O goes through card_io_size, card_io_read, card_io_write and
# card_io_flush. Sourcing this file defines the regular-file versions and does
# not run main; a test may redefine those four functions to model a fake card.
# There is no environment variable that selects another implementation.
#
# Profile: device-daemon (docs/shell-profiles.md): `set -uo pipefail`, no `-e`.
#
# shellcheck shell=bash

set -uo pipefail

readonly CARD_PROBE_FORMAT='ceralive-card-probe-reference/1'
readonly CARD_PROBE_MIB=1048576
readonly CARD_PROBE_MARK_BYTES=${CARD_PROBE_MIB}
readonly CARD_PROBE_SECTOR=512
readonly CARD_PROBE_DEFAULT_MARKS=64
readonly CARD_PROBE_MAX_MARKS=64
readonly CARD_PROBE_MIN_MARKS=2
readonly CARD_PROBE_MAX_REGIONS=4
readonly CARD_PROBE_MAX_GPT_ENTRIES=256
readonly CARD_PROBE_MAX_LOGGED=16

readonly CARD_PROBE_EXIT_PASS=0
readonly CARD_PROBE_EXIT_FAIL=1
readonly CARD_PROBE_EXIT_REFUSED=2
readonly CARD_PROBE_EXIT_IO=3
readonly CARD_PROBE_EXIT_SMALL=4

card_probe_say() { printf 'ceralive-card-probe: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Regular-file storage (the only implementation shipped in this file)
# ---------------------------------------------------------------------------

CARD_PROBE_TARGET=''

card_io_size() {
  stat -c '%s' -- "${CARD_PROBE_TARGET}"
}

# card_io_read OFFSET LENGTH: LENGTH bytes at OFFSET to stdout. Both are
# multiples of 512.
card_io_read() {
  local off=$1 len=$2 bs=${CARD_PROBE_SECTOR}
  if (( off % CARD_PROBE_MIB == 0 && len % CARD_PROBE_MIB == 0 )); then
    bs=${CARD_PROBE_MIB}
  fi
  dd if="${CARD_PROBE_TARGET}" bs="${bs}" skip=$((off / bs)) count=$((len / bs)) \
    status=none
}

# card_io_write OFFSET LENGTH: write LENGTH bytes from stdin at OFFSET. Both are
# multiples of 1 MiB.
card_io_write() {
  local off=$1 len=$2
  dd of="${CARD_PROBE_TARGET}" bs="${CARD_PROBE_MIB}" seek=$((off / CARD_PROBE_MIB)) \
    count=$((len / CARD_PROBE_MIB)) iflag=fullblock conv=notrunc status=none
}

# card_io_flush: make the writes durable, then drop the target's cached pages so
# the readback comes from the medium rather than from memory.
card_io_flush() {
  sync -- "${CARD_PROBE_TARGET}" \
    && dd if="${CARD_PROBE_TARGET}" iflag=nocache count=0 status=none
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

card_probe_is_uint() { [[ "$1" =~ ^(0|[1-9][0-9]{0,17})$ ]]; } # < 10^18, inside int64

card_probe_sha256() { sha256sum | { read -r sum _ && printf '%s\n' "${sum}"; }; }

# card_probe_pattern NONCE OFFSET: exactly 1 MiB. Every 512-byte sector names the
# run, the mark offset and the sector index, so a mark that landed on another,
# a stale mark from an earlier run and a blank read all differ from it.
card_probe_pattern() {
  awk -v run="$1" -v off="$2" 'BEGIN {
    for (i = 0; i < 2048; i++) {
      s = sprintf("CERALIVE-CARD-PROBE v1 run=%s mark=%s sector=%04d ", run, off, i)
      while (length(s) < 511) s = s s
      printf "%s\n", substr(s, 1, 511)
    }
  }'
}

card_probe_nonce() {
  od -An -tx1 -N16 /dev/urandom | tr -d ' \n'
}

# card_probe_u_le FILE OFFSET BYTES: unsigned little-endian integer (4 or 8 bytes).
card_probe_u_le() {
  od --endian=little -An -t "u$3" -j "$2" -N "$3" -- "$1" | tr -d ' \n'
}

# ---------------------------------------------------------------------------
# reference: hash the loader area and the backup GPT of a pristine image
# ---------------------------------------------------------------------------

card_probe_reference() {
  local image=$1 min_media=$2
  local size sig entries_lba count esize alt_lba last_usable
  local i entry type first min_first='' loader_bytes backup_off backup_len

  [[ -f "${image}" && ! -L "${image}" ]] || { card_probe_say "not a regular image file: ${image}"; return "${CARD_PROBE_EXIT_REFUSED}"; }
  size=$(stat -c '%s' -- "${image}") || return "${CARD_PROBE_EXIT_IO}"
  (( size > 0 && size % CARD_PROBE_SECTOR == 0 )) \
    || { card_probe_say "image size ${size} is not a positive multiple of 512"; return "${CARD_PROBE_EXIT_REFUSED}"; }
  (( size >= 68 * CARD_PROBE_SECTOR )) \
    || { card_probe_say "image too small to hold two GPTs"; return "${CARD_PROBE_EXIT_REFUSED}"; }

  sig=$(dd if="${image}" bs=1 skip=512 count=8 status=none | tr -d '\0') || return "${CARD_PROBE_EXIT_IO}"
  [[ "${sig}" == 'EFI PART' ]] || { card_probe_say "no primary GPT header at LBA 1"; return "${CARD_PROBE_EXIT_REFUSED}"; }

  alt_lba=$(card_probe_u_le "${image}" $((512 + 32)) 8)
  last_usable=$(card_probe_u_le "${image}" $((512 + 48)) 8)
  entries_lba=$(card_probe_u_le "${image}" $((512 + 72)) 8)
  count=$(card_probe_u_le "${image}" $((512 + 80)) 4)
  esize=$(card_probe_u_le "${image}" $((512 + 84)) 4)
  for i in "${alt_lba}" "${last_usable}" "${entries_lba}" "${count}" "${esize}"; do
    card_probe_is_uint "${i}" || { card_probe_say "unreadable GPT header field"; return "${CARD_PROBE_EXIT_REFUSED}"; }
  done
  (( count >= 1 && count <= CARD_PROBE_MAX_GPT_ENTRIES && esize >= 128 && esize % 128 == 0 && esize <= 1024 )) \
    || { card_probe_say "unsupported GPT entry table (${count} x ${esize})"; return "${CARD_PROBE_EXIT_REFUSED}"; }

  for (( i = 0; i < count; i++ )); do
    entry=$(( entries_lba * CARD_PROBE_SECTOR + i * esize ))
    type=$(od -An -tx1 -j "${entry}" -N 16 -- "${image}" | tr -d ' \n')
    [[ "${type}" =~ ^0+$ ]] && continue
    first=$(card_probe_u_le "${image}" $((entry + 32)) 8)
    card_probe_is_uint "${first}" || { card_probe_say "unreadable GPT entry ${i}"; return "${CARD_PROBE_EXIT_REFUSED}"; }
    if [[ -z "${min_first}" ]] || (( first < min_first )); then min_first=${first}; fi
  done
  [[ -n "${min_first}" ]] || { card_probe_say "GPT has no partitions"; return "${CARD_PROBE_EXIT_REFUSED}"; }

  loader_bytes=$(( min_first * CARD_PROBE_SECTOR ))
  (( loader_bytes >= 34 * CARD_PROBE_SECTOR && loader_bytes < size )) \
    || { card_probe_say "first partition starts inside the primary GPT or past the image"; return "${CARD_PROBE_EXIT_REFUSED}"; }

  # Backup GPT: its entry array followed by its header at the alternate LBA. It
  # must sit after the last usable LBA, so it never covers partition contents.
  backup_len=$(( ( (count * esize + CARD_PROBE_SECTOR - 1) / CARD_PROBE_SECTOR + 1 ) * CARD_PROBE_SECTOR ))
  backup_off=$(( (alt_lba + 1) * CARD_PROBE_SECTOR - backup_len ))
  (( backup_off > last_usable * CARD_PROBE_SECTOR && backup_off >= loader_bytes \
     && backup_off + backup_len <= size )) \
    || { card_probe_say "backup GPT is not after the last usable LBA inside the image"; return "${CARD_PROBE_EXIT_REFUSED}"; }
  sig=$(dd if="${image}" bs=512 skip="${alt_lba}" count=1 status=none | head -c 8 | tr -d '\0')
  [[ "${sig}" == 'EFI PART' ]] || { card_probe_say "no backup GPT header at LBA ${alt_lba}"; return "${CARD_PROBE_EXIT_REFUSED}"; }

  local loader_sum backup_sum
  loader_sum=$(CARD_PROBE_TARGET=${image} card_io_read 0 "${loader_bytes}" | card_probe_sha256) || return "${CARD_PROBE_EXIT_IO}"
  backup_sum=$(CARD_PROBE_TARGET=${image} card_io_read "${backup_off}" "${backup_len}" | card_probe_sha256) || return "${CARD_PROBE_EXIT_IO}"

  printf 'format=%s\n' "${CARD_PROBE_FORMAT}"
  printf 'image_bytes=%s\n' "${size}"
  [[ -n "${min_media}" ]] && printf 'min_media_bytes=%s\n' "${min_media}"
  printf 'region=loader 0 %s %s\n' "${loader_bytes}" "${loader_sum}"
  printf 'region=backup-gpt %s %s %s\n' "${backup_off}" "${backup_len}" "${backup_sum}"
  return "${CARD_PROBE_EXIT_PASS}"
}

# ---------------------------------------------------------------------------
# probe core: uses only card_io_* and a parsed reference
# ---------------------------------------------------------------------------

# Parsed reference (card_probe_load_reference fills these).
CP_IMAGE_BYTES=0
CP_MIN_MEDIA=0
CP_REGION_NAME=()
CP_REGION_OFF=()
CP_REGION_LEN=()
CP_REGION_SUM=()

card_probe_load_reference() {
  local file=$1 line key value name off len sum seen_format=0
  CP_IMAGE_BYTES=0; CP_MIN_MEDIA=0
  CP_REGION_NAME=(); CP_REGION_OFF=(); CP_REGION_LEN=(); CP_REGION_SUM=()
  [[ -f "${file}" ]] || { card_probe_say "reference not found: ${file}"; return 1; }
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^([a-z_]+)=(.*)$ ]] || { card_probe_say "malformed reference line: ${line}"; return 1; }
    key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
    case "${key}" in
      format)
        [[ "${value}" == "${CARD_PROBE_FORMAT}" ]] || { card_probe_say "unknown reference format: ${value}"; return 1; }
        seen_format=1 ;;
      image_bytes)
        card_probe_is_uint "${value}" || { card_probe_say "bad image_bytes"; return 1; }
        CP_IMAGE_BYTES=${value} ;;
      min_media_bytes)
        card_probe_is_uint "${value}" || { card_probe_say "bad min_media_bytes"; return 1; }
        CP_MIN_MEDIA=${value} ;;
      region)
        [[ "${value}" =~ ^([a-z][a-z-]{0,31})\ ([0-9]{1,18})\ ([0-9]{1,18})\ ([0-9a-f]{64})$ ]] \
          || { card_probe_say "malformed region: ${value}"; return 1; }
        name=${BASH_REMATCH[1]}; off=${BASH_REMATCH[2]}; len=${BASH_REMATCH[3]}; sum=${BASH_REMATCH[4]}
        card_probe_is_uint "${off}" && card_probe_is_uint "${len}" \
          || { card_probe_say "bad region numbers: ${value}"; return 1; }
        (( ${#CP_REGION_NAME[@]} < CARD_PROBE_MAX_REGIONS )) || { card_probe_say "too many regions"; return 1; }
        CP_REGION_NAME+=("${name}"); CP_REGION_OFF+=("${off}"); CP_REGION_LEN+=("${len}"); CP_REGION_SUM+=("${sum}") ;;
      *) card_probe_say "unknown reference key: ${key}"; return 1 ;;
    esac
  done <"${file}"
  (( seen_format == 1 )) || { card_probe_say "reference has no format line"; return 1; }
  (( CP_IMAGE_BYTES > 0 && CP_IMAGE_BYTES % CARD_PROBE_SECTOR == 0 )) \
    || { card_probe_say "image_bytes must be a positive multiple of 512"; return 1; }
  (( ${#CP_REGION_NAME[@]} >= 1 )) || { card_probe_say "reference lists no regions"; return 1; }
  local i
  for i in "${!CP_REGION_NAME[@]}"; do
    off=${CP_REGION_OFF[i]}; len=${CP_REGION_LEN[i]}
    (( len > 0 && off % CARD_PROBE_SECTOR == 0 && len % CARD_PROBE_SECTOR == 0 \
       && off + len <= CP_IMAGE_BYTES )) \
      || { card_probe_say "region ${CP_REGION_NAME[i]} is not sector-aligned inside the image"; return 1; }
  done
  return 0
}

# card_probe_check_regions: prints one region name per changed region; returns
# 0 when all match, 1 when any differ, 3 when a read failed.
card_probe_check_regions() {
  local i sum rc=0
  for i in "${!CP_REGION_NAME[@]}"; do
    sum=$(card_io_read "${CP_REGION_OFF[i]}" "${CP_REGION_LEN[i]}" | card_probe_sha256) || return 3
    if [[ "${sum}" != "${CP_REGION_SUM[i]}" ]]; then
      printf '%s\n' "${CP_REGION_NAME[i]}"
      rc=1
    fi
  done
  return "${rc}"
}

# card_probe_offsets SIZE MARKS: the mark offsets, ascending and unique.
card_probe_offsets() {
  local size=$1 marks=$2 start last span i p
  start=$(( (CP_IMAGE_BYTES + CARD_PROBE_MIB - 1) / CARD_PROBE_MIB * CARD_PROBE_MIB ))
  last=$(( (size - CARD_PROBE_MARK_BYTES) / CARD_PROBE_MIB * CARD_PROBE_MIB ))
  span=$(( last - start ))
  {
    for (( i = 0; i < marks; i++ )); do
      printf '%s\n' $(( start + (i * span / (marks - 1)) / CARD_PROBE_MIB * CARD_PROBE_MIB ))
    done
    for (( p = CARD_PROBE_MIB; p <= last; p *= 2 )); do
      (( p >= start )) && printf '%s\n' "${p}"
    done
  } | sort -n -u
}

card_probe_result() { # result reason
  printf 'result=%s\nreason=%s\n' "$1" "$2"
}

# card_probe_core REFERENCE_FILE MARKS
card_probe_core() {
  local reference=$1 marks=$2
  local size start nonce off rc changed i n_bad=0 written=0
  local -a offsets=() sums=() bad=()

  card_probe_is_uint "${marks}" && (( marks >= CARD_PROBE_MIN_MARKS && marks <= CARD_PROBE_MAX_MARKS )) \
    || { card_probe_result refused bad-arguments; return "${CARD_PROBE_EXIT_REFUSED}"; }
  card_probe_load_reference "${reference}" \
    || { card_probe_result refused invalid-reference; return "${CARD_PROBE_EXIT_REFUSED}"; }

  size=$(card_io_size) && card_probe_is_uint "${size}" \
    || { card_probe_result io-error size-unreadable; return "${CARD_PROBE_EXIT_IO}"; }
  start=$(( (CP_IMAGE_BYTES + CARD_PROBE_MIB - 1) / CARD_PROBE_MIB * CARD_PROBE_MIB ))
  printf 'size_bytes=%s\nimage_bytes=%s\nprobe_start=%s\n' "${size}" "${CP_IMAGE_BYTES}" "${start}"

  if (( CP_MIN_MEDIA > 0 && size < CP_MIN_MEDIA )); then
    card_probe_say "card reports ${size} bytes; this image needs at least ${CP_MIN_MEDIA}"
    card_probe_result too-small below-minimum
    return "${CARD_PROBE_EXIT_SMALL}"
  fi
  # At least two distinct mark positions must fit after the image.
  if (( size < start + 2 * CARD_PROBE_MARK_BYTES )); then
    card_probe_say "card reports ${size} bytes; no room for marks after the image"
    card_probe_result too-small no-room-after-image
    return "${CARD_PROBE_EXIT_SMALL}"
  fi

  # The image area must be intact before anything is written.
  changed=$(card_probe_check_regions); rc=$?
  if (( rc == 3 )); then card_probe_result io-error region-read; return "${CARD_PROBE_EXIT_IO}"; fi
  if (( rc != 0 )); then
    while IFS= read -r i; do printf 'region_changed=%s\n' "${i}"; done <<<"${changed}"
    printf 'marks_written=0\n'
    card_probe_say "the image area no longer matches the image; nothing was written"
    card_probe_result fake-or-faulty image-changed-before-probe
    return "${CARD_PROBE_EXIT_FAIL}"
  fi

  mapfile -t offsets < <(card_probe_offsets "${size}" "${marks}")
  nonce=$(card_probe_nonce)
  [[ "${nonce}" =~ ^[0-9a-f]{32}$ ]] || { card_probe_result io-error no-randomness; return "${CARD_PROBE_EXIT_IO}"; }

  for off in "${offsets[@]}"; do
    # Bound check on every write, independent of how the offsets were made.
    if (( off % CARD_PROBE_MIB != 0 || off < start || off + CARD_PROBE_MARK_BYTES > size )); then
      card_probe_say "internal error: mark offset ${off} outside [${start}, ${size})"
      card_probe_result refused offset-out-of-bounds
      return "${CARD_PROBE_EXIT_REFUSED}"
    fi
  done
  (( ${#offsets[@]} >= CARD_PROBE_MIN_MARKS && ${#offsets[@]} <= CARD_PROBE_MAX_MARKS + 64 )) \
    || { card_probe_result refused mark-count-out-of-bounds; return "${CARD_PROBE_EXIT_REFUSED}"; }

  for off in "${offsets[@]}"; do
    sums+=("$(card_probe_pattern "${nonce}" "${off}" | card_probe_sha256)")
    if ! card_probe_pattern "${nonce}" "${off}" | card_io_write "${off}" "${CARD_PROBE_MARK_BYTES}"; then
      printf 'marks_written=%s\nio_error_offset=%s\n' "${written}" "${off}"
      card_probe_result io-error mark-write
      return "${CARD_PROBE_EXIT_IO}"
    fi
    written=$(( written + 1 ))
  done
  printf 'marks_written=%s\n' "${written}"

  card_io_flush || { card_probe_result io-error flush; return "${CARD_PROBE_EXIT_IO}"; }

  local sum
  for i in "${!offsets[@]}"; do
    off=${offsets[i]}
    if ! sum=$(card_io_read "${off}" "${CARD_PROBE_MARK_BYTES}" | card_probe_sha256); then
      printf 'io_error_offset=%s\n' "${off}"
      card_probe_result io-error mark-read
      return "${CARD_PROBE_EXIT_IO}"
    fi
    if [[ "${sum}" != "${sums[i]}" ]]; then
      n_bad=$(( n_bad + 1 ))
      (( ${#bad[@]} < CARD_PROBE_MAX_LOGGED )) && bad+=("${off}")
    fi
  done
  printf 'mismatches=%s\n' "${n_bad}"
  for off in "${bad[@]}"; do printf 'mismatch_offset=%s\n' "${off}"; done

  changed=$(card_probe_check_regions); rc=$?
  if (( rc == 3 )); then card_probe_result io-error region-read; return "${CARD_PROBE_EXIT_IO}"; fi
  if (( rc != 0 )); then
    while IFS= read -r i; do printf 'region_changed=%s\n' "${i}"; done <<<"${changed}"
  fi

  if (( n_bad > 0 )); then
    card_probe_say "${n_bad} of ${#offsets[@]} marks read back wrong"
    card_probe_result fake-or-faulty mark-mismatch
    return "${CARD_PROBE_EXIT_FAIL}"
  fi
  if (( rc != 0 )); then
    card_probe_say "writing after the image changed the image area"
    card_probe_result fake-or-faulty image-changed-by-probe
    return "${CARD_PROBE_EXIT_FAIL}"
  fi
  card_probe_result pass all-marks-and-regions-match
  return "${CARD_PROBE_EXIT_PASS}"
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

card_probe_identity() { stat -c '%d:%i' -- "$1"; }

# card_probe_validate_target PATH: only an owned, single-link regular file.
card_probe_validate_target() {
  local path=$1 owner links
  if [[ -L "${path}" ]]; then card_probe_say "refusing a symlink: ${path}"; return 1; fi
  if [[ -b "${path}" ]]; then
    card_probe_say "refusing block device ${path}: this probe is not qualified on real cards yet"
    return 1
  fi
  [[ -f "${path}" ]] || { card_probe_say "refusing ${path}: not a regular file"; return 1; }
  read -r owner links < <(stat -c '%u %h' -- "${path}") || return 1
  [[ "${owner}" == "$(id -u)" ]] || { card_probe_say "refusing ${path}: not owned by the caller"; return 1; }
  [[ "${links}" == 1 ]] || { card_probe_say "refusing ${path}: it has other hard links"; return 1; }
  return 0
}

card_probe_usage() {
  sed -n '/^# USAGE$/,/^# Output/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

card_probe_main() {
  local cmd=${1:-}
  case "${cmd}" in
    reference)
      shift
      local image=${1:-} min=''
      [[ -n "${image}" ]] || { card_probe_usage; return "${CARD_PROBE_EXIT_REFUSED}"; }
      shift
      if (( $# > 0 )); then
        [[ "$1" == --min-media-bytes && $# -eq 2 ]] && card_probe_is_uint "$2" \
          || { card_probe_usage; return "${CARD_PROBE_EXIT_REFUSED}"; }
        min=$2
      fi
      card_probe_reference "${image}" "${min}"
      ;;
    probe)
      shift
      (( $# == 2 || $# == 4 )) || { card_probe_usage; return "${CARD_PROBE_EXIT_REFUSED}"; }
      local target=$1 reference=$2 marks=${CARD_PROBE_DEFAULT_MARKS} before after rc out
      if (( $# == 4 )); then
        [[ "$3" == --marks ]] && card_probe_is_uint "$4" \
          && (( $4 >= CARD_PROBE_MIN_MARKS && $4 <= CARD_PROBE_MAX_MARKS )) \
          || { card_probe_say "--marks must be ${CARD_PROBE_MIN_MARKS}..${CARD_PROBE_MAX_MARKS}"; card_probe_result refused bad-arguments; return "${CARD_PROBE_EXIT_REFUSED}"; }
        marks=$4
      fi
      card_probe_validate_target "${target}" \
        || { card_probe_result refused unsupported-target; return "${CARD_PROBE_EXIT_REFUSED}"; }
      before=$(card_probe_identity "${target}") \
        || { card_probe_result refused unsupported-target; return "${CARD_PROBE_EXIT_REFUSED}"; }
      CARD_PROBE_TARGET=${target}
      out=$(card_probe_core "${reference}" "${marks}"); rc=$?
      after=$(card_probe_identity "${target}" 2>/dev/null) || after=''
      if [[ "${after}" != "${before}" ]]; then
        printf '%s\n' "${out}" | grep -v -E '^(result|reason)='
        card_probe_say "the target was replaced while probing"
        card_probe_result refused target-changed
        return "${CARD_PROBE_EXIT_REFUSED}"
      fi
      printf '%s\n' "${out}"
      return "${rc}"
      ;;
    *)
      card_probe_usage
      return "${CARD_PROBE_EXIT_REFUSED}"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  card_probe_main "$@"
  exit $?
fi

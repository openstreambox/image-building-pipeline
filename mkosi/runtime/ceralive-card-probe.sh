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
# image end or past the reported size. A wrapping target can redirect
# those writes into the image, including the loader and running rootfs. It writes at most
# (64 + number of power-of-two offsets) MiB. It runs no speed test and makes no
# whole-card check; a full check (f3, H2testw) remains a separate, offline step.
#
# The reference is not trusted for geometry. Before the first write, the
# target's primary and backup GPT are read, CRC-checked and cross-checked
# (bounds, overlap, mirror), and the reference must name exactly the image end
# and the two regions that this GPT implies. The target is opened once, checked
# through that descriptor, and every read, write and flush goes to the opened
# file, never through its path again.
#
# KNOWN LIMIT: most non-power-of-two wrap sizes can evade this sampling when
# the image is large relative to the real capacity. Marks may overwrite boot
# or rootfs contents outside the hashed regions and still produce exit 0 pass.
# The small host fixture does not represent that blind spot. A pass proves only
# the sampled marks and regions matched, never genuine capacity or image safety.
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
#   2  refused: bad arguments, invalid reference, invalid GPT, reference that
#      does not match the GPT, unsupported or replaced target
#   3  io-error: a read, write or flush failed; the probe could not finish
#   4  too-small: below the reference minimum, or no room after the image
#
# STORAGE SEAM
#
# All target I/O goes through card_io_size, card_io_read, card_io_write and
# card_io_flush. They use only the descriptor in CARD_PROBE_FD, through
# /proc/self/fd, so the target path is never resolved again after it has been
# opened and checked. Every dd must move exactly the requested whole blocks;
# a short read or write is an I/O error. Sourcing this file defines the
# regular-file versions and does not run main; a test may redefine those four
# functions to model a fake card. There is no environment variable that selects
# another implementation.
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
readonly CARD_PROBE_MAX_GPT_ENTRIES=256
# GPT LBA fields must fit in 48 bits (128 PiB at 512 bytes), so offsets derived
# from them never overflow Bash's signed 64-bit arithmetic.
readonly CARD_PROBE_MAX_LBA=281474976710655
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

# CARD_PROBE_FD is the descriptor opened and checked by card_probe_open_target
# (or by card_probe_reference for the image); all target I/O uses it.
CARD_PROBE_FD=''

card_probe_fd_path() {
  [[ "${CARD_PROBE_FD}" =~ ^[0-9]{1,4}$ ]] || { card_probe_say "no open target descriptor"; return 1; }
  printf '/proc/self/fd/%s' "${CARD_PROBE_FD}"
}

# card_probe_dd RECORDS dd-operand...: run dd and require exactly RECORDS whole
# records in and out. iflag=fullblock (set by the callers) makes dd assemble
# whole blocks from short reads; a partial record still left means end of file
# or a failed transfer, which is an error here, never data to judge.
card_probe_dd() {
  local want=$1 err rc
  shift
  { err=$(LC_ALL=C dd "$@" status=noxfer 2>&1 1>&3 3>&-); rc=$?; } 3>&1
  (( rc == 0 )) || return 1
  [[ "${err}" == "${want}+0 records in"$'\n'"${want}+0 records out" ]] \
    || { card_probe_say "short transfer: wanted ${want} whole records, dd reported: ${err//$'\n'/; }"; return 1; }
}

card_io_size() {
  local fdp
  fdp=$(card_probe_fd_path) || return 1
  stat -L -c '%s' -- "${fdp}"
}

# card_io_read OFFSET LENGTH: exactly LENGTH bytes at OFFSET to stdout. Both are
# multiples of 512.
card_io_read() {
  local off=$1 len=$2 bs=${CARD_PROBE_SECTOR} fdp
  fdp=$(card_probe_fd_path) || return 1
  if (( off % CARD_PROBE_MIB == 0 && len % CARD_PROBE_MIB == 0 )); then
    bs=${CARD_PROBE_MIB}
  fi
  card_probe_dd $((len / bs)) if="${fdp}" bs="${bs}" skip=$((off / bs)) count=$((len / bs)) \
    iflag=fullblock
}

# card_io_write OFFSET LENGTH: write exactly LENGTH bytes from stdin at OFFSET.
# Both are multiples of 1 MiB.
card_io_write() {
  local off=$1 len=$2 fdp
  fdp=$(card_probe_fd_path) || return 1
  card_probe_dd $((len / CARD_PROBE_MIB)) of="${fdp}" bs="${CARD_PROBE_MIB}" \
    seek=$((off / CARD_PROBE_MIB)) count=$((len / CARD_PROBE_MIB)) iflag=fullblock conv=notrunc
}

# card_io_flush: make the writes durable, then drop the target's cached pages so
# the readback comes from the medium rather than from memory.
card_io_flush() {
  local fdp
  fdp=$(card_probe_fd_path) || return 1
  sync -- "${fdp}" \
    && dd if="${fdp}" iflag=nocache count=0 status=none
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

# ---------------------------------------------------------------------------
# GPT reader (Bash and coreutils only)
# ---------------------------------------------------------------------------

CP_BYTES=()
CP_CRC_TABLE=()
CP_LE=0

# card_probe_bytes OFFSET LENGTH: the bytes at OFFSET (LENGTH a multiple of 512)
# into CP_BYTES as decimal values. Returns 3 on a failed or short read.
card_probe_bytes() {
  local out
  CP_BYTES=()
  out=$(card_io_read "$1" "$2" | od -An -v -tu1) || return 3
  read -r -d '' -a CP_BYTES <<<"${out}"
  (( ${#CP_BYTES[@]} == $2 )) || return 3
  return 0
}

# card_probe_le INDEX BYTES: little-endian value of CP_BYTES[INDEX..] into CP_LE.
# Fails for an 8-byte value of 2^48 or more.
card_probe_le() {
  local i=$1 n=$2 k v=0
  if (( n == 8 )); then (( CP_BYTES[i + 7] == 0 && CP_BYTES[i + 6] == 0 )) || return 1; fi
  for (( k = n - 1; k >= 0; k-- )); do v=$(( v * 256 + CP_BYTES[i + k] )); done
  CP_LE=${v}
}

# card_probe_crc32 START LENGTH: CRC-32 (as used by GPT) of CP_BYTES[START..].
card_probe_crc32() {
  local i j c
  if (( ${#CP_CRC_TABLE[@]} != 256 )); then
    for (( i = 0; i < 256; i++ )); do
      c=${i}
      for (( j = 0; j < 8; j++ )); do
        if (( c & 1 )); then c=$(( (c >> 1) ^ 0xEDB88320 )); else c=$(( c >> 1 )); fi
      done
      CP_CRC_TABLE[i]=${c}
    done
  fi
  c=0xFFFFFFFF
  for (( i = $1; i < $1 + $2; i++ )); do
    c=$(( CP_CRC_TABLE[(c ^ CP_BYTES[i]) & 255] ^ (c >> 8) ))
  done
  printf '%s\n' $(( c ^ 0xFFFFFFFF ))
}

# Filled by card_probe_read_gpt.
CP_GPT_END=0      # bytes: end of the backup GPT header, the image length
CP_GPT_LOADER=0   # bytes: start of the lowest partition
CP_GPT_BK_OFF=0   # bytes: start of the backup entry array
CP_GPT_BK_LEN=0   # bytes: backup entry array plus backup header

card_probe_gpt_bad() { card_probe_say "invalid GPT: $*"; return 1; }

# card_probe_gpt_header LBA: check the header in CP_BYTES (one sector read at
# LBA) and set the hdr_* variables of the caller (dynamic scope).
card_probe_gpt_header() {
  local lba=$1 crc
  [[ "${CP_BYTES[*]:0:12}" == '69 70 73 32 80 65 82 84 0 0 1 0' ]] \
    || card_probe_gpt_bad "no GPT header (signature or revision 1.0) at LBA ${lba}" || return
  card_probe_le 12 4; hdr_size=${CP_LE}
  (( hdr_size >= 92 && hdr_size <= CARD_PROBE_SECTOR )) || card_probe_gpt_bad "header size ${hdr_size} at LBA ${lba}" || return
  card_probe_le 16 4; hdr_crc=${CP_LE}
  CP_BYTES[16]=0; CP_BYTES[17]=0; CP_BYTES[18]=0; CP_BYTES[19]=0
  crc=$(card_probe_crc32 0 "${hdr_size}")
  [[ "${crc}" == "${hdr_crc}" ]] || card_probe_gpt_bad "header CRC mismatch at LBA ${lba}" || return
  [[ "${CP_BYTES[*]:20:4}" == '0 0 0 0' ]] || card_probe_gpt_bad "reserved header field set at LBA ${lba}" || return
  card_probe_le 24 8 && hdr_my=${CP_LE} \
    && card_probe_le 32 8 && hdr_alt=${CP_LE} \
    && card_probe_le 40 8 && hdr_first=${CP_LE} \
    && card_probe_le 48 8 && hdr_last=${CP_LE} \
    && card_probe_le 72 8 && hdr_ent=${CP_LE} \
    || card_probe_gpt_bad "LBA field of 2^48 or more at LBA ${lba}" || return
  card_probe_le 80 4; hdr_count=${CP_LE}
  card_probe_le 84 4; hdr_esize=${CP_LE}
  card_probe_le 88 4; hdr_ecrc=${CP_LE}
  hdr_guid="${CP_BYTES[*]:56:16}"
  (( hdr_my == lba )) || card_probe_gpt_bad "header at LBA ${lba} names LBA ${hdr_my} as its own" || return
  return 0
}

# card_probe_read_gpt SIZE: read, CRC-check and cross-check the primary and
# backup GPT of the target (SIZE bytes). Sets CP_GPT_*. Returns 0 valid,
# 1 invalid, 3 read error. The backup header must sit inside SIZE, its entry
# array directly before it, after the last usable LBA; every partition must lie
# in [first usable, last usable] and no two may overlap.
card_probe_read_gpt() {
  local size=$1 lbas hdr_size hdr_crc hdr_my hdr_alt hdr_first hdr_last hdr_ent
  local hdr_count hdr_esize hdr_ecrc hdr_guid
  local p_size p_alt p_first p_last p_count p_esize p_ecrc p_guid
  local ent_bytes ent_sectors bk_ent i base first last prev_last min_first='' entries crc
  local -a parts=()

  lbas=$(( size / CARD_PROBE_SECTOR ))
  (( lbas >= 68 )) || card_probe_gpt_bad "target too small to hold two GPTs" || return
  card_probe_bytes "${CARD_PROBE_SECTOR}" "${CARD_PROBE_SECTOR}" || return 3
  card_probe_gpt_header 1 || return 1
  p_size=${hdr_size}; p_alt=${hdr_alt}; p_first=${hdr_first}; p_last=${hdr_last}
  p_count=${hdr_count}; p_esize=${hdr_esize}; p_ecrc=${hdr_ecrc}; p_guid=${hdr_guid}

  (( p_count >= 1 && p_count <= CARD_PROBE_MAX_GPT_ENTRIES && p_esize >= 128 && p_esize <= 1024 \
     && (p_esize & (p_esize - 1)) == 0 )) \
    || card_probe_gpt_bad "unsupported entry table (${p_count} x ${p_esize})" || return
  ent_bytes=$(( p_count * p_esize ))
  ent_sectors=$(( (ent_bytes + CARD_PROBE_SECTOR - 1) / CARD_PROBE_SECTOR ))
  # Order: 0 MBR < 1 header < entries < first usable <= last usable
  #        < backup entries < backup header (alternate LBA) < SIZE.
  (( p_alt < lbas && p_alt <= CARD_PROBE_MAX_LBA )) \
    || card_probe_gpt_bad "alternate LBA ${p_alt} is past the target (${lbas} sectors)" || return
  bk_ent=$(( p_alt - ent_sectors ))
  (( hdr_ent >= 2 && hdr_ent + ent_sectors <= p_first && p_first <= p_last && p_last < bk_ent )) \
    || card_probe_gpt_bad "primary entries ${hdr_ent}, usable ${p_first}..${p_last}, backup entries ${bk_ent} are out of order" || return

  card_probe_bytes $(( hdr_ent * CARD_PROBE_SECTOR )) $(( ent_sectors * CARD_PROBE_SECTOR )) || return 3
  crc=$(card_probe_crc32 0 "${ent_bytes}")
  [[ "${crc}" == "${p_ecrc}" ]] || card_probe_gpt_bad "primary entry array CRC mismatch" || return
  entries="${CP_BYTES[*]:0:ent_bytes}"
  for (( i = 0; i < p_count; i++ )); do
    base=$(( i * p_esize ))
    [[ "${CP_BYTES[*]:base:16}" == '0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0' ]] && continue
    card_probe_le $(( base + 32 )) 8 && first=${CP_LE} && card_probe_le $(( base + 40 )) 8 && last=${CP_LE} \
      || card_probe_gpt_bad "entry ${i}: LBA of 2^48 or more" || return
    (( p_first <= first && first <= last && last <= p_last )) \
      || card_probe_gpt_bad "entry ${i} (${first}..${last}) is outside the usable LBAs ${p_first}..${p_last}" || return
    parts+=("${first} ${last}")
    if [[ -z "${min_first}" ]] || (( first < min_first )); then min_first=${first}; fi
  done
  [[ -n "${min_first}" ]] || card_probe_gpt_bad "no partitions" || return
  prev_last=-1
  while read -r first last; do
    (( first > prev_last )) || card_probe_gpt_bad "partitions overlap at LBA ${first}" || return
    prev_last=${last}
  done < <(printf '%s\n' "${parts[@]}" | sort -n -k1,1)

  # The backup header mirrors the primary one.
  card_probe_bytes $(( p_alt * CARD_PROBE_SECTOR )) "${CARD_PROBE_SECTOR}" || return 3
  card_probe_gpt_header "${p_alt}" || return 1
  (( hdr_alt == 1 && hdr_ent == bk_ent && hdr_size == p_size && hdr_first == p_first && hdr_last == p_last \
     && hdr_count == p_count && hdr_esize == p_esize && hdr_ecrc == p_ecrc )) && [[ "${hdr_guid}" == "${p_guid}" ]] \
    || card_probe_gpt_bad "backup header at LBA ${p_alt} does not mirror the primary header" || return
  card_probe_bytes $(( bk_ent * CARD_PROBE_SECTOR )) $(( ent_sectors * CARD_PROBE_SECTOR )) || return 3
  [[ "${CP_BYTES[*]:0:ent_bytes}" == "${entries}" ]] \
    || card_probe_gpt_bad "backup entry array differs from the primary one" || return

  CP_GPT_END=$(( (p_alt + 1) * CARD_PROBE_SECTOR ))
  CP_GPT_LOADER=$(( min_first * CARD_PROBE_SECTOR ))
  CP_GPT_BK_OFF=$(( bk_ent * CARD_PROBE_SECTOR ))
  CP_GPT_BK_LEN=$(( (ent_sectors + 1) * CARD_PROBE_SECTOR ))
  return 0
}

# ---------------------------------------------------------------------------
# reference: hash the loader area and the backup GPT of a pristine image
# ---------------------------------------------------------------------------

card_probe_reference() {
  local image=$1 min_media=$2 size rc fd loader_sum backup_sum

  [[ -f "${image}" && ! -L "${image}" ]] || { card_probe_say "not a regular image file: ${image}"; return "${CARD_PROBE_EXIT_REFUSED}"; }
  { exec {fd}<"${image}"; } 2>/dev/null || { card_probe_say "cannot open ${image}"; return "${CARD_PROBE_EXIT_IO}"; }
  CARD_PROBE_FD=${fd}
  [[ "$(stat -L -c '%f' -- "/proc/self/fd/${fd}")" =~ ^8[0-9a-f]{3}$ ]] \
    || { exec {fd}<&-; card_probe_say "not a regular image file: ${image}"; return "${CARD_PROBE_EXIT_REFUSED}"; }
  size=$(card_io_size) || { exec {fd}<&-; return "${CARD_PROBE_EXIT_IO}"; }
  (( size > 0 && size % CARD_PROBE_SECTOR == 0 )) \
    || { exec {fd}<&-; card_probe_say "image size ${size} is not a positive multiple of 512"; return "${CARD_PROBE_EXIT_REFUSED}"; }

  card_probe_read_gpt "${size}"; rc=$?
  if (( rc != 0 )); then
    exec {fd}<&-
    (( rc == 3 )) && return "${CARD_PROBE_EXIT_IO}"
    return "${CARD_PROBE_EXIT_REFUSED}"
  fi
  (( CP_GPT_END == size )) \
    || { exec {fd}<&-; card_probe_say "the backup GPT header is not the last sector of the image"; return "${CARD_PROBE_EXIT_REFUSED}"; }

  loader_sum=$(card_io_read 0 "${CP_GPT_LOADER}" | card_probe_sha256) \
    && backup_sum=$(card_io_read "${CP_GPT_BK_OFF}" "${CP_GPT_BK_LEN}" | card_probe_sha256) \
    || { exec {fd}<&-; return "${CARD_PROBE_EXIT_IO}"; }
  exec {fd}<&-

  printf 'format=%s\n' "${CARD_PROBE_FORMAT}"
  printf 'image_bytes=%s\n' "${size}"
  [[ -n "${min_media}" ]] && printf 'min_media_bytes=%s\n' "${min_media}"
  printf 'region=loader 0 %s %s\n' "${CP_GPT_LOADER}" "${loader_sum}"
  printf 'region=backup-gpt %s %s %s\n' "${CP_GPT_BK_OFF}" "${CP_GPT_BK_LEN}" "${backup_sum}"
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

# card_probe_load_reference FILE: parse a reference strictly. It must hold one
# format, one image_bytes, at most one min_media_bytes and exactly the two
# regions the build side writes, in order: loader at offset 0, then backup-gpt
# ending at image_bytes. Their exact bounds are checked against the target's
# GPT later (card_probe_core); here only their shape.
card_probe_load_reference() {
  local file=$1 line key value name off len sum seen=' '
  CP_IMAGE_BYTES=0; CP_MIN_MEDIA=0
  CP_REGION_NAME=(); CP_REGION_OFF=(); CP_REGION_LEN=(); CP_REGION_SUM=()
  [[ -f "${file}" ]] || { card_probe_say "reference not found: ${file}"; return 1; }
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^([a-z_]+)=(.*)$ ]] || { card_probe_say "malformed reference line: ${line}"; return 1; }
    key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
    case "${key}" in
      format|image_bytes|min_media_bytes)
        [[ "${seen}" != *" ${key} "* ]] || { card_probe_say "duplicate reference key: ${key}"; return 1; }
        seen+="${key} " ;;
    esac
    case "${key}" in
      format)
        [[ "${value}" == "${CARD_PROBE_FORMAT}" ]] || { card_probe_say "unknown reference format: ${value}"; return 1; } ;;
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
        (( ${#CP_REGION_NAME[@]} < 2 )) || { card_probe_say "more than two regions"; return 1; }
        CP_REGION_NAME+=("${name}"); CP_REGION_OFF+=("${off}"); CP_REGION_LEN+=("${len}"); CP_REGION_SUM+=("${sum}") ;;
      *) card_probe_say "unknown reference key: ${key}"; return 1 ;;
    esac
  done <"${file}"
  [[ "${seen}" == *' format '* ]] || { card_probe_say "reference has no format line"; return 1; }
  (( CP_IMAGE_BYTES > 0 && CP_IMAGE_BYTES % CARD_PROBE_SECTOR == 0 )) \
    || { card_probe_say "image_bytes must be a positive multiple of 512"; return 1; }
  [[ "${CP_REGION_NAME[*]}" == 'loader backup-gpt' ]] \
    || { card_probe_say "reference must list exactly the loader and backup-gpt regions"; return 1; }
  local i
  for i in 0 1; do
    off=${CP_REGION_OFF[i]}; len=${CP_REGION_LEN[i]}
    (( len > 0 && off % CARD_PROBE_SECTOR == 0 && len % CARD_PROBE_SECTOR == 0 \
       && off + len <= CP_IMAGE_BYTES )) \
      || { card_probe_say "region ${CP_REGION_NAME[i]} is not sector-aligned inside the image"; return 1; }
  done
  (( CP_REGION_OFF[0] == 0 && CP_REGION_LEN[0] >= 34 * CARD_PROBE_SECTOR \
     && CP_REGION_OFF[1] >= CP_REGION_LEN[0] && CP_REGION_LEN[1] >= 2 * CARD_PROBE_SECTOR \
     && CP_REGION_OFF[1] + CP_REGION_LEN[1] == CP_IMAGE_BYTES )) \
    || { card_probe_say "regions must be loader [0, first partition) and backup-gpt ending at image_bytes"; return 1; }
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

  # The image area matches the reference hashes. Now the GPT in it must be
  # valid, and the reference must describe exactly that GPT: the image ends at
  # the backup header, the loader region is [0, first partition) and the
  # backup region is the backup entry array plus header. Otherwise the marks
  # could start inside the image.
  card_probe_read_gpt "${size}"; rc=$?
  if (( rc == 3 )); then card_probe_result io-error gpt-read; return "${CARD_PROBE_EXIT_IO}"; fi
  if (( rc != 0 )); then
    printf 'marks_written=0\n'
    card_probe_result refused invalid-gpt
    return "${CARD_PROBE_EXIT_REFUSED}"
  fi
  if (( CP_GPT_END != CP_IMAGE_BYTES || CP_REGION_LEN[0] != CP_GPT_LOADER \
        || CP_REGION_OFF[1] != CP_GPT_BK_OFF || CP_REGION_LEN[1] != CP_GPT_BK_LEN )); then
    printf 'marks_written=0\n'
    card_probe_say "the reference (image ${CP_IMAGE_BYTES}, loader ${CP_REGION_LEN[0]}, backup ${CP_REGION_OFF[1]}+${CP_REGION_LEN[1]}) does not match the GPT (image ${CP_GPT_END}, loader ${CP_GPT_LOADER}, backup ${CP_GPT_BK_OFF}+${CP_GPT_BK_LEN})"
    card_probe_result refused reference-mismatch
    return "${CARD_PROBE_EXIT_REFUSED}"
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

# card_probe_identity PATH: type, device and inode of PATH itself (no symlink
# is followed).
card_probe_identity() { stat -c '%f %d:%i' -- "$1"; }

# card_probe_validate_target PATH: checks made with stat only, before anything
# opens PATH: an owned, single-link regular file, reached without any symlink,
# in directories that only the caller or root can change (or sticky ones), so
# no other user can swap the path between these checks and the open.
card_probe_validate_target() {
  local path=$1 owner links uid resolved literal dir mode
  if [[ -L "${path}" ]]; then card_probe_say "refusing a symlink: ${path}"; return 1; fi
  if [[ -b "${path}" ]]; then
    card_probe_say "refusing block device ${path}: this probe is not qualified on real cards yet"
    return 1
  fi
  [[ -f "${path}" ]] || { card_probe_say "refusing ${path}: not a regular file"; return 1; }
  uid=$(id -u) || return 1
  read -r owner links < <(stat -c '%u %h' -- "${path}") || return 1
  [[ "${owner}" == "${uid}" ]] || { card_probe_say "refusing ${path}: not owned by the caller"; return 1; }
  [[ "${links}" == 1 ]] || { card_probe_say "refusing ${path}: it has other hard links"; return 1; }
  resolved=$(realpath -e -- "${path}") && literal=$(realpath -s -e -- "${path}") \
    || { card_probe_say "refusing ${path}: cannot resolve it"; return 1; }
  [[ "${resolved}" == "${literal}" ]] \
    || { card_probe_say "refusing ${path}: it is reached through a symlink"; return 1; }
  dir=${resolved%/*}
  while :; do
    [[ -n "${dir}" ]] || dir=/
    read -r owner mode < <(stat -c '%u %a' -- "${dir}") \
      || { card_probe_say "refusing ${path}: cannot check ${dir}"; return 1; }
    [[ "${owner}" == 0 || "${owner}" == "${uid}" ]] \
      || { card_probe_say "refusing ${path}: ${dir} belongs to another user"; return 1; }
    if (( (8#${mode} & 8#022) != 0 && (8#${mode} & 8#1000) == 0 )); then
      card_probe_say "refusing ${path}: other users can change ${dir}"
      return 1
    fi
    [[ "${dir}" == / ]] && break
    dir=${dir%/*}
  done
  return 0
}

# card_probe_open_target PATH: open PATH once, for reading and writing, then
# check through that descriptor that the opened file is an owned, single-link
# regular file and that PATH still names exactly it. Sets CARD_PROBE_FD and
# CP_TARGET_ID. Returns 1 for an unsupported file, 2 when PATH changed. All
# later I/O uses the descriptor; PATH is only compared again at the end.
CP_TARGET_ID=''
card_probe_open_target() {
  local path=$1 fd uid fmode fid fuid flinks now
  { exec {fd}<>"${path}"; } 2>/dev/null || { card_probe_say "cannot open ${path}"; return 1; }
  uid=$(id -u)
  read -r fmode fid fuid flinks < <(stat -L -c '%f %d:%i %u %h' -- "/proc/self/fd/${fd}" 2>/dev/null)
  if [[ ! "${fmode:-}" =~ ^8[0-9a-f]{3}$ || "${fuid:-}" != "${uid}" || "${flinks:-}" != 1 ]]; then
    exec {fd}>&-
    card_probe_say "refusing ${path}: the opened file is not an owned, single-link regular file"
    return 1
  fi
  now=$(card_probe_identity "${path}" 2>/dev/null) || now=''
  if [[ "${now}" != "${fmode} ${fid}" ]]; then
    exec {fd}>&-
    card_probe_say "refusing ${path}: it changed between the checks and the open"
    return 2
  fi
  CARD_PROBE_FD=${fd}
  CP_TARGET_ID=${now}
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
      local target=$1 reference=$2 marks=${CARD_PROBE_DEFAULT_MARKS} after rc out
      if (( $# == 4 )); then
        [[ "$3" == --marks ]] && card_probe_is_uint "$4" \
          && (( $4 >= CARD_PROBE_MIN_MARKS && $4 <= CARD_PROBE_MAX_MARKS )) \
          || { card_probe_say "--marks must be ${CARD_PROBE_MIN_MARKS}..${CARD_PROBE_MAX_MARKS}"; card_probe_result refused bad-arguments; return "${CARD_PROBE_EXIT_REFUSED}"; }
        marks=$4
      fi
      card_probe_validate_target "${target}" \
        || { card_probe_result refused unsupported-target; return "${CARD_PROBE_EXIT_REFUSED}"; }
      card_probe_open_target "${target}"; rc=$?
      if (( rc == 1 )); then card_probe_result refused unsupported-target; return "${CARD_PROBE_EXIT_REFUSED}"; fi
      if (( rc != 0 )); then card_probe_result refused target-changed; return "${CARD_PROBE_EXIT_REFUSED}"; fi
      out=$(card_probe_core "${reference}" "${marks}"); rc=$?
      exec {CARD_PROBE_FD}>&-
      CARD_PROBE_FD=''
      after=$(card_probe_identity "${target}" 2>/dev/null) || after=''
      if [[ "${after}" != "${CP_TARGET_ID}" ]]; then
        # Every write went to the opened file, but the path now names something
        # else, so the result no longer describes the path.
        printf '%s\n' "${out}" | grep -v -E '^(result|reason)='
        card_probe_say "the target path was replaced while probing; all I/O used the file opened at the start"
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

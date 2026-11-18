#!/bin/bash
# ceralive-tailscale-enroll — join Tailscale with a key someone placed on BOOT.
#
# 1. A file /boot/osb-tailscale[-<name>].key (".txt" appended by an editor is
#    fine) is read, checked to be one Tailscale auth key, moved into the 0700
#    state directory on /data and removed from the FAT partition at once, so it
#    never stays readable by a PC. <name> becomes the Tailscale machine name.
# 2. While a pending key exists, tailscaled is started and `tailscale up` runs
#    with Tailscale SSH on and no DNS/route changes. On success the pending key
#    is destroyed; on failure (no network yet, expired key) it stays and the
#    timer retries.
# More than one key file, or a file that is not an auth key, is renamed with a
# ".rejected" suffix and never used.
set -euo pipefail

BOOT="${CERALIVE_TS_BOOT_DIR:-/boot}"
STATE="${CERALIVE_TS_STATE_DIR:-/var/lib/tailscale}"
CLI="${CERALIVE_TS_CLI:-/usr/local/bin/tailscale}"
SOCKET="${CERALIVE_TS_SOCKET:-/run/tailscale/tailscaled.sock}"
SYSTEMCTL="${SYSTEMCTL_BIN:-systemctl}"
WAIT="${CERALIVE_TS_SOCKET_WAIT:-30}"
PENDING="${STATE}/pending-authkey"
PENDING_NAME="${STATE}/pending-hostname"

log() { logger -t ceralive-tailscale-enroll -- "$*" 2>/dev/null || true; echo "ceralive-tailscale-enroll: $*"; }

reject() { # file reason
  log "rejected $(basename -- "$1"): $2"
  mv -f -- "$1" "$1.rejected" 2>/dev/null || rm -f -- "$1"
}

take_boot_key() {
  local files=() f key base name
  shopt -s nullglob nocaseglob
  for f in "${BOOT}"/osb-tailscale*; do
    case "${f,,}" in *.rejected) continue ;; esac
    [[ -f "$f" && ! -L "$f" ]] && files+=("$f")
  done
  shopt -u nullglob nocaseglob
  (( ${#files[@]} > 0 )) || return 0
  if (( ${#files[@]} > 1 )); then
    for f in "${files[@]}"; do reject "$f" "more than one osb-tailscale key file on BOOT"; done
    sync -f "${BOOT}" 2>/dev/null || true
    return 0
  fi
  f="${files[0]}"
  if (( $(stat -c %s -- "$f") > 1024 )); then reject "$f" "larger than 1 KiB"; return 0; fi
  # Strip a UTF-8 BOM and all whitespace (Windows editors add CRLF, BOM, ".txt").
  key="$(LC_ALL=C sed '1s/^\xEF\xBB\xBF//' -- "$f" | LC_ALL=C tr -d ' \t\r\n')"
  if [[ ! "$key" =~ ^tskey-auth-[A-Za-z0-9_-]{8,200}$ ]]; then reject "$f" "not a Tailscale auth key"; return 0; fi
  base="$(basename -- "$f")"; base="${base,,}"; base="${base%.txt}"; base="${base%.key}"
  name="${base#osb-tailscale}"; name="${name#-}"
  [[ "$name" =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]] || name=""
  install -d -m 0700 "${STATE}"
  ( umask 077
    printf '%s' "$key" >"${PENDING}.tmp"
    printf '%s' "$name" >"${PENDING_NAME}.tmp" )
  sync "${PENDING}.tmp" "${PENDING_NAME}.tmp"
  mv -f "${PENDING_NAME}.tmp" "${PENDING_NAME}"
  mv -f "${PENDING}.tmp" "${PENDING}"
  sync "${STATE}"
  # FAT has no secure delete; overwrite, then remove, then flush the partition.
  shred -u -z -- "$f" 2>/dev/null || rm -f -- "$f"
  sync -f "${BOOT}" 2>/dev/null || true
  log "key taken off BOOT${name:+ for machine name ${name}}"
}

enroll_pending() {
  [[ -f "${PENDING}" ]] || return 0
  local name="" i args
  [[ -f "${PENDING_NAME}" ]] && name="$(cat -- "${PENDING_NAME}")"
  "${SYSTEMCTL}" start tailscaled.service
  for ((i = 0; i < WAIT; i++)); do [[ -S "${SOCKET}" ]] && break; sleep 1; done
  args=(up "--auth-key=file:${PENDING}" --ssh --accept-dns=false --accept-routes=false --timeout=90s)
  [[ -n "$name" ]] && args+=("--hostname=${name}")
  if "${CLI}" --socket="${SOCKET}" "${args[@]}"; then
    shred -u -z -- "${PENDING}" 2>/dev/null || rm -f -- "${PENDING}"
    rm -f -- "${PENDING_NAME}"
    sync "${STATE}"
    log "joined Tailscale${name:+ as ${name}}"
  else
    log "tailscale up failed; the key stays pending and the timer retries"
    return 1
  fi
}

take_boot_key
enroll_pending

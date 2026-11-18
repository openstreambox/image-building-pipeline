#!/bin/bash
# ceralive-tailscale-enroll — join Tailscale with a key someone placed on BOOT.
#
# 1. A file /boot/osb-tailscale[-<name>].key (any case; ".txt" appended by an
#    editor is fine) is read, checked to be one Tailscale auth key, moved into
#    the 0700 state directory on /data and overwritten + removed from the FAT
#    partition at once. (On an SD card the flash controller may keep old pages;
#    acceptable for a single-use key that is consumed right after.) <name>
#    becomes the Tailscale machine name.
# 2. While a pending key exists, tailscaled is started and `tailscale up` runs
#    with Tailscale SSH on and no DNS/route changes, then auto-update is pinned
#    off. On success the pending key is overwritten and removed.
# 3. Failures are bounded. A final control-plane answer (invalid, expired,
#    revoked or already used key) ends enrollment at once. Other failures (no
#    network yet) back off from 2 to 30 minutes and give up after
#    MAX_ATTEMPTS. Giving up removes the key, and the Tailscale state if the box
#    never joined, so tailscaled goes back to idle. enroll-status (no secrets)
#    records the outcome.
# Files that cannot be used (more than one key file, or not a tskey-auth- key)
# are overwritten and removed; only their names are logged and written to
# BOOT/TAILSCALE-KEY-REJECTED.txt. No key text is ever logged or printed.
set -euo pipefail

BOOT="${CERALIVE_TS_BOOT_DIR:-/boot}"
STATE="${CERALIVE_TS_STATE_DIR:-/var/lib/tailscale}"
CLI="${CERALIVE_TS_CLI:-/usr/local/bin/tailscale}"
SOCKET="${CERALIVE_TS_SOCKET:-/run/tailscale/tailscaled.sock}"
SYSTEMCTL="${SYSTEMCTL_BIN:-systemctl}"
WAIT="${CERALIVE_TS_SOCKET_WAIT:-30}"
MAX_ATTEMPTS="${CERALIVE_TS_MAX_ATTEMPTS:-100}"
NOW="${CERALIVE_TS_NOW:-$(date +%s)}"
PENDING="${STATE}/pending-authkey"
PENDING_NAME="${STATE}/pending-hostname"
STATUS="${STATE}/enroll-status"
REJECTED_NOTE="${BOOT}/TAILSCALE-KEY-REJECTED.txt"

log() { logger -t ceralive-tailscale-enroll -- "$*" 2>/dev/null || true; echo "ceralive-tailscale-enroll: $*"; }

wipe() { shred -u -z -- "$1" 2>/dev/null || rm -f -- "$1"; }

# status: state attempts next_epoch reason (one line, no secrets)
read_status() {
  attempts=0 next=0 joined=0
  [[ -e "${STATE}/joined-once" ]] && joined=1
  [[ -f "${STATUS}" ]] || return 0
  local a n
  read -r _ a n _ <"${STATUS}" || true
  [[ "$a" =~ ^[0-9]+$ ]] && attempts="$a"
  [[ "$n" =~ ^[0-9]+$ ]] && next="$n"
  return 0
}
write_status() { # state attempts next reason
  install -d -m 0700 "${STATE}"
  printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >"${STATUS}.tmp"
  mv -f "${STATUS}.tmp" "${STATUS}"
}

reject_all() { # reason files...
  local reason="$1" f names=()
  shift
  for f in "$@"; do names+=("$(basename -- "$f")"); wipe "$f"; done
  printf 'These files were removed from this card and not used: %s\nReason: %s\nAsk for a new key file.\n' \
    "${names[*]}" "$reason" >"${REJECTED_NOTE}" 2>/dev/null || true
  sync -f "${BOOT}" 2>/dev/null || true
  log "removed unusable key file(s) ${names[*]}: ${reason}"
}

take_boot_key() {
  local files=() f key base name
  shopt -s nullglob nocaseglob
  for f in "${BOOT}"/osb-tailscale*; do
    [[ -f "$f" && ! -L "$f" ]] && files+=("$f")
  done
  shopt -u nullglob nocaseglob
  (( ${#files[@]} > 0 )) || return 0
  if (( ${#files[@]} > 1 )); then
    reject_all "more than one osb-tailscale file on the card; put exactly one" "${files[@]}"
    return 0
  fi
  f="${files[0]}"
  if (( $(stat -c %s -- "$f") > 1024 )); then reject_all "larger than 1 KiB" "$f"; return 0; fi
  # Strip a UTF-8 BOM and all whitespace (Windows editors add CRLF, BOM, ".txt").
  key="$(LC_ALL=C sed '1s/^\xEF\xBB\xBF//' -- "$f" | LC_ALL=C tr -d ' \t\r\n')"
  if [[ ! "$key" =~ ^tskey-auth-[A-Za-z0-9_-]{8,200}$ ]]; then
    key=""
    reject_all "not a Tailscale auth key (tskey-auth-...)" "$f"
    return 0
  fi
  base="$(basename -- "$f")"; base="${base,,}"; base="${base%.txt}"; base="${base%.key}"
  name="${base#osb-tailscale}"; name="${name#-}"
  [[ "$name" =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]] || name=""
  install -d -m 0700 "${STATE}"
  ( umask 077
    printf '%s' "$key" >"${PENDING}.tmp"
    printf '%s' "$name" >"${PENDING_NAME}.tmp" )
  key=""
  sync "${PENDING}.tmp" "${PENDING_NAME}.tmp"
  mv -f "${PENDING_NAME}.tmp" "${PENDING_NAME}"
  mv -f "${PENDING}.tmp" "${PENDING}"
  write_status pending 0 0 new-key
  sync "${STATE}"
  wipe "$f"
  rm -f -- "${REJECTED_NOTE}"
  sync -f "${BOOT}" 2>/dev/null || true
  log "key taken off BOOT${name:+ for machine name ${name}}"
}

give_up() { # reason
  wipe "${PENDING}"
  rm -f -- "${PENDING_NAME}"
  if (( joined == 0 )); then
    # A box that never joined goes back to idle: no state, so tailscaled's
    # start conditions are false again.
    "${SYSTEMCTL}" stop tailscaled.service 2>/dev/null || true
    rm -f -- "${STATE}/tailscaled.state"
  fi
  write_status gave-up "$attempts" 0 "$1"
  sync "${STATE}" 2>/dev/null || true
  log "gave up Tailscale enrollment: $1; the key was removed. Put a new key file on BOOT to retry."
}

pin_no_autoupdate() {
  "${CLI}" --socket="${SOCKET}" set --auto-update=false --update-check=false
}

enroll_pending() {
  [[ -f "${PENDING}" ]] || return 0
  read_status
  if (( next > NOW && next - NOW <= 3600 )); then
    return 0   # backing off; a clock far ahead of `next` is ignored
  fi
  local name="" i out rc=0 delay
  [[ -f "${PENDING_NAME}" ]] && name="$(cat -- "${PENDING_NAME}")"
  attempts=$((attempts + 1))
  # Count and schedule the attempt before anything can fail, so even a daemon
  # that cannot start (or a crash here) backs off and is capped.
  delay=$(( 120 << (attempts > 4 ? 4 : attempts - 1) ))
  (( delay > 1800 )) && delay=1800
  write_status pending "$attempts" "$((NOW + delay))" trying
  if ! "${SYSTEMCTL}" start tailscaled.service; then
    log "tailscaled did not start (attempt ${attempts}/${MAX_ATTEMPTS})"
    if (( attempts >= MAX_ATTEMPTS )); then give_up "tailscaled did not start after ${attempts} attempts"; fi
    return 1
  fi
  for ((i = 0; i < WAIT; i++)); do [[ -S "${SOCKET}" ]] && break; sleep 1; done
  local args=(up "--auth-key=file:${PENDING}" --ssh --accept-risk=lose-ssh
              --accept-dns=false --accept-routes=false --timeout=90s)
  [[ -n "$name" ]] && args+=("--hostname=${name}")
  out="$("${CLI}" --socket="${SOCKET}" "${args[@]}" 2>&1)" || rc=$?
  out="$(printf '%s' "$out" | sed -E 's/tskey-[A-Za-z0-9_-]+/<key>/g' | tr '\n' ' ' | cut -c1-200)"
  if (( rc == 0 )); then
    # `up` resets the auto-update preference to "unset" (then the tailnet
    # default applies), so pin it off after every successful up.
    pin_no_autoupdate || log "could not pin auto-update off; tailscaled re-applies it at start"
    wipe "${PENDING}"
    rm -f -- "${PENDING_NAME}"
    write_status joined "$attempts" 0 ok
    : >"${STATE}/joined-once"
    sync "${STATE}"
    log "joined Tailscale${name:+ as ${name}}"
    return 0
  fi
  log "tailscale up failed (attempt ${attempts}/${MAX_ATTEMPTS}): ${out}"
  if printf '%s' "$out" | grep -qiE 'invalid key|expired|revoked|already used|not valid|authkey.*(used|invalid)'; then
    give_up "the control server refused the key"
    return 1
  fi
  if (( attempts >= MAX_ATTEMPTS )); then
    give_up "no success after ${attempts} attempts"
    return 1
  fi
  write_status pending "$attempts" "$((NOW + delay))" retry
  return 1
}

take_boot_key
enroll_pending

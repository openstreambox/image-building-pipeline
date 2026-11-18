#!/bin/bash
# ceralive-tailscale-enroll — join Tailscale with a key from the card's BOOT
# partition or from another local writer (CeraUI's Remote access card).
#
# Enrollment files live in ENROLL (/data/tailscale-enroll), a root-only 0700
# directory, not in tailscaled's own state directory: tailscaled runs as an
# unprivileged account that owns /var/lib/tailscale, and root must never follow
# files that account can replace.
#
# One run at a time: every run holds ENROLL/.lock for its whole duration, and only
# this script writes pending-*, enroll-status and joined-once.
#
# 1. Sources of a new key, both adopted under the lock (the newest wins):
#    - /boot/osb-tailscale[-<name>].key (any case; an editor's ".txt" is fine),
#      moved off the FAT partition at once (overwritten, then removed; an SD card
#      may keep old flash pages, acceptable for a single-use key consumed next);
#    - ENROLL/incoming-authkey (+ optional incoming-hostname), dropped by another
#      writer with tmp file + rename.
#    Adoption checks the key is one tskey-auth- key, makes it pending-authkey,
#    takes the machine name (DNS label) and resets enroll-status to a new key.
# 2. While a pending key exists, tailscaled is started and `tailscale up` runs
#    with Tailscale SSH on and no DNS/route changes, then auto-update is pinned
#    off. On success the pending key is overwritten and removed.
# 3. Failures are bounded. A final control-plane answer (invalid, expired,
#    revoked or already used key) ends enrollment at once. Other failures (no
#    network yet) back off from 2 to 30 minutes and give up after MAX_ATTEMPTS.
#    Giving up removes the key, and the Tailscale state if the box never joined,
#    so tailscaled goes back to idle.
# 4. A key that arrives while a run is busy is adopted when that attempt ends.
#
# Unusable inputs (several key files, not a tskey-auth- key, links, non-regular
# files) are removed; only names are logged (BOOT/TAILSCALE-KEY-REJECTED.txt for
# files from the card). No key text is ever logged or printed.
#
# CONTRACT with other writers: docs/agents/key-facts.md, "Remote-access
# enrollment contract". A writer may only create ENROLL/incoming-hostname and then
# ENROLL/incoming-authkey (each via tmp file + rename) and start this unit. It
# reads, never writes, enroll-status ("<pending|joined|gave-up> <attempts>
# <next-epoch> <reason>"), pending-authkey and joined-once.
set -euo pipefail

BOOT="${CERALIVE_TS_BOOT_DIR:-/boot}"
ENROLL="${CERALIVE_TS_ENROLL_DIR:-/data/tailscale-enroll}"
TS_STATE="${CERALIVE_TS_STATE_DIR:-/var/lib/tailscale}"
CLI="${CERALIVE_TS_CLI:-/usr/local/bin/tailscale}"
SOCKET="${CERALIVE_TS_SOCKET:-/run/tailscale/tailscaled.sock}"
SYSTEMCTL="${SYSTEMCTL_BIN:-systemctl}"
WAIT="${CERALIVE_TS_SOCKET_WAIT:-30}"
MAX_ATTEMPTS="${CERALIVE_TS_MAX_ATTEMPTS:-100}"
LOCK_WAIT="${CERALIVE_TS_LOCK_WAIT:-300}"
NOW="${CERALIVE_TS_NOW:-$(date +%s)}"
PENDING="${ENROLL}/pending-authkey"
PENDING_NAME="${ENROLL}/pending-hostname"
INCOMING="${ENROLL}/incoming-authkey"
INCOMING_NAME="${ENROLL}/incoming-hostname"
STATUS="${ENROLL}/enroll-status"
REJECTED_NOTE="${BOOT}/TAILSCALE-KEY-REJECTED.txt"
KEY_RE='^tskey-auth-[A-Za-z0-9_-]{8,200}$'
NAME_RE='^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$'

log() { logger -t ceralive-tailscale-enroll -- "$*" 2>/dev/null || true; echo "ceralive-tailscale-enroll: $*"; }

regular() { [[ -f "$1" && ! -L "$1" ]]; }
present() { [[ -e "$1" || -L "$1" ]]; }

wipe() { # never follows a link: a link (or other non-regular file) is only unlinked
  if ! regular "$1"; then rm -f -- "$1"; return 0; fi
  shred -u -z -- "$1" 2>/dev/null || rm -f -- "$1"
}

# At most N bytes of a regular, non-link file, without a UTF-8 BOM or any
# whitespace. Prints nothing for anything else.
read_token() { # path max
  regular "$1" || return 0
  (( $(stat -c %s -- "$1") <= $2 )) || return 0
  LC_ALL=C sed '1s/^\xEF\xBB\xBF//' -- "$1" | LC_ALL=C tr -d ' \t\r\n'
}

read_status() {
  attempts=0 next=0 joined=0
  [[ -e "${ENROLL}/joined-once" ]] && joined=1
  regular "${STATUS}" || return 0
  local a n
  read -r _ a n _ <"${STATUS}" || true
  [[ "$a" =~ ^[0-9]+$ ]] && attempts="$a"
  [[ "$n" =~ ^[0-9]+$ ]] && next="$n"
  return 0
}

write_status() { # state attempts next reason
  local tmp
  tmp="$(mktemp "${ENROLL}/.status.XXXXXX")"
  printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >"$tmp"
  chmod 0644 "$tmp"
  mv -f -- "$tmp" "${STATUS}"
}

# Make a validated key and name the pending pair (the caller holds the lock).
adopt() { # key name source
  local tmp
  wipe "${PENDING}"; rm -f -- "${PENDING_NAME}"
  if [[ -n "$2" ]]; then
    tmp="$(mktemp "${ENROLL}/.name.XXXXXX")"
    printf '%s' "$2" >"$tmp"
    mv -f -- "$tmp" "${PENDING_NAME}"
  fi
  tmp="$(mktemp "${ENROLL}/.pending.XXXXXX")"
  printf '%s' "$1" >"$tmp"
  sync "$tmp"
  mv -f -- "$tmp" "${PENDING}"
  write_status pending 0 0 new-key
  sync "${ENROLL}"
  log "new key from $3${2:+ for machine name $2}"
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
    if regular "$f"; then files+=("$f"); else rm -f -- "$f"; fi
  done
  shopt -u nullglob nocaseglob
  (( ${#files[@]} > 0 )) || return 0
  if (( ${#files[@]} > 1 )); then
    reject_all "more than one osb-tailscale file on the card; put exactly one" "${files[@]}"
    return 0
  fi
  f="${files[0]}"
  key="$(read_token "$f" 1024)"
  if [[ ! "$key" =~ $KEY_RE ]]; then
    key=""
    reject_all "not a Tailscale auth key (tskey-auth-...)" "$f"
    return 0
  fi
  base="$(basename -- "$f")"; base="${base,,}"; base="${base%.txt}"; base="${base%.key}"
  name="${base#osb-tailscale}"; name="${name#-}"
  [[ "$name" =~ $NAME_RE ]] || name=""
  adopt "$key" "$name" "the BOOT partition"
  key=""
  wipe "$f"
  rm -f -- "${REJECTED_NOTE}"
  sync -f "${BOOT}" 2>/dev/null || true
}

take_incoming_key() {
  local key name=""
  present "${INCOMING}" || return 0
  key="$(read_token "${INCOMING}" 1024)"
  if present "${INCOMING_NAME}"; then
    name="$(read_token "${INCOMING_NAME}" 64)"
    [[ "$name" =~ $NAME_RE ]] || name=""
    rm -f -- "${INCOMING_NAME}"
  fi
  if [[ ! "$key" =~ $KEY_RE ]]; then
    key=""
    wipe "${INCOMING}"
    log "removed incoming-authkey: not a regular file holding one tskey-auth- key"
    return 0
  fi
  adopt "$key" "$name" "a local writer"
  key=""
  wipe "${INCOMING}"
}

give_up() { # reason
  wipe "${PENDING}"
  rm -f -- "${PENDING_NAME}"
  if (( joined == 0 )); then
    # A box that never joined goes back to idle: no state, so tailscaled's
    # start conditions are false again. (rm never follows a link.)
    "${SYSTEMCTL}" stop tailscaled.service 2>/dev/null || true
    rm -f -- "${TS_STATE}/tailscaled.state"
  fi
  write_status gave-up "$attempts" 0 "$1"
  sync "${ENROLL}" 2>/dev/null || true
  log "gave up Tailscale enrollment: $1; the key was removed. Put a new key file on BOOT to retry."
}

enroll_pending() {
  present "${PENDING}" || return 0
  if [[ ! "$(read_token "${PENDING}" 1024)" =~ $KEY_RE ]]; then
    wipe "${PENDING}"; rm -f -- "${PENDING_NAME}"
    log "removed pending-authkey: not a regular file holding one tskey-auth- key"
    return 0
  fi
  read_status
  if (( next > NOW && next - NOW <= 3600 )); then
    return 0   # backing off; a clock far ahead of `next` is ignored
  fi
  local name="" i out rc=0 delay
  name="$(read_token "${PENDING_NAME}" 64)"
  [[ "$name" =~ $NAME_RE ]] || name=""
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
    "${CLI}" --socket="${SOCKET}" set --auto-update=false --update-check=false \
      || log "could not pin auto-update off; tailscaled re-applies it at start"
    wipe "${PENDING}"
    rm -f -- "${PENDING_NAME}"
    write_status joined "$attempts" 0 ok
    : >"${ENROLL}/joined-once"
    sync "${ENROLL}"
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

if present "${ENROLL}" && { [[ -L "${ENROLL}" ]] || [[ ! -d "${ENROLL}" ]]; }; then
  log "refusing: ${ENROLL} is not a plain directory"
  exit 1
fi
install -d -m 0700 "${ENROLL}"
chmod 0700 "${ENROLL}"
exec 9>"${ENROLL}/.lock"
flock -w "${LOCK_WAIT}" 9 || { log "another enrollment run holds the lock; the timer retries"; exit 0; }

take_boot_key
take_incoming_key
rc=0
enroll_pending || rc=$?
# A key that arrived during that attempt is used now, not after the back-off.
if present "${INCOMING}"; then
  take_incoming_key
  rc=0
  enroll_pending || rc=$?
fi
exit "$rc"

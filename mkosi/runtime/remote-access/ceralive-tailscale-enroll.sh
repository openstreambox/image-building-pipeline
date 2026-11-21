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
# this script writes pending-authkey, enroll-status, joined-once and state-ours.
#
# Key files hold the key on the first line and an optional machine name (a DNS
# label) on the second.
#
# 1. Sources of a new key, adopted under the lock (the newest wins):
#    - /boot/osb-tailscale[-<name>].key (any case; an editor's ".txt" is fine;
#      the name comes from the file name), moved off the FAT partition at once
#      (overwritten, then removed; an SD card may keep old flash pages, acceptable
#      for a single-use key consumed next);
#    - ENROLL/incoming-authkey, dropped by another writer (tmp file + rename) and
#      claimed here by renaming it to ENROLL/.claimed, so a later drop is never
#      lost or mixed with it.
#    Adoption validates the key, resets enroll-status and replaces pending-authkey
#    with one rename. A crash at any point leaves either the old pending key or
#    the new one, never a mix; .claimed is re-adopted and temporary files are
#    swept by the next run.
# 2. While a pending key exists, tailscaled is started and `tailscale up` runs
#    with Tailscale SSH on and no DNS/route changes, then auto-update is pinned
#    off. On success the pending key is overwritten and removed.
#    If the tailnet does not grant Tailscale SSH, tailscaled refuses every later
#    pref change (this pin, `down`, `logout`) while SSH is on, so SSH is turned
#    off in the same change as the pin; the status reason says so.
# 3. Failures are bounded. A final control-plane answer (invalid, expired,
#    revoked or already used key) ends enrollment at once. Other failures (no
#    network yet) back off from 2 to 30 minutes and give up after MAX_ATTEMPTS.
#    Giving up removes the key. It also removes tailscaled.state, but only when
#    this enrollment created it (state-ours, written before tailscaled first ran
#    without state), the box never joined, and tailscaled reports NeedsLogin
#    without a node key. A state that existed before is never touched.
# 4. A key that arrives while a run is busy is adopted when that attempt ends.
#
# Unusable inputs (several key files, not a tskey-auth- key, links, non-regular
# files) are removed from the input path; only names are logged
# (BOOT/TAILSCALE-KEY-REJECTED.txt for files from the card). No key text is logged.
#
# CONTRACT with other writers: docs/agents/key-facts.md, "Remote-access
# enrollment contract". A writer creates only ENROLL/incoming-authkey (tmp file +
# rename) and starts this unit. It reads, never writes, enroll-status
# ("<pending|joined|gave-up> <attempts> <next-epoch> <reason>"), pending-authkey
# (presence only) and joined-once.
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
INCOMING="${ENROLL}/incoming-authkey"
CLAIMED="${ENROLL}/.claimed"
STATUS="${ENROLL}/enroll-status"
OURS="${ENROLL}/state-ours"
REJECTED_NOTE="${BOOT}/TAILSCALE-KEY-REJECTED.txt"
KEY_RE='^tskey-auth-[A-Za-z0-9_-]{8,200}$'
NAME_RE='^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$'
REFUSED_RE='^(backend error: )?(invalid key|key (has )?(been )?(expired|revoked|already (been )?used))\b
\binvalid (pre[- ]?)?auth[- ]?key\b
\b(pre[- ]?)?auth[- ]?key (has )?(been )?(not found|not valid|invalid|expired|revoked|(already (been )?)?used)\b'
# tailscaled's answer to any pref change while Tailscale SSH is on and the
# tailnet's policy does not grant this node the SSH capability.
NO_TAILNET_SSH_RE='not enabled on tailnet'

log() { logger -t ceralive-tailscale-enroll -- "$*" 2>/dev/null || true; echo "ceralive-tailscale-enroll: $*"; }

regular() { [[ -f "$1" && ! -L "$1" ]]; }
present() { [[ -e "$1" || -L "$1" ]]; }

wipe() { # never follows a link: a link (or other non-regular file) is only unlinked
  if ! regular "$1"; then rm -f -- "$1"; return 0; fi
  shred -u -z -- "$1" 2>/dev/null || rm -f -- "$1"
}

discard_claim() {
  if [[ ! -d "${CLAIMED}" || -L "${CLAIMED}" ]]; then
    wipe "${CLAIMED}"
    return
  fi

  # A directory is never a key drop. Clear the claim without deleting its contents.
  if ! rmdir -- "${CLAIMED}" 2>/dev/null; then
    local rejected
    rejected="$(mktemp -d "${ENROLL}/.rejected.XXXXXX")"
    mv -T -- "${CLAIMED}" "${rejected}/incoming-authkey"
    log "quarantined a populated incoming-authkey directory"
  fi
}

# Parse a key file into KEY and NAME: a regular, non-link file of at most 1 KiB,
# UTF-8 BOM and whitespace stripped, line 1 the key, line 2 an optional name.
# KEY is empty when the file is unusable; NAME is empty unless it is a DNS label.
parse_keyfile() { # path
  KEY="" NAME=""
  regular "$1" || return 0
  (( $(stat -c %s -- "$1") <= 1024 )) || return 0
  local lines
  mapfile -t lines < <(LC_ALL=C sed '1s/^\xEF\xBB\xBF//' -- "$1" | LC_ALL=C tr -d ' \t\r' | grep -v '^$' || true)
  (( ${#lines[@]} >= 1 && ${#lines[@]} <= 2 )) || return 0
  [[ "${lines[0]}" =~ $KEY_RE ]] || return 0
  KEY="${lines[0]}"
  if (( ${#lines[@]} == 2 )) && [[ "${lines[1]}" =~ $NAME_RE ]]; then NAME="${lines[1]}"; fi
  return 0
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

# Start of every run (under the lock): migrate the pre-split layout, re-adopt a
# claim a crash left behind, and remove temporary files.
recover() {
  local f
  # Older builds kept joined-once in tailscaled's directory. Only its existence
  # is used (never its content), and only to be more careful with state.
  if [[ -e "${TS_STATE}/joined-once" && ! -e "${ENROLL}/joined-once" ]]; then
    : >"${ENROLL}/joined-once"
  fi
  rm -f -- "${TS_STATE}/pending-authkey" "${TS_STATE}/pending-hostname"   # rm never follows links
  # A writer built against the earlier two-file contract may leave this behind.
  rm -f -- "${ENROLL}/incoming-hostname" "${ENROLL}/pending-hostname"
  if present "${CLAIMED}"; then
    if regular "${CLAIMED}" && ! present "${INCOMING}"; then
      mv -f -- "${CLAIMED}" "${INCOMING}"
    else
      discard_claim
    fi
  fi
  shopt -s nullglob dotglob
  for f in "${ENROLL}"/.pending.* "${ENROLL}"/.status.* "${ENROLL}"/.up-key.*; do wipe "$f"; done
  shopt -u nullglob dotglob
}

# Make KEY/NAME the pending key: status first, then one rename (caller holds the lock).
adopt() { # source
  local tmp
  tmp="$(mktemp "${ENROLL}/.pending.XXXXXX")"
  printf '%s\n%s\n' "${KEY}" "${NAME}" >"$tmp"
  sync "$tmp"
  write_status pending 0 0 new-key
  mv -f -- "$tmp" "${PENDING}"
  sync "${ENROLL}"
  log "new key from $1${NAME:+ for machine name ${NAME}}"
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
  local files=() f base name
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
  parse_keyfile "$f"
  if [[ -z "${KEY}" ]]; then
    reject_all "not a Tailscale auth key (tskey-auth-...)" "$f"
    return 0
  fi
  base="$(basename -- "$f")"; base="${base,,}"; base="${base%.txt}"; base="${base%.key}"
  name="${base#osb-tailscale}"; name="${name#-}"
  [[ "$name" =~ $NAME_RE ]] && NAME="$name"
  adopt "the BOOT partition"
  KEY=""
  wipe "$f"
  rm -f -- "${REJECTED_NOTE}"
  sync -f "${BOOT}" 2>/dev/null || true
}

# Claim incoming-authkey by renaming it, then adopt it. Repeats while the writer
# keeps dropping keys (bounded), so the newest key is the one tried.
take_incoming_keys() {
  local i
  for ((i = 0; i < 5; i++)); do
    present "${INCOMING}" || return 0
    mv -fT -- "${INCOMING}" "${CLAIMED}"
    parse_keyfile "${CLAIMED}"
    if [[ -z "${KEY}" ]]; then
      log "removed incoming-authkey: not a regular file holding one tskey-auth- key (and an optional name)"
    else
      adopt "a local writer"
      KEY=""
    fi
    discard_claim
  done
}

give_up() { # reason
  wipe "${PENDING}"
  if (( joined == 0 )) && [[ -e "${OURS}" ]]; then
    # NoState is also possible for a registered node waiting for control.
    # Keep its state if the status is ambiguous or already has a node key.
    local backend="" status_json node_key_re='"HaveNodeKey"[[:space:]]*:[[:space:]]*true'
    if status_json="$("${CLI}" --socket="${SOCKET}" status --json 2>/dev/null)"; then
      backend="$(grep -o '"BackendState": *"[A-Za-z]*"' <<<"$status_json" \
        | head -n1 | grep -o '"[A-Za-z]*"$' | tr -d '"')" || true
    fi
    if [[ "$backend" == NeedsLogin && ! "$status_json" =~ $node_key_re ]]; then
      "${SYSTEMCTL}" stop tailscaled.service 2>/dev/null || true
      rm -f -- "${TS_STATE}/tailscaled.state"   # rm never follows a link
      rm -f -- "${OURS}"
    else
      log "kept tailscaled.state (tailscaled state '${backend:-unknown}')"
    fi
  fi
  write_status gave-up "$attempts" 0 "$1"
  sync "${ENROLL}" 2>/dev/null || true
  log "gave up Tailscale enrollment: $1; the key was removed. Put a new key file on BOOT to retry."
}

# `up` resets the auto-update preference to "unset" (then the tailnet default
# applies), so pin it off after every successful up. Prints the status reason.
pin_auto_update_off() {
  local out
  if out="$("${CLI}" --socket="${SOCKET}" set --auto-update=false --update-check=false 2>&1)"; then
    echo ok
    return 0
  fi
  if printf '%s' "$out" | grep -qiE "$NO_TAILNET_SSH_RE" \
     && "${CLI}" --socket="${SOCKET}" set --ssh=false --accept-risk=lose-ssh \
          --auto-update=false --update-check=false >/dev/null 2>&1; then
    log "this tailnet does not allow Tailscale SSH: turned SSH off on this box so its settings can change; auto-update pinned off" >&2
    echo ok-without-tailnet-ssh
    return 0
  fi
  log "could not pin auto-update off ($(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)); tailscaled re-applies it at start" >&2
  echo ok-auto-update-not-pinned
}

enroll_pending() {
  present "${PENDING}" || return 0
  parse_keyfile "${PENDING}"
  if [[ -z "${KEY}" ]]; then
    wipe "${PENDING}"
    log "removed pending-authkey: not a regular file holding one tskey-auth- key"
    return 0
  fi
  local name="${NAME}"
  KEY=""
  read_status
  if (( next > NOW && next - NOW <= 3600 )); then
    return 0   # backing off; a clock far ahead of `next` is ignored
  fi
  local i out message rc=0 delay keyfile
  attempts=$((attempts + 1))
  # Count and schedule the attempt before anything can fail, so even a daemon
  # that cannot start (or a crash here) backs off and is capped.
  delay=$(( 120 << (attempts > 4 ? 4 : attempts - 1) ))
  (( delay > 1800 )) && delay=1800
  write_status pending "$attempts" "$((NOW + delay))" trying
  # Any state that appears from now on, where none existed, is ours to clean up.
  if [[ ! -e "${TS_STATE}/tailscaled.state" && ! -L "${TS_STATE}/tailscaled.state" ]]; then
    : >"${OURS}"
  fi
  if ! "${SYSTEMCTL}" start tailscaled.service; then
    log "tailscaled did not start (attempt ${attempts}/${MAX_ATTEMPTS})"
    if (( attempts >= MAX_ATTEMPTS )); then give_up "tailscaled did not start after ${attempts} attempts"; fi
    return 1
  fi
  for ((i = 0; i < WAIT; i++)); do [[ -S "${SOCKET}" ]] && break; sleep 1; done
  # The CLI reads a key-only copy (the pending file also carries the name).
  keyfile="$(mktemp "${ENROLL}/.up-key.XXXXXX")"
  parse_keyfile "${PENDING}"
  printf '%s' "${KEY}" >"$keyfile"
  KEY=""
  local args=(up "--auth-key=file:${keyfile}" --ssh --accept-risk=lose-ssh
              --accept-dns=false --accept-routes=false --timeout=90s)
  [[ -n "$name" ]] && args+=("--hostname=${name}")
  out="$("${CLI}" --socket="${SOCKET}" "${args[@]}" 2>&1)" || rc=$?
  wipe "$keyfile"
  if (( rc == 0 )); then
    : >"${ENROLL}/joined-once"
    rm -f -- "${OURS}"
    local reason
    reason="$(pin_auto_update_off)"
    wipe "${PENDING}"
    write_status joined "$attempts" 0 "$reason"
    sync "${ENROLL}"
    log "joined Tailscale${name:+ as ${name}}"
    return 0
  fi
  message="$(printf '%s' "$out" | sed -E 's/tskey-[A-Za-z0-9_-]+/<key>/g' | tr '\n' ' ' | cut -c1-200)"
  log "tailscale up failed (attempt ${attempts}/${MAX_ATTEMPTS}): ${message}"
  # Final refusals: Tailscale's control plane ("invalid key: …", expired, revoked,
  # already used) and headscale ("invalid pre auth key", "… has expired", "… has
  # already been used"). Every phrase must be about the key: a TLS error such as
  # "certificate has expired" (a wrong clock on first boot) is transient.
  if printf '%s' "$out" | grep -qiE "$REFUSED_RE"; then
    give_up "the control server refused the key"
    return 1
  fi
  # Only a box that already holds a netmap from such a tailnet answers this way
  # (a fresh login has no netmap yet); retrying cannot change it.
  if printf '%s' "$out" | grep -qiE "$NO_TAILNET_SSH_RE"; then
    give_up "this tailnet does not allow Tailscale SSH; forget the box there first"
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

recover
take_boot_key
take_incoming_keys
rc=0
enroll_pending || rc=$?
# A key that arrived during that attempt is used now, not after the back-off.
if present "${INCOMING}"; then
  take_incoming_keys
  rc=0
  enroll_pending || rc=$?
fi
exit "$rc"

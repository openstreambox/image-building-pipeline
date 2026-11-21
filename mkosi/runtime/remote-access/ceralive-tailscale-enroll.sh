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
#    Before the keyed `up` first runs for a pending key, prior-login records
#    whether the box already held a login ("yes|no <pending inode>"), synced
#    to disk first and kept until the attempt's result is recorded. A retry
#    refused that way with "no" means an earlier attempt of this key registered
#    the box (e.g. it waited for approval past the timeout, or the box lost
#    power): that is finished as a join. A login that predates the key makes
#    the enrollment give up. Without an answer from tailscaled the keyed `up`
#    does not run, nor when the record cannot be synced. ssh-off-node holds the
#    stable node ID of the login whose SSH this enrollment turned off; a join
#    that keeps SSH on removes it. A join's result is synced before its key is
#    consumed.
#    This script never starts or stops tailscaled: switching it on and off is
#    the owner's (the card's On/Off: enable --now, down + disable --now). For a
#    join, ceralive-tailscaled-pending.path starts it once a key is pending, and
#    only while the owner has it enabled (it is in the unit's Also=, so Off
#    disables and stops it too); this script waits for that. While tailscaled
#    runs it is asked; while it does not, tailscaled.state is read (root,
#    read-only, no links, size-capped; nothing from it is logged). A box that already holds a working login (Running, or Stopped
#    because remote access is switched off), or that holds one in its state
#    while tailscaled is not running, does not use a new key: the box cannot
#    tell which tailnet a key belongs to without sending it, and an `up`
#    without --force-reauth keeps the old login anyway. The key is removed,
#    BOOT gets TAILSCALE-KEY-NOT-USED.txt (synced before the key goes) and the
#    status reads "joined … already-joined". Moving the box is an explicit
#    step: remove it from its tailnet (admin console, or Forget on the card),
#    then add the key again. A login that is still connecting (NoState or
#    Starting), a unit that is starting or stopping, and anything that cannot
#    be read (systemd, tailscaled or the state file) are asked again at the
#    next attempt, never taken as "no login". An expired, logged-out or
#    unapproved login reported by a running tailscaled uses the key as before.
# 3. Failures are bounded. A final control-plane answer (invalid, expired,
#    revoked or already used key) ends enrollment at once. Other failures (no
#    network yet) back off from 2 to 30 minutes and give up after MAX_ATTEMPTS;
#    a key that cannot be judged yet, or waits for the owner, never gives up.
#    Giving up removes the key. It also removes tailscaled.state, but only when
#    this enrollment created it (state-ours, written before tailscaled first ran
#    without state), the box never joined, tailscaled is not running and the
#    state holds no login. A state that existed before is never touched, and
#    giving up never stops tailscaled.
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
UP_TIMEOUT="${CERALIVE_TS_UP_TIMEOUT:-90s}"
NOW="${CERALIVE_TS_NOW:-$(date +%s)}"
PENDING="${ENROLL}/pending-authkey"
INCOMING="${ENROLL}/incoming-authkey"
CLAIMED="${ENROLL}/.claimed"
STATUS="${ENROLL}/enroll-status"
OURS="${ENROLL}/state-ours"
PRIOR="${ENROLL}/prior-login"
SSH_OFF="${ENROLL}/ssh-off-node"
REJECTED_NOTE="${BOOT}/TAILSCALE-KEY-REJECTED.txt"
NOT_USED_NOTE="${BOOT}/TAILSCALE-KEY-NOT-USED.txt"
UNUSED="${ENROLL}/key-unused"
START_WAIT="${CERALIVE_TS_START_WAIT:-30}"
PYTHON="${CERALIVE_TS_PYTHON:-python3}"
KEY_RE='^tskey-auth-[A-Za-z0-9_-]{8,200}$'
NAME_RE='^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$'
REFUSED_RE='^(backend error: )?(invalid key|key (has )?(been )?(expired|revoked|already (been )?used))\b
\binvalid (pre[- ]?)?auth[- ]?key\b
\b(pre[- ]?)?auth[- ]?key (has )?(been )?(not found|not valid|invalid|expired|revoked|(already (been )?)?used)\b'
# tailscaled's answer to any pref change while Tailscale SSH is on and the
# tailnet's policy does not grant this node the SSH capability.
NO_TAILNET_SSH_RE='not enabled on tailnet'

# Use the unit's journal stream once per message.
log() { local priority="$1"; shift; printf '<%s>ceralive-tailscale-enroll: %s\n' "$priority" "$*"; }

regular() { [[ -f "$1" && ! -L "$1" ]]; }
clean() { printf '%s' "$1" | sed -E 's/tskey-[A-Za-z0-9_-]+/<key>/g' | tr '\n' ' ' | cut -c1-160; }

backend_state() { # prints tailscaled's BackendState (empty if it does not answer) and sets STATUS_JSON
  # `status` exits non-zero in some states but still prints its JSON.
  STATUS_JSON="$("${CLI}" --socket="${SOCKET}" status --json --peers=false 2>/dev/null)" || true
  [[ "$STATUS_JSON" == \{* ]] || { STATUS_JSON=""; return 0; }
  grep -o '"BackendState": *"[A-Za-z]*"' <<<"$STATUS_JSON" | head -n1 | grep -o '"[A-Za-z]*"$' | tr -d '"' || true
}

put_synced() { # path content tmp-prefix: tmp file in ENROLL, fsync, rename, fsync the directory
  # Every step is checked: callers run under `||`, where errexit does not apply.
  local tmp
  tmp="$(mktemp "${ENROLL}/$3.XXXXXX")" || return 1
  if ! { printf '%s\n' "$2" >"$tmp" && chmod 0644 "$tmp" && sync "$tmp" && mv -f -- "$tmp" "$1"; }; then
    rm -f -- "$tmp"
    return 1
  fi
  # Not durable yet: do not leave it for a later run to trust.
  sync "${ENROLL}" || { rm -f -- "$1"; return 1; }
}

# The login record of the current pending key: "yes" or "no", empty when there
# is none for this key (another key's record does not count), "error" when it
# cannot be read.
read_prior() {
  present "${PRIOR}" || return 0
  regular "${PRIOR}" && regular "${PENDING}" || { echo error; return 0; }
  local value="" inode="" current
  { read -r value inode <"${PRIOR}"; } 2>/dev/null || [[ -n "$value" ]] || { echo error; return 0; }
  current="$(stat -c %i -- "${PENDING}" 2>/dev/null)" || { echo error; return 0; }
  [[ "$inode" == "$current" ]] || return 0
  if [[ "$value" =~ ^(yes|no)$ ]]; then echo "$value"; else echo error; fi
  return 0
}
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
    log 4 "quarantined a populated incoming-authkey directory"
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

write_status() { # state attempts next reason; returns non-zero if it could not
  local tmp
  tmp="$(mktemp "${ENROLL}/.status.XXXXXX")" || return 1
  if ! { printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >"$tmp" && chmod 0644 "$tmp" && mv -f -- "$tmp" "${STATUS}"; }; then
    rm -f -- "$tmp"
    return 1
  fi
}

# The terminal result: file contents synced before the rename, then the
# directory, every step checked. Unlike put_synced, a failed directory sync
# keeps the new status (the key is still there, so the next run redoes it).
write_status_synced() { # state attempts next reason
  local tmp
  tmp="$(mktemp "${ENROLL}/.status.XXXXXX")" || return 1
  if ! { printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >"$tmp" && chmod 0644 "$tmp" && sync "$tmp" && mv -f -- "$tmp" "${STATUS}"; }; then
    rm -f -- "$tmp"
    return 1
  fi
  sync "${ENROLL}"
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
  for f in "${ENROLL}"/.pending.* "${ENROLL}"/.status.* "${ENROLL}"/.up-key.* "${ENROLL}"/.prior.* "${ENROLL}"/.sshoff.* "${ENROLL}"/.unused.*; do wipe "$f"; done
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
  # A new key supersedes an earlier "not used" outcome and its note.
  rm -f -- "${UNUSED}" "${NOT_USED_NOTE}" 2>/dev/null || true
  sync -f "${BOOT}" 2>/dev/null || true
  log 5 "new key from $1${NAME:+ for machine name ${NAME}}"
}

reject_all() { # reason files...
  local reason="$1" f names=()
  shift
  for f in "$@"; do names+=("$(basename -- "$f")"); wipe "$f"; done
  printf 'These files were removed from this card and not used: %s\nReason: %s\nAsk for a new key file.\n' \
    "${names[*]}" "$reason" >"${REJECTED_NOTE}" 2>/dev/null || true
  sync -f "${BOOT}" 2>/dev/null || true
  log 4 "removed unusable key file(s) ${names[*]}: ${reason}"
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
  rm -f -- "${REJECTED_NOTE}" 2>/dev/null || true   # an old note is not worth stopping for
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
      log 4 "removed incoming-authkey: not a regular file holding one tskey-auth- key (and an optional name)"
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
    # Only a state with no login, while tailscaled is not running, goes; this
    # never stops tailscaled. A running daemon (the owner's, or one the
    # pending-key path started) keeps its state until a later key or Forget.
    local daemon saved=""
    daemon="$(daemon_state)"
    [[ "$daemon" == down ]] && saved="$(saved_login)"
    if [[ "$saved" == no-login ]]; then
      rm -f -- "${TS_STATE}/tailscaled.state"   # rm never follows a link
      rm -f -- "${OURS}"
    else
      log 5 "kept tailscaled.state (tailscaled ${daemon}${saved:+, saved state: ${saved}})"
    fi
  fi
  write_status gave-up "$attempts" 0 "$1"
  sync "${ENROLL}" 2>/dev/null || true
  rm -f -- "${PRIOR}"
  log 4 "gave up Tailscale enrollment: $1; the key was removed. Put a new key file on BOOT to retry."
}

# `up` resets the auto-update preference to "unset" (then the tailnet default
# applies), so pin it off after every successful up. Prints the status reason.
pin_auto_update_off() {
  local out
  if out="$("${CLI}" --socket="${SOCKET}" set --auto-update=false --update-check=false 2>&1)"; then
    echo ok
    return 0
  fi
  if printf '%s' "$out" | grep -qiE "$NO_TAILNET_SSH_RE"; then
    if out="$("${CLI}" --socket="${SOCKET}" set --ssh=false --accept-risk=lose-ssh \
          --auto-update=false --update-check=false 2>&1)"; then
      log 4 "this tailnet does not allow Tailscale SSH: turned SSH off on this box so its settings can change; auto-update pinned off" >&2
      record_ssh_off || true
      echo ok-without-tailnet-ssh
      return 0
    fi
    log 4 "this tailnet does not allow Tailscale SSH, and turning SSH off failed too" >&2
  fi
  log 4 "could not pin auto-update off ($(clean "$out")); tailscaled tries again at its next start" >&2
  echo ok-auto-update-not-pinned
}

record_ssh_off() { # remember which node had its SSH turned off (for CeraUI's card)
  # The stable node ID (Self.ID) survives a node key rotation; a new login gets a new one.
  local node="" i
  for ((i = 0; i < 3; i++)); do
    backend_state >/dev/null
    node="$(grep -o '"ID": *"[A-Za-z0-9]*"' <<<"$STATUS_JSON" | head -n1 | grep -o '"[A-Za-z0-9]*"$' | tr -d '"')" || true
    [[ -n "$node" ]] && break
    sleep 1
  done
  if [[ -z "$node" ]] || ! put_synced "${SSH_OFF}" "$node" .sshoff; then
    log 4 "could not record which login had Tailscale SSH turned off; the Remote access card will not show its note" >&2
    return 1
  fi
}

finish_join() { # name [refused-ssh]: the second argument says tailscaled refused --ssh here
  : >"${ENROLL}/joined-once"
  rm -f -- "${OURS}"
  local reason
  reason="$(pin_auto_update_off)"
  if [[ -n "${2:-}" && "$reason" == ok ]]; then
    # The plain pin went through, so SSH was already off (an earlier run of
    # this join turned it off before it could record the result).
    record_ssh_off || true
    reason=ok-without-tailnet-ssh
  fi
  [[ "$reason" == ok ]] && rm -f -- "${SSH_OFF}"
  # The result goes to disk before the key is consumed: a cut in between leaves
  # the key, so the next run finishes again instead of leaving "pending". If
  # the result cannot be stored, the key and the login record stay for that run.
  if ! write_status_synced joined "$attempts" 0 "$reason"; then
    log 4 "could not store the join result; the next run finishes it"
    return 1
  fi
  wipe "${PENDING}"
  sync "${ENROLL}"
  rm -f -- "${PRIOR}"   # only once the result is on disk
  log 5 "joined Tailscale${1:+ as $1}"
}

# The box's own name in its tailnet ("box.tail1234.ts.net"), from STATUS_JSON:
# Self.DNSName, else the tailnet's MagicDNS suffix. Empty when tailscaled has no
# netmap (switched off since boot). Not the tailnet's account name.
tailnet_name() {
  local name
  name="$(grep -o '"DNSName": *"[^"]*"' <<<"$STATUS_JSON" | head -n1 | sed -E 's/.*"([^"]*)"$/\1/')" || true
  [[ -n "$name" ]] || name="$(grep -o '"MagicDNSSuffix": *"[^"]*"' <<<"$STATUS_JSON" | head -n1 | sed -E 's/.*"([^"]*)"$/\1/')" || true
  name="${name%.}"
  [[ "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,250})$ ]] && echo "$name"
  return 0
}

# tailscaled's answer from STATUS_JSON, checked as a whole: "<BackendState>
# yes|no" (node key; HaveNodeKey is omitted when false), or "unknown" for
# anything that is not a JSON object with a known BackendState.
# shellcheck disable=SC2016
LIVE_READER='
import json, sys
try:
    status = json.loads(sys.stdin.read())
except Exception:
    status = None
known = ("NoState", "NeedsLogin", "NeedsMachineAuth", "Stopped", "Starting", "Running")
if not isinstance(status, dict) or status.get("BackendState") not in known \
        or not isinstance(status.get("HaveNodeKey", False), bool):
    print("unknown")
else:
    print(status["BackendState"], "yes" if status.get("HaveNodeKey", False) else "no")
'
live_login() {
  local answer
  answer="$("${PYTHON}" -I -c "${LIVE_READER}" <<<"$STATUS_JSON" 2>/dev/null)" || answer=""
  [[ "$answer" =~ ^[A-Za-z]+\ (yes|no)$ ]] && echo "$answer" || echo unknown
}

# Is tailscaled running? Prints running, down (inactive or failed), busy
# (starting, stopping or waiting to restart) or unknown (systemd gave no clear
# answer). Only the owner's On/Off changes this; enrollment only looks.
daemon_state() {
  local state rc=0
  state="$("${SYSTEMCTL}" is-active tailscaled.service 2>/dev/null)" || rc=$?
  case "$state" in
    active|reloading|refreshing) (( rc == 0 )) && echo running || echo unknown ;;
    inactive|failed) (( rc != 0 )) && echo down || echo unknown ;;
    activating|deactivating) echo busy ;;
    *) echo unknown ;;
  esac
}

# What tailscaled.state says about the login, for a tailscaled that is not
# running. Layout measured on tailscaled 1.104.7 (tests/fixtures/tailscaled-state):
# a JSON object of base64 values; "_current-profile" names the profile key,
# whose value holds the prefs; prefs.Config.PrivateNodeKey is the node key
# ("privkey:" and 64 hex digits, all zero when there is none) and prefs.LoggedOut
# says the login was given up. A logout deletes the profile, a fresh daemon
# writes "{}". The file belongs to tailscaled's account, so it is opened without
# following a link or blocking, must be a regular file under the size cap, and
# nothing read from it is printed (the state holds private keys). Prints
# "login on|off|unknown" (WantRunning), "no-login" or "unknown <reason>";
# anything the reader does not recognise is unknown, never "no login".
# shellcheck disable=SC2016
STATE_READER='
import base64, errno, json, os, re, stat, sys
CAP = 1 << 20
def out(text):
    print(text)
    sys.exit(0)
def unb64(value):
    if not isinstance(value, str):
        out("unknown layout")
    return base64.b64decode(value, validate=True)
path = sys.argv[1]
try:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_NOCTTY | os.O_CLOEXEC)
    except FileNotFoundError:
        # No state at all is "no login", but only inside a real directory.
        out("no-login" if stat.S_ISDIR(os.lstat(os.path.dirname(path) or ".").st_mode) else "unknown no-directory")
    except OSError as error:
        out("unknown link" if error.errno == errno.ELOOP else "unknown open-failed")
    with os.fdopen(fd, "rb") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode):
            out("unknown not-a-regular-file")
        if info.st_size > CAP:
            out("unknown too-large")
        data = handle.read(CAP + 1)
    if len(data) > CAP:
        out("unknown too-large")
    store = json.loads(data.decode("utf-8"))
    if not isinstance(store, dict):
        out("unknown layout")
    # "No login" needs a layout this reader knows: the keys of tailscaled
    # start with "_"; "_daemon" held the prefs before profiles existed.
    if "_daemon" in store or any(not key.startswith(("_", "profile-")) for key in store):
        out("unknown layout")
    profiles = [key for key in store if key.startswith("profile-")]
    listed = json.loads(unb64(store["_profiles"]).decode("utf-8")) if "_profiles" in store else {}
    if not isinstance(listed, dict):
        out("unknown layout")
    if "_current-profile" not in store:
        out("unknown no-current-profile" if profiles or listed else "no-login")
    current = unb64(store["_current-profile"]).decode("ascii")
    if not re.fullmatch(r"profile-[A-Za-z0-9]{1,64}", current):
        out("unknown layout")
    if current not in store:
        # a logout deletes the profile; another profile would need a closer look
        out("unknown other-profiles" if profiles or listed else "no-login")
    prefs = json.loads(unb64(store[current]).decode("utf-8"))
    if not isinstance(prefs, dict):
        out("unknown layout")
    logged_out = prefs.get("LoggedOut", False)
    if not isinstance(logged_out, bool):
        out("unknown layout")
    if logged_out:
        out("no-login")
    persist = prefs.get("Config")
    if persist is None:
        out("no-login")
    if not isinstance(persist, dict):
        out("unknown layout")
    node_key = persist.get("PrivateNodeKey")
    if node_key is None:
        out("no-login")
    match = re.fullmatch(r"privkey:([0-9a-f]{64})", node_key) if isinstance(node_key, str) else None
    if not match:
        out("unknown node-key-format")
    if set(match.group(1)) == {"0"}:
        out("no-login")
    running = prefs.get("WantRunning")
    out("login " + ("on" if running is True else "off" if running is False else "unknown"))
except Exception:   # never a traceback with file content; SystemExit passes
    out("unknown unreadable")
'

saved_login() {
  local answer
  answer="$("${PYTHON}" -I -c "${STATE_READER}" "${TS_STATE}/tailscaled.state" 2>/dev/null)" || answer=""
  case "$answer" in
    "login on"|"login off"|"login unknown"|no-login|"unknown "[a-z-]*) echo "$answer" ;;
    *) echo "unknown no-answer" ;;
  esac
}

# An attempt that cannot decide now (or waits for the owner) keeps the key,
# does nothing else and asks again after the back-off, without a cap: giving
# up would decide something about a key it could not judge (attempts and
# delay are enroll_pending's).
retry_later() {
  write_status pending "$attempts" "$((NOW + delay))" retry || true
}

# The box already holds a login: leave it as it is and say so on BOOT before
# the key goes. how: running (tailscaled answered; $2 its state, Running or
# Stopped) or saved (tailscaled is not running; $2 the saved WantRunning).
key_not_used() { # how state [where]
  local where="${3:-}" off="" checked=1
  if [[ "$1" == running ]]; then
    [[ -n "$where" ]] || where="$(tailnet_name)"
    [[ "$2" == Stopped ]] && off=switched-off
  else
    checked=""
    [[ "$2" == off ]] && off=switched-off || off=not-running
  fi
  # The outcome is recorded for this key before anything is published, so a
  # retry finishes it as it is instead of deciding again (and maybe using a
  # key the note already says was not used).
  if ! put_synced "${UNUSED}" "$(stat -c %i -- "${PENDING}") $1 $2 ${where}" .unused; then
    log 4 "could not record that the key is not used; the key stays and the next run tries again"
    write_status pending "$attempts" "$((NOW + delay))" retry || true
    return 1
  fi
  # The note is what the owner sees, so it is on the card before the key goes.
  if ! {
    {
      if [[ -n "$checked" ]]; then
        printf 'This box is already in a Tailscale network%s, so the new key was not used.\n' "${where:+ (${where})}"
      else
        printf 'This box already holds a Tailscale login, so the new key was not used.\n'
      fi
      printf 'The key file was removed from this card. An unused key stays valid until it expires.\n'
      case "$off" in
        switched-off) printf 'Remote access is switched off on this box; it keeps its login and stays off.\n' ;;
        not-running) printf 'Remote access was not running on this box; it keeps its login.\n' ;;
      esac
      if [[ -z "$checked" ]]; then
        printf 'While it is off, the box cannot check whether that login still works.\n'
        printf 'To renew it, switch remote access on under Settings, Developer, Remote access in CeraUI.\n'
        printf 'If the card then asks for a key, put the key file on this card again.\n'
      else
        printf 'If that is the network you meant, there is nothing to do.\n'
      fi
      printf 'To move the box to another network, first remove it from the one it is in: delete it in that\n'
      printf "network's admin console, or press Forget this device under Settings, Developer, Remote access\n"
      printf 'in CeraUI. Then put a key file for the new network on this card again.\n'
    } >"${NOT_USED_NOTE}" && sync -f "${BOOT}"
  } 2>/dev/null; then
    log 4 "could not write ${NOT_USED_NOTE##*/} on BOOT; the key stays and the next run tries again"
    write_status pending "$attempts" "$((NOW + delay))" retry || true
    return 1
  fi
  # The result goes to disk before the key is removed, as in finish_join.
  if ! write_status_synced joined "$attempts" 0 already-joined; then
    log 4 "could not store the enrollment result; the next run tries again"
    return 1
  fi
  wipe "${PENDING}"
  sync "${ENROLL}" 2>/dev/null || true
  rm -f -- "${PRIOR}" "${UNUSED}"
  rm -f -- "${REJECTED_NOTE}"
  sync -f "${BOOT}" 2>/dev/null || true
  log 5 "this box already holds a Tailscale login${where:+ as ${where}}${off:+ (${off/-/ })}; the new key was not used and was removed. To move it, remove it from that network first, then add the key again."
}

enroll_pending() {
  present "${PENDING}" || return 0
  parse_keyfile "${PENDING}"
  if [[ -z "${KEY}" ]]; then
    wipe "${PENDING}"
    log 4 "removed pending-authkey: not a regular file holding one tskey-auth- key"
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
  local prior_now
  prior_now="$(read_prior)"
  if [[ "$prior_now" == error ]]; then
    log 4 "cannot read this key's login record; the key stays pending (${attempts}/${MAX_ATTEMPTS})"
    retry_later
    return 1
  fi
  # An earlier attempt already decided not to use this key: finish that.
  local unused_inode="" unused_how="" unused_state="" unused_where=""
  if regular "${UNUSED}"; then
    { read -r unused_inode unused_how unused_state unused_where <"${UNUSED}"; } 2>/dev/null || true
  fi
  if [[ -n "$unused_inode" && "$unused_inode" == "$(stat -c %i -- "${PENDING}" 2>/dev/null)" ]] \
      && [[ "$unused_how" =~ ^(running|saved)$ && "$unused_state" =~ ^[A-Za-z]+$ ]]; then
    key_not_used "$unused_how" "$unused_state" "$unused_where" || return 1
    return 0
  fi
  # This script never starts or stops tailscaled; whether it runs is the
  # owner's. A running one is asked below. One that is not running is judged
  # from its saved state. Anything inconclusive keeps the key, does nothing
  # and asks again after the back-off, without a cap.
  local daemon saved=""
  daemon="$(daemon_state)"
  # Any state that appears from now on, where none existed, is ours to clean up.
  if [[ ! -e "${TS_STATE}/tailscaled.state" && ! -L "${TS_STATE}/tailscaled.state" ]]; then
    : >"${OURS}"
  fi
  case "$daemon" in
    running) ;;
    down)
      saved="$(saved_login)"
      case "$saved" in
        no-login)
          # A key on a box without a login asks to join. The pending-key path
          # unit starts tailscaled while the owner has it enabled; wait for it.
          for ((i = 0; i < START_WAIT; i++)); do
            daemon="$(daemon_state)"
            [[ "$daemon" == running ]] && break
            sleep 1
          done
          daemon="$(daemon_state)"
          if [[ "$daemon" != running ]]; then
            log 5 "tailscaled is not running (remote access switched off, or not started yet); the key waits (${attempts}/${MAX_ATTEMPTS})"
            retry_later
            return 1
          fi
          saved=started
          ;;
        login\ *)
          if [[ -n "$prior_now" ]]; then
            # This key's join began while tailscaled ran, and it was stopped since.
            log 5 "tailscaled is not running; this key's join goes on once remote access is switched on (${attempts}/${MAX_ATTEMPTS})"
            retry_later
            return 1
          fi
          key_not_used saved "${saved#login }" || return 1
          return 0
          ;;
        *)
          log 4 "cannot tell from tailscaled.state whether this box holds a login (${saved#unknown }); the key stays pending (${attempts}/${MAX_ATTEMPTS})"
          retry_later
          return 1
          ;;
      esac
      ;;
    *)
      if [[ "$daemon" == busy ]]; then
        log 5 "tailscaled is starting or stopping; asking again later (${attempts}/${MAX_ATTEMPTS})"
      else
        log 4 "systemd did not say whether tailscaled runs; asking again later (${attempts}/${MAX_ATTEMPTS})"
      fi
      retry_later
      return 1
      ;;
  esac
  for ((i = 0; i < WAIT; i++)); do [[ -S "${SOCKET}" ]] && break; sleep 1; done
  if [[ -n "$prior_now" ]] && ! { sync -- "${PRIOR}" && sync "${ENROLL}"; }; then
    # A record left by an earlier run is trusted only once it is durable.
    log 4 "could not make the login check durable (${attempts}/${MAX_ATTEMPTS}); trying again later"
    retry_later
    return 1
  fi
  if [[ -z "$prior_now" ]]; then
    # Before the keyed up first runs for this key: did the box already hold a
    # login? On disk before the up, so a power cut cannot lose it afterwards.
    backend_state >/dev/null
    local live backend nodekey prior=no
    live="$(live_login)"
    if [[ "$live" == unknown ]]; then
      log 4 "tailscaled gave no usable answer before the attempt (${attempts}/${MAX_ATTEMPTS}); trying again later"
      retry_later
      return 1
    fi
    backend="${live% *}" nodekey="${live#* }"
    if [[ "$nodekey" == yes ]]; then
      prior=yes
      case "$backend" in
        Running|Stopped)
          if [[ "$saved" == started ]]; then
            log 4 "tailscaled.state showed no login, but tailscaled reports one; the key is not used"
          fi
          key_not_used running "$backend" || return 1
          return 0
          ;;
        NoState|Starting)
          # A login that is still connecting may be working or expired; ask again.
          log 5 "tailscaled is still connecting with its current login (${attempts}/${MAX_ATTEMPTS}); asking again later"
          retry_later
          return 1
          ;;
      esac
    fi
    if ! put_synced "${PRIOR}" "$prior $(stat -c %i -- "${PENDING}")" .prior; then
      log 4 "could not store the login check durably (${attempts}/${MAX_ATTEMPTS}); trying again later"
      retry_later
      return 1
    fi
  fi
  # The CLI reads a key-only copy (the pending file also carries the name).
  keyfile="$(mktemp "${ENROLL}/.up-key.XXXXXX")"
  parse_keyfile "${PENDING}"
  printf '%s' "${KEY}" >"$keyfile"
  KEY=""
  local args=(up "--auth-key=file:${keyfile}" --ssh --accept-risk=lose-ssh
              --accept-dns=false --accept-routes=false "--timeout=${UP_TIMEOUT}")
  [[ -n "$name" ]] && args+=("--hostname=${name}")
  out="$("${CLI}" --socket="${SOCKET}" "${args[@]}" 2>&1)" || rc=$?
  wipe "$keyfile"
  if (( rc == 0 )); then
    finish_join "$name" || return 1
    return 0
  fi
  message="$(clean "$out")"
  log 4 "tailscale up failed (attempt ${attempts}/${MAX_ATTEMPTS}): ${message}"
  # Final refusals: Tailscale's control plane ("invalid key: …", expired, revoked,
  # already used) and headscale ("invalid pre auth key", "… has expired", "… has
  # already been used"). Every phrase must be about the key: a TLS error such as
  # "certificate has expired" (a wrong clock on first boot) is transient.
  if printf '%s' "$out" | grep -qiE "$REFUSED_RE"; then
    give_up "the control server refused the key"
    return 1
  fi
  # Only a box that already holds a netmap from such a tailnet answers this way
  # (a fresh login has no netmap yet). If that login predates this key, retrying
  # cannot change it. Otherwise an earlier attempt of this key registered the box
  # and only timed out: finish that join.
  if printf '%s' "$out" | grep -qiE "$NO_TAILNET_SSH_RE"; then
    # Only a record that this key found no login counts; anything else means
    # the login predates the key.
    case "$(read_prior)" in
      no) ;;
      error)
        log 4 "cannot read this key's login record; the key stays pending (${attempts}/${MAX_ATTEMPTS})"
        retry_later
        return 1
        ;;
      *)
        give_up "this tailnet does not allow Tailscale SSH; forget the box there first"
        return 1
        ;;
    esac
    if [[ "$(backend_state)" == Running ]]; then
      log 5 "an earlier attempt with this key registered the box"
      finish_join "$name" refused-ssh || return 1
      return 0
    fi
  fi
  if (( attempts >= MAX_ATTEMPTS )); then
    give_up "no success after ${attempts} attempts"
    return 1
  fi
  write_status pending "$attempts" "$((NOW + delay))" retry
  return 1
}

if present "${ENROLL}" && { [[ -L "${ENROLL}" ]] || [[ ! -d "${ENROLL}" ]]; }; then
  log 3 "refusing: ${ENROLL} is not a plain directory"
  exit 1
fi
install -d -m 0700 "${ENROLL}"
chmod 0700 "${ENROLL}"
exec 9>"${ENROLL}/.lock"
flock -w "${LOCK_WAIT}" 9 || { log 6 "another enrollment run holds the lock; the timer retries"; exit 0; }

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

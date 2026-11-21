#!/bin/sh
# ceralive-clock-gate: start the persistent calendar timers that
# 50-ceralive-clock-gate.conf holds back at boot, once the wall clock is
# usable. The reasons are in ceralive-clock-gate.service.
#
# The clock counts as usable when
#   1. chronyd reports a synchronised clock, or
#   2. the clock did not come from systemd's build-date floor: the wall-clock
#      time of boot (now - uptime) is clearly later than /usr/lib/clock-epoch.
#      A cold boot without RTC sits right at that floor; a valid RTC or a
#      clock set by hand is past it.
# Stamps are not used to decide. Rule 2 trusts an RTC or a hand-set clock
# without checking it against a network source; with no network there is
# nothing to check it against.
#
# While the clock is not usable, the jobs in FALLBACK_SERVICES still run,
# directly and only if their timer is enabled, once after FALLBACK_AFTER
# seconds of uptime and then every FALLBACK_EVERY seconds. A failed run is
# retried on the next poll. Everything else waits: trims, apt and the
# certificate expiry check need a real date to mean anything.
set -u

CHRONYC="${CERALIVE_CHRONYC:-chronyc}"
SYSTEMCTL="${CERALIVE_SYSTEMCTL:-systemctl}"
FLAG="${CERALIVE_CLOCK_FLAG:-/run/ceralive/clock-gate-open}"
UNIT_DIR="${CERALIVE_CLOCK_GATE_UNIT_DIR:-/etc/systemd/system}"
EPOCH_FILE="${CERALIVE_CLOCK_GATE_EPOCH_FILE:-/usr/lib/clock-epoch}"
EPOCH_MARGIN="${CERALIVE_CLOCK_GATE_EPOCH_MARGIN:-300}"
UPTIME_FILE="${CERALIVE_CLOCK_GATE_UPTIME_FILE:-/proc/uptime}"
INTERVAL="${CERALIVE_CLOCK_GATE_INTERVAL:-10}"
SLOW_INTERVAL="${CERALIVE_CLOCK_GATE_SLOW_INTERVAL:-60}"
FALLBACK_AFTER="${CERALIVE_CLOCK_GATE_FALLBACK_AFTER:-3600}"
FALLBACK_EVERY="${CERALIVE_CLOCK_GATE_FALLBACK_EVERY:-86400}"
FALLBACK_SERVICES="${CERALIVE_CLOCK_GATE_FALLBACK_SERVICES:-dpkg-db-backup.service}"
# How long a timer may keep failing to start (manager unreachable, job
# rejected) before the gate gives up on it and fails visibly.
START_BUDGET="${CERALIVE_CLOCK_GATE_START_BUDGET:-600}"
DROPIN=50-ceralive-clock-gate.conf

log() { printf '%s\n' "$*"; }
uptime_s() { cut -d. -f1 "$UPTIME_FILE"; }

# Timers that carry the drop-in, in a stable order.
pending=""
for dropin in "$UNIT_DIR"/*.timer.d/"$DROPIN"; do
  [ -e "$dropin" ] || continue
  timer="${dropin%/*}"
  timer="${timer##*/}"
  pending="$pending ${timer%.d}"
done
[ -n "$pending" ] || { log "no gated timers"; exit 0; }

# enabled | off (disabled, masked, static: boot would not start it) | unknown
boot_state() {
  case "$("$SYSTEMCTL" is-enabled "$1" 2>/dev/null)" in
    enabled|enabled-runtime) echo enabled ;;
    disabled|masked|masked-runtime|static|indirect|generated|alias|linked|linked-runtime|transient|bad|not-found) echo off ;;
    *) echo unknown ;;
  esac
}

clock_usable() {
  if "$CHRONYC" -n waitsync 1 1 >/dev/null 2>&1; then why=synced; return 0; fi
  epoch="$(stat -c %Y "$EPOCH_FILE" 2>/dev/null)" || return 1
  booted_at=$(( $(date +%s) - $(uptime_s) ))
  if [ "$booted_at" -gt $((epoch + EPOCH_MARGIN)) ]; then why=clock; return 0; fi
  return 1
}

# --- wait for a usable clock; run the fallback jobs meanwhile ----------------
next_fallback="$FALLBACK_AFTER"
while ! clock_usable; do
  now="$(uptime_s)"
  if [ "$now" -ge "$next_fallback" ]; then
    retry=0
    for service in $FALLBACK_SERVICES; do
      case "$(boot_state "${service%.service}.timer")" in
        enabled) ;;
        off) continue ;;
        *) retry=1; continue ;;
      esac
      # Blocking start: success means the job ran, not only that it queued.
      if "$SYSTEMCTL" start "$service" 2>/dev/null; then
        log "no usable clock after ${now}s; ran $service without its timer"
      else
        log "no usable clock after ${now}s; $service failed, retrying" >&2
        retry=1
      fi
    done
    if [ "$retry" -eq 0 ]; then next_fallback=$((now + FALLBACK_EVERY)); fi
  fi
  if [ "$now" -ge "$FALLBACK_AFTER" ]; then sleep "$SLOW_INTERVAL"; else sleep "$INTERVAL"; fi
done

# --- release -------------------------------------------------------------------
mkdir -p "${FLAG%/*}" 2>/dev/null
# touch, not a redirection: in dash a failed redirection on a special builtin
# exits the shell with 2, which the unit reserves for start errors.
if ! touch "$FLAG" 2>/dev/null; then
  log "cannot write $FLAG; timers stay held" >&2
  exit 1
fi

started=""
skipped=""
failed=""
first_failure=""
while [ -n "$pending" ]; do
  still=""
  for timer in $pending; do
    case "$(boot_state "$timer")" in
      off) skipped="$skipped $timer"; continue ;;
      enabled)
        if "$SYSTEMCTL" start "$timer" 2>/dev/null; then
          started="$started $timer"
          continue
        fi ;;
    esac
    still="$still $timer"
  done
  pending="$still"
  [ -n "$pending" ] || break
  now="$(uptime_s)"
  first_failure="${first_failure:-$now}"
  if [ $((now - first_failure)) -ge "$START_BUDGET" ]; then
    failed="$pending"
    break
  fi
  sleep "$INTERVAL"
done

log "clock usable ($why); started:${started:- none}; not enabled:${skipped:- none}"
if [ -n "$failed" ]; then
  log "gave up after ${START_BUDGET}s on:$failed" >&2
  # 2 = not retried by systemd (RestartPreventExitStatus=2): the unit fails
  # visibly instead of looping on a timer that will not start.
  exit 2
fi
exit 0

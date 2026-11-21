#!/bin/sh
# ceralive-clock-gate: start the persistent calendar timers that
# 50-ceralive-clock-gate.conf holds back at boot, each one as soon as systemd
# can read its stamp correctly. The reasons are in ceralive-clock-gate.service.
#
# systemd drops a timer's stamp only when the stamp is ahead of the clock. A
# cold boot without RTC starts at /usr/lib/clock-epoch (the build date), which
# can lag real time but never leads it. So a timer whose stamp is already
# behind the clock is safe to start now: it can look "not due yet" but never
# falsely overdue, and systemd recalculates when chrony later steps the clock.
# A timer is released when
#   1. it has no stamp, or the clock is past its stamp (valid RTC, warm boot,
#      clock set by hand or stepped by chrony; NTP not needed), or
#   2. chronyd reports a synchronised clock (also covers a stamp left in the
#      future by an earlier wrong clock).
# A box that never gets a usable clock in a boot still runs the jobs listed in
# FALLBACK_SERVICES once, after FALLBACK_AFTER seconds of uptime, by starting
# the service directly (the timer stays held). Everything else waits: trims,
# apt and the certificate expiry check need a real date to mean anything.
set -u

CHRONYC="${CERALIVE_CHRONYC:-chronyc}"
SYSTEMCTL="${CERALIVE_SYSTEMCTL:-systemctl}"
FLAG="${CERALIVE_CLOCK_FLAG:-/run/ceralive/clock-gate-open}"
UNIT_DIR="${CERALIVE_CLOCK_GATE_UNIT_DIR:-/etc/systemd/system}"
STAMP_DIR="${CERALIVE_CLOCK_GATE_STAMP_DIR:-/var/lib/systemd/timers}"
UPTIME_FILE="${CERALIVE_CLOCK_GATE_UPTIME_FILE:-/proc/uptime}"
INTERVAL="${CERALIVE_CLOCK_GATE_INTERVAL:-10}"
SLOW_INTERVAL="${CERALIVE_CLOCK_GATE_SLOW_INTERVAL:-60}"
FALLBACK_AFTER="${CERALIVE_CLOCK_GATE_FALLBACK_AFTER:-3600}"
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

flag_written=0
open_flag() {
  [ "$flag_written" -eq 1 ] && return 0
  mkdir -p "${FLAG%/*}" 2>/dev/null
  # touch, not a redirection: in dash a failed redirection on a special
  # builtin exits the shell with 2, which the unit reserves for start errors.
  if ! touch "$FLAG" 2>/dev/null; then
    log "cannot write $FLAG; timers stay held" >&2
    exit 1
  fi
  flag_written=1
}

clock_past_stamp() {
  stamp="$STAMP_DIR/stamp-$1"
  [ -e "$stamp" ] || return 0
  mtime="$(stat -c %Y "$stamp" 2>/dev/null)" || return 1
  [ "$(date +%s)" -gt "$mtime" ]
}

chrony_synced() {
  "$CHRONYC" -n waitsync 1 1 >/dev/null 2>&1
}

started=""
skipped=""
failed=""
failing=""   # "timer=uptime-of-first-failure"; only read for timers still pending
fallback_done=0

first_failure_of() {
  for entry in $failing; do
    case "$entry" in "$1="*) printf '%s' "${entry#*=}"; return ;; esac
  done
}
note_failure() {
  [ -n "$(first_failure_of "$1")" ] || failing="$failing $1=$(uptime_s)"
}

while [ -n "$pending" ]; do
  synced=""   # asked at most once per round, and only if a stamp is ahead
  still=""
  for timer in $pending; do
    if ! clock_past_stamp "$timer"; then
      if [ -z "$synced" ]; then
        if chrony_synced; then synced=1; else synced=0; fi
      fi
      if [ "$synced" -eq 0 ]; then
        still="$still $timer"
        continue
      fi
      why=synced
    else
      why=stamp
    fi
    # Only what boot would have started. A query that gives no known answer
    # (manager not reachable) is retried, not taken as "disabled".
    state="$("$SYSTEMCTL" is-enabled "$timer" 2>/dev/null)"
    case "$state" in
      enabled|enabled-runtime) ;;
      disabled|masked|masked-runtime|static|indirect|generated|alias|linked|linked-runtime|transient|bad|not-found)
        skipped="$skipped $timer($state)"
        continue ;;
      *)
        still="$still $timer"
        note_failure "$timer"
        continue ;;
    esac
    open_flag
    if "$SYSTEMCTL" start "$timer" 2>/dev/null; then
      started="$started $timer($why)"
    else
      still="$still $timer"
      note_failure "$timer"
    fi
  done

  now="$(uptime_s)"
  pending=""
  for timer in $still; do
    first="$(first_failure_of "$timer")"
    if [ -n "$first" ] && [ $((now - first)) -ge "$START_BUDGET" ]; then
      failed="$failed $timer"
    else
      pending="$pending $timer"
    fi
  done
  [ -n "$pending" ] || break

  if [ "$fallback_done" -eq 0 ] && [ "$now" -ge "$FALLBACK_AFTER" ]; then
    fallback_done=1
    for service in $FALLBACK_SERVICES; do
      case " $pending " in *" ${service%.service}.timer "*) ;; *) continue ;; esac
      if "$SYSTEMCTL" start --no-block "$service" 2>/dev/null; then
        log "no usable clock after ${now}s; ran $service once without its timer"
      else
        log "no usable clock after ${now}s; could not start $service" >&2
      fi
    done
  fi
  if [ "$now" -ge "$FALLBACK_AFTER" ]; then sleep "$SLOW_INTERVAL"; else sleep "$INTERVAL"; fi
done

log "started:${started:- none}; not enabled:${skipped:- none}"
if [ -n "$failed" ]; then
  log "gave up after ${START_BUDGET}s on:$failed" >&2
  # 2 = not retried by systemd (RestartPreventExitStatus=2): the unit fails
  # visibly instead of looping on a timer that will not start.
  exit 2
fi
exit 0

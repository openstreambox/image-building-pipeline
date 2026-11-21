#!/bin/sh
# ceralive-clock-gate: wait until chrony reports a synchronised clock, then
# start the calendar timers that ceralive-clock-gate.service holds back (each
# carries 50-ceralive-clock-gate.conf). The reasons are in the unit file.
set -eu

CHRONYC="${CERALIVE_CHRONYC:-chronyc}"
SYSTEMCTL="${CERALIVE_SYSTEMCTL:-systemctl}"
FLAG="${CERALIVE_CLOCK_FLAG:-/run/ceralive/clock-synchronized}"
UNIT_DIR="${CERALIVE_CLOCK_GATE_UNIT_DIR:-/etc/systemd/system}"
DROPIN=50-ceralive-clock-gate.conf
INTERVAL="${CERALIVE_CLOCK_GATE_INTERVAL:-10}"

# No try limit: returns once chronyd has a real reference and the remaining
# correction is under a second (after its makestep, that is the first update).
# chronyc keeps asking if chronyd is not up yet. It prints a line per try, and
# that would go to the journal every few seconds on a box without an uplink.
if ! "$CHRONYC" -n waitsync 0 1 0 "$INTERVAL" >/dev/null; then
  echo "chronyc waitsync failed; timers stay held" >&2
  exit 1
fi

mkdir -p "${FLAG%/*}"
: >"$FLAG"

started=""
failed=0
for dropin in "$UNIT_DIR"/*.timer.d/"$DROPIN"; do
  [ -e "$dropin" ] || continue
  timer="${dropin%/*}"
  timer="${timer##*/}"
  timer="${timer%.d}"
  # Only what boot would have started: a timer someone disabled or masked
  # stays off.
  "$SYSTEMCTL" is-enabled --quiet "$timer" 2>/dev/null || continue
  if "$SYSTEMCTL" start "$timer"; then
    started="$started $timer"
  else
    echo "could not start $timer" >&2
    failed=2
  fi
done

echo "clock synchronised; started:${started:- none}"
# 2 = a timer would not start: the unit fails visibly but is not restarted
# (RestartPreventExitStatus=2), since a retry would not change that.
exit "$failed"

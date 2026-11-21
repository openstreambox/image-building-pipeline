#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
#
# clock-gated-timers.bats — persistent calendar timers wait for a real clock.
#
# The Rock 5B+ RTC has no battery, so a cold boot starts at /usr/lib/clock-epoch
# (the build date). A persistent timer started then finds its stamp "in the
# future", drops it and runs its job on every boot; on a board this made
# fstrim discard ~51 GiB within 100 minutes of each boot. The timers carry a
# ConditionPathExists drop-in and ceralive-clock-gate.service starts them once
# chrony reports a synchronised clock (runtime/clock/).
#
# Run:  run-tests   or   bats tests/clock-gated-timers.bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLOCK_SRC="$ROOT/mkosi/runtime/clock"
  GATE="$CLOCK_SRC/ceralive-clock-gate.sh"
  UNIT="$CLOCK_SRC/ceralive-clock-gate.service"
  DROPIN="$CLOCK_SRC/50-ceralive-clock-gate.conf"
  SERVICES="$ROOT/mkosi/customize/postinst.d/services.sh"
  FLAG_PATH=/run/ceralive/clock-synchronized
}

# A fake /etc/systemd/system with gated and ungated timers, plus stubs for
# chronyc and systemctl that log every call. The systemctl stub records whether
# the flag already existed when a timer was started.
make_gate_fixture() {
  local root="$1"
  mkdir -p "$root/bin" "$root/units"
  : >"$root/calls"
  local timer
  for timer in fstrim.timer e2scrub_all.timer dpkg-db-backup.timer disabled-by-admin.timer; do
    install -D -m 0644 "$DROPIN" "$root/units/$timer.d/50-ceralive-clock-gate.conf"
  done
  # An ungated timer with some other drop-in must never be started.
  mkdir -p "$root/units/ceralive-typec-recheck.timer.d"
  printf '[Timer]\nOnUnitActiveSec=10s\n' >"$root/units/ceralive-typec-recheck.timer.d/10-other.conf"

  cat >"$root/bin/chronyc" <<'SH'
#!/bin/sh
printf 'chronyc %s\n' "$*" >>"$GATE_CALLS"
# What chronyc prints per try; the gate must keep it out of the journal.
echo "try: 1, refid: C0A8B201, correction: 0.000111722, skew: 1.214"
exit "${GATE_CHRONYC_RC:-0}"
SH
  cat >"$root/bin/systemctl" <<'SH'
#!/bin/sh
case "$1" in
  is-enabled)
    printf 'systemctl %s\n' "$*" >>"$GATE_CALLS"
    [ "$3" != disabled-by-admin.timer ] ;;
  start)
    if [ -e "$CERALIVE_CLOCK_FLAG" ]; then flag=present; else flag=absent; fi
    printf 'systemctl start %s flag=%s\n' "$2" "$flag" >>"$GATE_CALLS"
    [ "$2" != "${GATE_FAIL_TIMER:-}" ] ;;
  *) printf 'unexpected systemctl %s\n' "$*" >>"$GATE_CALLS"; exit 99 ;;
esac
SH
  chmod +x "$root/bin/chronyc" "$root/bin/systemctl"
}

run_gate() {
  local root="$1"
  shift
  run env "$@" \
    GATE_CALLS="$root/calls" \
    CERALIVE_CHRONYC="$root/bin/chronyc" \
    CERALIVE_SYSTEMCTL="$root/bin/systemctl" \
    CERALIVE_CLOCK_FLAG="$root/run/ceralive/clock-synchronized" \
    CERALIVE_CLOCK_GATE_UNIT_DIR="$root/units" \
    sh "$GATE"
}

@test "clock gate: after sync it writes the flag, then starts every enabled gated timer and nothing else" {
  local root="$BATS_TEST_TMPDIR/sync"
  make_gate_fixture "$root"
  run_gate "$root"
  printf '%s\n' "$output"
  cat "$root/calls"
  [ "$status" -eq 0 ]
  [ -f "$root/run/ceralive/clock-synchronized" ]
  # Unlimited tries, under a second of remaining correction.
  grep -Fxq 'chronyc -n waitsync 0 1 0 10' "$root/calls"
  [ "$(grep -c '^chronyc ' "$root/calls")" -eq 1 ]
  local timer
  for timer in fstrim.timer e2scrub_all.timer dpkg-db-backup.timer; do
    grep -Fxq "systemctl start $timer flag=present" "$root/calls"
  done
  ! grep -Fq 'start disabled-by-admin.timer' "$root/calls"
  ! grep -Fq 'ceralive-typec-recheck' "$root/calls"
  [ "$(grep -c '^systemctl start ' "$root/calls")" -eq 3 ]
  # chronyc's per-try lines stay out of the journal; one summary line instead.
  [[ "$output" != *"try: 1"* ]]
  [[ "$output" == *"clock synchronised; started: "*"fstrim.timer"* ]]
}

@test "clock gate: while chrony has no synchronised clock, no flag and no timer" {
  local root="$BATS_TEST_TMPDIR/nosync"
  make_gate_fixture "$root"
  run_gate "$root" GATE_CHRONYC_RC=1
  printf '%s\n' "$output"
  [ "$status" -eq 1 ]
  [ ! -e "$root/run/ceralive/clock-synchronized" ]
  ! grep -q '^systemctl' "$root/calls"
  [[ "$output" == *"timers stay held"* ]]
}

@test "clock gate: a timer that will not start fails with 2 (not retried) after starting the rest" {
  local root="$BATS_TEST_TMPDIR/startfail"
  make_gate_fixture "$root"
  run_gate "$root" GATE_FAIL_TIMER=e2scrub_all.timer
  printf '%s\n' "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not start e2scrub_all.timer"* ]]
  grep -Fxq 'systemctl start fstrim.timer flag=present' "$root/calls"
  grep -Fxq 'systemctl start dpkg-db-backup.timer flag=present' "$root/calls"
  grep -Fxq 'RestartPreventExitStatus=2' "$UNIT"
}

@test "clock gate: with no gated timers installed it still writes the flag and starts nothing" {
  local root="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$root/units"
  make_gate_fixture "$root"
  rm -rf "$root"/units/*.timer.d
  run_gate "$root"
  [ "$status" -eq 0 ]
  [ -f "$root/run/ceralive/clock-synchronized" ]
  ! grep -q '^systemctl' "$root/calls"
  [[ "$output" == *"started: none"* ]]
}

@test "clock gate: drop-in, script and unit agree on the flag and the drop-in name" {
  # The drop-in holds only the condition, in [Unit].
  [ "$(grep -Ev '^(#|$)' "$DROPIN")" = "[Unit]
ConditionPathExists=$FLAG_PATH" ]
  grep -Fq "CERALIVE_CLOCK_FLAG:-$FLAG_PATH}" "$GATE"
  grep -Fq "DROPIN=$(basename "$DROPIN")" "$GATE"
  grep -Fq "$FLAG_PATH" "$UNIT"
}

@test "clock gate unit: runs in the background and never becomes a boot gate" {
  # exec, not oneshot: no start job waits on the clock, so is-system-running
  # does not sit in "starting" until chrony syncs (or forever without uplink).
  grep -Fxq 'Type=exec' "$UNIT"
  ! grep -Eq '^Type=oneshot' "$UNIT"
  ! grep -Eq '^(Before|WantedBy|RequiredBy)=.*time-sync\.target' "$UNIT"
  ! grep -Eq '^Before=' "$UNIT"
  grep -Fxq 'WantedBy=multi-user.target' "$UNIT"
  grep -Fxq 'ExecStart=/usr/libexec/ceralive/ceralive-clock-gate' "$UNIT"
  grep -Fxq 'Restart=on-failure' "$UNIT"
}

@test "clock gate units parse under systemd-analyze verify" {
  command -v systemd-analyze >/dev/null || skip "systemd-analyze not installed"
  local dir="$BATS_TEST_TMPDIR/verify"
  mkdir -p "$dir/fstrim.timer.d" "$dir/bin"
  # Stock Debian fstrim.timer, with the drop-in beside it.
  printf '[Unit]\nDescription=Discard unused filesystem blocks once a week\n[Timer]\nOnCalendar=weekly\nAccuracySec=1h\nPersistent=true\nRandomizedDelaySec=100min\n[Install]\nWantedBy=timers.target\n' >"$dir/fstrim.timer"
  printf '[Unit]\nDescription=fstrim\n[Service]\nType=oneshot\nExecStart=/bin/true\n' >"$dir/fstrim.service"
  cp "$DROPIN" "$dir/fstrim.timer.d/50-ceralive-clock-gate.conf"
  sed 's#^ExecStart=.*#ExecStart=/bin/true#' "$UNIT" >"$dir/ceralive-clock-gate.service"
  run systemd-analyze verify --man=no "$dir/fstrim.timer" "$dir/ceralive-clock-gate.service"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Unknown"* ]]
}

@test "clock gate installer: script, unit and one drop-in per listed timer; unit enabled" {
  local install_root="$BATS_TEST_TMPDIR/install"
  run env CERALIVE_RUNTIME_SRC="$ROOT/mkosi/runtime" \
    CERALIVE_CLOCK_GATE_UNIT_DIR="$install_root/units" \
    CERALIVE_CLOCK_GATE_HELPER_DIR="$install_root/helpers" \
    TEST_ENABLE_LOG="$install_root/enabled" bash -c '
      source "$1/mkosi/customize/postinst-lib.sh"
      enable_service() { printf "%s\n" "$1" >>"$TEST_ENABLE_LOG"; }
      setup_clock_gated_timers
    ' _ "$ROOT"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  cmp "$GATE" "$install_root/helpers/ceralive-clock-gate"
  [ -x "$install_root/helpers/ceralive-clock-gate" ]
  cmp "$UNIT" "$install_root/units/ceralive-clock-gate.service"
  [ "$(cat "$install_root/enabled")" = ceralive-clock-gate.service ]
  # Every timer the boot journal showed dropping its stamp on a cold boot.
  local timer
  for timer in fstrim.timer e2scrub_all.timer dpkg-db-backup.timer apt-daily.timer \
    apt-daily-upgrade.timer cert-rotation-expiry.timer; do
    cmp "$DROPIN" "$install_root/units/$timer.d/50-ceralive-clock-gate.conf"
  done
  [ "$(find "$install_root/units" -name 50-ceralive-clock-gate.conf | wc -l)" -eq 6 ]
}

@test "clock gate installer: a missing source fails the build before installing anything" {
  local src="$BATS_TEST_TMPDIR/runtime" install_root="$BATS_TEST_TMPDIR/install-missing"
  mkdir -p "$src/clock"
  cp "$GATE" "$UNIT" "$src/clock/"
  run env CERALIVE_RUNTIME_SRC="$src" \
    CERALIVE_CLOCK_GATE_UNIT_DIR="$install_root/units" \
    CERALIVE_CLOCK_GATE_HELPER_DIR="$install_root/helpers" bash -c '
      source "$1/mkosi/customize/postinst-lib.sh"
      enable_service() { :; }
      setup_clock_gated_timers
    ' _ "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"50-ceralive-clock-gate.conf"* ]]
  [ ! -e "$install_root" ]
}

@test "clock gate installer: wired into configure_services" {
  run bash -c "sed -n '/^configure_services() {/,/^}/p' '$SERVICES'"
  [[ "$output" == *"  setup_clock_gated_timers"* ]]
}

@test "clock gate script passes shellcheck as POSIX sh" {
  command -v shellcheck >/dev/null || skip "shellcheck not installed"
  shellcheck -s sh "$GATE"
}

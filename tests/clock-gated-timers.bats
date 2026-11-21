#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
#
# clock-gated-timers.bats — persistent calendar timers are started only once
# systemd can read their stamps correctly.
#
# The Rock 5B+ RTC has no battery, so a cold boot starts at /usr/lib/clock-epoch
# (the build date). A persistent timer started then finds its stamp "in the
# future", drops it and runs its job on every boot; on a board this made
# fstrim discard ~51 GiB within 100 minutes of each boot. The timers carry a
# ConditionPathExists drop-in and ceralive-clock-gate.service starts each one
# when the clock is past its stamp or chrony reports sync, with a once-per-boot
# dpkg-db-backup fallback for a box that never gets a usable clock
# (runtime/clock/).
#
# Run:  run-tests   or   bats tests/clock-gated-timers.bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLOCK_SRC="$ROOT/mkosi/runtime/clock"
  GATE="$CLOCK_SRC/ceralive-clock-gate.sh"
  UNIT="$CLOCK_SRC/ceralive-clock-gate.service"
  DROPIN="$CLOCK_SRC/50-ceralive-clock-gate.conf"
  SERVICES="$ROOT/mkosi/customize/postinst.d/services.sh"
  FLAG_PATH=/run/ceralive/clock-gate-open
  # The image's /bin/sh is dash; run the gate with it where available.
  GATE_SH="$(command -v dash || command -v sh)"
}

teardown() {
  # Only the real-manager test sets this; never an EXIT trap, which is bats' own.
  if [ -n "${REAL_CLEANUP+x}" ]; then
    local name="${REAL_CLEANUP[0]}" udir="${REAL_CLEANUP[1]}" sdir="${REAL_CLEANUP[2]}"
    systemctl --user disable --runtime --now "$name.timer" >/dev/null 2>&1 || true
    rm -rf "$udir/$name.timer" "$udir/$name.service" "$udir/$name.timer.d" "$sdir/stamp-$name.timer"
    systemctl --user daemon-reload || true
  fi
}

# A bare `! cmd` line never fails a bats test (set -e ignores negated
# commands); a function returning non-zero does.
refute() { ! "$@"; }

# A fake /etc/systemd/system with gated timers and one ungated timer, a stamp
# directory, and stubs that log every call:
#   chronyc   synchronised once the fake uptime reaches GATE_SYNC_AT (never if unset)
#   systemctl is-enabled answers from states/<timer> (one line consumed per
#             call, then states/<timer>.final, default enabled; "ERR" = manager
#             not reachable); start fails while startfail/<unit> has lines
#             left (one consumed per call) and records whether the flag existed
#   sleep     advances the fake uptime instead of sleeping
make_gate_fixture() {
  local root="$1"
  mkdir -p "$root/bin" "$root/units" "$root/stamps" "$root/states" "$root/startfail"
  : >"$root/calls"
  printf '100.00 400.00\n' >"$root/uptime"
  local timer
  for timer in fstrim.timer e2scrub_all.timer dpkg-db-backup.timer; do
    install -D -m 0644 "$DROPIN" "$root/units/$timer.d/50-ceralive-clock-gate.conf"
  done
  mkdir -p "$root/units/ceralive-typec-recheck.timer.d"
  printf '[Timer]\nOnUnitActiveSec=10s\n' >"$root/units/ceralive-typec-recheck.timer.d/10-other.conf"

  cat >"$root/bin/chronyc" <<'SH'
#!/bin/sh
up="$(cut -d. -f1 "$GATE_ROOT/uptime")"
printf 'chronyc %s up=%s\n' "$*" "$up" >>"$GATE_ROOT/calls"
echo "try: 1, refid: 00000000, correction: 0.000000000, skew: 0.000"
[ -n "${GATE_SYNC_AT:-}" ] && [ "$up" -ge "$GATE_SYNC_AT" ]
SH
  cat >"$root/bin/systemctl" <<'SH'
#!/bin/sh
pop() { # first line of $1, removed from the file
  [ -s "$1" ] || return 1
  head -n1 "$1"; sed -i 1d "$1"
}
case "$1" in
  is-enabled)
    f="$GATE_ROOT/states/$2"
    if [ -f "$f" ]; then s="$(pop "$f")" || s="$(cat "$f.final" 2>/dev/null || echo enabled)"; else s=enabled; fi
    printf 'systemctl is-enabled %s -> %s\n' "$2" "$s" >>"$GATE_ROOT/calls"
    case "$s" in
      ERR) echo "Failed to connect to bus: No such file or directory" >&2; exit 1 ;;
      enabled|enabled-runtime|static|alias|indirect|generated|transient) echo "$s"; exit 0 ;;
      *) echo "$s"; exit 1 ;;
    esac ;;
  start)
    shift
    nb=""; [ "$1" = --no-block ] && { nb="--no-block "; shift; }
    if [ -e "$CERALIVE_CLOCK_FLAG" ]; then flag=present; else flag=absent; fi
    printf 'systemctl start %s%s flag=%s up=%s\n' "$nb" "$1" "$flag" "$(cut -d. -f1 "$GATE_ROOT/uptime")" >>"$GATE_ROOT/calls"
    if pop "$GATE_ROOT/startfail/$1" >/dev/null; then exit 1; fi
    exit 0 ;;
  *) printf 'unexpected systemctl %s\n' "$*" >>"$GATE_ROOT/calls"; exit 99 ;;
esac
SH
  cat >"$root/bin/sleep" <<'SH'
#!/bin/sh
printf 'sleep %s\n' "$1" >>"$GATE_ROOT/calls"
up="$(cut -d. -f1 "$GATE_ROOT/uptime")"
# A gate that never finishes would loop here forever: end it (our parent).
[ "$up" -lt "${GATE_MAX_UPTIME:-20000}" ] || { echo "fixture: runaway gate loop" >&2; kill -TERM "$PPID"; exit 1; }
printf '%s.00 0.00\n' "$((up + $1))" >"$GATE_ROOT/uptime"
SH
  chmod +x "$root/bin/chronyc" "$root/bin/systemctl" "$root/bin/sleep"
}

# stamp <root> <timer> <offset-seconds-from-now>
stamp() {
  touch -d "@$(( $(date +%s) + $3 ))" "$1/stamps/stamp-$2"
}

run_gate() {
  local root="$1"
  shift
  run env "$@" \
    PATH="$root/bin:$PATH" \
    GATE_ROOT="$root" \
    CERALIVE_CHRONYC="$root/bin/chronyc" \
    CERALIVE_SYSTEMCTL="$root/bin/systemctl" \
    CERALIVE_CLOCK_FLAG="$root/run/ceralive/clock-gate-open" \
    CERALIVE_CLOCK_GATE_UNIT_DIR="$root/units" \
    CERALIVE_CLOCK_GATE_STAMP_DIR="$root/stamps" \
    CERALIVE_CLOCK_GATE_UPTIME_FILE="$root/uptime" \
    "$GATE_SH" "$GATE"
  printf '%s\n' "$output"
  cat "$root/calls"
}

@test "clock gate: a usable clock without NTP releases every timer at once (stamps behind the clock)" {
  # Valid RTC, warm boot or a clock set by hand on a network that blocks NTP:
  # the stamps are behind the clock, so systemd reads them correctly.
  local root="$BATS_TEST_TMPDIR/usable"
  make_gate_fixture "$root"
  stamp "$root" fstrim.timer -3600
  stamp "$root" e2scrub_all.timer -86400
  # dpkg-db-backup has no stamp yet (fresh slot): also safe.
  run_gate "$root"
  [ "$status" -eq 0 ]
  local timer
  for timer in fstrim.timer e2scrub_all.timer dpkg-db-backup.timer; do
    grep -Fxq "systemctl start $timer flag=present up=100" "$root/calls"
  done
  # chrony is not needed and not asked.
  refute grep -q '^chronyc' "$root/calls"
  refute grep -q '^sleep' "$root/calls"
  refute grep -Fq 'ceralive-typec-recheck' "$root/calls"
  [[ "$output" == *"fstrim.timer(stamp)"* ]]
}

@test "clock gate: cold boot holds timers whose stamps are ahead until chrony syncs" {
  local root="$BATS_TEST_TMPDIR/coldboot"
  make_gate_fixture "$root"
  # Clock at the build date: the last real runs are "in the future".
  stamp "$root" fstrim.timer 86400
  stamp "$root" e2scrub_all.timer 86400
  stamp "$root" dpkg-db-backup.timer -60
  run_gate "$root" GATE_SYNC_AT=130 CERALIVE_CLOCK_GATE_INTERVAL=10
  [ "$status" -eq 0 ]
  # dpkg-db-backup's stamp is behind the clock: released in the first round.
  grep -Fxq 'systemctl start dpkg-db-backup.timer flag=present up=100' "$root/calls"
  # The other two wait for the sync at 130 s, polled every 10 s, one try each.
  refute grep -Eq '^systemctl start (fstrim|e2scrub_all)\.timer .* up=1[0-2][0-9]$' "$root/calls"
  grep -Fxq 'systemctl start fstrim.timer flag=present up=130' "$root/calls"
  grep -Fxq 'systemctl start e2scrub_all.timer flag=present up=130' "$root/calls"
  [ "$(grep -c '^sleep 10$' "$root/calls")" -eq 3 ]
  grep -Fxq 'chronyc -n waitsync 1 1 up=100' "$root/calls"
  refute grep -Eq '^chronyc -n waitsync 0' "$root/calls"
  # chronyc's per-try output stays out of the journal.
  [[ "$output" != *"try: 1"* ]]
  [[ "$output" == *"fstrim.timer(synced)"* ]]
}

@test "clock gate: with no usable clock, dpkg-db-backup still runs once after an hour; trims wait" {
  local root="$BATS_TEST_TMPDIR/offline"
  make_gate_fixture "$root"
  stamp "$root" fstrim.timer 86400
  stamp "$root" e2scrub_all.timer 86400
  stamp "$root" dpkg-db-backup.timer 86400
  # NTP arrives only after two hours, to end the run (seen on the next
  # once-a-minute poll, at 7320 s).
  run_gate "$root" GATE_SYNC_AT=7300 CERALIVE_CLOCK_GATE_INTERVAL=10 CERALIVE_CLOCK_GATE_SLOW_INTERVAL=60
  [ "$status" -eq 0 ]
  [ "$(grep -c '^systemctl start --no-block dpkg-db-backup.service' "$root/calls")" -eq 1 ]
  grep -Eq '^systemctl start --no-block dpkg-db-backup\.service flag=absent up=3(6|7)[0-9][0-9]$' "$root/calls"
  # No other job gets a fallback, and no timer starts before the sync.
  refute grep -Eq '^systemctl start --no-block (fstrim|e2scrub)' "$root/calls"
  awk '/^systemctl start [a-z_-]+\.timer /{split($NF, a, "="); if (a[2] + 0 < 7300) bad = 1} END {exit bad}' "$root/calls"
  grep -Fxq 'systemctl start fstrim.timer flag=present up=7320' "$root/calls"
  grep -Fxq 'systemctl start dpkg-db-backup.timer flag=present up=7320' "$root/calls"
  # After the first hour it polls once a minute.
  grep -Fxq 'sleep 60' "$root/calls"
  [[ "$output" == *"ran dpkg-db-backup.service once without its timer"* ]]
}

@test "clock gate: an unreachable manager is retried, not taken as disabled; disabled and masked stay off" {
  local root="$BATS_TEST_TMPDIR/query"
  make_gate_fixture "$root"
  printf 'ERR\nERR\n' >"$root/states/fstrim.timer"
  echo disabled >"$root/states/e2scrub_all.timer.final"; : >"$root/states/e2scrub_all.timer"
  echo masked >"$root/states/dpkg-db-backup.timer.final"; : >"$root/states/dpkg-db-backup.timer"
  run_gate "$root" CERALIVE_CLOCK_GATE_INTERVAL=10
  [ "$status" -eq 0 ]
  [ "$(grep -c '^systemctl is-enabled fstrim.timer' "$root/calls")" -eq 3 ]
  grep -Fxq 'systemctl start fstrim.timer flag=present up=120' "$root/calls"
  refute grep -Fq 'start e2scrub_all.timer' "$root/calls"
  refute grep -Fq 'start dpkg-db-backup.timer' "$root/calls"
  [[ "$output" == *"e2scrub_all.timer(disabled)"* ]]
  [[ "$output" == *"dpkg-db-backup.timer(masked)"* ]]
}

@test "clock gate: a static timer (no install hooks) is not something boot would start" {
  local root="$BATS_TEST_TMPDIR/static"
  make_gate_fixture "$root"
  echo static >"$root/states/e2scrub_all.timer.final"; : >"$root/states/e2scrub_all.timer"
  run_gate "$root"
  [ "$status" -eq 0 ]
  refute grep -Fq 'start e2scrub_all.timer' "$root/calls"
  [[ "$output" == *"e2scrub_all.timer(static)"* ]]
}

@test "clock gate: a start that fails for a while is retried until it succeeds" {
  local root="$BATS_TEST_TMPDIR/transient"
  make_gate_fixture "$root"
  printf 'x\nx\n' >"$root/startfail/fstrim.timer"
  run_gate "$root" CERALIVE_CLOCK_GATE_INTERVAL=10
  [ "$status" -eq 0 ]
  [ "$(grep -c '^systemctl start fstrim.timer' "$root/calls")" -eq 3 ]
  grep -Fxq 'systemctl start fstrim.timer flag=present up=120' "$root/calls"
  [[ "$output" == *"fstrim.timer(stamp)"* ]]
}

@test "clock gate: a timer that keeps failing is given up after the budget (exit 2), the rest still start" {
  local root="$BATS_TEST_TMPDIR/budget"
  make_gate_fixture "$root"
  yes x | head -n 100 >"$root/startfail/e2scrub_all.timer"
  run_gate "$root" CERALIVE_CLOCK_GATE_INTERVAL=10 CERALIVE_CLOCK_GATE_START_BUDGET=60
  [ "$status" -eq 2 ]
  grep -Fxq 'systemctl start fstrim.timer flag=present up=100' "$root/calls"
  grep -Fxq 'systemctl start dpkg-db-backup.timer flag=present up=100' "$root/calls"
  [ "$(grep -c '^systemctl start e2scrub_all.timer' "$root/calls")" -eq 7 ]
  [[ "$output" == *"gave up after 60s on: e2scrub_all.timer"* ]]
  grep -Fxq 'RestartPreventExitStatus=2' "$UNIT"
}

@test "clock gate: the start budget counts per timer, not while others wait for the clock" {
  local root="$BATS_TEST_TMPDIR/budget-per-timer"
  make_gate_fixture "$root"
  stamp "$root" fstrim.timer 86400
  # dpkg-db-backup fails once at 100 s, then starts; fstrim waits 200 s for sync.
  printf 'x\n' >"$root/startfail/dpkg-db-backup.timer"
  run_gate "$root" GATE_SYNC_AT=300 CERALIVE_CLOCK_GATE_INTERVAL=10 CERALIVE_CLOCK_GATE_START_BUDGET=60
  [ "$status" -eq 0 ]
  grep -Fxq 'systemctl start fstrim.timer flag=present up=300' "$root/calls"
}

@test "clock gate: a flag that cannot be written exits 1 (retried), before any timer starts" {
  local root="$BATS_TEST_TMPDIR/flagfail"
  make_gate_fixture "$root"
  mkdir -p "$root/run/ceralive"
  # A dangling symlink whose target directory is missing: in dash a
  # redirection onto it would exit 2, the code reserved for start errors.
  ln -s "$root/missing-dir/flag" "$root/run/ceralive/clock-gate-open"
  stamp "$root" fstrim.timer 86400
  run_gate "$root" GATE_SYNC_AT=0
  [ "$status" -eq 1 ]
  refute grep -q '^systemctl start' "$root/calls"
  [[ "$output" == *"timers stay held"* ]]
  grep -Fxq 'Restart=on-failure' "$UNIT"
}

@test "clock gate: with no gated timers installed it starts nothing and writes no flag" {
  local root="$BATS_TEST_TMPDIR/empty"
  make_gate_fixture "$root"
  rm -rf "$root"/units/*.timer.d
  run_gate "$root"
  [ "$status" -eq 0 ]
  [ ! -e "$root/run/ceralive/clock-gate-open" ]
  refute grep -q '^systemctl' "$root/calls"
  [[ "$output" == *"started: none"* ]]
}

@test "clock gate: drop-in, script and unit agree on the flag and the drop-in name" {
  [ "$(grep -Ev '^(#|$)' "$DROPIN")" = "[Unit]
ConditionPathExists=$FLAG_PATH" ]
  grep -Fq "CERALIVE_CLOCK_FLAG:-$FLAG_PATH}" "$GATE"
  grep -Fq "DROPIN=$(basename "$DROPIN")" "$GATE"
  grep -Fq "$FLAG_PATH" "$UNIT"
}

@test "clock gate unit: runs in the background and never becomes a boot gate" {
  # exec, not oneshot: no start job waits on the clock, so is-system-running
  # does not sit in "starting" until the clock is usable.
  grep -Fxq 'Type=exec' "$UNIT"
  refute grep -Eq '^Type=oneshot' "$UNIT"
  refute grep -Eq '^(Before|WantedBy|RequiredBy)=.*time-sync\.target' "$UNIT"
  refute grep -Eq '^Before=' "$UNIT"
  grep -Fxq 'WantedBy=multi-user.target' "$UNIT"
  grep -Fxq 'ExecStart=/usr/libexec/ceralive/ceralive-clock-gate' "$UNIT"
}

@test "clock gate units parse under systemd-analyze verify" {
  command -v systemd-analyze >/dev/null || skip "systemd-analyze not installed"
  local dir="$BATS_TEST_TMPDIR/verify"
  mkdir -p "$dir/fstrim.timer.d"
  printf '[Unit]\nDescription=Discard unused filesystem blocks once a week\n[Timer]\nOnCalendar=weekly\nAccuracySec=1h\nPersistent=true\nRandomizedDelaySec=100min\n[Install]\nWantedBy=timers.target\n' >"$dir/fstrim.timer"
  printf '[Unit]\nDescription=fstrim\n[Service]\nType=oneshot\nExecStart=/bin/true\n' >"$dir/fstrim.service"
  cp "$DROPIN" "$dir/fstrim.timer.d/50-ceralive-clock-gate.conf"
  sed 's#^ExecStart=.*#ExecStart=/bin/true#' "$UNIT" >"$dir/ceralive-clock-gate.service"
  run systemd-analyze verify --man=no "$dir/fstrim.timer" "$dir/ceralive-clock-gate.service"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Unknown"* ]]
}

# Real systemd: the user manager runs the same timer code as PID 1. A test
# timer with the drop-in (pointing at a test flag) is skipped on start, then
# the gate starts it: with a recent stamp it keeps its weekly schedule, with a
# stamp a week old it catches up at once.
user_manager_ok() {
  command -v systemctl >/dev/null || return 1
  [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] || return 1
  local state
  state="$(systemctl --user is-system-running 2>/dev/null)"
  case "$state" in running|degraded) return 0 ;; *) return 1 ;; esac
}

@test "clock gate against a real systemd manager: skip at start, release, keep a recent stamp, catch up an old one" {
  user_manager_ok || skip "no systemd user manager"
  local name="clockgate-test-$$-$RANDOM"
  local udir="$XDG_RUNTIME_DIR/systemd/user"
  local sdir="${XDG_DATA_HOME:-$HOME/.local/share}/systemd/timers"
  local work="$BATS_TEST_TMPDIR/real"
  mkdir -p "$udir/$name.timer.d" "$sdir" "$work/bin" "$work/units/$name.timer.d"
  REAL_CLEANUP=("$name" "$udir" "$sdir")

  printf '[Unit]\nDescription=clock gate test\n[Timer]\nOnCalendar=weekly\nPersistent=true\nRandomizedDelaySec=0\nAccuracySec=1s\n[Install]\nWantedBy=timers.target\n' >"$udir/$name.timer"
  printf '[Service]\nType=oneshot\nExecStart=/bin/sh -c "echo ran >>%s/ran"\n' "$work" >"$udir/$name.service"
  sed "s#^ConditionPathExists=.*#ConditionPathExists=$work/flag#" "$DROPIN" >"$udir/$name.timer.d/50-ceralive-clock-gate.conf"
  cp "$udir/$name.timer.d/50-ceralive-clock-gate.conf" "$work/units/$name.timer.d/"
  printf '#!/bin/sh\nexec systemctl --user "$@"\n' >"$work/bin/systemctl"
  printf '#!/bin/sh\nexit 1\n' >"$work/bin/chronyc"
  chmod +x "$work/bin/systemctl" "$work/bin/chronyc"
  systemctl --user daemon-reload
  systemctl --user enable --runtime "$name.timer" >/dev/null 2>&1

  gate() {
    env CERALIVE_CHRONYC="$work/bin/chronyc" CERALIVE_SYSTEMCTL="$work/bin/systemctl" \
      CERALIVE_CLOCK_FLAG="$work/flag" CERALIVE_CLOCK_GATE_UNIT_DIR="$work/units" \
      CERALIVE_CLOCK_GATE_STAMP_DIR="$sdir" "$GATE_SH" "$GATE"
  }

  # 1. Recent stamp: skipped at start, then released with its weekly schedule.
  touch -d '-1 hour' "$sdir/stamp-$name.timer"
  systemctl --user start "$name.timer"
  [ "$(systemctl --user show -p ActiveState --value "$name.timer")" = inactive ]
  run gate
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$name.timer(stamp)"* ]]
  [ "$(systemctl --user show -p ActiveState --value "$name.timer")" = active ]
  local next now
  next="$(systemctl --user show -p NextElapseUSecRealtime --value "$name.timer")"
  now="$(date +%s)"
  [ "$(( $(date -d "$next" +%s) - now ))" -gt 3600 ] || [ "$(date -d "$next" +%u)" = 1 ]
  sleep 2
  [ ! -e "$work/ran" ]

  # 2. Stamp eight days old: released and run at once (persistent catch-up).
  systemctl --user stop "$name.timer"
  rm -f "$work/flag"
  touch -d '-8 days' "$sdir/stamp-$name.timer"
  systemctl --user start "$name.timer"
  [ "$(systemctl --user show -p ActiveState --value "$name.timer")" = inactive ]
  run gate
  [ "$status" -eq 0 ]
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -e "$work/ran" ] && break; sleep 0.5; done
  [ "$(cat "$work/ran")" = ran ]
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

#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
#
# srtla-send-unit.bats — the SRTLA sender gets its own systemd unit.
#
# CeraUI used to spawn srtla_send as its own child, so every restart of
# ceralive.service (KillMode=mixed) killed the sender and ended a live stream.
# srtla-send.service runs the sender in its own cgroup: CeraUI publishes the
# arguments as /run/srtla-send/argv and starts, restarts or stops the unit.
# The legacy OTA guard already refuses to update while a unit of this name is
# active.
#
# Run:  run-tests   or   bats tests/srtla-send-unit.bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SRC="$ROOT/mkosi/runtime/srtla-send"
  UNIT="$SRC/srtla-send.service"
  LAUNCH="$SRC/srtla-send-launch.py"
  TMPFILES="$SRC/srtla-send.tmpfiles.conf"
  SERVICES="$ROOT/mkosi/customize/postinst.d/services.sh"
  ARGDIR="$BATS_TEST_TMPDIR/run-srtla-send"
  mkdir -p "$ARGDIR"
  chmod 0700 "$ARGDIR"
  ARGV="$ARGDIR/argv"
  STUB="$BATS_TEST_TMPDIR/srtla_send"
  cat >"$STUB" <<'EOF'
#!/bin/bash
printf '%s\n' "$#" >"$STUB_OUT"
for a in "$@"; do printf '[%s]\n' "$a" >>"$STUB_OUT"; done
exit "${STUB_EXIT:-0}"
EOF
  chmod 0755 "$STUB"
  export STUB_OUT="$BATS_TEST_TMPDIR/stub.out"
  export CERALIVE_SRTLA_SEND_ARGV="$ARGV"
  export CERALIVE_SRTLA_SEND_BIN="$STUB"
  CERALIVE_SRTLA_SEND_OWNER_UID="$(id -u)"
  export CERALIVE_SRTLA_SEND_OWNER_UID
}

teardown() {
  # Only the real-manager test sets this; never an EXIT trap, which is bats' own.
  if [ -n "${REAL_CLEANUP+x}" ]; then
    local name="${REAL_CLEANUP[0]}" udir="${REAL_CLEANUP[1]}"
    systemctl --user stop "$name.service" "$name-owner.service" >/dev/null 2>&1 || true
    systemctl --user reset-failed "$name.service" "$name-owner.service" >/dev/null 2>&1 || true
    rm -f "$udir/$name.service"
    systemctl --user daemon-reload || true
  fi
}

refute() { ! "$@"; }

# publish <arg>... — what a caller does: a fresh 0600 file, each argument
# NUL-terminated, renamed into place.
publish() {
  local tmp="$ARGDIR/.argv.new"
  ( umask 077; printf '%s\0' "$@" >"$tmp" )
  mv -f "$tmp" "$ARGV"
}

launch() { python3 "$LAUNCH"; }

# --- installer --------------------------------------------------------------

@test "installer: launcher, unit and runtime directory land where they belong, not enabled" {
  local helpers="$BATS_TEST_TMPDIR/libexec" units="$BATS_TEST_TMPDIR/system" tmpf="$BATS_TEST_TMPDIR/tmpfiles.d"
  run bash -euc 'source "$1"; setup_srtla_send_unit' _ "$SERVICES"
  [ "$status" -ne 0 ]
  [[ "$output" == *"srtla-send unit source not found"* ]]

  CERALIVE_RUNTIME_SRC="$ROOT/mkosi/runtime" CERALIVE_SRTLA_SEND_HELPER_DIR="$helpers" \
  CERALIVE_SRTLA_SEND_UNIT_DIR="$units" CERALIVE_SRTLA_SEND_TMPFILES_DIR="$tmpf" \
    run bash -euc 'source "$1"; setup_srtla_send_unit' _ "$SERVICES"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$helpers/srtla-send-launch")" = 755 ]
  [ "$(stat -c %a "$units/srtla-send.service")" = 644 ]
  [ "$(stat -c %a "$tmpf/srtla-send.conf")" = 644 ]
  cmp "$UNIT" "$units/srtla-send.service"
  cmp "$LAUNCH" "$helpers/srtla-send-launch"
  head -1 "$helpers/srtla-send-launch" | grep -qx '#!/usr/bin/python3'
  # Started by CeraUI only: no wants link and nothing to enable.
  [ -z "$(find "$units" -name '*.wants' -print -quit)" ]
  refute grep -q '^\[Install\]' "$units/srtla-send.service"
  # The unit runs exactly the path the installer writes.
  grep -qx 'ExecStart=/usr/libexec/ceralive/srtla-send-launch' "$units/srtla-send.service"
}

@test "installer: configure_services installs the unit and enables nothing for it" {
  local helpers="$BATS_TEST_TMPDIR/libexec" units="$BATS_TEST_TMPDIR/system" tmpf="$BATS_TEST_TMPDIR/tmpfiles.d"
  local enables="$BATS_TEST_TMPDIR/enables"
  : >"$enables"
  CERALIVE_RUNTIME_SRC="$ROOT/mkosi/runtime" CERALIVE_SRTLA_SEND_HELPER_DIR="$helpers" \
  CERALIVE_SRTLA_SEND_UNIT_DIR="$units" CERALIVE_SRTLA_SEND_TMPFILES_DIR="$tmpf" ENABLES="$enables" \
    run bash -euc '
      source "$1"
      # The other steps of configure_services, by name; anything else fails.
      for fn in configure_debug_access configure_ntp configure_ssh_enablement \
          suppress_unusable_boot_units setup_typec_policy setup_fan_curve setup_fan_kickstart \
          setup_led_status setup_reset_evidence setup_cpu_governor setup_hdmirx_edid \
          setup_pipewire_system_mode setup_power_policy setup_rauc_activation setup_slot_sync \
          setup_boot_script_sync setup_dpkg_recovery setup_clock_gated_timers; do
        eval "$fn() { :; }"
      done
      enable_service() { printf "enable %s\n" "$1" >>"$ENABLES"; }
      disable_service() { :; }
      configure_services
    ' _ "$SERVICES"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ -x "$helpers/srtla-send-launch" ]
  [ -f "$units/srtla-send.service" ]
  [ -f "$tmpf/srtla-send.conf" ]
  refute grep -q srtla "$enables"
}

# --- unit -------------------------------------------------------------------

@test "unit: systemd restarts a crashed sender, not a configuration error, within a bound" {
  grep -qx 'Type=exec' "$UNIT"
  grep -qx 'Restart=on-failure' "$UNIT"
  grep -qx 'RestartPreventExitStatus=2 78' "$UNIT"
  grep -qx 'StartLimitIntervalSec=60' "$UNIT"
  grep -qx 'StartLimitBurst=10' "$UNIT"
  grep -qx 'After=network.target' "$UNIT"
  # CeraUI's files must stay visible to the sender.
  refute grep -Eq '^(PrivateTmp|ProtectSystem|ReadOnlyPaths|InaccessiblePaths)=' "$UNIT"
  # No ties to ceralive.service: its stop must not reach the sender.
  refute grep -Eq '^(PartOf|BindsTo|Requires|Requisite)=' "$UNIT"
  # The runtime directory does not depend on CeraUI's own.
  refute grep -Eq '^RuntimeDirectory' "$UNIT"
  grep -qx 'd /run/srtla-send 0700 root root -' "$TMPFILES"
}

@test "unit: the legacy OTA guard checks a unit of exactly this name" {
  local name
  name="$(basename "$UNIT")"
  run bash -c 'grep -E "^for svc in .*\\bsrtla-send\\.service\\b" "$1"' _ \
    "$ROOT/mkosi/customize/postinst.d/persistence.sh"
  [ "$status" -eq 0 ]
  [ "$name" = srtla-send.service ]
}

@test "unit: systemd-analyze verify accepts it" {
  command -v systemd-analyze >/dev/null || skip "systemd-analyze not installed"
  local dir="$BATS_TEST_TMPDIR/verify"
  mkdir -p "$dir"
  sed "s#^ExecStart=.*#ExecStart=$LAUNCH#" "$UNIT" >"$dir/srtla-send.service"
  run systemd-analyze verify --man=no "$dir/srtla-send.service"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
}

# --- launcher ---------------------------------------------------------------

@test "launcher: execs the sender with the exact argument vector" {
  publish 9000 relay.example.net 5000 /tmp/srtla_ips --conn-timeout-ms 15000 \
    --stats-file "/run/srtla-send/stats file.json" ""
  run launch
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_OUT")" = "9
[9000]
[relay.example.net]
[5000]
[/tmp/srtla_ips]
[--conn-timeout-ms]
[15000]
[--stats-file]
[/run/srtla-send/stats file.json]
[]" ]
}

@test "launcher: the sender's exit status is the unit's" {
  publish 9000 relay.example.net 5000 /tmp/srtla_ips
  STUB_EXIT=7 run launch
  [ "$status" -eq 7 ]
}

@test "launcher: the sender replaces the launcher (same PID)" {
  publish 9000 relay.example.net 5000 /tmp/srtla_ips
  cat >"$STUB" <<'EOF'
#!/bin/bash
printf '%s\n' "$$" >"$STUB_OUT"
EOF
  python3 "$LAUNCH" &
  local pid=$!
  wait "$pid"
  [ "$(cat "$STUB_OUT")" = "$pid" ]
}

@test "launcher: refuses a missing, linked, special, foreign or writable argument file with 78" {
  run launch
  [ "$status" -eq 78 ]
  [[ "$output" == *"cannot open"* ]]

  publish 9000 relay.example.net 5000 /tmp/srtla_ips
  ln -s "$ARGV" "$ARGDIR/link"
  CERALIVE_SRTLA_SEND_ARGV="$ARGDIR/link" run launch
  [ "$status" -eq 78 ]

  # A FIFO must neither block the launcher nor be read.
  mkfifo "$ARGDIR/fifo"
  CERALIVE_SRTLA_SEND_ARGV="$ARGDIR/fifo" run timeout 5 python3 "$LAUNCH"
  [ "$status" -eq 78 ]
  [[ "$output" == *"not a regular file"* ]]

  CERALIVE_SRTLA_SEND_OWNER_UID=12345 run launch
  [ "$status" -eq 78 ]

  chmod 0620 "$ARGV"
  run launch
  [ "$status" -eq 78 ]
  [[ "$output" == *"writable by group or others"* ]]
  chmod 0600 "$ARGV"

  chmod 0000 "$ARGV"
  if [ "$(id -u)" -ne 0 ]; then
    run launch
    [ "$status" -eq 78 ]
    [[ "$output" == *"cannot open"* ]]
  fi
  [ ! -e "$STUB_OUT" ]
}

@test "launcher: refuses an argument file in a directory others could swap it in" {
  publish 9000 relay.example.net 5000 /tmp/srtla_ips
  chmod 0770 "$ARGDIR"
  run launch
  [ "$status" -eq 78 ]
  [[ "$output" == *"writable by nobody else"* ]]
  chmod 0700 "$ARGDIR"

  ln -s "$ARGDIR" "$BATS_TEST_TMPDIR/linkdir"
  CERALIVE_SRTLA_SEND_ARGV="$BATS_TEST_TMPDIR/linkdir/argv" run launch
  [ "$status" -eq 78 ]
  [[ "$output" == *"not a directory"* ]]
  [ ! -e "$STUB_OUT" ]
}

@test "launcher: refuses an empty, oversized, truncated, short or portless argument vector with 78" {
  ( umask 077; : >"$ARGV" )
  run launch
  [ "$status" -eq 78 ]
  [[ "$output" == *"0 bytes"* ]]

  head -c 8192 /dev/zero | tr '\0' a >"$ARGV"
  printf '\0' >>"$ARGV"
  run launch
  [ "$status" -eq 78 ]
  [[ "$output" == *"8193 bytes"* ]]

  # A write cut short loses the final NUL; never launch its last argument.
  printf '9000\0relay.example.net\0005000\0/tmp/srtla_i' >"$ARGV"
  run launch
  [ "$status" -eq 78 ]
  [[ "$output" == *"does not end in a NUL"* ]]

  publish 9000 relay.example.net 5000
  run launch
  [ "$status" -eq 78 ]
  [[ "$output" == *"needs at least 4"* ]]

  local port
  for port in 0 65536 abc -1 "" 123456 "٩٠٠٠" " 9000"; do
    publish "$port" relay.example.net 5000 /tmp/srtla_ips
    run launch
    [ "$status" -eq 78 ] || { echo "port '$port' accepted"; false; }
  done
  [ ! -e "$STUB_OUT" ]
}

# --- real service manager ---------------------------------------------------

# main_pid_running <unit> — the unit's MainPID once it is the sender itself.
sender_pid() {
  local unit="$1" pid i
  for i in $(seq 100); do
    pid="$(systemctl --user show -p MainPID --value "$unit")"
    if [ "${pid:-0}" -gt 0 ] && [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = sleep ]; then
      printf '%s\n' "$pid"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# Runs the unit under the caller's user manager with a sender that sleeps, so
# the restart, refusal and owner-restart behaviour are systemd's own.
@test "real manager: a sender outlives its owner's restart, restarts after a crash, stays down when stopped or refused" {
  systemctl --user is-system-running >/dev/null 2>&1 \
    || [ "$(systemctl --user is-system-running 2>/dev/null)" = degraded ] \
    || skip "no user service manager"
  local udir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  local name="osb-test-srtla-send-$$-$RANDOM"
  mkdir -p "$udir"
  REAL_CLEANUP=("$name" "$udir")
  cat >"$STUB" <<'EOF'
#!/bin/bash
exec sleep 600
EOF
  {
    sed -e "s#^ExecStart=.*#ExecStart=/usr/bin/python3 $LAUNCH#" -e 's#^RestartSec=.*#RestartSec=200ms#' "$UNIT"
    printf 'Environment=CERALIVE_SRTLA_SEND_ARGV=%s\n' "$ARGV"
    printf 'Environment=CERALIVE_SRTLA_SEND_BIN=%s\n' "$STUB"
    printf 'Environment=CERALIVE_SRTLA_SEND_OWNER_UID=%s\n' "$(id -u)"
  } >"$udir/$name.service"
  systemctl --user daemon-reload
  publish 9000 relay.example.net 5000 /tmp/srtla_ips

  # The owner stands in for ceralive.service: it starts the sender and keeps
  # a child of its own, then is restarted with KillMode=mixed the way a
  # CeraUI restart is.
  systemd-run --user --quiet --unit="$name-owner" -p KillMode=mixed -p Restart=no \
    bash -c "systemctl --user start '$name.service'; sleep 600 & wait"
  local pid
  pid="$(sender_pid "$name.service")"
  local owner_cg
  owner_cg="$(systemctl --user show -p ControlGroup --value "$name-owner.service")"
  [ -n "$owner_cg" ]
  systemctl --user stop "$name-owner.service"
  # The owner's cgroup is drained; the sender is untouched.
  [ "$(systemctl --user is-active "$name-owner.service")" != active ]
  [ "$(systemctl --user is-active "$name.service")" = active ]
  [ "$(systemctl --user show -p MainPID --value "$name.service")" = "$pid" ]
  systemd-run --user --quiet --unit="$name-owner" -p KillMode=mixed -p Restart=no \
    bash -c "systemctl --user start '$name.service'; sleep 600 & wait"
  sleep 0.5
  [ "$(systemctl --user show -p MainPID --value "$name.service")" = "$pid" ]

  # A crash is restarted by systemd.
  kill -9 "$pid"
  local again="" i
  for i in $(seq 50); do
    again="$(sender_pid "$name.service" || true)"
    [ -n "$again" ] && [ "$again" != "$pid" ] && break
    sleep 0.1
  done
  [ -n "$again" ] && [ "$again" != "$pid" ]
  [ "$(systemctl --user show -p NRestarts --value "$name.service")" -ge 1 ]

  # A stop is final, also after RestartSec has passed.
  systemctl --user stop "$name.service"
  sleep 0.6
  [ "$(systemctl --user is-active "$name.service")" = inactive ]

  # A refused argument file fails once and is not retried.
  chmod 0666 "$ARGV"
  systemctl --user reset-failed "$name.service" >/dev/null 2>&1 || true
  systemctl --user start "$name.service" || true
  for i in $(seq 30); do
    [ "$(systemctl --user is-active "$name.service")" = failed ] && break
    sleep 0.1
  done
  sleep 0.6
  [ "$(systemctl --user is-active "$name.service")" = failed ]
  [ "$(systemctl --user show -p NRestarts --value "$name.service")" = 0 ]
  [ "$(systemctl --user show -p ExecMainStatus --value "$name.service")" = 78 ]
}

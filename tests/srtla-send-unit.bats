#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
#
# srtla-send-unit.bats — the SRTLA sender gets its own systemd unit.
#
# CeraUI used to spawn srtla_send as its own child, so every restart of
# ceralive.service (KillMode=mixed) killed the sender and ended a live stream.
# srtla-send.service runs the sender in its own cgroup: CeraUI writes the
# arguments to /run/ceralive/srtla-send.argv and starts, restarts or stops the
# unit. cerastream.service already orders itself after this unit, and the OTA
# guard already refuses to update while it is active.
#
# Run:  run-tests   or   bats tests/srtla-send-unit.bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SRC="$ROOT/mkosi/runtime/srtla-send"
  UNIT="$SRC/srtla-send.service"
  LAUNCH="$SRC/srtla-send-launch.sh"
  SERVICES="$ROOT/mkosi/customize/postinst.d/services.sh"
  ARGV="$BATS_TEST_TMPDIR/srtla-send.argv"
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

# write_argv <arg>... — NUL-separated, as CeraUI writes it, mode 0600.
write_argv() {
  : >"$ARGV"
  chmod 0600 "$ARGV"
  printf '%s\0' "$@" >"$ARGV"
}

# --- installer --------------------------------------------------------------

@test "installer: launcher and unit land where systemd and the unit expect them, not enabled" {
  local helpers="$BATS_TEST_TMPDIR/libexec" units="$BATS_TEST_TMPDIR/system"
  run bash -euc '
    source "$1"
    setup_srtla_send_unit
  ' _ "$SERVICES"
  [ "$status" -ne 0 ]
  [[ "$output" == *"srtla-send unit source not found"* ]]

  CERALIVE_RUNTIME_SRC="$ROOT/mkosi/runtime" \
  CERALIVE_SRTLA_SEND_HELPER_DIR="$helpers" CERALIVE_SRTLA_SEND_UNIT_DIR="$units" \
    run bash -euc 'source "$1"; setup_srtla_send_unit' _ "$SERVICES"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$helpers/srtla-send-launch")" = 755 ]
  [ "$(stat -c %a "$units/srtla-send.service")" = 644 ]
  cmp "$UNIT" "$units/srtla-send.service"
  # Started by CeraUI only: no wants link and nothing to enable.
  [ -z "$(find "$units" -name '*.wants' -print -quit)" ]
  refute grep -q '^\[Install\]' "$units/srtla-send.service"
  # The unit runs exactly the path the installer writes.
  grep -qx 'ExecStart=/usr/libexec/ceralive/srtla-send-launch' "$units/srtla-send.service"
}

@test "installer: configure_services installs the unit" {
  local helpers="$BATS_TEST_TMPDIR/libexec" units="$BATS_TEST_TMPDIR/system"
  CERALIVE_RUNTIME_SRC="$ROOT/mkosi/runtime" \
  CERALIVE_SRTLA_SEND_HELPER_DIR="$helpers" CERALIVE_SRTLA_SEND_UNIT_DIR="$units" \
    run bash -euc '
      source "$1"
      # Steps that live in other postinst modules are not under test here.
      command_not_found_handle() { :; }
      for fn in $(declare -F | cut -d" " -f3); do
        case "$fn" in configure_services|setup_srtla_send_unit|log|die|command_not_found_handle) ;; *) eval "$fn() { :; }" ;; esac
      done
      configure_services
    ' _ "$SERVICES"
  [ "$status" -eq 0 ]
  [ -x "$helpers/srtla-send-launch" ]
  [ -f "$units/srtla-send.service" ]
}

# --- unit -------------------------------------------------------------------

@test "unit: systemd restarts a crashed sender, not a refused argument file, within a bound" {
  grep -qx 'Type=exec' "$UNIT"
  grep -qx 'Restart=on-failure' "$UNIT"
  grep -qx 'RestartPreventExitStatus=2' "$UNIT"
  grep -qx 'StartLimitIntervalSec=60' "$UNIT"
  grep -qx 'StartLimitBurst=10' "$UNIT"
  grep -qx 'After=network.target' "$UNIT"
  # CeraUI's files under /tmp and /run must stay visible to the sender.
  refute grep -Eq '^(PrivateTmp|ProtectSystem|ReadOnlyPaths|InaccessiblePaths)=' "$UNIT"
  # No ties to ceralive.service: its stop must not reach the sender.
  refute grep -Eq '^(PartOf|BindsTo|Requires|Requisite)=' "$UNIT"
}

@test "unit: cerastream's packaged ordering and the OTA guard name this exact unit" {
  # Both were written for a srtla-send.service that the image did not have.
  grep -q 'srtla-send.service' "$ROOT/docs/agents/key-facts.md"
  grep -q 'for svc in cerastream.service srtla.service srtla-send.service' \
    "$ROOT/mkosi/customize/postinst.d/persistence.sh"
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
  write_argv 9000 relay.example.net 5000 /tmp/srtla_ips --conn-timeout-ms 15000 \
    --stats-file "/run/ceralive/srtla stats.json" ""
  run bash "$LAUNCH"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_OUT")" = "9
[9000]
[relay.example.net]
[5000]
[/tmp/srtla_ips]
[--conn-timeout-ms]
[15000]
[--stats-file]
[/run/ceralive/srtla stats.json]
[]" ]
}

@test "launcher: the sender's exit status is the unit's" {
  write_argv 9000 relay.example.net 5000 /tmp/srtla_ips
  STUB_EXIT=7 run bash "$LAUNCH"
  [ "$status" -eq 7 ]
}

@test "launcher: the sender replaces the launcher (same PID)" {
  write_argv 9000 relay.example.net 5000 /tmp/srtla_ips
  cat >"$STUB" <<'EOF'
#!/bin/bash
printf '%s\n' "$$" >"$STUB_OUT"
EOF
  bash "$LAUNCH" &
  local pid=$!
  wait "$pid"
  [ "$(cat "$STUB_OUT")" = "$pid" ]
}

@test "launcher: refuses a missing, linked, foreign or writable argument file with exit 2" {
  run bash "$LAUNCH"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no argument file"* ]]

  write_argv 9000 relay.example.net 5000 /tmp/srtla_ips
  ln -s "$ARGV" "$BATS_TEST_TMPDIR/link.argv"
  CERALIVE_SRTLA_SEND_ARGV="$BATS_TEST_TMPDIR/link.argv" run bash "$LAUNCH"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no argument file"* ]]

  CERALIVE_SRTLA_SEND_OWNER_UID=12345 run bash "$LAUNCH"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not 12345"* ]]

  chmod 0620 "$ARGV"
  run bash "$LAUNCH"
  [ "$status" -eq 2 ]
  [[ "$output" == *"writable by group or others"* ]]
  chmod 0602 "$ARGV"
  run bash "$LAUNCH"
  [ "$status" -eq 2 ]
  [ ! -e "$STUB_OUT" ]
}

@test "launcher: refuses an empty, oversized, short or portless argument vector with exit 2" {
  : >"$ARGV"
  chmod 0600 "$ARGV"
  run bash "$LAUNCH"
  [ "$status" -eq 2 ]
  [[ "$output" == *"0 bytes"* ]]

  head -c 8193 /dev/zero | tr '\0' a >"$ARGV"
  run bash "$LAUNCH"
  [ "$status" -eq 2 ]
  [[ "$output" == *"8193 bytes"* ]]

  write_argv 9000 relay.example.net 5000
  run bash "$LAUNCH"
  [ "$status" -eq 2 ]
  [[ "$output" == *"needs at least 4"* ]]

  local port
  for port in 0 65536 abc -1 "" 123456; do
    write_argv "$port" relay.example.net 5000 /tmp/srtla_ips
    run bash "$LAUNCH"
    [ "$status" -eq 2 ] || { echo "port '$port' accepted"; false; }
  done
  [ ! -e "$STUB_OUT" ]
}

# --- real service manager ---------------------------------------------------

# Runs the unit under the caller's user manager with a sender that sleeps, so
# the restart, refusal and owner-restart behaviour are systemd's own.
@test "real manager: a sender outlives its owner's restart, restarts after a crash, stays down when refused" {
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
    sed -e "s#^ExecStart=.*#ExecStart=$LAUNCH#" -e 's#^RestartSec=.*#RestartSec=200ms#' "$UNIT"
    printf 'Environment=CERALIVE_SRTLA_SEND_ARGV=%s\n' "$ARGV"
    printf 'Environment=CERALIVE_SRTLA_SEND_BIN=%s\n' "$STUB"
    printf 'Environment=CERALIVE_SRTLA_SEND_OWNER_UID=%s\n' "$(id -u)"
  } >"$udir/$name.service"
  systemctl --user daemon-reload
  write_argv 9000 relay.example.net 5000 /tmp/srtla_ips

  # The owner stands in for ceralive.service: it starts the sender, then is
  # stopped with KillMode=mixed the way a CeraUI restart is.
  systemd-run --user --quiet --unit="$name-owner" -p KillMode=mixed \
    bash -c "systemctl --user start '$name.service'; exec sleep 600"
  local i pid=""
  for i in $(seq 50); do
    pid="$(systemctl --user show -p MainPID --value "$name.service")"
    [ "${pid:-0}" -gt 0 ] && break
    sleep 0.1
  done
  [ "${pid:-0}" -gt 0 ]
  [ "$(cat "/proc/$pid/comm")" = sleep ]
  systemctl --user stop "$name-owner.service"
  [ "$(systemctl --user is-active "$name.service")" = active ]
  [ "$(systemctl --user show -p MainPID --value "$name.service")" = "$pid" ]

  # A crash is restarted by systemd.
  kill -9 "$pid"
  local again=""
  for i in $(seq 50); do
    again="$(systemctl --user show -p MainPID --value "$name.service")"
    [ "${again:-0}" -gt 0 ] && [ "$again" != "$pid" ] && break
    sleep 0.1
  done
  [ "${again:-0}" -gt 0 ] && [ "$again" != "$pid" ]
  [ "$(systemctl --user show -p NRestarts --value "$name.service")" -ge 1 ]

  # A stop is final.
  systemctl --user stop "$name.service"
  [ "$(systemctl --user is-active "$name.service")" = inactive ]

  # A refused argument file fails once and is not retried.
  chmod 0666 "$ARGV"
  systemctl --user reset-failed "$name.service" >/dev/null 2>&1 || true
  systemctl --user start "$name.service" || true
  for i in $(seq 30); do
    [ "$(systemctl --user is-active "$name.service")" = failed ] && break
    sleep 0.1
  done
  sleep 0.5
  [ "$(systemctl --user is-active "$name.service")" = failed ]
  [ "$(systemctl --user show -p NRestarts --value "$name.service")" = 0 ]
  [ "$(systemctl --user show -p ExecMainStatus --value "$name.service")" = 2 ]
}

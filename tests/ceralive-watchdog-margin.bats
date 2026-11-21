#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
#
# ceralive-watchdog-margin.bats — the image widens ceralive.service's watchdog
# to 90 s with a drop-in, changes nothing else about the unit, and keeps the
# drop-in only when the installed CeraUI unit arms a watchdog of its own.
#
# The CeraUI .deb ships WatchdogSec=30s, WatchdogSignal=SIGKILL and
# KillMode=mixed. The backend pulses every WATCHDOG_USEC/2 from its main loop,
# so the tolerated main-loop stall follows WatchdogSec: 15-30 s at 30 s, 45-90 s
# at 90 s. A kill also takes srtla_send, so it ends a live stream. Older
# ceralive-device builds (2026.11.2) ship no WatchdogSec and no pulse; the drop-in
# alone would turn on a watchdog nothing feeds, so the app layer removes it there.
#
# Run:  run-tests   or   bats tests/ceralive-watchdog-margin.bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  POSTINST_ENTRY="$ROOT/mkosi/customize/postinst-lib.sh"
  RUNTIME="$ROOT/mkosi/runtime"
  SRC="$RUNTIME/ceralive-watchdog-margin.dropin.conf"
  CHROOT="$ROOT/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
  APP_POSTINST="$ROOT/mkosi/mkosi.images/app/mkosi.postinst.chroot"
}

teardown() {
  if [ -n "${REAL_CLEANUP+x}" ]; then
    local name="${REAL_CLEANUP[0]}" udir="${REAL_CLEANUP[1]}"
    systemctl --user stop "$name.service" >/dev/null 2>&1 || true
    systemctl --user reset-failed "$name.service" >/dev/null 2>&1 || true
    rm -rf "$udir/$name.service" "$udir/$name.service.d"
    systemctl --user daemon-reload || true
  fi
}

install_dropin() { # <dir>
  env CERALIVE_RUNTIME_SRC="$RUNTIME" CERALIVE_WATCHDOG_DROPIN_DIR="$1" \
    bash -c "source '$POSTINST_ENTRY'; setup_ceralive_watchdog_margin"
}

# Directive lines of a unit file, comments and blanks dropped.
directives() { grep -Ev '^[[:space:]]*(#|$)' "$1"; }

@test "watchdog margin: the installer bakes 60-watchdog-margin.conf with WatchdogSec=90s" {
  local dir="$BATS_TEST_TMPDIR/ceralive.service.d"
  run install_dropin "$dir"
  [ "$status" -eq 0 ]
  [ -f "$dir/60-watchdog-margin.conf" ]
  [ "$(stat -c %a "$dir/60-watchdog-margin.conf")" = 644 ]
  cmp "$SRC" "$dir/60-watchdog-margin.conf"
}

@test "watchdog margin: the drop-in sets only WatchdogSec, in [Service]" {
  run directives "$SRC"
  [ "$status" -eq 0 ]
  [ "$output" = $'[Service]\nWatchdogSec=90s' ]
}

@test "watchdog margin: a missing runtime source fails the build and installs nothing" {
  local dir="$BATS_TEST_TMPDIR/ceralive-wd-fail.d"
  run env CERALIVE_RUNTIME_SRC="$BATS_TEST_TMPDIR/empty-src" CERALIVE_WATCHDOG_DROPIN_DIR="$dir" \
    bash -c "source '$POSTINST_ENTRY'; setup_ceralive_watchdog_margin"
  [ "$status" -ne 0 ]
  [[ "$output" == *"watchdog-margin source not found"* ]]
  [ ! -e "$dir/60-watchdog-margin.conf" ]
}

@test "watchdog margin: the runtime executor calls the installer" {
  grep -Eq '^[[:space:]]*setup_ceralive_watchdog_margin([[:space:]]|$)' "$CHROOT"
}

@test "watchdog margin: nothing else in the image sets WatchdogSec or WatchdogSignal" {
  run grep -rlE '^[[:space:]]*Watchdog(Sec|Signal)=' "$ROOT/mkosi"
  [ "$output" = "$SRC" ]
}

@test "watchdog margin: 60-watchdog-margin.conf sorts after every other ceralive.service.d drop-in" {
  # systemd applies drop-ins in file-name order, so a later one would win.
  # Literal paths, plus the two installers that take the directory as a variable.
  local names
  names="$( { grep -rhoE 'ceralive\.service\.d/[0-9A-Za-z._-]+\.conf' "$ROOT/mkosi" | sed 's#.*/##'
              printf '%s\n' 20-paseto-public-key.conf 40-nftables-ordering.conf; } | sort -u)"
  grep -q 'dropin_dir}/20-paseto-public-key.conf' "$ROOT/mkosi/customize/postinst.d/tls-ssh.sh"
  grep -q 'dropin_dir}/40-nftables-ordering.conf' "$ROOT/mkosi/customize/postinst.d/networking.sh"
  [ "$(printf '%s\n' "$names" | tail -n1)" = 60-watchdog-margin.conf ]
  [ "$(printf '%s\n' "$names" | wc -l)" -ge 6 ]
}

# A synthetic finished tree: the runtime layer's drop-in plus a packaged unit
# body given on stdin (none when "-" is passed as the only argument).
gate_tree() { # <root> [-]
  local root="$1"
  install -D -m 0644 "$SRC" "$root/etc/systemd/system/ceralive.service.d/60-watchdog-margin.conf"
  if [ "${2:-}" != - ]; then
    cat >"$root/etc/systemd/system/ceralive.service"
  fi
}

run_gate() { # <root>
  run bash -c 'set -euo pipefail; source "$1"; gate_ceralive_watchdog_margin "$2"' _ "$APP_POSTINST" "$1"
}

# The watchdog lines of CeraUI's current deployment/ceralive.service.
PACKAGED_WITH_WATCHDOG='[Unit]
Description=CeraLive service
After=network.target

[Service]
Type=notify
NotifyAccess=main
Environment=NODE_ENV=production
ExecStart=/usr/local/bin/ceralive
KillMode=mixed
Restart=always
RestartSec=2s
WatchdogSec=30s
WatchdogSignal=SIGKILL

[Install]
WantedBy=multi-user.target'

# ceralive-device 2026.11.2 (CeraUI 31b06d54): notify unit, no watchdog.
PACKAGED_WITHOUT_WATCHDOG='[Unit]
Description=CeraLive service
After=network.target

[Service]
Type=notify
NotifyAccess=main
Environment=NODE_ENV=production
ExecStart=/usr/local/bin/ceralive
KillMode=mixed
Restart=always

[Install]
WantedBy=multi-user.target'

@test "watchdog gate: kept when the packaged unit arms its own watchdog" {
  local root="$BATS_TEST_TMPDIR/with"
  printf '%s\n' "$PACKAGED_WITH_WATCHDOG" | gate_tree "$root"
  run_gate "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept etc/systemd/system/ceralive.service.d/60-watchdog-margin.conf"* ]]
  cmp "$SRC" "$root/etc/systemd/system/ceralive.service.d/60-watchdog-margin.conf"
}

@test "watchdog gate: removed for a ceralive-device without a watchdog (2026.11.2)" {
  local root="$BATS_TEST_TMPDIR/without"
  printf '%s\n' "$PACKAGED_WITHOUT_WATCHDOG" | gate_tree "$root"
  run_gate "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed etc/systemd/system/ceralive.service.d/60-watchdog-margin.conf"* ]]
  [ ! -e "$root/etc/systemd/system/ceralive.service.d/60-watchdog-margin.conf" ]
  [ -f "$root/etc/systemd/system/ceralive.service" ]
}

@test "watchdog gate: removed when no CeraUI is installed" {
  local root="$BATS_TEST_TMPDIR/none"
  gate_tree "$root" -
  run_gate "$root"
  [ "$status" -eq 0 ]
  [ ! -e "$root/etc/systemd/system/ceralive.service.d/60-watchdog-margin.conf" ]
}

# packaged_with <lines> — the 2026.11.2 unit with <lines> added to [Service]
# after Restart=always. awk -v turns \n into a line break and \\ into one
# backslash, so a case can hold several lines or a continuation.
packaged_with() {
  printf '%s\n' "$PACKAGED_WITHOUT_WATCHDOG" | awk -v v="$1" '{ print } $0 == "Restart=always" { print v }'
}

# The plain forms CeraUI ships, below 90 s: the drop-in stays.
GATE_KEEPS=('WatchdogSec=30s' 'WatchdogSec=30' 'WatchdogSec=1min' 'WatchdogSec=89sec')
# Everything else removes it (fail closed: the wider margin is given up, never
# a watchdog armed that nothing feeds or a longer one shortened).
GATE_REMOVES=(
  'WatchdogSec=0' 'WatchdogSec=0s' 'WatchdogSec=0 sec' 'WatchdogSec=0.0s' 'WatchdogSec=0d'
  'WatchdogSec=infinity' 'WatchdogSec=' 'WatchdogSec=90s' 'WatchdogSec=2min' 'WatchdogSec=1min 30s'
  'WatchdogSec = 30s' 'WatchdogSec=30s ' 'WatchdogSec=30s\nWatchdogSec=' 'WatchdogSec=30s\nWatchdogSec=60s'
  'WatchdogSec=\\\n0' 'WatchdogSec\\\n=30s' 'Environment=A=1 \\\nWatchdogSec=30s'
)

@test "watchdog gate: only one plain WatchdogSec under 90 s keeps the drop-in" {
  local v root i=0
  for v in "${GATE_KEEPS[@]}"; do
    root="$BATS_TEST_TMPDIR/keep-$((i++))"
    packaged_with "$v" | gate_tree "$root"
    run_gate "$root"
    [ "$status" -eq 0 ] || { echo "gate failed for: $v"; return 1; }
    [ -e "$root/etc/systemd/system/ceralive.service.d/60-watchdog-margin.conf" ] \
      || { echo "removed for: $v"; return 1; }
  done
  for v in "${GATE_REMOVES[@]}"; do
    root="$BATS_TEST_TMPDIR/remove-$((i++))"
    packaged_with "$v" | gate_tree "$root"
    grep -q 'WatchdogSec' "$root/etc/systemd/system/ceralive.service"
    run_gate "$root"
    [ "$status" -eq 0 ] || { echo "gate failed for: $v"; return 1; }
    [ ! -e "$root/etc/systemd/system/ceralive.service.d/60-watchdog-margin.conf" ] \
      || { echo "kept for: $v"; return 1; }
  done
  # Outside [Service] it is not a service setting.
  root="$BATS_TEST_TMPDIR/misplaced"
  printf '%s\n' "$PACKAGED_WITHOUT_WATCHDOG" | sed 's|^After=network.target$|After=network.target\nWatchdogSec=30s|' | gate_tree "$root"
  run_gate "$root"
  [ ! -e "$root/etc/systemd/system/ceralive.service.d/60-watchdog-margin.conf" ]
  # A continuation anywhere in the unit makes it ambiguous.
  root="$BATS_TEST_TMPDIR/continued"
  printf '%s\n' "$PACKAGED_WITH_WATCHDOG" | sed 's|^ExecStart=/usr/local/bin/ceralive$|ExecStart=/usr/local/bin/ceralive \\\n  --flag|' | gate_tree "$root"
  run_gate "$root"
  [ ! -e "$root/etc/systemd/system/ceralive.service.d/60-watchdog-margin.conf" ]
}

@test "watchdog gate: the app layer runs the gate after the first-party install, on every build" {
  local body
  body="$(sed -n '/^main() {/,/^}/p' "$APP_POSTINST")"
  printf '%s\n' "$body" | grep -Eq '^  gate_ceralive_watchdog_margin$'
  # After the install branch closes (so dev builds without CeraUI are covered too)
  # and before the staging tree goes.
  local fi_line gate_line rm_line
  fi_line="$(printf '%s\n' "$body" | grep -n '^  fi$' | head -n1 | cut -d: -f1)"
  gate_line="$(printf '%s\n' "$body" | grep -n '^  gate_ceralive_watchdog_margin$' | cut -d: -f1)"
  rm_line="$(printf '%s\n' "$body" | grep -n 'rm -rf "${FIRST_PARTY_DIR}"' | cut -d: -f1)"
  [ "$fi_line" -lt "$gate_line" ]
  [ "$gate_line" -lt "$rm_line" ]
}

user_manager_ok() {
  command -v systemctl >/dev/null || return 1
  [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] || return 1
  local state
  state="$(systemctl --user is-system-running 2>/dev/null)"
  case "$state" in running|degraded) return 0 ;; *) return 1 ;; esac
}

@test "watchdog margin: a real systemd manager applies 90 s over the packaged 30 s and hands it to the process" {
  user_manager_ok || skip "no systemd user manager"
  local name="ceralive-wd-test-$$-$RANDOM"
  local udir="$XDG_RUNTIME_DIR/systemd/user"
  local work="$BATS_TEST_TMPDIR/real"
  mkdir -p "$udir" "$work"
  REAL_CLEANUP=("$name" "$udir")

  # The watchdog and kill lines of CeraUI's deployment/ceralive.service. The
  # process records the WATCHDOG_USEC it gets, then reports ready and keeps
  # pulsing so the test unit is not killed while it is inspected.
  cat >"$udir/$name.service" <<UNIT
[Service]
Type=notify
NotifyAccess=all
KillMode=mixed
Restart=always
RestartSec=2s
WatchdogSec=30s
WatchdogSignal=SIGKILL
ExecStart=/bin/sh -c 'echo \$\$WATCHDOG_USEC >"$work/usec"; systemd-notify --ready; while :; do systemd-notify WATCHDOG=1; sleep 1; done'
UNIT

  # The manager reports WatchdogUSec only for a running unit.
  run_and_read() {
    rm -f "$work/usec"
    systemctl --user daemon-reload
    systemctl --user start "$name.service"
    WD_PROP="$(systemctl --user show -p WatchdogUSec --value "$name.service")"
    WD_ENV="$(cat "$work/usec")"
    systemctl --user stop "$name.service"
  }

  # Non-vacuity: without the drop-in the packaged 30 s applies.
  run_and_read
  [ "$WD_PROP" = 30s ]
  [ "$WD_ENV" = 30000000 ]

  run install_dropin "$udir/$name.service.d"
  [ "$status" -eq 0 ]
  run_and_read
  [ "$WD_PROP" = "1min 30s" ]
  [ "$WD_ENV" = 90000000 ]
  # CeraUI's helper pulses every floor(WATCHDOG_USEC / 2000) ms.
  [ "$(( WD_ENV / 2000 ))" = 45000 ]
  # Everything else stays as packaged.
  [ "$(systemctl --user show -p WatchdogSignal --value "$name.service")" = 9 ]
  [ "$(systemctl --user show -p KillMode --value "$name.service")" = mixed ]
  [ "$(systemctl --user show -p Restart --value "$name.service")" = always ]
  [ "$(systemctl --user show -p RestartUSec --value "$name.service")" = 2s ]

  # Every form the gate keeps really arms a watchdog under 90 s in systemd.
  rm -rf "$udir/$name.service.d"
  local v want
  local -A expect=([WatchdogSec=30s]=30s [WatchdogSec=30]=30s [WatchdogSec=1min]=1min [WatchdogSec=89sec]="1min 29s")
  [ "${#expect[@]}" -eq "${#GATE_KEEPS[@]}" ]
  for v in "${GATE_KEEPS[@]}"; do
    want="${expect[$v]}"
    [ -n "$want" ]
    sed -i "s|^WatchdogSec.*|$v|" "$udir/$name.service"
    run_and_read
    [ "$WD_PROP" = "$want" ] || { echo "$v: manager reports $WD_PROP"; return 1; }
  done
}

#!/usr/bin/env bats
# Power admission broker: installer, unit and rule contracts, and the broker's
# hardware-free socket/pty/lock contracts (tests/power-admission-contract.py).
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"; P="$ROOT/mkosi/runtime/power"; }

@test "power admission: broker socket, terminal prompt, fencing, draining and logind submission" {
  run timeout 180 python3 "$ROOT/tests/power-admission-contract.py"
  [ "$status" -eq 0 ]
}

@test "power admission: installer stages broker, client, units, group and rule" {
  run bash -euc '
    source "$1/mkosi/customize/postinst.d/services.sh"
    CERALIVE_RUNTIME_SRC="$1/mkosi/runtime"; CERALIVE_POWER_ROOT="$2"
    enable_service() { echo "$1" >> "$CERALIVE_POWER_ROOT/enabled"; }
    setup_power_operators() { echo operators >> "$CERALIVE_POWER_ROOT/enabled"; }
    setup_power_admission
  ' _ "$ROOT" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  local r="$BATS_TEST_TMPDIR"
  [ "$(stat -c %a "$r/usr/libexec/ceralive/ceralive-power-broker")" = 755 ]
  [ "$(stat -c %a "$r/usr/bin/ceralive-poweroff")" = 755 ]
  [ "$(readlink "$r/usr/bin/ceralive-reboot")" = ceralive-poweroff ]
  for unit in ceralive-power.socket ceralive-power.service ceralive-write-drain.service; do
    [ "$(stat -c %a "$r/etc/systemd/system/$unit")" = 644 ]
  done
  [ "$(stat -c %a "$r/etc/polkit-1/rules.d/60-ceralive-power-broker.rules")" = 644 ]
  [ "$(stat -c %a "$r/usr/lib/sysusers.d/ceralive-power.conf")" = 644 ]
  grep -qx operators "$r/enabled"
  grep -qx ceralive-power.socket "$r/enabled"
  grep -qx ceralive-power.service "$r/enabled"
  grep -qx ceralive-write-drain.service "$r/enabled"
}

@test "power admission: one broker instance on a root:ceralive-power 0660 socket" {
  grep -qx 'Accept=no' "$P/ceralive-power.socket"
  grep -qx 'ListenStream=/run/ceralive-power/request.sock' "$P/ceralive-power.socket"
  grep -qx 'SocketUser=root' "$P/ceralive-power.socket"
  grep -qx 'SocketGroup=ceralive-power' "$P/ceralive-power.socket"
  grep -qx 'SocketMode=0660' "$P/ceralive-power.socket"
  grep -qx 'ExecStart=/usr/bin/python3 -I /usr/libexec/ceralive/ceralive-power-broker' "$P/ceralive-power.service"
  grep -qx 'Restart=always' "$P/ceralive-power.service"
  grep -qx 'StartLimitIntervalSec=0' "$P/ceralive-power.service"
  ! grep -q '^User=' "$P/ceralive-power.service"
}

@test "power admission: only the broker's exact unit may skip block locks, and never for halt" {
  local rule="$P/60-ceralive-power-broker.rules"
  grep -Fq 'subject.user == "root" && subject.system_unit == "ceralive-power.service"' "$rule"
  [ "$(grep -c 'polkit.Result.YES' "$rule")" -eq 1 ]
  grep -Fq 'action.id != "org.freedesktop.login1.halt-ignore-inhibit")' "$rule"
  grep -Fq 'return polkit.Result.NO;' "$rule"
  [ "$(grep -oE '"org\.freedesktop\.[a-z0-9.-]+"' "$rule" | sort -u | tr -d '"' | tr '\n' ' ')" = \
    "org.freedesktop.login1.halt-ignore-inhibit org.freedesktop.login1.power-off-ignore-inhibit org.freedesktop.login1.reboot-ignore-inhibit " ]
  ! grep -Eq 'isInGroup|subject\.(local|active|session)' "$rule"
}

@test "power admission: the shutdown drain stops before writers and networking, with no deadline" {
  local u="$P/ceralive-write-drain.service"
  for writer in rauc.service ceralive-software-update.service ceralive-os-stage-guard.service ceralive-slot-sync.service \
      NetworkManager.service ModemManager.service; do
    grep -E '^After=' "$u" | grep -qw "$writer"
  done
  grep -qx 'TimeoutStopSec=infinity' "$u"
  grep -qx 'ExecStop=/usr/bin/python3 -I /usr/libexec/ceralive/ceralive-power-broker drain' "$u"
  grep -qx 'RemainAfterExit=yes' "$u"
}

@test "power admission: the broker never runs systemctl power verbs or starts a target" {
  local b="$P/ceralive-power-broker.py"
  ! grep -Eq "'(poweroff|reboot|halt)\.target'|'systemctl', *'(poweroff|reboot|halt)'|replace-irreversibly" "$b"
  grep -Fq "'PowerOffWithFlags'" "$b"
  grep -Fq "'RebootWithFlags'" "$b"
}

@test "power admission: operators are a group; the remote layer adds its user without creating accounts elsewhere" {
  grep -qx 'g ceralive-power -' "$P/ceralive-power.sysusers.conf"
  ! grep -q '^m ' "$P/ceralive-power.sysusers.conf"
  grep -qx 'm ceralive-tailscale ceralive-power' "$ROOT/mkosi/runtime/remote-access/ceralive-tailscale.sysusers.conf"
  grep -q 'usermod -aG ceralive-power ceralive' "$ROOT/mkosi/customize/postinst.d/services.sh"
}

@test "power admission: RAUC refuses to start writing while a power-off is pending" {
  local h="$ROOT/mkosi/runtime/rauc/ceralive-pre-install"
  [ -x "$h" ]
  CERALIVE_POWER_FENCE="$BATS_TEST_TMPDIR/fence" run "$h"
  [ "$status" -eq 0 ]
  touch "$BATS_TEST_TMPDIR/fence"
  CERALIVE_POWER_FENCE="$BATS_TEST_TMPDIR/fence" run "$h"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refused before writing"* ]]
  # Every place that writes RAUC's system.conf runs it, and installs it.
  for f in mkosi/platform/boot/install-boot.sh mkosi/customize/rauc-setup.sh \
      mkosi/platform/x86/install-x86-boot.sh mkosi/platform/x86/install-x86-grub.sh mkosi/runtime/rauc/system.conf; do
    grep -qx 'pre-install=/usr/lib/rauc/ceralive-pre-install' "$ROOT/$f"
  done
  for f in mkosi/platform/boot/install-boot.sh mkosi/customize/rauc-setup.sh \
      mkosi/platform/x86/install-x86-boot.sh mkosi/platform/x86/install-x86-grub.sh; do
    grep -q 'ceralive-pre-install" .*/usr/lib/rauc/ceralive-pre-install\|ceralive-pre-install" /usr/lib/rauc/ceralive-pre-install' "$ROOT/$f"
  done
}

@test "power admission: no power target forces the shutdown while a write runs" {
  local conf="$P/60-ceralive-wait-for-writes.conf"
  grep -qx 'JobTimeoutSec=infinity' "$conf"
  grep -qx 'JobTimeoutAction=none' "$conf"
  run bash -euc '
    source "$1/mkosi/customize/postinst.d/services.sh"
    CERALIVE_RUNTIME_SRC="$1/mkosi/runtime"; CERALIVE_POWER_ROOT="$2"
    enable_service() { :; }; setup_power_operators() { :; }
    setup_power_admission
  ' _ "$ROOT" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  for t in poweroff reboot halt; do
    cmp "$conf" "$BATS_TEST_TMPDIR/etc/systemd/system/$t.target.d/60-ceralive-wait-for-writes.conf"
  done
}

@test "power admission: activation and boot-script writers stop only after the drain" {
  grep -E '^After=' "$P/ceralive-write-drain.service" | grep -qw ceralive-boot-script-sync.service
  grep -E '^After=' "$P/ceralive-write-drain.service" | grep -qw ceralive-rauc-activate.service
  grep -qx 'Before=ceralive-write-drain.service' "$ROOT/mkosi/runtime/ceralive-rauc-arm@.service"
}

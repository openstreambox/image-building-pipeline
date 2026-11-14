#!/usr/bin/env bats
load manifest-helpers

setup() {
  PIPELINE_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export MODEM_SLOT_RULES_DIR="$BATS_TEST_TMPDIR/rules"
  export MODEM_MODPROBE_DIR="$BATS_TEST_TMPDIR/modprobe"
}

@test "internal modem: production and test variants carry the immutable cold-start patch series" {
  for variant in edge edge-test; do
    run bash "$PIPELINE_DIR/lib/resolve.sh" rock-5b-plus --variant "$variant"
    [ "$status" -eq 0 ]
    [[ "$output" == *"KERNEL_SOURCE_PATCHES_COMMIT='c65b7ddc5fee14abc0f9de54a104fb5f8db087f2'"* ]]
    [[ "$output" == *"KERNEL_SOURCE_PATCHES_GIT_URL='https://github.com/openstreambox/rk3588-kernel-patches.git'"* ]]
    [[ "$output" == *"MODEM_PORTS_SLOTS_INTERNAL_4G='platform-fc800000.usb-usb-0:1.4'"* ]]
  done
}

@test "internal modem: rfkill and MBIM survive the final config gate" {
  for setting in CONFIG_RFKILL=m CONFIG_RFKILL_GPIO=m CONFIG_USB_NET_CDC_MBIM=m; do
    grep -Fxq "$setting" "$PIPELINE_DIR/manifests/kernel/required-symbols.list"
  done
  grep -Fxq CONFIG_RFKILL=m "$PIPELINE_DIR/manifests/kernel/rk3588-edge.fragment"
}

@test "internal modem: boot unblocks only WWAN and excludes stale persistent rfkill restore" {
  run env BOARD_ID=rock-5b-plus bash -c 'source "$1/mkosi/customize/postinst-lib.sh"; setup_internal_modem_rfkill' _ "$PIPELINE_DIR"
  [ "$status" -eq 0 ]
  grep -Fxq 'options rfkill default_state=1' "$MODEM_MODPROBE_DIR/ceralive-internal-wwan.conf"
  rule="$MODEM_SLOT_RULES_DIR/99-zz-ceralive-internal-wwan.rules"
  ! grep -q SYSTEMD_RFKILL "$rule"
  grep -Fxq 'ACTION=="add", SUBSYSTEM=="rfkill", ATTR{name}=="rfkill-m2-wwan", ATTR{soft}="0"' "$rule"
  # A later user-requested block must not be undone by a change-event rule.
  ! grep -E 'ACTION=="[^\"]*(change|bind)' "$rule"
  run env BOARD_ID=orange-pi-5-plus bash -c 'source "$1/mkosi/customize/postinst-lib.sh"; setup_internal_modem_rfkill' _ "$PIPELINE_DIR"
  [ "$status" -eq 0 ]
  [ ! -e "$rule" ]
  [ ! -e "$MODEM_MODPROBE_DIR/ceralive-internal-wwan.conf" ]
}

@test "internal modem: saved WWAN block cannot override add-time release" {
  run env BOARD_ID=rock-5b-plus bash -c 'source "$1/mkosi/customize/postinst-lib.sh"; setup_internal_modem_rfkill' _ "$PIPELINE_DIR"
  [ "$status" -eq 0 ]
  # Replay the generated add actions before systemd v257's post-udev load.
  # Only the state directory is remapped; execute the shipped cleanup command.
  run python3 - "$MODEM_SLOT_RULES_DIR/99-zz-ceralive-internal-wwan.rules" "$BATS_TEST_TMPDIR" <<'PYTEST'
import pathlib, re, shlex, subprocess, sys
rules = pathlib.Path(sys.argv[1]).read_text()
root = pathlib.Path(sys.argv[2]) / 'rfkill'
root.mkdir()
key = 'platform-ceralive-internal-wwan:wwan'
state = root / key
wifi = root / 'platform-wifi:wlan'
external = root / 'platform-external:wwan'
for p in (state, wifi, external):
    p.write_text('1\n')

def udev_event(action, name, soft):
    # Minimal udev fixture: match generated predicates, apply assignments and
    # run the real cleanup argv against only the fixture's state directory.
    values = {'ACTION': action, 'SUBSYSTEM': 'rfkill', 'ATTR{name}': name,
              'ATTR{soft}': str(soft), 'ENV{ID_PATH}': 'platform-original'}
    for line in rules.splitlines():
        if not line or line.startswith('#'):
            continue
        fields = re.findall(r'([A-Z]+(?:\{[^}]+\})?)(==|\+=|=)"([^"]*)"', line)
        assert fields, line
        if any(values.get(k) != v for k, op, v in fields if op == '=='):
            continue
        for k, op, v in fields:
            if op == '=':
                values[k] = v
            elif k == 'RUN' and op == '+=':
                args = shlex.split(v)
                assert args == ['/usr/bin/rm', '-f', '/var/lib/systemd/rfkill/' + key]
                subprocess.run(args[:2] + [str(state)], check=True)
    return values

def restore(values):
    # systemd v257 load_state after udev: a missing file saves event.soft;
    # an existing file restores its boolean. All add fixtures start with the
    # configured unblocked kernel default, like rfkill-gpio on a cold boot.
    path = root / (values['ENV{ID_PATH}'] + ':wwan')
    if path.exists():
        return int(path.read_text())
    path.write_text(values['ATTR{soft}'] + '\n')
    return int(values['ATTR{soft}'])

for boot in range(2):
    state.write_text('1\n')  # A deliberate block persisted before cold boot.
    added = udev_event('add', 'rfkill-m2-wwan', 0)
    assert added['ENV{ID_PATH}'] + ':wwan' == key
    assert restore(added) == 0, 'saved block won after udev'
    assert wifi.read_text() == external.read_text() == '1\n'
    state.write_text('1\n')
    changed = udev_event('change', 'rfkill-m2-wwan', 1)
    assert changed['ATTR{soft}'] == '1', 'later intentional block undone'
    assert state.read_text() == '1\n', 'change discarded saved state'
    unrelated = udev_event('add', 'external-wwan', 1)
    assert unrelated['ENV{ID_PATH}'] == 'platform-original'
    assert unrelated['ATTR{soft}'] == '1'
    assert state.read_text() == '1\n', 'unrelated add discarded saved state'

PYTEST
  [ "$status" -eq 0 ]
}

@test "internal modem: generated positional UID leaves the external Dell and other ports alone" {
  run env CERALIVE_MODEM_PORTS_STATUS=verified CERALIVE_MODEM_PORTS_SLOTS='internal_4g=platform-fc800000.usb-usb-0:1.4' bash -c 'source "$1/mkosi/customize/postinst-lib.sh"; generate_modem_slot_uid_rules' _ "$PIPELINE_DIR"
  [ "$status" -eq 0 ]
  rule="$MODEM_SLOT_RULES_DIR/78-mm-ceralive-slot-uid.rules"
  grep -Fq 'IMPORT{builtin}="path_id"' "$rule"
  grep -Fxq 'ACTION=="add|bind", SUBSYSTEM=="usb", ENV{ID_PATH}=="platform-fc800000.usb-usb-0:1.4", ENV{ID_MM_PHYSDEV_UID}="internal 4G"' "$rule"
  [ "$(grep -c 'ID_MM_PHYSDEV_UID}=' "$rule")" -eq 1 ]
  ! grep -E 'wwan[0-9]|idVendor|1\.1"|NAME=' "$rule"
}

@test "internal modem: both runtime installers invoke shared naming and rfkill policy" {
  for entry in mkosi/customize/udev.sh mkosi/mkosi.images/runtime/mkosi.postinst.chroot; do
    grep -Eq '^ *generate_modem_slot_uid_rules( |$)' "$PIPELINE_DIR/$entry"
    grep -Eq '^ *setup_internal_modem_rfkill( |$)' "$PIPELINE_DIR/$entry"
  done
}

@test "internal modem: image runtime has no rail or slot power-cycle implementation" {
  # Recovery belongs to the modem owner. This image grants no GPIO/regulator
  # power-cycle path. Any future implementation needs a FULL_CARD_POWER_OFF#
  # boundary and behavioral tests before this absence guard can be replaced.
  run python3 "$PIPELINE_DIR/ci/check-internal-modem-power.py" "$PIPELINE_DIR/mkosi"
  [ "$status" -eq 0 ]
  # Cover suffixless payloads, all image layers and non-shell entry points.
  local entry command
  for entry in runtime/cycle customize/cycle.py app/cycle.timer platform/cycle.socket mkosi.images/runtime/cycle.tmpl platform/cycle.cmd; do
    for command in 'gpioset gpiochip1 26=0' 'uhubctl -a off' '/sys/class/gpio/export' '/sys/class/regulator/x' '/sys/kernel/debug/regulator/x' '/dev/gpiochip2' '/sys/bus/usb/devices/1-1/port4/disable' '/sys/bus/platform/drivers/reg-fixed-voltage/unbind' 'gpiod.Chip("gpiochip2")' 'gpioset --chip gpiochip2 1=0'; do
      mkdir -p "$BATS_TEST_TMPDIR/unsafe/$(dirname "$entry")"
      printf '%s\n' "$command" >"$BATS_TEST_TMPDIR/unsafe/$entry"
      run python3 "$PIPELINE_DIR/ci/check-internal-modem-power.py" "$BATS_TEST_TMPDIR/unsafe"
      [ "$status" -ne 0 ]
      [[ "$output" == *"power control requires a reviewed FULL_CARD_POWER_OFF# boundary"* ]]
      rm "$BATS_TEST_TMPDIR/unsafe/$entry"
    done
  done
}

@test "internal modem: real pinned series applies and the compiled board DTB carries 0052" {
  [[ -n "${CERALIVE_WWAN_KERNEL_TREE:-}" && -n "${CERALIVE_WWAN_PATCHES_TREE:-}" ]] || skip 'set CERALIVE_WWAN_KERNEL_TREE and CERALIVE_WWAN_PATCHES_TREE after applying the pinned series'
  run python3 "$PIPELINE_DIR/ci/check-internal-modem-dtb.py" "$CERALIVE_WWAN_KERNEL_TREE" "$CERALIVE_WWAN_PATCHES_TREE"
  [ "$status" -eq 0 ]
}

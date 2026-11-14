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
  grep -Fxq 'SUBSYSTEM=="rfkill", ATTR{name}=="rfkill-m2-wwan", ENV{SYSTEMD_RFKILL}="0"' "$rule"
  grep -Fxq 'ACTION=="add", SUBSYSTEM=="rfkill", ATTR{name}=="rfkill-m2-wwan", ATTR{soft}="0"' "$rule"
  # A later user-requested block must not be undone by a change-event rule.
  ! grep -E 'ACTION=="[^\"]*(change|bind)' "$rule"
  run env BOARD_ID=orange-pi-5-plus bash -c 'source "$1/mkosi/customize/postinst-lib.sh"; setup_internal_modem_rfkill' _ "$PIPELINE_DIR"
  [ "$status" -eq 0 ]
  [ ! -e "$rule" ]
  [ ! -e "$MODEM_MODPROBE_DIR/ceralive-internal-wwan.conf" ]
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
  mkdir -p "$BATS_TEST_TMPDIR/unsafe/runtime"
  printf '%s\n' 'gpioset gpiochip1 26=0' >"$BATS_TEST_TMPDIR/unsafe/runtime/cycle.sh"
  run python3 "$PIPELINE_DIR/ci/check-internal-modem-power.py" "$BATS_TEST_TMPDIR/unsafe"
  [ "$status" -ne 0 ]
  [[ "$output" == *"power control requires a reviewed FULL_CARD_POWER_OFF# boundary"* ]]
}

@test "internal modem: real pinned series applies and the compiled board DTB carries 0052" {
  [[ -n "${CERALIVE_WWAN_KERNEL_TREE:-}" && -n "${CERALIVE_WWAN_PATCHES_TREE:-}" ]] || skip 'set CERALIVE_WWAN_KERNEL_TREE and CERALIVE_WWAN_PATCHES_TREE after applying the pinned series'
  run python3 "$PIPELINE_DIR/ci/check-internal-modem-dtb.py" "$CERALIVE_WWAN_KERNEL_TREE" "$CERALIVE_WWAN_PATCHES_TREE"
  [ "$status" -eq 0 ]
}

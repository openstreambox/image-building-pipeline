#!/usr/bin/env bats

ROOT="${BATS_TEST_DIRNAME}/.."
RUNTIME="${ROOT}/mkosi/runtime"

@test "RM520N usbspeed quirk: decisions against a fake sysfs, mmcli and pty modem" {
  run python3 "${BATS_TEST_DIRNAME}/modem-usbspeed-test.py"
  [ "$status" -eq 0 ]
}

@test "RM520N usbspeed quirk: udev starts one instance per added 2c7c:0801 USB device only" {
  rules="${RUNTIME}/99-ceralive-modem-usbspeed.rules"
  run grep -v '^#' "$rules"
  [ "${#lines[@]}" -eq 1 ]
  line="${lines[0]}"
  [[ "$line" == 'ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", '* ]]
  [[ "$line" == *'ATTR{idVendor}=="2c7c", ATTR{idProduct}=="0801"'* ]]
  [[ "$line" == *'TAG+="systemd", ENV{SYSTEMD_WANTS}+="ceralive-modem-usbspeed@%k.service"' ]]
  # No RUN+=: udev never blocks on the modem.
  ! grep -q 'RUN' "$rules"
}

@test "RM520N usbspeed quirk: oneshot template keeps its markers for the whole boot" {
  unit="${RUNTIME}/ceralive-modem-usbspeed@.service"
  grep -qx 'Type=oneshot' "$unit"
  grep -qx 'ExecStart=/usr/local/sbin/ceralive-modem-usbspeed %i' "$unit"
  grep -qx 'After=ModemManager.service systemd-udev-trigger.service' "$unit"
  grep -qx 'RuntimeDirectory=ceralive/modem-usbspeed' "$unit"
  grep -qx 'RuntimeDirectoryPreserve=yes' "$unit"
  grep -qx 'NoNewPrivileges=yes' "$unit"
  ! grep -q '^\[Install\]' "$unit"
}

@test "RM520N usbspeed quirk: installed by both runtime writers into the admin tier" {
  grep -q '^  setup_modem_usbspeed' "${ROOT}/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
  grep -q '^  setup_modem_usbspeed' "${ROOT}/mkosi/customize/services.sh"
  grep -qx $'image\t/etc/udev/rules.d/99-ceralive-modem-usbspeed.rules' "${ROOT}/manifests/modem-support-ownership.txt"
  grep -qx $'image\t/etc/systemd/system/ceralive-modem-usbspeed@.service' "${ROOT}/manifests/modem-support-ownership.txt"

  dest="${BATS_TEST_TMPDIR}/rootfs"
  run env CERALIVE_RUNTIME_SRC="${RUNTIME}" \
    MODEM_USBSPEED_SBIN_DIR="${dest}/usr/local/sbin" \
    MODEM_USBSPEED_UNIT_DIR="${dest}/etc/systemd/system" \
    MODEM_USBSPEED_RULES_DIR="${dest}/etc/udev/rules.d" \
    bash -c 'source "$1"; setup_modem_usbspeed' _ "${ROOT}/mkosi/customize/postinst.d/networking.sh"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "${dest}/usr/local/sbin/ceralive-modem-usbspeed")" = 755 ]
  [ "$(stat -c %a "${dest}/etc/systemd/system/ceralive-modem-usbspeed@.service")" = 644 ]
  [ "$(stat -c %a "${dest}/etc/udev/rules.d/99-ceralive-modem-usbspeed.rules")" = 644 ]
  head -1 "${dest}/usr/local/sbin/ceralive-modem-usbspeed" | grep -qx '#!/usr/bin/python3'
}

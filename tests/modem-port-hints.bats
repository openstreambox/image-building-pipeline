#!/usr/bin/env bats
#
# ModemManager port hints (mkosi/runtime/78-ceralive-modem-port-hints.rules):
# which AT ports ModemManager leaves alone, matched by exact USB ID and interface.
#
# The last test runs the real `udevadm test` against a generated sysfs tree in an
# unprivileged user and mount namespace, with only this rules file installed. The
# tree uses the USB IDs, configurations and interface numbers recorded on the
# bench boards: DW5821e 413c:81d7 in its MBIM configuration 2 (ttys on
# interfaces 2-5), RM520N-GL 2c7c:0801 in its QMI configuration 1 (ttys on 0-3).

ROOT="${BATS_TEST_DIRNAME}/.."
RULES="${ROOT}/mkosi/runtime/78-ceralive-modem-port-hints.rules"
RULES_NAME=78-ceralive-modem-port-hints.rules

@test "port hints: the rules file holds exactly the reviewed matches" {
  [ -f "${RULES}" ]
  run grep -v -e '^#' -e '^[[:space:]]*$' "${RULES}"
  [ "$status" -eq 0 ]
  expected=(
    'ACTION!="add|change|move|bind", GOTO="ceralive_mm_port_hints_end"'
    'SUBSYSTEM!="tty", GOTO="ceralive_mm_port_hints_end"'
    'SUBSYSTEMS=="usb", ATTRS{bInterfaceNumber}=="?*", ENV{.CERALIVE_MM_USBIFNUM}="$attr{bInterfaceNumber}"'
    'ATTRS{idVendor}=="2c7c", ATTRS{idProduct}=="0801", ENV{.CERALIVE_MM_USBIFNUM}=="03", ENV{ID_MM_PORT_IGNORE}="1"'
    'LABEL="ceralive_mm_port_hints_end"'
  )
  [ "${#lines[@]}" -eq "${#expected[@]}" ]
  for i in "${!expected[@]}"; do
    [ "${lines[$i]}" = "${expected[$i]}" ] || { echo "line $i: ${lines[$i]}"; return 1; }
  done
}

@test "port hints: the file only sets ENV properties" {
  [ -f "${RULES}" ]
  # No RUN, MODE, GROUP, OWNER, SYMLINK, TAG, NAME, IMPORT or ATTR{} writes.
  # (A bare `! cmd` does not fail a Bats test, hence the explicit returns.)
  if grep -v '^#' "${RULES}" | grep -E 'RUN|MODE|GROUP|OWNER|SYMLINK|TAG|NAME|IMPORT|PROGRAM|ATTR\{[^}]*\}=[^=]'; then
    return 1
  fi
  # The interface number stays a private (dot) property.
  if grep -v '^#' "${RULES}" | grep -E 'ENV\{CERALIVE'; then
    return 1
  fi
  # Never a vendor-wide release: every ID_MM_PORT_IGNORE names a product and an interface.
  run grep -c 'ID_MM_PORT_IGNORE' "${RULES}"
  [ "$output" -ge 1 ]
  while IFS= read -r line; do
    [[ "$line" == *'ATTRS{idProduct}=="'* && "$line" == *'ENV{.CERALIVE_MM_USBIFNUM}=="'* ]] || return 1
  done < <(grep -v '^#' "${RULES}" | grep 'ID_MM_PORT_IGNORE')
}

@test "port hints: installed by both runtime writers into the admin tier" {
  grep -q '^  setup_modem_port_hints' "${ROOT}/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
  grep -q '^  setup_modem_port_hints' "${ROOT}/mkosi/customize/services.sh"
  grep -qx $'image\t/etc/udev/rules.d/'"${RULES_NAME}" "${ROOT}/manifests/modem-support-ownership.txt"

  dest="${BATS_TEST_TMPDIR}/rootfs"
  run env CERALIVE_RUNTIME_SRC="${ROOT}/mkosi/runtime" \
    MODEM_PORT_HINTS_RULES_DIR="${dest}/etc/udev/rules.d" \
    bash -c 'source "$1"; setup_modem_port_hints' _ "${ROOT}/mkosi/customize/postinst.d/networking.sh"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "${dest}/etc/udev/rules.d/${RULES_NAME}")" = 644 ]
  cmp "${RULES}" "${dest}/etc/udev/rules.d/${RULES_NAME}"
}

@test "port hints: udevadm matches the recorded modems and nothing else" {
  command -v udevadm >/dev/null 2>&1 || skip "no udevadm"
  unshare --user --map-root-user --mount true 2>/dev/null || skip "no unprivileged user namespaces"
  [ -f "${RULES}" ]
  run env SYSTEMD_DEVICE_VERIFY_SYSFS=0 unshare --user --map-root-user --mount \
    bash "${BATS_TEST_DIRNAME}/lib/modem-port-hints-udev.sh" "${RULES}" "${BATS_TEST_TMPDIR}/udev"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: modem port hints"* ]]
}

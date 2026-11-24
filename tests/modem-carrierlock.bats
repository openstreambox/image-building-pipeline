#!/usr/bin/env bats

ROOT="${BATS_TEST_DIRNAME}/.."
RUNTIME="${ROOT}/mkosi/runtime"

@test "FM350-GL carrier unlock: decisions against a fake sysfs, mmcli and recorded pty answers" {
  run python3 "${BATS_TEST_DIRNAME}/modem-carrierlock-test.py"
  [ "$status" -eq 0 ]
}

@test "FM350-GL carrier unlock: udev starts one instance per added 0e8d:7127 USB device only" {
  rules="${RUNTIME}/99-ceralive-modem-carrierlock.rules"
  run grep -v '^#' "$rules"
  [ "${#lines[@]}" -eq 1 ]
  line="${lines[0]}"
  [[ "$line" == 'ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", '* ]]
  [[ "$line" == *'ATTR{idVendor}=="0e8d", ATTR{idProduct}=="7127"'* ]]
  [[ "$line" == *'TAG+="systemd", ENV{SYSTEMD_WANTS}+="ceralive-modem-carrierlock@%k.service"' ]]
  # No RUN+=: udev never blocks on the modem.
  ! grep -q 'RUN' "$rules"
}

@test "FM350-GL carrier unlock: oneshot template keeps its markers for the whole boot" {
  unit="${RUNTIME}/ceralive-modem-carrierlock@.service"
  grep -qx 'Type=oneshot' "$unit"
  grep -qx 'ExecStart=/usr/local/sbin/ceralive-modem-carrierlock %i' "$unit"
  grep -qx 'After=ModemManager.service systemd-udev-trigger.service' "$unit"
  grep -qx 'RuntimeDirectory=ceralive/modem-carrierlock' "$unit"
  grep -qx 'RuntimeDirectoryPreserve=yes' "$unit"
  grep -qx 'NoNewPrivileges=yes' "$unit"
  ! grep -q '^\[Install\]' "$unit"
}

@test "FM350-GL carrier unlock: the script can only unlock, never write a lock" {
  # Every string in the code (the module docstring aside) that starts an AT
  # command is a plain literal from this list; no formatted command exists.
  run python3 - "${RUNTIME}/ceralive-modem-carrierlock.py" <<'PY'
import ast, sys
tree = ast.parse(open(sys.argv[1]).read())
doc = tree.body[0].value if isinstance(tree.body[0], ast.Expr) else None
allowed = {'AT+CIMI', 'AT+GTLOCKCAR?', 'AT+GTCURCAR?', 'AT+CFUN?', 'AT+CFUN=4', 'AT+CFUN=1', 'AT+GTLOCKCAR=0'}
sent = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Call) and getattr(node.func, 'attr', '') == 'command':
        first = node.args[0]
        if not isinstance(first, ast.Constant):
            sys.exit(f'line {node.lineno}: command built at run time')
        sent.add(first.value)
if not sent or sent - allowed:
    sys.exit(f'unexpected AT commands: {sorted(sent - allowed) or "none found"}')
print(sorted(sent))
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"'AT+GTLOCKCAR=0'"* ]]
}

@test "FM350-GL carrier unlock: installed by both runtime writers into the admin tier" {
  grep -q '^  setup_modem_carrierlock' "${ROOT}/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
  grep -q '^  setup_modem_carrierlock' "${ROOT}/mkosi/customize/services.sh"
  grep -qx $'image\t/etc/udev/rules.d/99-ceralive-modem-carrierlock.rules' "${ROOT}/manifests/modem-support-ownership.txt"
  grep -qx $'image\t/etc/systemd/system/ceralive-modem-carrierlock@.service' "${ROOT}/manifests/modem-support-ownership.txt"

  dest="${BATS_TEST_TMPDIR}/rootfs"
  run env CERALIVE_RUNTIME_SRC="${RUNTIME}" \
    MODEM_CARRIERLOCK_SBIN_DIR="${dest}/usr/local/sbin" \
    MODEM_CARRIERLOCK_UNIT_DIR="${dest}/etc/systemd/system" \
    MODEM_CARRIERLOCK_RULES_DIR="${dest}/etc/udev/rules.d" \
    bash -c 'source "$1"; setup_modem_carrierlock' _ "${ROOT}/mkosi/customize/postinst.d/networking.sh"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "${dest}/usr/local/sbin/ceralive-modem-carrierlock")" = 755 ]
  [ "$(stat -c %a "${dest}/etc/systemd/system/ceralive-modem-carrierlock@.service")" = 644 ]
  [ "$(stat -c %a "${dest}/etc/udev/rules.d/99-ceralive-modem-carrierlock.rules")" = 644 ]
  head -1 "${dest}/usr/local/sbin/ceralive-modem-carrierlock" | grep -qx '#!/usr/bin/python3'
}

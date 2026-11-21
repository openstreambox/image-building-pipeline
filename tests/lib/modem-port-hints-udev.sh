#!/usr/bin/env bash
# modem-port-hints-udev.sh RULES WORKDIR: run INSIDE an unprivileged user + mount
# namespace (tests/modem-port-hints.bats does that). Builds a fake sysfs with the
# recorded modem compositions, bind-mounts it over /sys, hides every host rules
# directory and installs ONLY the given rules file, then checks the properties
# `udevadm test` computes for each tty. SYSTEMD_DEVICE_VERIFY_SYSFS=0 is systemd's
# own switch for a sysfs that is not a sysfs mount.
set -euo pipefail

RULES="$1"
work="$2"
fail=0
SYS="${work}/sys"
mkdir -p "${SYS}/bus/usb" "${SYS}/bus/usb-serial" "${SYS}/class/tty"

# usb_device VID PID PORT -> a USB device under a fake host controller.
usb_device() {
  local d="${SYS}/devices/platform/fake.usb/usb3/$3"
  mkdir -p "$d"
  printf '%s\n' "$1" >"$d/idVendor"
  printf '%s\n' "$2" >"$d/idProduct"
  printf 'DEVTYPE=usb_device\nDRIVER=usb\nPRODUCT=%s/%s/318\n' "$1" "$2" >"$d/uevent"
  ln -s ../../../../../bus/usb "$d/subsystem"
}

# tty_on PORT CONFIG IFNUM TTY -> an option-driver tty on that interface; prints its syspath.
tty_on() {
  local i="${SYS}/devices/platform/fake.usb/usb3/$1/$1:$2.$3" n="$4"
  mkdir -p "$i/$n/tty/$n"
  printf '%02d\n' "$3" >"$i/bInterfaceNumber"
  printf 'ff\n' >"$i/bInterfaceClass"
  printf 'DEVTYPE=usb_interface\nDRIVER=option\nINTERFACE=255/255/255\n' >"$i/uevent"
  ln -s ../../../../../../bus/usb "$i/subsystem"
  printf 'DRIVER=option1\n' >"$i/$n/uevent"
  ln -s ../../../../../../../bus/usb-serial "$i/$n/subsystem"
  printf 'MAJOR=188\nMINOR=%d\nDEVNAME=%s\n' "${n#ttyUSB}" "$n" >"$i/$n/tty/$n/uevent"
  printf '188:%d\n' "${n#ttyUSB}" >"$i/$n/tty/$n/dev"
  ln -s ../../../../../../../../../class/tty "$i/$n/tty/$n/subsystem"
  echo "/sys/devices/platform/fake.usb/usb3/$1/$1:$2.$3/$n/tty/$n"
}

# DW5821e, MBIM configuration 2 (as on the ROCK 5B+ B-key slot and on hubs).
usb_device 413c 81d7 3-1.4
dell_if2="$(tty_on 3-1.4 2 2 ttyUSB0)"
dell_if3="$(tty_on 3-1.4 2 3 ttyUSB1)"
dell_if4="$(tty_on 3-1.4 2 4 ttyUSB2)"
dell_if5="$(tty_on 3-1.4 2 5 ttyUSB3)"
# DW5821e eSIM variant: same layout in ModemManager's rules, never measured here.
usb_device 413c 81e0 3-1.3
esim_if2="$(tty_on 3-1.3 2 2 ttyUSB4)"
# RM520N-GL, QMI configuration 1 (as on J11 and the A3 hub).
usb_device 2c7c 0801 3-1.2
rm520_if0="$(tty_on 3-1.2 1 0 ttyUSB5)"
rm520_if1="$(tty_on 3-1.2 1 1 ttyUSB6)"
rm520_if2="$(tty_on 3-1.2 1 2 ttyUSB7)"
rm520_if3="$(tty_on 3-1.2 1 3 ttyUSB8)"
# Another Quectel product (EC25) and a Sierra card: interface 3 must stay untouched.
usb_device 2c7c 0125 3-1.1
ec25_if3="$(tty_on 3-1.1 1 3 ttyUSB9)"
usb_device 1199 9091 3-1.5
sierra_if3="$(tty_on 3-1.5 1 3 ttyUSB10)"

mount --bind "${SYS}" /sys
for d in /etc/udev/rules.d /usr/lib/udev/rules.d /lib/udev/rules.d /usr/local/lib/udev/rules.d /run/udev; do
  [ -d "$d" ] && mount -t tmpfs tmpfs "$d"
done
mkdir -p /run/udev/rules.d /etc/udev/rules.d
cp "${RULES}" /etc/udev/rules.d/

props() { # ACTION SYSPATH -> the property list `udevadm test` computed
  udevadm test --action="$1" "$2" 2>/dev/null | sed -n '/^Properties:/,$p'
}
expect_has() { # NAME ACTION SYSPATH PROPERTY
  if props "$2" "$3" | grep -qx "  $4"; then echo "  ok: $1"; else echo "  FAIL: $1 (no $4)"; fail=1; fi
}
expect_lacks() { # NAME ACTION SYSPATH PROPERTY-PREFIX
  if props "$2" "$3" | grep -q "^  $4"; then echo "  FAIL: $1 (has $4)"; fail=1; else echo "  ok: $1"; fi
}

echo "modem port hint matches (udevadm $(udevadm --version))"
# Non-vacuity: udevadm test must report properties for these fake devices at all.
if props add "${dell_if4}" | grep -q '^  DEVNAME='; then
  echo "  ok: udevadm test reads the fake sysfs"
else
  echo "  FAIL: udevadm test reports no properties for the fake sysfs"; fail=1
fi

expect_lacks "DW5821e interface 2 (AT primary) stays with ModemManager" add "${dell_if2}" "ID_MM_PORT_IGNORE"
expect_lacks "DW5821e interface 3 (AT secondary) stays with ModemManager" add "${dell_if3}" "ID_MM_PORT_IGNORE"
expect_lacks "DW5821e interface 4 (GPS) stays with ModemManager" add "${dell_if4}" "ID_MM_PORT_IGNORE"
expect_lacks "DW5821e interface 5 (QCDM) stays with ModemManager" add "${dell_if5}" "ID_MM_PORT_IGNORE"
expect_lacks "the DW5821e eSIM product is untouched" add "${esim_if2}" "ID_MM_PORT_IGNORE"
expect_has   "the RM520N release holds on a change event" change "${rm520_if3}" "ID_MM_PORT_IGNORE=1"
expect_has   "the RM520N release holds on a bind event" bind "${rm520_if3}" "ID_MM_PORT_IGNORE=1"
expect_has   "RM520N interface 3 (AT secondary) is left to other tools" add "${rm520_if3}" "ID_MM_PORT_IGNORE=1"
expect_lacks "RM520N interface 2 (AT primary) stays with ModemManager" add "${rm520_if2}" "ID_MM_PORT_IGNORE"
expect_lacks "RM520N interface 1 (GPS) stays with ModemManager" add "${rm520_if1}" "ID_MM_PORT_IGNORE"
expect_lacks "RM520N interface 0 (QCDM) stays with ModemManager" add "${rm520_if0}" "ID_MM_PORT_IGNORE"
expect_lacks "another Quectel product's interface 3 is untouched" add "${ec25_if3}" "ID_MM_PORT_IGNORE"
expect_lacks "a Sierra card's interface 3 is untouched" add "${sierra_if3}" "ID_MM_PORT_IGNORE"
expect_lacks "a remove event sets nothing" remove "${rm520_if3}" "ID_MM_PORT_IGNORE"
expect_lacks "the interface number stays a private (dot) property" add "${rm520_if3}" "CERALIVE_MM_USBIFNUM"
expect_lacks "the USB device itself is not released" add /sys/devices/platform/fake.usb/usb3/3-1.2 "ID_MM_PORT_IGNORE"

if [ "${fail}" -eq 0 ]; then echo "PASS: modem port hints"; else echo "FAIL: modem port hints"; exit 1; fi

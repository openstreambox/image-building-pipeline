#!/usr/bin/python3
"""ceralive-slot-dell-fastboot-release: safety net for the ROCK 5B+ B-key Dell DW5821e.

WHY: a DW5821e that gets slot power while its RESET# is still low starts in its
bootloader's fastboot mode (USB 413c:81d6, one ff/42/03 interface) and stays there:
no modem, no ModemManager object. The boot script holds the slot unpowered until
Linux has released RESET#, so this should never run. If a boot path skips that hold,
or the hold ever stops working, this sends the waiting bootloader one fastboot
`continue`, after which the card starts its modem firmware (413c:81d7, about 9 s).
Measured on a ROCK 5B+: 7 of 7 `continue` runs (1 manual, 1 warm, 5 cold) gave one
clean ModemManager object each; the one `reboot` run left two objects, so this never
falls back to `reboot`.

TRIGGER: a udev rule on the add event of 413c:81d6 at the board's verified B-key
position (matched by ID_PATH, because the USB bus number is not fixed) starts
ceralive-slot-dell-fastboot-release@<kernel name>.service, which runs this with that
kernel name.

RULES:
  * at most ONE fastboot command per boot (a marker under /run, created before the
    command is sent, so a crash mid-send also counts);
  * it re-checks the device first: 413c:81d6, the expected ID_PATH, and exactly one
    unbound ff/42/03 interface; anything else is left alone;
  * it never de-authorizes, unbinds or resets the port: after the host de-configured
    the device once, its fastboot endpoint stopped answering until a board reboot;
  * the inhibit file /etc/ceralive/keep-slot-dell-fastboot leaves the card in
    fastboot (for a deliberate firmware update);
  * no flash, erase or download command exists in this file.
Every run logs what it saw and did; the firing itself logs at warning level.

Test seams (production uses every default):
  CERALIVE_SLOT_DELL_SYSFS     USB device directory (default /sys/bus/usb/devices)
  CERALIVE_SLOT_DELL_DEVROOT   usbfs node directory (default /dev/bus/usb)
  CERALIVE_SLOT_DELL_MARKER    per-boot marker (default /run/ceralive/slot-dell-fastboot-release)
  CERALIVE_SLOT_DELL_INHIBIT   inhibit file (default /etc/ceralive/keep-slot-dell-fastboot)
  CERALIVE_SLOT_DELL_CMDLINE   kernel command line (default /proc/cmdline)
  CERALIVE_SLOT_DELL_UPTIME    uptime file (default /proc/uptime)
  CERALIVE_UDEVADM_BIN         udevadm (default udevadm)
  CERALIVE_SLOT_ID_PATH        expected ID_PATH (from the generated environment file)
"""

import ctypes
import fcntl
import os
import re
import struct
import subprocess
import sys

TAG = 'ceralive-slot-dell-fastboot-release'
VENDOR, PRODUCT = '413c', '81d6'
FASTBOOT_INTERFACE = ('ff', '42', '03')
EP_OUT, EP_IN = 0x01, 0x81
# linux/usbdevice_fs.h on 64-bit: struct usbdevfs_bulktransfer is
# {unsigned ep; unsigned len; unsigned timeout; void *data} = 24 bytes.
USBDEVFS_BULK = 0xC0185502
USBDEVFS_CLAIMINTERFACE = 0x8004550F
USBDEVFS_RELEASEINTERFACE = 0x80045510
COMMAND = b'continue'


def env(name, default):
    return os.environ.get(name) or default


def read(path):
    try:
        with open(path, encoding='ascii', errors='replace') as handle:
            return handle.read().strip()
    except OSError:
        return ''


def log(level, message):
    # systemd reads the <N> prefix as the journal priority (4 warning, 5 notice, 6 info).
    uptime = read(env('CERALIVE_SLOT_DELL_UPTIME', '/proc/uptime')).split(' ')[0] or '?'
    print(f'<{level}>{TAG}: uptime {uptime} s: {message}', flush=True)


class UsbFs:
    """One claimed interface on a usbfs node; bulk transfers only."""

    def __init__(self, node):
        self.fd = os.open(node, os.O_RDWR)
        self.claimed = False
        fcntl.ioctl(self.fd, USBDEVFS_CLAIMINTERFACE, struct.pack('I', 0))
        self.claimed = True

    def bulk(self, endpoint, data, timeout_ms):
        buffer = ctypes.create_string_buffer(data, len(data))
        request = bytearray(struct.pack('IIIxxxxQ', endpoint, len(data), timeout_ms, ctypes.addressof(buffer)))
        # A mutable request with mutate_flag returns the ioctl's own result: bytes moved.
        count = fcntl.ioctl(self.fd, USBDEVFS_BULK, request, True)
        return buffer.raw[:count]

    def command(self, text):
        """Send one fastboot command; return OKAY/FAIL text, or GONE if the card left the bus."""
        try:
            self.bulk(EP_OUT, text, 1000)
        except OSError as error:
            return f'WRITEFAIL {error.strerror}'
        for _ in range(8):
            try:
                reply = self.bulk(EP_IN, b'\0' * 64, 2000)
            except OSError:
                return 'GONE'  # the bootloader left USB to start the firmware
            if reply.startswith(b'INFO'):
                continue
            return reply.decode('ascii', errors='replace') or 'EMPTY'
        return 'NORESP'

    def close(self):
        if self.claimed:
            try:
                fcntl.ioctl(self.fd, USBDEVFS_RELEASEINTERFACE, struct.pack('I', 0))
            except OSError:
                pass  # the card has usually left the bus by now
        os.close(self.fd)


def id_path(sysdev):
    udevadm = env('CERALIVE_UDEVADM_BIN', 'udevadm')
    try:
        output = subprocess.run([udevadm, 'info', '--query=property', f'--path={sysdev}'],
                                capture_output=True, text=True, timeout=10, check=False).stdout
    except (OSError, subprocess.SubprocessError):
        return ''
    for line in output.splitlines():
        if line.startswith('ID_PATH='):
            return line.split('=', 1)[1]
    return ''


def slot_power_report():
    match = re.search(r'(?:^|\s)cera_slot_power=(\S+)', read(env('CERALIVE_SLOT_DELL_CMDLINE', '/proc/cmdline')))
    return match.group(1) if match else 'not reported by the boot script'


def main(argv, transport=UsbFs):
    if len(argv) != 2 or not re.fullmatch(r'\d+-[\d.]+', argv[1]):
        log(3, f'usage: {TAG} <usb kernel name>, got {argv[1:]!r}')
        return 2
    name = argv[1]
    expected = os.environ.get('CERALIVE_SLOT_ID_PATH', '')
    if not expected:
        log(6, 'no verified B-key slot ID_PATH configured: nothing to do')
        return 0
    sysdev = os.path.join(env('CERALIVE_SLOT_DELL_SYSFS', '/sys/bus/usb/devices'), name)
    if (read(f'{sysdev}/idVendor'), read(f'{sysdev}/idProduct')) != (VENDOR, PRODUCT):
        log(6, f'{name} is not {VENDOR}:{PRODUCT} (any more): nothing to do')
        return 0
    actual = id_path(sysdev)
    if actual != expected:
        log(6, f'{name} is at ID_PATH {actual or "unknown"}, not the B-key slot {expected}: not touching it')
        return 0
    interfaces = sorted(entry for entry in os.listdir(sysdev) if entry.startswith(f'{name}:'))
    if len(interfaces) != 1:
        log(6, f'{name} has {len(interfaces)} interfaces, not the single fastboot one: not touching it')
        return 0
    interface = os.path.join(sysdev, interfaces[0])
    kind = tuple(read(f'{interface}/bInterface{field}') for field in ('Class', 'SubClass', 'Protocol'))
    if kind != FASTBOOT_INTERFACE or os.path.exists(f'{interface}/driver'):
        log(6, f'{name} interface is {"/".join(kind)}{" (bound)" if os.path.exists(f"{interface}/driver") else ""}, '
               'not an unbound ff/42/03: not touching it')
        return 0

    power = slot_power_report()
    inhibit = env('CERALIVE_SLOT_DELL_INHIBIT', '/etc/ceralive/keep-slot-dell-fastboot')
    if os.path.exists(inhibit):
        log(4, f'the B-key slot Dell {name} is in fastboot (413c:81d6); {inhibit} exists, leaving it there')
        return 0

    marker = env('CERALIVE_SLOT_DELL_MARKER', '/run/ceralive/slot-dell-fastboot-release')
    os.makedirs(os.path.dirname(marker), exist_ok=True)
    try:
        fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except FileExistsError:
        log(4, f'the B-key slot Dell {name} is in fastboot (413c:81d6) again, but this boot already sent '
               f'its one fastboot command ({read(marker) or "result unknown"}): not retrying')
        return 0

    log(4, f'FIRED: the B-key slot Dell {name} ({expected}) is waiting in its fastboot bootloader '
           f'(413c:81d6). This should not happen; boot-time slot power hold: {power}. '
           'Sending one fastboot "continue".')
    try:
        device = transport(os.path.join(env('CERALIVE_SLOT_DELL_DEVROOT', '/dev/bus/usb'),
                                        '%03d' % int(read(f'{sysdev}/busnum') or 0),
                                        '%03d' % int(read(f'{sysdev}/devnum') or 0)))
    except OSError as error:
        result = f'open/claim failed: {error.strerror or error}'
    else:
        try:
            result = device.command(COMMAND)
        finally:
            device.close()
    os.write(fd, f'continue -> {result}\n'.encode())
    os.close(fd)
    if result.startswith(('OKAY', 'GONE')):
        log(5, f'fastboot continue -> {result[:24]}; the card now starts its modem firmware (413c:81d7 expected in about 9 s)')
        return 0
    log(3, f'fastboot continue -> {result[:40]}; the card stays in fastboot until the next boot')
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))

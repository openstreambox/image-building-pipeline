#!/usr/bin/env python3
"""Behaviour of the shipped B-key Dell fastboot release, against a fake sysfs.

Driven by tests/rock5bplus-internal-modem.bats. Loads the real
mkosi/runtime/ceralive-slot-dell-fastboot-release.py and replaces only its USB
transport, so every check runs the shipped matching, one-shot and logging code.
"""
import contextlib
import importlib.machinery
import importlib.util
import io
import os
import pathlib
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / 'mkosi/runtime/ceralive-slot-dell-fastboot-release.py'
SLOT = 'platform-fc800000.usb-usb-0:1.4'


def load():
    spec = importlib.util.spec_from_file_location('release', SCRIPT,
                                                  loader=importlib.machinery.SourceFileLoader('release', str(SCRIPT)))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load()
sent = []      # (node, command) for every fastboot command the transport received
opened = []
REPLY = ['OKAY']
SCRATCH = tempfile.TemporaryDirectory()  # removed at exit with every case below


class FakeUsb:
    def __init__(self, node):
        opened.append(node)
        self.node = node

    def command(self, text):
        sent.append((self.node, text))
        return REPLY[0]

    def close(self):
        pass


def device(base, name, vid='413c', pid='81d6', busnum=3, devnum=2, interfaces=(('ff', '42', '03', False),),
           id_path=SLOT):
    sysdev = base / 'sys' / name
    sysdev.mkdir(parents=True)
    for key, value in (('idVendor', vid), ('idProduct', pid), ('busnum', busnum), ('devnum', devnum),
                       ('authorized', 1)):
        (sysdev / key).write_text(f'{value}\n')
    for index, (cls, sub, proto, bound) in enumerate(interfaces):
        interface = sysdev / f'{name}:1.{index}'
        interface.mkdir()
        for key, value in (('Class', cls), ('SubClass', sub), ('Protocol', proto)):
            (interface / f'bInterface{key}').write_text(value + '\n')
        if bound:
            (interface / 'driver').mkdir()
    (base / 'paths').mkdir(exist_ok=True)
    (base / 'paths' / name).write_text(id_path)
    return sysdev


def run(base, name, power='held', expected=SLOT):
    udevadm = base / 'udevadm'
    if not udevadm.exists():
        # Prints ID_PATH for --path=<sysfs dir> from the fixture, like udevadm info.
        udevadm.write_text('#!/bin/sh\nfor a; do case "$a" in --path=*) p="${a#--path=}";; esac; done\n'
                           f'n=$(basename "$p"); [ -f "{base}/paths/$n" ] && printf "DEVPATH=x\\nID_PATH=%s\\n" "$(cat "{base}/paths/$n")"\n')
        udevadm.chmod(0o755)
        (base / 'cmdline').write_text(f'root=PARTLABEL=rootfs_a cera_slot=A' + (f' cera_slot_power={power}' if power else '') + '\n')
        (base / 'uptime').write_text('10.52 20.00\n')
    os.environ.update({
        'CERALIVE_SLOT_DELL_SYSFS': str(base / 'sys'), 'CERALIVE_SLOT_DELL_DEVROOT': '/dev/bus/usb',
        'CERALIVE_SLOT_DELL_MARKER': str(base / 'run/ceralive/slot-dell-fastboot-release'),
        'CERALIVE_SLOT_DELL_INHIBIT': str(base / 'etc/keep-slot-dell-fastboot'),
        'CERALIVE_SLOT_DELL_CMDLINE': str(base / 'cmdline'), 'CERALIVE_SLOT_DELL_UPTIME': str(base / 'uptime'),
        'CERALIVE_UDEVADM_BIN': str(udevadm), 'CERALIVE_SLOT_ID_PATH': expected})
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = release.main([str(SCRIPT), name], transport=FakeUsb)
    return rc, out.getvalue()


def case(title):
    sent.clear()
    opened.clear()
    REPLY[0] = 'OKAY'
    base = pathlib.Path(tempfile.mkdtemp(dir=SCRATCH.name))
    print(f'  case: {title}')
    return base


failures = []


def check(condition, message):
    if not condition:
        failures.append(message)
        print(f'    FAIL {message}')


# 1. The fastboot Dell at the slot position: one continue, logged as fired.
base = case('81d6 at the B-key position')
device(base, '3-1.4')
rc, log = run(base, '3-1.4')
check(rc == 0, f'exit {rc}')
check(sent == [('/dev/bus/usb/003/002', b'continue')], f'commands {sent}')
check('<4>' in log and 'FIRED' in log and 'This should not happen' in log, 'fired line missing or not a warning')
check('boot-time slot power hold: held' in log, 'power report missing')
check('continue -> OKAY' in (base / 'run/ceralive/slot-dell-fastboot-release').read_text(), 'marker lacks result')
check((base / 'sys/3-1.4/authorized').read_text() == '1\n', 'authorized changed')

# 2. One-shot: the same boot never sends a second command, even if it re-appears.
rc, log = run(base, '3-1.4')
check(rc == 0 and len(sent) == 1, f'second run sent {sent}')
check('not retrying' in log and '<4>' in log, 'second run not logged as a warning')

# 3. A failed reply is logged as an error, never followed by reboot or a retry.
base = case('bootloader refuses continue')
device(base, '3-1.4')
REPLY[0] = 'FAILunknown command'
rc, log = run(base, '3-1.4')
check(rc == 1 and sent == [('/dev/bus/usb/003/002', b'continue')], f'rc {rc}, commands {sent}')
check('<3>' in log, 'failure not logged as an error')
rc, _ = run(base, '3-1.4')
check(len(sent) == 1, f'failed attempt was retried: {sent}')

# 4. ID_PATH decides, not the bus number: the same position on bus 5 still matches.
base = case('slot position on another bus number')
device(base, '5-1.4', busnum=5, devnum=7)
rc, log = run(base, '5-1.4')
check(sent == [('/dev/bus/usb/005/007', b'continue')], f'commands {sent}')

# 5. A fastboot Dell somewhere else (external USB) is left alone.
base = case('81d6 on an external port')
device(base, '3-1.4', id_path='platform-fc880000.usb-usb-0:1')
rc, log = run(base, '3-1.4')
check(rc == 0 and not opened, f'external device opened: {opened}')

# 6. A running modem, a bound interface or extra interfaces are left alone.
for title, kwargs in (('81d7 modem', {'pid': '81d7'}),
                      ('bound interface', {'interfaces': (('ff', '42', '03', True),)}),
                      ('two interfaces', {'interfaces': (('ff', '42', '03', False), ('02', '0e', '00', False))}),
                      ('other interface class', {'interfaces': (('ff', 'ff', 'ff', False),)})):
    base = case(title)
    device(base, '3-1.4', **kwargs)
    rc, log = run(base, '3-1.4')
    check(rc == 0 and not opened and not (base / 'run').exists(), f'{title}: touched the device')

# 7. The inhibit file leaves the card in fastboot, logged; no marker spent.
base = case('inhibit file')
device(base, '3-1.4')
(base / 'etc').mkdir()
(base / 'etc/keep-slot-dell-fastboot').write_text('')
rc, log = run(base, '3-1.4')
check(rc == 0 and not opened and 'leaving it there' in log, 'inhibit ignored')

# 8. No configured position (unverified board) does nothing.
base = case('no verified position')
device(base, '3-1.4')
rc, log = run(base, '3-1.4', expected='')
check(rc == 0 and not opened, 'acted without a configured position')

# 9. The boot script did not report the hold: the log says so.
base = case('no power report')
device(base, '3-1.4')
rc, log = run(base, '3-1.4', power='')
check('not reported by the boot script' in log, 'missing power report not logged')

# 10. Static: the shipped command is continue only; no de-authorize, unbind or reset.
source = SCRIPT.read_text()
check(release.COMMAND == b'continue', 'command is not continue')
code = source.split('"""', 2)[2]  # skip the module docstring, which explains why not reboot
for forbidden in ("b'reboot'", 'authorized', 'unbind', 'USBDEVFS_RESET', '0x5514', 'flash', 'erase'):
    check(forbidden not in code, f'release code mentions {forbidden}')

if failures:
    sys.exit(f'{len(failures)} failure(s)')
print('slot Dell fastboot release: all cases pass')

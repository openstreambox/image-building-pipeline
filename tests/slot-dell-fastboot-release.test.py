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

# 9. A boot script without the hold (a field-updated board): expected, a notice.
base = case('no power report')
device(base, '3-1.4')
rc, log = run(base, '3-1.4', power='')
check('<5>' in log and 'FIRED' in log and 'has no slot power hold' in log and '<4>' not in log,
      'firing without a reported hold is not a plain notice')
check(sent == [('/dev/bus/usb/003/002', b'continue')], f'commands {sent}')

# 10. Static: the shipped command is continue only; no de-authorize, unbind or reset.
source = SCRIPT.read_text()
check(release.COMMAND == b'continue', 'command is not continue')
code = source.split('"""', 2)[2]  # skip the module docstring, which explains why not reboot
for forbidden in ("b'reboot'", 'authorized', 'unbind', 'USBDEVFS_RESET', '0x5514', 'flash', 'erase'):
    check(forbidden not in code, f'release code mentions {forbidden}')

# 11. Event order. The kernel announces the USB device before it configures it (no
# interface yet), then the interface. Replay that through the GENERATED rule: the
# device event must start nothing, the interface event must release the card once, and
# later events must not send a second command.
import re  # noqa: E402


def wants(rules, event):
    """Minimal udev matcher for the generated rule: == matches, ATTRS walks to the parent."""
    units = []
    env = dict(event['env'])
    for line in rules.splitlines():
        if not line or line.startswith('#'):
            continue
        fields = re.findall(r'([A-Z_]+(?:\{[^}]+\})?)(==|\+=|=)"([^"]*)"', line)
        assert fields, line
        matched = True
        for key, op, value in fields:
            if op != '==':
                continue
            if key == 'ACTION':
                actual = event['action']
            elif key == 'SUBSYSTEM':
                actual = 'usb'
            elif key.startswith('ENV{'):
                actual = env.get(key[4:-1])
            elif key.startswith('ATTR{'):
                actual = event['attr'].get(key[5:-1])
            elif key.startswith('ATTRS{'):
                actual = event['attr'].get(key[6:-1], event['parent'].get(key[6:-1]))
            else:
                raise AssertionError(f'unsupported match key {key}')
            matched = matched and actual is not None and re.fullmatch('|'.join(map(re.escape, value.split('|'))), actual)
        if not matched:
            continue
        for key, op, value in fields:
            if key == 'IMPORT{builtin}' and value == 'path_id':
                env['ID_PATH'] = event['id_path']
            elif key == 'ENV{SYSTEMD_WANTS}':
                units.append(value.replace('%k', event['kernel']))
    return units


rule_file = sys.argv[1] if len(sys.argv) > 1 else None
if rule_file:
    rules = pathlib.Path(rule_file).read_text()
    base = case('event order: device add before its interface exists')
    sysdev = device(base, '3-1.4', interfaces=())
    parent = {'idVendor': '413c', 'idProduct': '81d6'}
    device_add = {'action': 'add', 'kernel': '3-1.4', 'env': {'DEVTYPE': 'usb_device'}, 'attr': parent, 'parent': {},
                  'id_path': SLOT}
    interface_add = {'action': 'add', 'kernel': '3-1.4:1.0', 'env': {'DEVTYPE': 'usb_interface'},
                     'attr': {'bInterfaceClass': 'ff', 'bInterfaceSubClass': '42', 'bInterfaceProtocol': '03'},
                     'parent': parent, 'id_path': SLOT + ':1.0'}
    started = wants(rules, device_add)
    check(started == [], f'the unconfigured device event started {started}')
    # Even if something ran the helper now, it must not spend the per-boot marker.
    rc, log = run(base, '3-1.4')
    check(rc == 0 and not opened and not (base / 'run').exists(), 'helper spent the marker with zero interfaces')
    # Configuration completes: the interface appears and is announced.
    interface = sysdev / '3-1.4:1.0'
    interface.mkdir()
    for key, value in (('Class', 'ff'), ('SubClass', '42'), ('Protocol', '03')):
        (interface / f'bInterface{key}').write_text(value + '\n')
    started = wants(rules, interface_add)
    check(started == ['ceralive-slot-dell-fastboot-release@3-1.4:1.0.service'], f'interface add started {started}')
    for unit in started:
        rc, log = run(base, unit.split('@', 1)[1].removesuffix('.service'))
        check(rc == 0, f'exit {rc}')
    check(sent == [('/dev/bus/usb/003/002', b'continue')], f'commands after the interface event: {sent}')
    for later in (dict(interface_add, action='bind'), dict(device_add, action='bind'), dict(interface_add, action='change')):
        check(wants(rules, later) == [], f'{later["action"]} of {later["kernel"]} starts the unit')
    # The card re-appearing as 81d6 in the same boot: the unit may start, no second command.
    for unit in wants(rules, interface_add):
        run(base, unit.split('@', 1)[1].removesuffix('.service'))
    check(len(sent) == 1, f'a second command was sent: {sent}')
    # Same interface class elsewhere, or another interface of a Dell at the slot: no start.
    check(wants(rules, dict(interface_add, id_path='platform-fc880000.usb-usb-0:1:1.0')) == [], 'external port matched')
    check(wants(rules, dict(interface_add, attr={'bInterfaceClass': 'ff', 'bInterfaceSubClass': 'ff',
                                                 'bInterfaceProtocol': 'ff'})) == [], 'non-fastboot interface matched')
    check(wants(rules, dict(interface_add, parent={'idVendor': '413c', 'idProduct': '81d7'})) == [], '81d7 matched')
else:
    print('  (no generated rule file given: event-order case skipped)')

# 12. The REAL UsbFs.command against injected bulk outcomes: only an OKAY reply or a
# confirmed disconnect (ENODEV) is success; a timeout, stall or I/O error is a failure
# that reaches the marker and the exit status, with no second command.
import errno  # noqa: E402


def real_usb(outcomes):
    """The shipped UsbFs with only bulk() replaced; outcomes are bytes or errno values."""
    calls = []

    class Injected(release.UsbFs):
        def __init__(self, node):  # no usbfs node on the test host
            self.claimed = False
            self.fd = os.open(os.devnull, os.O_RDONLY)

        def bulk(self, endpoint, data, timeout_ms):
            calls.append((endpoint, bytes(data) if endpoint == release.EP_OUT else None))
            outcome = outcomes.pop(0)
            if isinstance(outcome, int):
                raise OSError(outcome, os.strerror(outcome))
            return outcome
    return Injected, calls


for title, outcomes, want_rc, want_text in (
        ('OKAY reply', [b'continue', b'OKAY'], 0, 'OKAY'),
        ('INFO then OKAY', [b'continue', b'INFOresuming', b'OKAY'], 0, 'OKAY'),
        ('disconnect after the command', [b'continue', errno.ENODEV], 0, 'GONE'),
        ('read timeout', [b'continue', errno.ETIMEDOUT], 1, 'READFAIL ETIMEDOUT'),
        ('stall', [b'continue', errno.EPIPE], 1, 'READFAIL EPIPE'),
        ('I/O error', [b'continue', errno.EIO], 1, 'READFAIL EIO'),
        ('write timeout', [errno.ETIMEDOUT], 1, 'WRITEFAIL ETIMEDOUT'),
        ('FAIL reply', [b'continue', b'FAILnope'], 1, 'FAILnope')):
    base = case(f'real UsbFs: {title}')
    device(base, '3-1.4')
    transport, calls = real_usb(list(outcomes))
    run(base, '3-1.4')  # prime the fixture environment (udevadm, cmdline) with the fake transport
    marker = base / 'run/ceralive/slot-dell-fastboot-release'
    marker.unlink()
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = release.main([str(SCRIPT), '3-1.4:1.0'], transport=transport)
    text = out.getvalue()
    check(rc == want_rc, f'{title}: exit {rc}, wanted {want_rc}')
    check(want_text in marker.read_text(), f'{title}: marker says {marker.read_text()!r}')
    check(('<3>' in text) == (want_rc != 0), f'{title}: error logging does not match the outcome')
    check('starts its modem firmware' not in text or want_rc == 0, f'{title}: logged as a successful start')
    check([c for c in calls if c[0] == release.EP_OUT] == [(release.EP_OUT, b'continue')],
          f'{title}: commands written {calls}')

if failures:
    sys.exit(f'{len(failures)} failure(s)')
print('slot Dell fastboot release: all cases pass')

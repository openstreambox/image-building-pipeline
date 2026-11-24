#!/usr/bin/env python3
"""Replay slot-Dell udev events through a generated 78-mm-ceralive-slot-uid.rules
and group the ports the way ModemManager does.

ModemManager (1.20 and 1.24, kernel_device_get_physdev_uid) takes
ID_MM_PHYSDEV_UID from the physdev's udev record, then from the port's own
record, then falls back to the physdev sysfs path. Ports with different UIDs
become different modems. udev rebuilds a device's record on every event from
that event's rules alone, so a property set only on add|bind is missing after
an unbind, and a port read in that window gets the sysfs-path UID.

The device tree is ROCK 5B+ hardware: the B-key DW5821e (413c:81d7, config 2)
as read with udevadm on image 5.1, plus an external Dell behind a hub and a
virtual tty. Usage: modem-slot-uid-grouping.py RULES [--expect-split]
"""
import fnmatch
import itertools
import re
import sys

SLOT = '/devices/platform/fc800000.usb/usb3/3-1/3-1.4'
EXT = '/devices/platform/fc800000.usb/usb3/3-1/3-1.1/3-1.1.3'
DEEPER = '/devices/platform/fc800000.usb/usb3/3-1/3-1.4/3-1.4.1'

# (subsystem, devtype, devpath) for every device that can carry the UID.
USB = {SLOT: 'usb_device', EXT: 'usb_device', DEEPER: 'usb_device'}
SLOT_PORTS = [
    ('net', SLOT + '/3-1.4:2.0/net/wwu1u4c2'),
    ('usbmisc', SLOT + '/3-1.4:2.0/usbmisc/cdc-wdm0'),
    ('tty', SLOT + '/3-1.4:2.2/ttyUSB0/tty/ttyUSB0'),
    ('tty', SLOT + '/3-1.4:2.3/ttyUSB1/tty/ttyUSB1'),
    ('tty', SLOT + '/3-1.4:2.4/ttyUSB2/tty/ttyUSB2'),
    ('tty', SLOT + '/3-1.4:2.5/ttyUSB3/tty/ttyUSB3'),
]
OTHER_PORTS = [
    ('net', EXT + '/3-1.1.3:2.0/net/wwu1u1u3c2'),
    ('usbmisc', EXT + '/3-1.1.3:2.0/usbmisc/cdc-wdm1'),
    ('tty', EXT + '/3-1.1.3:2.2/ttyUSB4/tty/ttyUSB4'),
    ('tty', DEEPER + '/3-1.4.1:1.0/ttyUSB8/tty/ttyUSB8'),
    ('tty', '/devices/virtual/tty/tty1'),
]


def path_id(devpath):
    """systemd path_id for this tree: platform-<ctrl>-usb-0:<port>[:<cfg.if>],
    named after the deepest usb_device or interface on the path."""
    m = re.match(r'/devices/platform/([^/]+)/usb\d+/', devpath)
    if not m:
        return None
    usb = [p for p in devpath.split('/') if re.fullmatch(r'\d+-[\d.]+(:[\d.]+)?', p)]
    return 'platform-%s-usb-0:%s' % (m.group(1), usb[-1].split('-', 1)[1])


def parse(rules_text):
    rules = []
    for line in rules_text.splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        fields = re.findall(r'([A-Z]+(?:\{[^}]+\})?)(==|!=|\+=|=)"([^"]*)"', line)
        assert fields, 'unparsed rule: %r' % line
        rules.append(fields)
    return rules


def match(pattern, value):
    return any(fnmatch.fnmatchcase(value or '', alt) for alt in pattern.split('|'))


def run_event(rules, action, subsystem, devpath, devtype=None):
    """Return the record udev stores for this event."""
    env = {'ACTION': action, 'SUBSYSTEM': subsystem, 'DEVPATH': devpath}
    if devtype:
        env['DEVTYPE'] = devtype
    ancestors = {'usb'} if devpath.startswith('/devices/platform/') else set()
    for fields in rules:
        ok = True
        for key, op, val in fields:
            if op not in ('==', '!='):
                continue
            if key == 'SUBSYSTEMS':
                hit = any(match(val, a) for a in ancestors | {subsystem})
            else:
                name = key[4:-1] if key.startswith('ENV{') else key
                hit = match(val, env.get(name, ''))
            if hit != (op == '=='):
                ok = False
                break
        if not ok:
            continue
        for key, op, val in fields:
            if key == 'IMPORT{builtin}':
                assert val == 'path_id', val
                pid = path_id(devpath)
                if pid:
                    env['ID_PATH'] = pid
            elif op == '=' and key.startswith('ENV{'):
                env[key[4:-1]] = val
    return env


def mm_uid(physdev_record, port_record, physdev_path):
    return (physdev_record.get('ID_MM_PHYSDEV_UID')
            or port_record.get('ID_MM_PHYSDEV_UID')
            or '/sys' + physdev_path)


def scenarios(rules):
    """Yield (name, {port: uid}) for each ordering of physdev vs port events."""
    usb = lambda action: run_event(rules, action, 'usb', SLOT, 'usb_device')
    ports = {p: run_event(rules, 'add', s, p) for s, p in SLOT_PORTS}
    names = [p for _, p in SLOT_PORTS]
    # Manual or driver rebind: unbind record, ports added, then the bind event.
    unbound = usb('unbind')
    yield 'rebind', {p: mm_uid(unbound, ports[p], SLOT) for p in names}
    # Boot-time re-enumeration: some ports are read before the device's
    # add record exists (empty), the rest after it.
    for k in range(len(names) + 1):
        for early in itertools.combinations(names, k):
            seen = {p: mm_uid({} if p in early else usb('add'), ports[p], SLOT) for p in names}
            yield 'boot-%d-early' % k, seen
    # A later change event on the usb_device must not drop it either.
    yield 'change', {p: mm_uid(usb('change'), ports[p], SLOT) for p in names}


def main():
    rules = parse(open(sys.argv[1]).read())
    expect_split = '--expect-split' in sys.argv[2:]
    split = []
    for name, seen in scenarios(rules):
        groups = set(seen.values())
        if len(groups) != 1 or groups != {'internal 4G'}:
            split.append((name, sorted(groups)))
    for s, p in OTHER_PORTS:
        rec = run_event(rules, 'add', s, p)
        assert 'ID_MM_PHYSDEV_UID' not in rec, 'UID leaked onto %s' % p
    for path in (EXT, DEEPER):
        rec = run_event(rules, 'add', 'usb', path, 'usb_device')
        assert 'ID_MM_PHYSDEV_UID' not in rec, 'UID leaked onto %s' % path
    assert run_event(rules, 'add', 'usb', SLOT, 'usb_device').get('ID_MM_PHYSDEV_UID') == 'internal 4G'
    if expect_split:
        assert split, 'expected the rule set to split or mislabel the slot modem'
        print('split as expected: %d orderings, e.g. %s %s' % (len(split), *split[0]))
    else:
        assert not split, 'slot modem split or mislabelled: %s' % split[:3]
        print('one "internal 4G" modem in every ordering')


if __name__ == '__main__':
    main()

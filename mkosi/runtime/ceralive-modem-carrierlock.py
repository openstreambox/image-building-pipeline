#!/usr/bin/python3
"""Unlock a carrier-locked Fibocom FM350-GL so its profile follows the SIM again.

Why: an FM350-GL with no lock (`AT+GTLOCKCAR?` -> `0,65535`) picks its carrier
profile from the SIM by itself. A unit locked with `AT+GTLOCKCAR=1,<carrier
id>` keeps that profile whatever SIM goes in; with the Verizon profile and a
T-Mobile SIM it crashed on its first radio-on. The lock survived module
restarts although Fibocom's AT manual (V2.10 §3.27) calls it non-persistent.
Measured on firmware 81600.0000.00.29.18.01: with ModemManager holding off and
the radio off (AT+CFUN=4), the one-parameter `AT+GTLOCKCAR=0` answers OK and
the lock reads `0,65535`; the module then picks its profile from the SIM and
reconnects. With the radio on, and in every two-parameter form
(`=0,65535`, `=0,<id>`), the unlock is refused. Whether the unlock survives a
module restart has not been measured, so this service checks again on later
boots until it has seen the unit still unlocked once.

udev starts one instance of ceralive-modem-carrierlock@<usb device>.service for
every 0e8d:7127 device that is added (coldplug at boot included). This script
then, for that one device:

  1. Holds back while a stream runs (an srtla_send process) and while
     /data/ceralive/modem-carrierlock.disabled exists. Both are checked again
     right before ModemManager is asked to hold the modem and right before the
     radio is switched off; after that the exchange is finished and the radio
     put back as it was.
  2. Waits for ModemManager to list the modem (matched by its physical device)
     with a SIM, and accepts only the models in MODELS. A Verizon SIM (home
     PLMN in VERIZON) is left alone: an unlocked unit selects the Verizon
     profile, and this firmware crash-loops with a Verizon SIM.
  3. Acts once per unit and SIM per boot (a marker in /run). A unit whose
     record in /data shows it unlocked on a boot after any unlock by this
     service is not held at all: holding a modem makes ModemManager drop it
     and probe it again. Nothing on the image locks a unit, so that record
     only goes stale through a lock set by hand;
     `touch /data/ceralive/modem-carrierlock.retry` forgets every unit's
     recorded state once (the first recorded values and the history stay).
  4. Takes the modem from ModemManager with `mmcli --inhibit-device` for the
     whole exchange (ModemManager's polling otherwise takes answers on the
     same port), then talks to ModemManager's `(at)` port on USB interface 6.
  5. Checks AT+CIMI against ModemManager's IMSI and reads AT+GTLOCKCAR? and
     AT+GTCURCAR?. Unlocked: recorded, left alone. Locked (`1,<id>`):
     AT+CFUN? (1 or 4 only), AT+CFUN=4 if the radio was on, AT+GTLOCKCAR=0,
     read both back (the lock must read `0,65535`), then AT+CFUN=1 if the
     radio was on. No lock is ever written.
  6. If the module restarts on the unlock (the port goes silent and the USB
     device leaves), the outcome is `restarted`; the instance started by its
     return reads the lock back without writing anything and records
     `unlocked-by-service` or `failed`. A unit whose unlock was refused or did
     not take is left alone on later boots until the retry file is used. A
     unit found locked again after an unlock is unlocked again (once per boot)
     and is read on every boot from then on.

Any answer that doesn't match what was measured ends the run with nothing
written, the radio put back and the modem released.

The unit id in /data is HMAC-SHA256(machine-id, IMEI) truncated to 16 hex
digits; the SIM is recorded only by its home PLMN, never by its IMSI.

Undo: the unit's original lock is in its record. Create the .disabled file,
hold the modem with `mmcli --inhibit-device=<uid>`, then on the AT port
AT+CFUN=4, AT+GTLOCKCAR=1,<id>, AT+CFUN=1.

Test seams (production uses every default):
  CERALIVE_CARRIERLOCK_SYSFS        sysfs root (default /sys)
  CERALIVE_CARRIERLOCK_DEV          device node dir (default /dev)
  CERALIVE_CARRIERLOCK_PROC         procfs root (default /proc)
  CERALIVE_CARRIERLOCK_RUN          volatile markers (default /run/ceralive/modem-carrierlock)
  CERALIVE_CARRIERLOCK_DATA         persistent records (default /data/ceralive/modem-carrierlock)
  CERALIVE_CARRIERLOCK_MACHINE_ID   HMAC key file (default /etc/machine-id)
  CERALIVE_CARRIERLOCK_MMCLI        mmcli binary (default mmcli)
  CERALIVE_CARRIERLOCK_BUDGET       seconds for the whole run (default 270)
  CERALIVE_CARRIERLOCK_MM_WAIT      seconds to wait for ModemManager and the SIM (default 120)
  CERALIVE_CARRIERLOCK_POLL         poll interval seconds (default 2)
  CERALIVE_CARRIERLOCK_AT_TIMEOUT   seconds per AT command (default 3)
  CERALIVE_CARRIERLOCK_LOCK_TIMEOUT seconds for the radio and unlock commands (default 10)
  CERALIVE_CARRIERLOCK_PORT_WAIT    seconds for ModemManager to let go of the port (default 10)
  CERALIVE_CARRIERLOCK_LEAVE_WAIT   seconds for a restarting module to drop off (default 15)
"""
import errno
import fcntl
import hashlib
import hmac
import html
import json
import os
import re
import select
import signal
import subprocess
import sys
import termios
import time
from pathlib import Path

TAG = 'ceralive-modem-carrierlock'
# FM350-GL in USB mode 41 (RNDIS). Mode 40 (0e8d:7126) has its AT port on
# another interface and has not been read on a bench.
USB_IDS = {('0e8d', '7127')}
MODELS = {'FM350-GL'}
# ModemManager's 77-mm-fm350gl.rules types interface 06 as the primary AT port
# of 0e8d:7127 and ignores every other tty; the lock answers were recorded there.
AT_INTERFACE = '06'
# Verizon home PLMNs: CeraUI's carrier table
# (apps/backend/src/modules/modems/subscription-policy.ts, CARRIER_POLICIES,
# row "verizon"). An unlocked unit selects Fibocom profile 101 for these SIMs.
VERIZON = {'310590', '310890', '311270', '311480', '312770'}
UNLOCKED = ('0', '65535')
# Outcomes that leave a unit alone on later boots until the retry file is used.
GIVE_UP = {'unlock-refused', 'failed', 'radio-off-failed', 'radio-not-back'}
STREAM_PROCESSES = {'srtla_send'}
KERNEL_NAME = re.compile(r'\d+-\d+(\.\d+)*')

SYSFS = Path(os.environ.get('CERALIVE_CARRIERLOCK_SYSFS', '/sys'))
DEV = Path(os.environ.get('CERALIVE_CARRIERLOCK_DEV', '/dev'))
PROC = Path(os.environ.get('CERALIVE_CARRIERLOCK_PROC', '/proc'))
RUN = Path(os.environ.get('CERALIVE_CARRIERLOCK_RUN', '/run/ceralive/modem-carrierlock'))
DATA = Path(os.environ.get('CERALIVE_CARRIERLOCK_DATA', '/data/ceralive/modem-carrierlock'))
DISABLED = DATA.parent / 'modem-carrierlock.disabled'
RETRY = DATA.parent / 'modem-carrierlock.retry'
MACHINE_ID = Path(os.environ.get('CERALIVE_CARRIERLOCK_MACHINE_ID', '/etc/machine-id'))
MMCLI = os.environ.get('CERALIVE_CARRIERLOCK_MMCLI', 'mmcli')
BUDGET = float(os.environ.get('CERALIVE_CARRIERLOCK_BUDGET', '270'))
MM_WAIT = float(os.environ.get('CERALIVE_CARRIERLOCK_MM_WAIT', '120'))
POLL = float(os.environ.get('CERALIVE_CARRIERLOCK_POLL', '2'))
AT_TIMEOUT = float(os.environ.get('CERALIVE_CARRIERLOCK_AT_TIMEOUT', '3'))
LOCK_TIMEOUT = float(os.environ.get('CERALIVE_CARRIERLOCK_LOCK_TIMEOUT', '10'))
PORT_WAIT = float(os.environ.get('CERALIVE_CARRIERLOCK_PORT_WAIT', '10'))
LEAVE_WAIT = float(os.environ.get('CERALIVE_CARRIERLOCK_LEAVE_WAIT', '15'))
DEADLINE = time.monotonic() + BUDGET
HISTORY = 20


def remaining():
    return DEADLINE - time.monotonic()


def log(level, message):
    # journald reads the <n> prefix as the syslog priority (6 info, 4 warning, 3 error).
    print(f'<{level}>{TAG}: {message}', flush=True)


def read(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return None


def realpath(path):
    try:
        return os.path.realpath(path, strict=True)
    except OSError:
        return None


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.tmp')
    with temp.open('w') as stream:
        stream.write(json.dumps(data, sort_keys=True) + '\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)


def lock_text(lock):
    return f'{lock[0]},{lock[1]}' if lock else None


# --- per-boot markers (/run) and per-unit records (/data) --------------------

def marker_path(key):
    return RUN / f'{key}.json'


def load_marker(key):
    try:
        return json.loads(marker_path(key).read_text())
    except (OSError, ValueError):
        return None


def save_marker(key, phase, **fields):
    data = dict(fields, phase=phase, time=int(time.time()))
    atomic_json(marker_path(key), data)
    return data


def keyed_hmac(value):
    key = read(MACHINE_ID)
    if not value or not key:
        return None
    return hmac.new(key.encode(), value.encode(), hashlib.sha256).hexdigest()[:16]


def load_record(unit):
    try:
        return json.loads((DATA / f'{unit}.json').read_text())
    except (OSError, ValueError):
        return {}


def save_record(unit, port, event=None, **fields):
    """Merge fields into the unit's record and append the event to its history.
    The first recorded lock and profile (`original_*`) are never replaced."""
    if not DATA.parent.is_dir():
        log(6, f'{port}: no {DATA.parent}; this result is only in the journal and the /run marker')
        return
    record = load_record(unit)
    for name in ('original_lock', 'original_profile'):
        if name in record:
            fields.pop(name, None)
    now = int(time.time())
    record.update(fields, time=now, port=port)
    if event:
        record['history'] = (record.get('history', []) + [dict(event, time=now)])[-HISTORY:]
    try:
        atomic_json(DATA / f'{unit}.json', record)
    except OSError as error:
        log(4, f'{port}: could not write the record ({error}); see this journal')


def honour_retry():
    """`touch /data/ceralive/modem-carrierlock.retry` forgets every unit's
    recorded lock and last outcome, so each unit is read (and if needed
    relocked) once more. The original values and the history stay."""
    if not RETRY.exists():
        return
    cleared = 0
    for path in sorted(DATA.glob('*.json')) if DATA.is_dir() else []:
        try:
            record = json.loads(path.read_text())
            changed = [record.pop(name, None) for name in ('status', 'lock', 'profile', 'plmn')]
            if any(value is not None for value in changed):
                atomic_json(path, record)
                cleared += 1
        except (OSError, ValueError):
            continue
    try:
        RETRY.unlink()
    except OSError as error:
        log(4, f'could not remove {RETRY} ({error})')
        return
    log(6, f'{RETRY}: forgot the recorded lock and outcome of {cleared} unit(s); original values kept')


# --- what may stop an attempt ----------------------------------------------

def streaming():
    """Return the name of a running stream process, or None. Unreadable means streaming."""
    try:
        entries = list(PROC.iterdir())
    except OSError:
        return 'unreadable process list'
    for entry in entries:
        if not entry.name.isdigit():
            continue
        if read(entry / 'comm') in STREAM_PROCESSES:
            return read(entry / 'comm')
    return None


def holding_back():
    """Why this run must not go on right now, or None."""
    if DISABLED.exists():
        return f'{DISABLED} exists'
    stream = streaming()
    if stream:
        return f'a stream is running ({stream})'
    return None


def holders(node):
    """PIDs other than ours with an open file descriptor on node."""
    target = os.path.realpath(node)
    found = []
    try:
        entries = list(PROC.iterdir())
    except OSError:
        return ['unknown']
    for entry in entries:
        if not entry.name.isdigit() or int(entry.name) == os.getpid():
            continue
        try:
            fds = list((entry / 'fd').iterdir())
        except OSError:
            continue
        for fd in fds:
            try:
                if os.path.realpath(os.readlink(fd)) == target:
                    found.append(entry.name)
                    break
            except OSError:
                continue
    return found


# --- ModemManager -----------------------------------------------------------

def mmcli(*args, timeout=15):
    budget = min(timeout, remaining())
    if budget < 0.5:
        return None
    try:
        done = subprocess.run([MMCLI, *args], capture_output=True, text=True, timeout=budget)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return done.stdout if done.returncode == 0 else None


def keyed(text):
    """Parse `mmcli -K` output into {key: value} plus {key: [values]} for lists."""
    values, lists = {}, {}
    for line in (text or '').splitlines():
        key, sep, value = line.partition(':')
        if not sep:
            continue
        key, value = key.strip(), value.strip()
        match = re.fullmatch(r'(.+)\.value\[\d+\]', key)
        if match:
            lists.setdefault(match.group(1), []).append(value)
        else:
            values[key] = value
    return values, lists


def find_modem(device):
    """ModemManager's record of this USB device with its SIM's IMSI, or None.

    `generic.device` is the inhibit uid; it is a sysfs path unless udev set
    ID_MM_PHYSDEV_UID, so the match also accepts `generic.physdev`.
    """
    _, lists = keyed(mmcli('-L', '-K'))
    for path in lists.get('modem-list', []):
        values, mlists = keyed(mmcli('-m', path, '-K'))
        uid = values.get('modem.generic.device', '')
        physdev = values.get('modem.generic.physdev', '')
        if device not in (realpath(uid) if uid.startswith('/') else None,
                          realpath(physdev) if physdev.startswith('/') else None):
            continue
        sim = values.get('modem.generic.sim', '--')
        imsi = None
        if sim.startswith('/'):
            simvalues, _ = keyed(mmcli('-i', sim, '-K'))
            imsi = simvalues.get('sim.properties.imsi', '')
            imsi = imsi if re.fullmatch(r'\d{14,15}', imsi) else None
        return {
            'path': path,
            'uid': uid,
            'model': values.get('modem.generic.model', ''),
            'revision': values.get('modem.generic.revision', ''),
            'equipment': values.get('modem.generic.equipment-identifier', ''),
            'ports': mlists.get('modem.generic.ports', []),
            'imsi': imsi,
        }
    return None


def at_ports(device, ports):
    """ModemManager's `(at)` ttys that sit on this device's interface 6."""
    names = []
    for port in ports:
        match = re.fullmatch(r'(tty[A-Za-z]+\d+) \(at\)', port)
        if not match:
            continue
        tty = match.group(1)
        for interface in Path(device).glob(Path(device).name + ':*'):
            if read(interface / 'bInterfaceNumber') != AT_INTERFACE:
                continue
            if (interface / tty).exists() or (interface / 'tty' / tty).exists():
                names.append(tty)
    return names


class Hold:
    """`mmcli --inhibit-device` for as long as the object lives."""

    def __init__(self, uid):
        self.process = None
        try:
            self.process = subprocess.Popen(
                [MMCLI, f'--inhibit-device={uid}'],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
        except OSError as error:
            self.reason = str(error)
            return
        wait = max(0.0, min(15.0, remaining()))
        self.reason = f'no confirmation from mmcli within {wait:g} s'
        fd = self.process.stdout.fileno()
        deadline = time.monotonic() + wait
        seen = b''
        while time.monotonic() < deadline:
            ready, _, _ = select.select([fd], [], [], max(0.0, deadline - time.monotonic()))
            if not ready:
                break
            chunk = os.read(fd, 4096)
            if not chunk:
                text = seen.decode(errors='replace').strip().replace('\n', ' ')
                self.reason = f'mmcli exited with status {self.process.wait()}' + (f': {text}' if text else '')
                break
            seen += chunk
            if b'successfully inhibited' in seen.lower():
                self.reason = None
                return
        self.release()

    @property
    def held(self):
        return self.reason is None and self.process is not None and self.process.poll() is None

    def release(self):
        if self.process is None or self.process.poll() is not None:
            return
        self.process.send_signal(signal.SIGINT)
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


# --- AT port ----------------------------------------------------------------

class AtPort:
    FINAL = re.compile(r'^(OK|ERROR|\+CME ERROR:.*|\+CMS ERROR:.*)$')

    def __init__(self, node):
        self.fd = os.open(node, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        try:
            fcntl.ioctl(self.fd, termios.TIOCEXCL)
            attrs = termios.tcgetattr(self.fd)
            attrs[0] = 0                                     # iflag
            attrs[1] = 0                                     # oflag
            attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
            attrs[3] = 0                                     # lflag: raw, no echo
            attrs[4] = attrs[5] = termios.B115200
            attrs[6][termios.VMIN] = 0
            attrs[6][termios.VTIME] = 0
            termios.tcsetattr(self.fd, termios.TCSANOW, attrs)
        except OSError:
            os.close(self.fd)
            raise

    def close(self):
        try:
            fcntl.ioctl(self.fd, termios.TIOCNXCL)
        except OSError:
            pass
        os.close(self.fd)

    def drain(self):
        while True:
            ready, _, _ = select.select([self.fd], [], [], 0.05)
            if not ready:
                return
            try:
                if not os.read(self.fd, 4096):
                    return
            except OSError as error:
                if error.errno == errno.EAGAIN:
                    return
                raise

    def command(self, text, timeout=None):
        """Send one command; return (final, lines) with the echo removed, final None on timeout.

        `lines` keeps every other line, unsolicited ones (+CIEV, +CTZV, ...)
        included; the parsers below pick the one answer they expect."""
        deadline = time.monotonic() + (AT_TIMEOUT if timeout is None else timeout)
        buffer, lines = b'', []
        try:
            self.drain()
            pending = (text + '\r').encode()
            while pending:
                left = deadline - time.monotonic()
                if left <= 0:
                    return None, lines
                _, ready, _ = select.select([], [self.fd], [], left)
                if not ready:
                    continue
                try:
                    pending = pending[os.write(self.fd, pending):]
                except OSError as error:
                    if error.errno != errno.EAGAIN:
                        raise
        except OSError:
            # EIO and friends: the port went away (a module restarting).
            return None, lines
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return None, lines
            ready, _, _ = select.select([self.fd], [], [], left)
            if not ready:
                continue
            try:
                chunk = os.read(self.fd, 4096)
            except OSError as error:
                if error.errno == errno.EAGAIN:
                    continue
                return None, lines
            if not chunk:
                return None, lines
            buffer += chunk
            while b'\n' in buffer or b'\r' in buffer:
                cut = min(i for i in (buffer.find(b'\r'), buffer.find(b'\n')) if i >= 0)
                line, buffer = buffer[:cut].decode(errors='replace').strip(), buffer[cut + 1:]
                if not line or line == text:
                    continue
                if self.FINAL.match(line):
                    return line, lines
                lines.append(line)


def only(pattern, lines):
    """The match of the one line that fits pattern; None unless exactly one does."""
    found = [m for m in (re.fullmatch(pattern, line) for line in lines) if m]
    return found[0] if len(found) == 1 else None


def parse_imsi(final, lines):
    match = only(r'(\d{14,15})', lines) if final == 'OK' else None
    return match.group(1) if match else None


def parse_lock(final, lines):
    """(mode, id) from `+GTLOCKCAR: 1,203`."""
    match = only(r'\+GTLOCKCAR:\s*(\d+)\s*,\s*(\d+)', lines) if final == 'OK' else None
    return (match.group(1), match.group(2)) if match else None


def parse_profile(final, lines):
    """(id, name) from `+GTCURCAR: 201,"AT&amp;T"`; the module HTML-escapes the name."""
    match = only(r'\+GTCURCAR:\s*(\d+)\s*(?:,\s*"([^"]*)")?', lines) if final == 'OK' else None
    return (match.group(1), html.unescape(match.group(2) or '')) if match else None


def parse_radio(final, lines):
    match = only(r'\+CFUN:\s*(\d+)', lines) if final == 'OK' else None
    return match.group(1) if match else None


# --- the decision -----------------------------------------------------------

def run(port):
    device_dir = SYSFS / 'bus/usb/devices' / port
    if not device_dir.exists():
        log(6, f'{port}: device is gone; nothing to do')
        return 0
    device = os.path.realpath(device_dir)
    ids = (read(device_dir / 'idVendor'), read(device_dir / 'idProduct'))
    if ids not in USB_IDS:
        log(6, f'{port}: {ids[0]}:{ids[1]} is not an FM350-GL ID; leaving it alone')
        return 0
    honour_retry()
    reason = holding_back()
    if reason:
        log(6, f'{port}: {reason}; checking again at the next appearance or boot')
        return 0

    log(6, f'{port}: waiting for ModemManager to list the modem and its SIM')
    deadline = time.monotonic() + min(MM_WAIT, max(0.0, remaining() - 90))
    modem = find_modem(device)
    while (modem is None or modem['imsi'] is None) and time.monotonic() < deadline:
        time.sleep(POLL)
        if not device_dir.exists():
            log(6, f'{port}: device went away while waiting; nothing to do')
            return 0
        modem = find_modem(device)
    if modem is None:
        log(4, f'{port}: ModemManager did not list the modem in time; leaving it alone')
        return 0
    if modem['model'] not in MODELS:
        log(6, f'{port}: model "{modem["model"]}" is not on the list ({", ".join(sorted(MODELS))}); leaving it alone')
        return 0
    if modem['imsi'] is None:
        log(6, f'{port}: ModemManager reports no readable SIM; leaving the lock as it is')
        return 0
    plmn = modem['imsi'][:6]
    if plmn in VERIZON:
        log(4, f'{port}: Verizon SIM ({plmn}): an unlocked unit would select the Verizon profile, which '
               'crash-loops on this firmware; leaving the lock as it is')
        return 0
    unit, sim = keyed_hmac(modem['equipment']), keyed_hmac(modem['imsi'])
    if not unit or not sim:
        log(4, f'{port}: no IMEI or machine-id, so this run could not be kept to once per unit; leaving it alone')
        return 0
    key = f'{unit}-{sim[:8]}'
    base = dict(unit=unit, plmn=plmn, model=modem['model'], revision=modem['revision'])

    marker = load_marker(key)
    verify_only = False
    if marker and marker.get('phase') == 'restarted':
        verify_only = True
        log(6, f'{port}: back after the module restarted on the unlock; reading the lock, writing nothing')
    elif marker:
        log(6, f'{port}: this unit and SIM were already handled this boot ({marker.get("phase")}); nothing to do')
        return 0
    else:
        record = load_record(unit)
        if record.get('status') in GIVE_UP:
            save_marker(key, 'gave-up', **base)
            log(4, f'{port}: an earlier attempt on this unit ended "{record["status"]}"; leaving it alone '
                   f'(touch {RETRY} to try once more)')
            return 0
        if record.get('status') == 'unlocked' and not record.get('lock_returned'):
            save_marker(key, 'unlocked', **base)
            log(6, f'{port}: recorded as unlocked; it picks its profile from the SIM; nothing to do')
            return 0

    candidates = at_ports(device, modem['ports'])
    if not candidates:
        save_marker(key, 'no-at-port', **base)
        log(4, f'{port}: ModemManager lists no AT port on interface {AT_INTERFACE} of this device '
               f'({", ".join(modem["ports"]) or "none"}); leaving it alone')
        return 0
    # Written before anything is asked of ModemManager: whatever happens next,
    # this unit and SIM are not tried a second time this boot.
    save_marker(key, 'verifying' if verify_only else 'attempting', **base)
    reason = holding_back()
    if reason:
        if verify_only:
            save_marker(key, 'restarted', **base)
        else:
            marker_path(key).unlink(missing_ok=True)
        log(6, f'{port}: {reason} now; not asking ModemManager, checking again at the next appearance or boot')
        return 0
    hold = Hold(modem['uid'])
    if not hold.held:
        save_marker(key, 'inhibit-failed', **base, reason=hold.reason)
        log(4, f'{port}: ModemManager would not release the modem ({hold.reason}); leaving it alone this boot')
        return 0
    try:
        exchange(port, device_dir, key, candidates, base, modem['imsi'], verify_only)
    finally:
        hold.release()
    return 0


def open_port(candidates):
    deadline = time.monotonic() + PORT_WAIT
    while time.monotonic() < deadline:
        for tty in candidates:
            path = DEV / tty
            if path.exists() and not holders(path):
                return path
        time.sleep(min(POLL, 0.5))
    return None


def exchange(port, device_dir, key, candidates, base, imsi, verify_only):
    """The AT part, under the hold."""
    unit = base['unit']
    node = open_port(candidates)
    if node is None:
        save_marker(key, 'port-busy', **base)
        log(4, f'{port}: no free AT port among {", ".join(candidates)} while held; leaving it alone this boot')
        return
    try:
        at = AtPort(node)
    except OSError as error:
        save_marker(key, 'port-failed', **base, reason=str(error))
        log(4, f'{port}: cannot open {node.name} ({error}); leaving it alone this boot')
        return
    try:
        if parse_imsi(*at.command('AT+CIMI')) != imsi:
            save_marker(key, 'sim-mismatch', **base)
            log(4, f'{port}: AT+CIMI does not match the SIM ModemManager reported; nothing written')
            return
        lock = parse_lock(*at.command('AT+GTLOCKCAR?'))
        profile = parse_profile(*at.command('AT+GTCURCAR?'))
        if lock is None or profile is None:
            save_marker(key, 'read-failed', **base)
            log(4, f'{port}: no clear answer to AT+GTLOCKCAR? / AT+GTCURCAR?; nothing written')
            return
        seen = dict(lock=lock_text(lock), profile=profile[0])
        record = load_record(unit)
        if verify_only:
            phase = 'unlocked-by-service' if lock == UNLOCKED else 'failed'
            save_marker(key, phase, **base, **seen)
            save_record(unit, port, dict(seen, plmn=base['plmn'], outcome=phase), status=phase, plmn=base['plmn'], **seen)
            if lock == UNLOCKED:
                log(6, f'{port}: after the restart the lock reads {seen["lock"]}, profile {profile[0]} '
                       f'"{profile[1]}"; done')
            else:
                log(4, f'{port}: after the restart the lock reads {seen["lock"]}; recorded as failed, '
                       'not tried again')
            return
        if lock == UNLOCKED:
            confirmed = record.get('status') == 'unlocked-by-service'
            save_marker(key, 'unlocked', **base, **seen)
            save_record(unit, port, dict(seen, plmn=base['plmn'], outcome='unlocked'), status='unlocked',
                        original_lock=seen['lock'], original_profile=profile[0], plmn=base['plmn'], **seen)
            log(6, f'{port}: unlocked (profile {profile[0]} "{profile[1]}" picked from the SIM)'
                   + ('; the unlock held across the restart' if confirmed else '') + '; left alone')
            return
        if lock[0] != '1':
            save_marker(key, 'unexpected-lock', **base, **seen)
            save_record(unit, port, dict(seen, plmn=base['plmn'], outcome='unexpected-lock'),
                        original_lock=seen['lock'], original_profile=profile[0])
            log(4, f'{port}: lock reads {seen["lock"]}, which is neither unlocked nor a lock; nothing written')
            return
        returned = record.get('status') in ('unlocked', 'unlocked-by-service') or record.get('lock_returned')
        unlock(port, device_dir, key, at, base, lock, profile, seen, returned)
    finally:
        at.close()


def unlock(port, device_dir, key, at, base, lock, profile, seen, returned):
    unit = base['unit']
    old = dict(old_lock=lock_text(lock), old_profile=profile[0])
    reason = holding_back()
    if reason:
        marker_path(key).unlink(missing_ok=True)
        log(6, f'{port}: locked to {old["old_lock"]}, but {reason}; nothing written, released')
        return
    radio = parse_radio(*at.command('AT+CFUN?'))
    if radio not in ('1', '4'):
        save_marker(key, 'radio-unexpected', **base, **old, radio=radio)
        log(4, f'{port}: AT+CFUN? read {radio or "nothing clear"}, not 1 or 4; nothing written')
        return
    extra = dict(lock_returned=True) if returned else {}
    if returned:
        log(4, f'{port}: locked to {old["old_lock"]} again after an earlier unlock; unlocking again and '
               'reading this unit on every boot from now on')
    log(6, f'{port}: locked to {old["old_lock"]} (profile {profile[0]} "{profile[1]}"); unlocking '
           f'so the profile follows the SIM ({base["plmn"]}), old value recorded')
    save_marker(key, 'unlocking', **base, **old, radio=radio)
    save_record(unit, port, dict(seen, plmn=base['plmn'], outcome='unlocking'), status='unlocking',
                original_lock=old['old_lock'], original_profile=profile[0], plmn=base['plmn'], **seen, **extra)
    if radio == '1':
        final, _ = at.command('AT+CFUN=4', timeout=LOCK_TIMEOUT)
        after = parse_radio(*at.command('AT+CFUN?')) if final == 'OK' else None
        if after != '4':
            put_radio_back(port, at, radio)
            save_marker(key, 'radio-off-failed', **base, **old, reply=final)
            save_record(unit, port, dict(seen, plmn=base['plmn'], outcome='radio-off-failed'), status='radio-off-failed')
            log(4, f'{port}: AT+CFUN=4 answered {final or "nothing"}, radio reads {after}; nothing written')
            return
    final, _ = at.command('AT+GTLOCKCAR=0', timeout=LOCK_TIMEOUT)
    if final is not None and final != 'OK':
        put_radio_back(port, at, radio)
        save_marker(key, 'unlock-refused', **base, **old, reply=final)
        save_record(unit, port, dict(seen, plmn=base['plmn'], outcome='unlock-refused', reply=final), status='unlock-refused')
        log(4, f'{port}: AT+GTLOCKCAR=0 answered {final}; the lock stays {old["old_lock"]}, not tried again')
        return
    new_lock = parse_lock(*at.command('AT+GTLOCKCAR?')) if final == 'OK' else None
    new_profile = parse_profile(*at.command('AT+GTCURCAR?')) if new_lock else None
    if new_lock is None or new_profile is None:
        if left(device_dir):
            save_marker(key, 'restarted', **base, **old, write=final)
            save_record(unit, port, dict(seen, plmn=base['plmn'], outcome='restarted', write=final), status='restarted')
            log(6, f'{port}: the module restarted on AT+GTLOCKCAR=0 (answer: {final or "none"}); '
                   'its return reads the lock back')
            return
        put_radio_back(port, at, radio)
        save_marker(key, 'failed', **base, **old, write=final)
        save_record(unit, port, dict(seen, plmn=base['plmn'], outcome='failed', write=final), status='failed')
        log(4, f'{port}: no clear answer after AT+GTLOCKCAR=0 ({final or "none"}) and the module did '
               'not restart; recorded as failed, not tried again')
        return
    new = dict(lock=lock_text(new_lock), profile=new_profile[0])
    if new_lock != UNLOCKED:
        put_radio_back(port, at, radio)
        save_marker(key, 'failed', **base, **old, **new)
        save_record(unit, port, dict(seen, plmn=base['plmn'], outcome='failed', **new), status='failed', **new)
        log(4, f'{port}: after AT+GTLOCKCAR=0 the lock reads {new["lock"]}; recorded as failed, not tried again')
        return
    phase = 'unlocked-by-service'
    if not put_radio_back(port, at, radio):
        phase = 'restarted' if left(device_dir) else 'radio-not-back'
    save_marker(key, phase, **base, **old, **new)
    save_record(unit, port, dict(seen, plmn=base['plmn'], outcome=phase, **new),
                status='unlocked-by-service' if phase == 'restarted' else phase, **new)
    if phase == 'radio-not-back':
        log(3, f'{port}: unlocked ({old["old_lock"]} -> {new["lock"]}), but AT+CFUN=1 failed; '
               'the radio stays off until the module restarts')
    else:
        log(6, f'{port}: unlocked ({old["old_lock"]} -> {new["lock"]}), profile {profile[0]} -> '
               f'{new["profile"]} "{new_profile[1]}"' + ('; the module then restarted' if phase != 'unlocked-by-service' else ''))


def put_radio_back(port, at, radio):
    """Switch the radio on again if it was on before; True when it is as found."""
    if radio != '1':
        return True
    final, _ = at.command('AT+CFUN=1', timeout=LOCK_TIMEOUT)
    if final != 'OK':
        log(4, f'{port}: AT+CFUN=1 answered {final or "nothing"}')
        return False
    return True


def left(device_dir):
    """True when the USB device drops off within LEAVE_WAIT (the module restarting)."""
    deadline = time.monotonic() + min(LEAVE_WAIT, max(0.0, remaining()))
    while time.monotonic() < deadline:
        if not device_dir.exists():
            return True
        time.sleep(0.1)
    return not device_dir.exists()


def main(argv):
    if len(argv) != 2 or not KERNEL_NAME.fullmatch(argv[1]):
        print(f'usage: {TAG} <usb device kernel name, e.g. 10-1.4>', file=sys.stderr)
        return 2
    return run(argv[1])


if __name__ == '__main__':
    sys.exit(main(sys.argv))

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
module restart has not been measured.

Off by default: the service acts only while
/data/ceralive/modem-carrierlock.enabled exists (DEFAULT_ENABLED flips that
once a hardware run has shown the unlock path), and never while
/data/ceralive/modem-carrierlock.disabled exists.

udev starts one instance of ceralive-modem-carrierlock@<usb device>.service for
every 0e8d:7127 device that is added (coldplug at boot included). This script
then, for that one device:

  1. Holds back while it is off (above), while a stream runs (an srtla_send
     process) and while /data/ceralive is missing or not writable (the switch
     files and the records live there). The switches and the stream are
     checked again before ModemManager is asked to hold the modem, before the
     radio is switched off and before the unlock; so is the hold itself.
  2. Waits for ModemManager to list the modem (matched by its physical device)
     with a SIM, and accepts only the models in MODELS on the firmware in
     FIRMWARE. It unlocks only for a
     SIM whose home network is in QUALIFIED, the carriers whose profile an
     unlocked FM350-GL has been measured to select and connect on (AT&T 201,
     T-Mobile 203). A Verizon SIM is left alone: an unlocked unit selects the
     Verizon profile, and this firmware crash-loops with a Verizon SIM. Every
     other SIM is left alone too.
  3. Acts once per unit and SIM per boot (a marker in /run). Holding a modem
     makes ModemManager drop it and probe it again, so a unit is not held
     while its record shows it unlocked, read on a host boot after any unlock
     by this service, within the last RECHECK_DAYS. Nothing on the image locks
     a unit; `touch /data/ceralive/modem-carrierlock.retry` forgets every
     unit's recorded lock, last outcome and unlock count once (the first
     recorded values, the history and a "lock returned" mark stay).
  4. Takes the modem from ModemManager with `mmcli --inhibit-device` for the
     whole exchange (ModemManager's polling otherwise takes answers on the
     same port), then talks to ModemManager's `(at)` port on USB interface 6.
  5. Checks AT+CIMI against ModemManager's IMSI and reads AT+GTLOCKCAR? and
     AT+GTCURCAR?. Unlocked: recorded, left alone. Locked (`1,<id>`):
     AT+CFUN? (1 or 4 only), AT+CFUN=4 if the radio was on, AT+GTLOCKCAR=0,
     read both back (the lock must read `0,65535`), then AT+CFUN=1 if the
     radio was on, confirmed by AT+CFUN? reading 1. No lock is ever written. A
     radio this run switched off and could not switch on again is an error,
     and the unit is left alone after. The attempt is counted in /data before
     anything is sent; an answer that stops a run is counted too, and after
     MAX_MISREADS in a row the unit is left alone.
  6. If the module restarts on the unlock (the port goes silent and the USB
     device leaves), the run records `restarted` with the radio state it found
     and exits at once, before the module is back (it takes seconds to boot),
     so the instance started by its return is a new run (the module also
     switches its own radio on a few seconds into every boot). That run reads the
     lock back, writes nothing, switches the radio on if it was on before and
     the module left it off, and records the outcome. A unit whose unlock was
     refused or did not take is left alone on later boots until the retry
     file is used. A unit found locked again after an unlock is unlocked
     again (once per boot), read on every boot from then on, and left alone
     after MAX_UNLOCKS unlocks.

Any answer that doesn't match what was measured ends the run with nothing
(more) written, the radio put back and the modem released.

The unit id in /data is HMAC-SHA256(machine-id, IMEI) truncated to 16 hex
digits; the SIM is recorded only by its home PLMN, never by its IMSI.

Undo: the unit's original lock is in its record. Create the .disabled file,
hold the modem with `mmcli --inhibit-device=<uid>`, then on the AT port
AT+CFUN=4, AT+GTLOCKCAR=1,<id>, AT+CFUN=1.

Test seams (production uses every default):
  CERALIVE_CARRIERLOCK_SYSFS          sysfs root (default /sys)
  CERALIVE_CARRIERLOCK_DEV            device node dir (default /dev)
  CERALIVE_CARRIERLOCK_PROC           procfs root (default /proc)
  CERALIVE_CARRIERLOCK_RUN            volatile markers (default /run/ceralive/modem-carrierlock)
  CERALIVE_CARRIERLOCK_DATA           persistent records (default /data/ceralive/modem-carrierlock)
  CERALIVE_CARRIERLOCK_MACHINE_ID     HMAC key file (default /etc/machine-id)
  CERALIVE_CARRIERLOCK_BOOT_ID        host boot id file (default /proc/sys/kernel/random/boot_id)
  CERALIVE_CARRIERLOCK_MMCLI          mmcli binary (default mmcli)
  CERALIVE_CARRIERLOCK_BUDGET         seconds for the whole run (default 270)
  CERALIVE_CARRIERLOCK_MM_WAIT        seconds to wait for ModemManager and the SIM (default 120)
  CERALIVE_CARRIERLOCK_POLL           poll interval seconds (default 2)
  CERALIVE_CARRIERLOCK_AT_TIMEOUT     seconds per AT command (default 3)
  CERALIVE_CARRIERLOCK_LOCK_TIMEOUT   seconds for the radio and unlock commands (default 10)
  CERALIVE_CARRIERLOCK_PORT_WAIT      seconds for ModemManager to let go of the port (default 10)
  CERALIVE_CARRIERLOCK_LEAVE_WAIT     seconds for a restarting module to drop off (default 15)
  CERALIVE_CARRIERLOCK_RECHECK_DAYS   days a recorded unlock is trusted without a read (default 7)
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
# Firmware the lock and unlock answers were recorded on (ModemManager's
# revision string). Any other firmware is left alone.
FIRMWARE = {'81600.0000.00.29.18.01'}
# ModemManager's 77-mm-fm350gl.rules types interface 06 as the primary AT port
# of 0e8d:7127 and ignores every other tty; the lock answers were recorded there.
AT_INTERFACE = '06'
# Home PLMN -> (carrier, the Fibocom profile an unlocked unit selects). The
# PLMN rows are CeraUI's carrier table
# (apps/backend/src/modules/modems/subscription-policy.ts, CARRIER_POLICIES:
# ATT, TMO and the "verizon" row); the profile ids are Fibocom's (FM350 AT
# manual V2.10 §22). Unlocked FM350-GLs were measured selecting 201 with an
# AT&T SIM and 203 with a T-Mobile SIM and connecting on both.
QUALIFIED = {
    '310280': ('AT&T', '201'),
    '310410': ('AT&T', '201'),
    '310240': ('T-Mobile', '203'),
    '310260': ('T-Mobile', '203'),
}
VERIZON = {'310590', '310890', '311270', '311480', '312770'}
UNLOCKED = ('0', '65535')
MAX_UNLOCKS = 3
MAX_MISREADS = 3
# Outcomes that leave a unit alone on later boots until the retry file is used.
GIVE_UP = {'unlock-refused', 'failed', 'radio-off-failed', 'radio-not-back', 'lock-keeps-returning',
           'unreadable'}
STREAM_PROCESSES = {'srtla_send'}
KERNEL_NAME = re.compile(r'\d+-\d+(\.\d+)*')
DEFAULT_ENABLED = False

SYSFS = Path(os.environ.get('CERALIVE_CARRIERLOCK_SYSFS', '/sys'))
DEV = Path(os.environ.get('CERALIVE_CARRIERLOCK_DEV', '/dev'))
PROC = Path(os.environ.get('CERALIVE_CARRIERLOCK_PROC', '/proc'))
RUN = Path(os.environ.get('CERALIVE_CARRIERLOCK_RUN', '/run/ceralive/modem-carrierlock'))
DATA = Path(os.environ.get('CERALIVE_CARRIERLOCK_DATA', '/data/ceralive/modem-carrierlock'))
ENABLED = DATA.parent / 'modem-carrierlock.enabled'
DISABLED = DATA.parent / 'modem-carrierlock.disabled'
RETRY = DATA.parent / 'modem-carrierlock.retry'
MACHINE_ID = Path(os.environ.get('CERALIVE_CARRIERLOCK_MACHINE_ID', '/etc/machine-id'))
BOOT_ID = Path(os.environ.get('CERALIVE_CARRIERLOCK_BOOT_ID', '/proc/sys/kernel/random/boot_id'))
MMCLI = os.environ.get('CERALIVE_CARRIERLOCK_MMCLI', 'mmcli')
BUDGET = float(os.environ.get('CERALIVE_CARRIERLOCK_BUDGET', '270'))
MM_WAIT = float(os.environ.get('CERALIVE_CARRIERLOCK_MM_WAIT', '120'))
POLL = float(os.environ.get('CERALIVE_CARRIERLOCK_POLL', '2'))
AT_TIMEOUT = float(os.environ.get('CERALIVE_CARRIERLOCK_AT_TIMEOUT', '3'))
LOCK_TIMEOUT = float(os.environ.get('CERALIVE_CARRIERLOCK_LOCK_TIMEOUT', '10'))
PORT_WAIT = float(os.environ.get('CERALIVE_CARRIERLOCK_PORT_WAIT', '10'))
LEAVE_WAIT = float(os.environ.get('CERALIVE_CARRIERLOCK_LEAVE_WAIT', '15'))
RECHECK_DAYS = float(os.environ.get('CERALIVE_CARRIERLOCK_RECHECK_DAYS', '7'))
DEADLINE = time.monotonic() + BUDGET
HISTORY = 20


def remaining():
    return DEADLINE - time.monotonic()


class Stopped(Exception):
    """SIGTERM (systemd stopping the unit or its start timeout) as an exception,
    so a radio this run switched off is switched on again on the way out."""


def stop(signum, _frame):
    raise Stopped(signal.Signals(signum).name)


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
        return False
    return True


def honour_retry():
    """`touch /data/ceralive/modem-carrierlock.retry` forgets every unit's
    recorded lock, last outcome and unlock count, so each unit is read (and if
    needed unlocked) once more. The original values, the history and the
    `lock_returned` mark (read on every boot) stay."""
    if not RETRY.exists():
        return
    cleared = 0
    for path in sorted(DATA.glob('*.json')) if DATA.is_dir() else []:
        try:
            record = json.loads(path.read_text())
            changed = [record.pop(name, None) for name in ('status', 'lock', 'profile', 'plmn', 'checked', 'unlocks',
                                                          'misreads')]
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
        name = read(entry / 'comm')
        if name in STREAM_PROCESSES:
            return name
    return None


def holding_back():
    """Why this run must not go on right now, or None."""
    if DISABLED.exists():
        return f'{DISABLED} exists'
    if not DEFAULT_ENABLED and not ENABLED.exists():
        return f'off by default (touch {ENABLED} to turn it on)'
    stream = streaming()
    if stream:
        return f'a stream is running ({stream})'
    return None


def writable_data():
    """The records and the switch files live in /data/ceralive: no change
    without it (a /data not mounted yet would hide the kill switch)."""
    if not DATA.parent.is_dir() or not os.access(DATA.parent, os.W_OK | os.X_OK):
        return False
    try:
        DATA.mkdir(exist_ok=True)
    except OSError:
        return False
    return os.access(DATA, os.W_OK | os.X_OK)


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

def trusted(record):
    """True when the record alone shows the unit unlocked (no hold needed)."""
    if record.get('status') != 'unlocked' or record.get('lock_returned'):
        return False
    checked = record.get('checked')
    return isinstance(checked, (int, float)) and 0 <= time.time() - checked < RECHECK_DAYS * 86400


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
    if not writable_data():
        log(4, f'{port}: {DATA.parent} is missing or not writable (its switch files and records live '
               'there); leaving it alone')
        return 0
    reason = holding_back()
    if reason:
        log(6, f'{port}: {reason}; leaving it alone')
        return 0
    honour_retry()

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
    if modem['revision'] not in FIRMWARE:
        log(6, f'{port}: firmware "{modem["revision"]}" is not one the unlock was measured on '
               f'({", ".join(sorted(FIRMWARE))}); leaving it alone')
        return 0
    if modem['imsi'] is None:
        log(6, f'{port}: ModemManager reports no readable SIM; leaving the lock as it is')
        return 0
    plmn = modem['imsi'][:6]
    if plmn in VERIZON:
        log(4, f'{port}: Verizon SIM ({plmn}): an unlocked unit would select the Verizon profile, which '
               'crash-loops on this firmware; leaving the lock as it is')
        return 0
    if plmn not in QUALIFIED:
        log(6, f'{port}: SIM home network {plmn} is not one an unlocked FM350-GL has been measured on '
               '(AT&T, T-Mobile); leaving the lock as it is')
        return 0
    carrier, expected = QUALIFIED[plmn]
    unit, sim = keyed_hmac(modem['equipment']), keyed_hmac(modem['imsi'])
    if not unit or not sim:
        log(4, f'{port}: no IMEI or machine-id, so this run could not be kept to once per unit; leaving it alone')
        return 0
    key = f'{unit}-{sim[:8]}'
    base = dict(unit=unit, plmn=plmn, carrier=carrier, expected=expected, model=modem['model'],
                revision=modem['revision'])

    marker = load_marker(key)
    restart = None
    if marker and marker.get('phase') == 'restarted':
        restart = marker
        log(6, f'{port}: back after the module restarted during the unlock; reading the lock, writing nothing')
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
        if trusted(record):
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
    save_marker(key, 'verifying' if restart else 'attempting', **base,
                **({'radio': restart.get('radio')} if restart else {}))
    reason = holding_back()
    if reason:
        if restart:
            atomic_json(marker_path(key), restart)
        else:
            marker_path(key).unlink(missing_ok=True)
        log(6, f'{port}: {reason} now; not asking ModemManager, checking again at the next appearance or boot')
        return 0
    hold = Hold(modem['uid'])
    if not hold.held:
        settle(key, restart, 'inhibit-failed', **base, reason=hold.reason)
        log(4, f'{port}: ModemManager would not release the modem ({hold.reason}); leaving it alone this boot')
        return 0
    try:
        exchange(port, device_dir, key, candidates, base, modem['imsi'], hold, restart)
    finally:
        hold.release()
    return 0


def settle(key, restart, phase, **fields):
    """Mark the end of a run that did not get to read the unit. A pending
    check after a restart stays pending, so a later appearance still makes it."""
    if restart:
        atomic_json(marker_path(key), dict(restart, last=phase))
    else:
        save_marker(key, phase, **fields)


def misread(unit, port, key, base, restart, phase, message):
    """An answer that stops the run before any change. Counted: after
    MAX_MISREADS in a row the unit is left alone until the retry file."""
    count = load_record(unit).get('misreads', 0)
    count = (count if isinstance(count, int) else 0) + 1
    status = {'status': 'unreadable'} if count >= MAX_MISREADS else {}
    settle(key, restart, phase, **base)
    save_record(unit, port, dict(outcome=phase), misreads=count, **status)
    log(4, f'{port}: {message}' + (f'; {count} in a row, left alone from now on (touch {RETRY} to try '
                                   'once more)' if status else ''))


def open_port(candidates):
    deadline = time.monotonic() + PORT_WAIT
    while time.monotonic() < deadline:
        for tty in candidates:
            path = DEV / tty
            if path.exists() and not holders(path):
                return path
        time.sleep(min(POLL, 0.5))
    return None


class Run:
    """One exchange with one unit under the hold."""

    def __init__(self, port, device_dir, key, base, at, hold):
        self.port, self.device_dir, self.key, self.base = port, device_dir, key, base
        self.unit, self.at, self.hold = base['unit'], at, hold
        self.seen, self.old, self.radio = {}, {}, None

    def marker(self, phase, **fields):
        save_marker(self.key, phase, **self.base, **self.old, **fields)

    def record(self, outcome, status=None, **fields):
        event = dict(self.seen, plmn=self.base['plmn'], outcome=outcome)
        event.update({k: v for k, v in fields.items() if k in ('lock', 'profile', 'reply', 'write')})
        return save_record(self.unit, self.port, event, **({'status': status} if status else {}), **fields)

    def interrupted(self):
        """Why the unlock must not go on, or None: the switches, a stream, the hold."""
        return holding_back() or (None if self.hold.held else 'the ModemManager hold ended')

    def radio_back(self):
        """Switch the radio on again if this run found it on; True when it is as found."""
        return put_radio_back(self.port, self.at, self.radio)

    def fail(self, phase, message, **fields):
        """Stop after the radio went off: put it back, record, never try again
        (`interrupted` aside, which may be tried at the next boot)."""
        status = phase if self.radio_back() else 'radio-not-back'
        self.marker(status, **fields)
        self.record(status, status=status, **fields)
        log(4, f'{self.port}: {message}')
        if status == 'radio-not-back':
            log(3, f'{self.port}: AT+CFUN=1 failed; the radio stays off until the module restarts')


def exchange(port, device_dir, key, candidates, base, imsi, hold, restart):
    """The AT part, under the hold."""
    unit = base['unit']
    node = open_port(candidates)
    if node is None:
        settle(key, restart, 'port-busy', **base)
        log(4, f'{port}: no free AT port among {", ".join(candidates)} while held; leaving it alone this boot')
        return
    try:
        at = AtPort(node)
    except OSError as error:
        settle(key, restart, 'port-failed', **base, reason=str(error))
        log(4, f'{port}: cannot open {node.name} ({error}); leaving it alone this boot')
        return
    try:
        if parse_imsi(*at.command('AT+CIMI')) != imsi:
            misread(unit, port, key, base, restart, 'sim-mismatch',
                    'AT+CIMI does not match the SIM ModemManager reported; nothing written')
            return
        lock = parse_lock(*at.command('AT+GTLOCKCAR?'))
        profile = parse_profile(*at.command('AT+GTCURCAR?'))
        if lock is None or profile is None:
            misread(unit, port, key, base, restart, 'read-failed',
                    'no clear answer to AT+GTLOCKCAR? / AT+GTCURCAR?; nothing written')
            return
        job = Run(port, device_dir, key, base, at, hold)
        job.seen = dict(lock=lock_text(lock), profile=profile[0])
        seen = dict(job.seen, plmn=base['plmn'], checked=int(time.time()), misreads=0)
        record = load_record(unit)
        boot = read(BOOT_ID)
        if restart:
            verify(job, restart, lock, profile, seen, boot)
            return
        if lock == UNLOCKED:
            same_boot = record.get('status') == 'unlocked-by-service' and record.get('unlocked_boot') == boot
            status = 'unlocked-by-service' if same_boot else 'unlocked'
            job.marker('unlocked', **job.seen)
            job.record('unlocked', status=status, original_lock=job.seen['lock'],
                       original_profile=profile[0], **seen)
            if same_boot:
                note = '; unlocked earlier this boot, so read again on a later boot'
            elif record.get('status') == 'unlocked-by-service':
                note = '; the unlock held across a restart'
            else:
                note = ''
            log(6, f'{port}: unlocked (profile {profile[0]} "{profile[1]}" picked from the SIM){note}; left alone')
            return
        if lock[0] != '1':
            misread(unit, port, key, base, None, 'unexpected-lock',
                    f'lock reads {job.seen["lock"]}, which is neither unlocked nor a lock; nothing written')
            return
        returned = record.get('status') in ('unlocked', 'unlocked-by-service') or bool(record.get('lock_returned'))
        unlocks = record.get('unlocks', 0) if isinstance(record.get('unlocks'), int) else 0
        if unlocks >= MAX_UNLOCKS:
            job.marker('lock-keeps-returning', **job.seen)
            job.record('lock-keeps-returning', status='lock-keeps-returning', lock_returned=True, **seen)
            log(4, f'{port}: locked to {job.seen["lock"]} after {unlocks} unlocks; leaving it alone '
                   f'(touch {RETRY} to try once more)')
            return
        unlock(job, lock, profile, seen, returned, unlocks, boot)
    finally:
        at.close()


def verify(job, restart, lock, profile, seen, boot):
    """After a restart during the unlock: read only; the radio back on if this
    unit's radio was on before and the module left it off."""
    port = job.port
    job.radio = restart.get('radio')
    phase = 'unlocked-by-service' if lock == UNLOCKED else 'failed'
    if job.radio == '1':
        now = parse_radio(*job.at.command('AT+CFUN?'))
        if now == '4':
            log(6, f'{port}: the radio was on before the unlock and is off after the restart; switching it on')
            if not job.radio_back():
                phase = 'radio-not-back'
        elif now != '1':
            phase = 'radio-not-back'
    fields = dict(seen, unlocked_boot=boot) if phase == 'unlocked-by-service' else seen
    job.marker(phase, **job.seen)
    job.record(phase, status=phase, **fields)
    if phase == 'unlocked-by-service':
        log(6, f'{port}: after the restart the lock reads {job.seen["lock"]}, profile {profile[0]} '
               f'"{profile[1]}"; done')
    elif phase == 'radio-not-back':
        log(3, f'{port}: after the restart the lock reads {job.seen["lock"]}, but the radio is off and '
               'would not switch on; left alone from now on')
    else:
        log(4, f'{port}: after the restart the lock reads {job.seen["lock"]}; recorded as failed, '
               'not tried again')


def unlock(job, lock, profile, seen, returned, unlocks, boot):
    port, at = job.port, job.at
    job.old = dict(old_lock=lock_text(lock), old_profile=profile[0])
    # Radio off, unlock and both read-backs at their longest, plus the radio
    # back on and a restart watch: never start what the budget can't finish.
    needed = 5 * LOCK_TIMEOUT + LEAVE_WAIT
    if remaining() < needed:
        job.marker('no-time')
        log(4, f'{port}: {remaining():.0f} s left of the run budget, {needed:g} s needed; nothing written')
        return
    reason = job.interrupted()
    if reason:
        marker_path(job.key).unlink(missing_ok=True)
        log(6, f'{port}: locked to {job.old["old_lock"]}, but {reason}; nothing written, released')
        return
    job.radio = parse_radio(*at.command('AT+CFUN?'))
    if job.radio not in ('1', '4'):
        misread(job.unit, port, job.key, job.base, None, 'radio-unexpected',
                f'AT+CFUN? read {job.radio or "nothing clear"}, not 1 or 4; nothing written')
        return
    reason = job.interrupted()
    if reason:
        marker_path(job.key).unlink(missing_ok=True)
        log(6, f'{port}: locked to {job.old["old_lock"]}, but {reason}; nothing written, released')
        return
    if returned:
        log(4, f'{port}: locked to {job.old["old_lock"]} again after an earlier unlock; unlocking again and '
               'reading this unit on every boot from now on')
    log(6, f'{port}: locked to {job.old["old_lock"]} (profile {profile[0]} "{profile[1]}") with a '
           f'{job.base["carrier"]} SIM ({job.base["plmn"]}); unlocking, old value recorded')
    job.marker('unlocking', radio=job.radio)
    # The attempt is counted on disk before anything is sent; without that
    # record the unlock cap could not hold, so no record means no unlock.
    if not job.record('unlocking', status='unlocking', original_lock=job.old['old_lock'],
                      original_profile=profile[0], unlocks=unlocks + 1,
                      **({'lock_returned': True} if returned else {}), **seen):
        job.marker('no-record')
        log(4, f'{port}: the attempt could not be recorded; nothing written')
        return
    try:
        unlock_steps(job, boot)
    except Stopped as signal_name:
        ok = job.radio_back()
        job.marker('stopped' if ok else 'radio-not-back', radio=job.radio)
        job.record('stopped', status=None if ok else 'radio-not-back')
        log(4, f'{port}: stopped ({signal_name}) during the unlock; '
               + ('radio put back as found' if ok else 'AT+CFUN=1 failed, the radio stays off'))
        raise


def unlock_steps(job, boot):
    port, at = job.port, job.at
    if job.radio == '1':
        final, _ = at.command('AT+CFUN=4', timeout=LOCK_TIMEOUT)
        after = parse_radio(*at.command('AT+CFUN?')) if final == 'OK' else None
        if after != '4':
            job.fail('radio-off-failed', f'AT+CFUN=4 answered {final or "nothing"}, radio reads {after}; '
                     'nothing written', reply=final)
            return
    reason = job.interrupted()
    if reason:
        ok = job.radio_back()
        status = 'interrupted' if ok else 'radio-not-back'
        job.marker(status)
        job.record(status, status=status)
        log(4 if ok else 3, f'{port}: {reason} with the radio off; nothing written, '
            + ('radio put back as found' if ok else 'AT+CFUN=1 failed, the radio stays off'))
        return
    final, _ = at.command('AT+GTLOCKCAR=0', timeout=LOCK_TIMEOUT)
    if final is not None and final != 'OK':
        job.fail('unlock-refused', f'AT+GTLOCKCAR=0 answered {final}; the lock stays {job.old["old_lock"]}, '
                 'not tried again', reply=final)
        return
    new_lock = parse_lock(*at.command('AT+GTLOCKCAR?')) if final == 'OK' else None
    new_profile = parse_profile(*at.command('AT+GTCURCAR?')) if new_lock else None
    if new_lock is None or new_profile is None:
        if left(job.device_dir):
            job.marker('restarted', radio=job.radio, write=final)
            job.record('restarted', status='restarted', write=final)
            log(6, f'{port}: the module restarted on AT+GTLOCKCAR=0 (answer: {final or "none"}); '
                   'its return reads the lock back')
            return
        job.fail('failed', f'no clear answer after AT+GTLOCKCAR=0 ({final or "none"}) and the module did '
                 'not restart; recorded as failed, not tried again', write=final)
        return
    new = dict(lock=lock_text(new_lock), profile=new_profile[0])
    if new_lock != UNLOCKED:
        job.fail('failed', f'after AT+GTLOCKCAR=0 the lock reads {new["lock"]}; recorded as failed, '
                 'not tried again', **new)
        return
    if new_profile[0] == '101':
        log(4, f'{port}: right after the unlock the profile still reads 101 (Verizon); a '
               f'{job.base["carrier"]} SIM should select {job.base["expected"]} once the radio is on')
    if job.radio_back():
        job.marker('unlocked-by-service', **new)
        job.record('unlocked-by-service', status='unlocked-by-service', unlocked_boot=boot, **new)
        log(6, f'{port}: unlocked ({job.old["old_lock"]} -> {new["lock"]}), profile {job.old["old_profile"]} '
               f'-> {new["profile"]} "{new_profile[1]}" (a {job.base["carrier"]} SIM selects '
               f'{job.base["expected"]} once the radio is on)')
    elif left(job.device_dir):
        job.marker('restarted', radio=job.radio, **new)
        job.record('restarted', status='unlocked-by-service', unlocked_boot=boot, **new)
        log(6, f'{port}: unlocked ({job.old["old_lock"]} -> {new["lock"]}); the module then restarted, its '
               'return checks the radio')
    else:
        job.marker('radio-not-back', **new)
        job.record('radio-not-back', status='radio-not-back', **new)
        log(3, f'{port}: unlocked ({job.old["old_lock"]} -> {new["lock"]}), but AT+CFUN=1 failed; '
               'the radio stays off until the module restarts')


def put_radio_back(port, at, radio):
    """Switch the radio on again if it was on before; True when it is as found."""
    if radio != '1':
        return True
    final, _ = at.command('AT+CFUN=1', timeout=LOCK_TIMEOUT)
    if final != 'OK':
        log(4, f'{port}: AT+CFUN=1 answered {final or "nothing"}')
        return False
    now = parse_radio(*at.command('AT+CFUN?'))
    if now != '1':
        log(4, f'{port}: AT+CFUN=1 answered OK, but AT+CFUN? reads {now or "nothing clear"}')
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
    signal.signal(signal.SIGTERM, stop)
    try:
        return run(argv[1])
    except Stopped:
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))

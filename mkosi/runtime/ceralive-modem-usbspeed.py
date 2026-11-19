#!/usr/bin/python3
"""Keep Quectel RM520N modems on USB 2: AT+QCFG="usbspeed","20", once per boot.

Why: an RM520N's own USB 3 link raises its receiver's noise floor. Measured on
two units, at unchanged RSRP: about 5 dB of S/N on LTE B1 and on the 5G leg at
strong signal, and about 14 dB on one weak cell. A bonded uplink never needs
more than USB 2 (480 Mbit/s). The module stores the setting in its own NV
memory, so whatever a unit carried in from the factory or a previous host is
what it uses on any port. Nothing else on the image sets it.

udev starts one instance of ceralive-modem-usbspeed@<usb device>.service for
every 2c7c:0801 device that is added (coldplug at boot included). This script
then, for that one device:

  1. Reads the link speed from sysfs. At 480 Mbit/s or slower the module is
     already on USB 2 (or the port only offers USB 2): nothing is done, no
     ModemManager hold, no AT command.
  2. Holds back while a stream runs (an srtla_send process, CeraLive's bonding
     sender, which runs exactly while a stream is live) and while
     /data/ceralive/modem-usbspeed.disabled exists. Both are checked again
     right before ModemManager is asked to hold the modem, before the write and
     before the reset; a stream that starts in between ends the attempt with
     the modem released and nothing (more) sent.
  3. Waits for ModemManager to list the modem (matched by its physical device,
     so slot names from ID_MM_PHYSDEV_UID don't hide it) and accepts only the
     models in MODELS (2c7c:0801 is shared with the RM530N-GL, not verified).
  4. Acts once per USB port and once per unit per boot: a marker in /run is
     written before ModemManager is asked for anything and again before the
     reset. A unit whose earlier attempt did not bring it to USB 2 is recorded
     as failed in /data and left alone on later boots;
     `touch /data/ceralive/modem-usbspeed.retry` clears those outcomes (the
     recorded original values stay) so each unit is tried once more.
  5. Takes the modem from ModemManager with `mmcli --inhibit-device` (held for
     the whole exchange; ModemManager closes all its ports, the secondary AT
     port included, and re-probes when the hold ends), then talks to one AT
     port that ModemManager had listed as "(at)" for this device and that no
     process holds open.
  6. Reads AT+QCFG="usbspeed". If it is not "20", records the old value
     (journal, /run marker and /data/ceralive/modem-usbspeed/<unit>.json),
     writes "20" and reads it back; a mismatch stops before any reset. Then
     AT+CFUN=1,1 restarts the module (back on USB in roughly 13-24 s, data in
     about a minute). A stored "20" with a fast link means the value was never
     applied, so the module is reset once without a write.
  7. Releases the hold and watches the module leave and come back. A module
     that returns at 480 Mbit/s usually lands on the controller's High Speed
     bus under another kernel name (4-1 -> 1-1), so it is recognised by the
     USB port's peer link, or as the only unclaimed new 2c7c:0801 while no
     other reset is in flight. Verified, still fast, never left, never back or
     unattributed (two resets at once, return on no known socket; not a
     failure): each is one journal line.

The unit id in /data is HMAC-SHA256(machine-id, IMEI) truncated to 16 hex
digits: stable on this box, not reversible from the file alone.

Restore by hand: AT+QCFG="usbspeed","<original>" and AT+CFUN=1,1 on the AT
port, with ModemManager held off (mmcli --inhibit-device), after creating the
.disabled file so this service leaves the unit alone.

Test seams (production uses every default):
  CERALIVE_USBSPEED_SYSFS       sysfs root (default /sys)
  CERALIVE_USBSPEED_DEV         device node dir (default /dev)
  CERALIVE_USBSPEED_PROC        procfs root (default /proc)
  CERALIVE_USBSPEED_RUN         volatile markers (default /run/ceralive/modem-usbspeed)
  CERALIVE_USBSPEED_DATA        persistent records (default /data/ceralive/modem-usbspeed)
  CERALIVE_USBSPEED_MACHINE_ID  HMAC key file (default /etc/machine-id)
  CERALIVE_USBSPEED_MMCLI       mmcli binary (default mmcli)
  CERALIVE_USBSPEED_BUDGET      seconds for the whole run (default 270)
  CERALIVE_USBSPEED_MM_WAIT     seconds to wait for ModemManager (default 90)
  CERALIVE_USBSPEED_POLL        poll interval seconds (default 2)
  CERALIVE_USBSPEED_AT_TIMEOUT  seconds per AT command (default 3)
  CERALIVE_USBSPEED_PORT_WAIT   seconds for ModemManager to let go of the port (default 10)
  CERALIVE_USBSPEED_LEAVE_WAIT  seconds for the module to drop off after the reset (default 15)
  CERALIVE_USBSPEED_RETURN_WAIT seconds for it to come back (default 60)
"""
import errno
import fcntl
import hashlib
import hmac
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

TAG = 'ceralive-modem-usbspeed'
# USB IDs this quirk may touch. Only 2c7c:0801 is measured; other RM5xx PIDs
# (RM500Q 2c7c:0800, ...) are left alone until a unit has been read on a bench.
USB_IDS = {('2c7c', '0801')}
# ModemManager model strings accepted on those IDs. The RM530N-GL shares
# 2c7c:0801 and is deliberately absent.
MODELS = {'RM520N-GL', 'RM520N-EU'}
DESIRED = '20'
# CeraLive's live-stream process: the backend spawns srtla_send for exactly the
# stream's lifetime (cerastream itself is a daemon that runs while idle too).
STREAM_PROCESSES = {'srtla_send'}
USB2_MAX_MBPS = 480
KERNEL_NAME = re.compile(r'\d+-\d+(\.\d+)*')

SYSFS = Path(os.environ.get('CERALIVE_USBSPEED_SYSFS', '/sys'))
DEV = Path(os.environ.get('CERALIVE_USBSPEED_DEV', '/dev'))
PROC = Path(os.environ.get('CERALIVE_USBSPEED_PROC', '/proc'))
RUN = Path(os.environ.get('CERALIVE_USBSPEED_RUN', '/run/ceralive/modem-usbspeed'))
DATA = Path(os.environ.get('CERALIVE_USBSPEED_DATA', '/data/ceralive/modem-usbspeed'))
DISABLED = DATA.parent / 'modem-usbspeed.disabled'
RETRY = DATA.parent / 'modem-usbspeed.retry'
MACHINE_ID = Path(os.environ.get('CERALIVE_USBSPEED_MACHINE_ID', '/etc/machine-id'))
MMCLI = os.environ.get('CERALIVE_USBSPEED_MMCLI', 'mmcli')
BUDGET = float(os.environ.get('CERALIVE_USBSPEED_BUDGET', '270'))
MM_WAIT = float(os.environ.get('CERALIVE_USBSPEED_MM_WAIT', '90'))
POLL = float(os.environ.get('CERALIVE_USBSPEED_POLL', '2'))
AT_TIMEOUT = float(os.environ.get('CERALIVE_USBSPEED_AT_TIMEOUT', '3'))
PORT_WAIT = float(os.environ.get('CERALIVE_USBSPEED_PORT_WAIT', '10'))
LEAVE_WAIT = float(os.environ.get('CERALIVE_USBSPEED_LEAVE_WAIT', '15'))
RETURN_WAIT = float(os.environ.get('CERALIVE_USBSPEED_RETURN_WAIT', '60'))
DEADLINE = time.monotonic() + BUDGET


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


# --- per-boot markers (/run) and per-unit records (/data) --------------------

def marker_path(port):
    return RUN / f'{port}.json'


def load_marker(port):
    try:
        return json.loads(marker_path(port).read_text())
    except (OSError, ValueError):
        return None


def save_marker(port, phase, **fields):
    data = dict(fields, phase=phase, time=int(time.time()))
    atomic_json(marker_path(port), data)
    return data


def markers():
    """(port, marker) for every marker written this boot."""
    try:
        paths = sorted(RUN.glob('*.json'))
    except OSError:
        return []
    found = []
    for path in paths:
        try:
            found.append((path.stem, json.loads(path.read_text())))
        except (OSError, ValueError):
            continue
    return found


def unit_id(equipment):
    """HMAC-SHA256(machine-id, IMEI)[:16]: stable on this box, not reversible from /data."""
    key = read(MACHINE_ID)
    if not equipment or not key:
        return None
    return hmac.new(key.encode(), equipment.encode(), hashlib.sha256).hexdigest()[:16]


def load_record(unit):
    if not unit:
        return {}
    try:
        return json.loads((DATA / f'{unit}.json').read_text())
    except (OSError, ValueError):
        return {}


def save_record(unit, port, **fields):
    """Merge fields into the unit's record; the first original value is kept."""
    if not unit:
        return
    if not DATA.parent.is_dir():
        log(6, f'{port}: no {DATA.parent}; this result is only in the journal and the /run marker')
        return
    record = load_record(unit)
    if 'original' in record:
        fields.pop('original', None)
    record.update(fields, time=int(time.time()), port=port)
    try:
        atomic_json(DATA / f'{unit}.json', record)
    except OSError as error:
        log(4, f'{port}: could not write the record ({error}); see this journal')


def honour_retry():
    """`touch /data/ceralive/modem-usbspeed.retry` forgets every unit's last
    outcome (so a unit that gave up is tried once more) and keeps each recorded
    original value. The file is consumed."""
    if not RETRY.exists():
        return
    cleared = 0
    for path in sorted(DATA.glob('*.json')) if DATA.is_dir() else []:
        try:
            record = json.loads(path.read_text())
            if record.pop('status', None) is not None:
                atomic_json(path, record)
                cleared += 1
        except (OSError, ValueError):
            continue
    try:
        RETRY.unlink()
    except OSError as error:
        log(4, f'could not remove {RETRY} ({error})')
        return
    log(6, f'{RETRY}: cleared the last outcome of {cleared} unit(s); original values kept')


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


# --- sysfs ------------------------------------------------------------------

def link_speed(device_dir):
    try:
        return int(float(read(Path(device_dir) / 'speed') or ''))
    except ValueError:
        return None


def rm520_devices():
    """Kernel names of every 2c7c:0801 USB device present now."""
    names = set()
    try:
        entries = list((SYSFS / 'bus/usb/devices').iterdir())
    except OSError:
        return names
    for entry in entries:
        if KERNEL_NAME.fullmatch(entry.name) and (read(entry / 'idVendor'), read(entry / 'idProduct')) in USB_IDS:
            names.add(entry.name)
    return names


def port_paths(device_dir):
    """The device's USB port and that port's peer (the same socket's other bus)."""
    paths = set()
    port = realpath(Path(device_dir) / 'port')
    if port:
        paths.add(port)
        peer = realpath(Path(port) / 'peer')
        if peer:
            paths.add(peer)
    return sorted(paths)


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
    """The ModemManager record of this USB device, or None.

    `generic.device` is the inhibit uid; it is a sysfs path unless udev set
    ID_MM_PHYSDEV_UID (slot names), so the match also accepts `generic.physdev`.
    """
    _, lists = keyed(mmcli('-L', '-K'))
    for path in lists.get('modem-list', []):
        values, mlists = keyed(mmcli('-m', path, '-K'))
        uid = values.get('modem.generic.device', '')
        physdev = values.get('modem.generic.physdev', '')
        if device in (realpath(uid) if uid.startswith('/') else None, realpath(physdev) if physdev.startswith('/') else None):
            return {
                'path': path,
                'uid': uid,
                'model': values.get('modem.generic.model', ''),
                'revision': values.get('modem.generic.revision', ''),
                'equipment': values.get('modem.generic.equipment-identifier', ''),
                'ports': mlists.get('modem.generic.ports', []),
            }
    return None


def at_ports(ports):
    """tty names ModemManager typed as AT, in its order."""
    names = []
    for port in ports:
        match = re.fullmatch(r'(tty[A-Za-z]+\d+) \(at\)', port)
        if match:
            names.append(match.group(1))
    return names


def belongs_to(device, tty):
    """True when sysfs places tty under this USB device (an interface of it)."""
    for interface in Path(device).glob(Path(device).name + ':*'):
        if (interface / tty).exists() or (interface / 'tty' / tty).exists():
            return True
    return False


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
        # Exclusive mode outlives this fd while anything else holds the tty;
        # hand the port back as found.
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
        """Send one command; return (final, lines) with the echo removed, final None on timeout."""
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
            # EIO and friends: the port went away (a module restarting, a
            # hang-up). Same as no reply: the caller stops before anything else.
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


def usbspeed_value(lines):
    """The stored value from `+QCFG: "usbspeed","312"`; None unless exactly one such line."""
    values = [m.group(1) for m in (re.fullmatch(r'\+QCFG:\s*"usbspeed",\s*"?(\d+)"?', line) for line in lines) if m]
    return values[0] if len(values) == 1 else None




# --- the decision -----------------------------------------------------------

def fallback_verify(port, marker, speed):
    """A marker still at reset-sent means the run that reset the module ended
    before it saw the module return (same kernel name, so this instance waited
    behind it). Judge by the link it came back with; never try again."""
    kept = {k: v for k, v in marker.items() if k not in ('phase', 'time')}
    kept['speed'] = speed
    phase = 'verified' if speed is not None and speed <= USB2_MAX_MBPS else 'failed'
    save_marker(port, phase, **kept)
    save_record(marker.get('unit'), port, status=phase, speed=speed)
    if phase == 'verified':
        log(6, f'{port}: back at {speed} Mbit/s after the reset; done for this boot')
    else:
        log(4, f'{port}: still at {speed} Mbit/s after the reset; recorded as failed, not tried again')


def adopt(port, speed):
    """A USB 2 appearance that matches a pending reset on another kernel name
    whose own run is gone. While that run lives, it judges the return itself."""
    mine = port_paths(SYSFS / 'bus/usb/devices' / port)
    pending = [(name, m) for name, m in markers() if m.get('phase') == 'reset-sent' and name != port]
    for name, marker in pending:
        if (PROC / str(marker.get('pid', 0))).exists():
            continue
        if mine and set(mine) & set(marker.get('port_paths', [])):
            fallback_verify(name, dict(marker, returned_as=port), speed)
            return True
    return False


def run(port):
    device_dir = SYSFS / 'bus/usb/devices' / port
    if not device_dir.exists():
        log(6, f'{port}: device is gone; nothing to do')
        return 0
    device = os.path.realpath(device_dir)
    ids = (read(device_dir / 'idVendor'), read(device_dir / 'idProduct'))
    if ids not in USB_IDS:
        log(6, f'{port}: {ids[0]}:{ids[1]} is not an RM520N ID; leaving it alone')
        return 0
    speed = link_speed(device_dir)
    honour_retry()

    marker = load_marker(port)
    if marker and marker.get('phase') == 'reset-sent':
        fallback_verify(port, marker, speed)
        return 0
    if marker:
        log(6, f'{port}: already handled this boot ({marker.get("phase")}); nothing to do')
        return 0
    if speed is None:
        log(4, f'{port}: link speed unreadable; leaving it alone')
        return 0
    if speed <= USB2_MAX_MBPS:
        if not adopt(port, speed):
            log(6, f'{port}: link at {speed} Mbit/s, already USB 2; nothing to do')
        return 0
    reason = holding_back()
    if reason:
        log(6, f'{port}: link at {speed} Mbit/s, but {reason}; checking again at the next appearance or boot')
        return 0

    log(6, f'{port}: link at {speed} Mbit/s; waiting for ModemManager to list the modem')
    deadline = time.monotonic() + min(MM_WAIT, max(0.0, remaining() - 60))
    modem = find_modem(device)
    while modem is None and time.monotonic() < deadline:
        time.sleep(POLL)
        if not device_dir.exists():
            log(6, f'{port}: device went away while waiting; nothing to do')
            return 0
        modem = find_modem(device)
    if modem is None:
        save_marker(port, 'no-modemmanager', speed=speed)
        log(4, f'{port}: ModemManager did not list the modem in time; leaving it alone this boot')
        return 0
    if modem['model'] not in MODELS:
        save_marker(port, 'other-model', model=modem['model'], speed=speed)
        log(6, f'{port}: model "{modem["model"]}" is not on the list ({", ".join(sorted(MODELS))}); leaving it alone')
        return 0
    unit = unit_id(modem['equipment'])
    if unit:
        for name, other in markers():
            if other.get('unit') == unit:
                save_marker(port, 'unit-handled', unit=unit, speed=speed, other_port=name)
                log(6, f'{port}: this unit was already handled this boot on {name} ({other.get("phase")}); nothing to do')
                return 0
        previous = load_record(unit).get('status')
        if previous in ('failed', 'not-back'):
            save_marker(port, 'gave-up', unit=unit, speed=speed)
            log(4, f'{port}: an earlier attempt on this unit ended "{previous}"; leaving it alone '
                   f'(touch {RETRY} to try once more)')
            return 0
    candidates = [tty for tty in at_ports(modem['ports']) if belongs_to(device, tty)]
    if not candidates:
        save_marker(port, 'no-at-port', model=modem['model'], speed=speed)
        log(4, f'{port}: ModemManager lists no AT port of this device ({", ".join(modem["ports"]) or "none"}); leaving it alone')
        return 0

    base = dict(model=modem['model'], revision=modem['revision'], speed_before=speed, unit=unit,
                port_paths=port_paths(device_dir))
    # Written before anything is asked of ModemManager: whatever happens next,
    # this port and this unit are not tried a second time this boot.
    save_marker(port, 'attempting', **base)
    reason = holding_back()
    if reason:
        marker_path(port).unlink(missing_ok=True)
        log(6, f'{port}: {reason} now; not asking ModemManager, checking again at the next appearance or boot')
        return 0
    before = rm520_devices() - {port}
    hold = Hold(modem['uid'])
    if not hold.held:
        save_marker(port, 'inhibit-failed', **base, reason=hold.reason)
        log(4, f'{port}: ModemManager would not release the modem ({hold.reason}); leaving it alone this boot')
        return 0
    try:
        reset = exchange(port, candidates, base, unit)
    finally:
        hold.release()
    if reset:
        watch_return(port, before, base, unit)
    return 0


def exchange(port, candidates, base, unit):
    """The AT part, under the hold. True when the reset was sent."""
    reason = holding_back()
    if reason:
        marker_path(port).unlink(missing_ok=True)
        log(6, f'{port}: {reason}; released the modem untouched, checking again at the next appearance or boot')
        return False
    node = None
    deadline = time.monotonic() + PORT_WAIT
    while node is None and time.monotonic() < deadline:
        for tty in candidates:
            path = DEV / tty
            if path.exists() and not holders(path):
                node = path
                break
        else:
            time.sleep(min(POLL, 0.5))
    if node is None:
        save_marker(port, 'port-busy', **base)
        log(4, f'{port}: no free AT port among {", ".join(candidates)} while held; leaving it alone this boot')
        return False
    try:
        at = AtPort(node)
    except OSError as error:
        save_marker(port, 'port-failed', **base, reason=str(error))
        log(4, f'{port}: cannot open {node.name} ({error}); leaving it alone this boot')
        return False
    try:
        final, lines = at.command('AT+QCFG="usbspeed"')
        original = usbspeed_value(lines) if final == 'OK' else None
        if original is None:
            save_marker(port, 'read-failed', **base, reply=final)
            log(4, f'{port}: AT+QCFG="usbspeed" gave no value ({final or "timeout"}); nothing written')
            return False
        base['original'] = original
        if original != DESIRED:
            reason = holding_back()
            if reason:
                marker_path(port).unlink(missing_ok=True)
                log(6, f'{port}: stored usbspeed "{original}", but {reason}; nothing written, released')
                return False
            log(6, f'{port}: stored usbspeed "{original}" at {base["speed_before"]} Mbit/s; '
                   f'writing "{DESIRED}" (old value recorded)')
            save_marker(port, 'writing', **base)
            save_record(unit, port, original=original, desired=DESIRED, status='writing',
                        model=base['model'], revision=base['revision'])
            final, _ = at.command(f'AT+QCFG="usbspeed","{DESIRED}"')
            check_final, check_lines = at.command('AT+QCFG="usbspeed"')
            readback = usbspeed_value(check_lines) if check_final == 'OK' else None
            if final != 'OK' or readback != DESIRED:
                save_marker(port, 'write-failed', **base, write=final, readback=readback)
                save_record(unit, port, status='write-failed')
                log(4, f'{port}: write answered {final or "nothing"}, read back "{readback}"; '
                       'no reset, leaving it this boot')
                return False
        else:
            log(6, f'{port}: stored usbspeed is already "{DESIRED}" but the link is at '
                   f'{base["speed_before"]} Mbit/s, so it was never applied; resetting once')
            save_record(unit, port, original=original, desired=DESIRED, status='resetting',
                        model=base['model'], revision=base['revision'])
        reason = holding_back()
        if reason:
            save_marker(port, 'stored-no-reset', **base)
            save_record(unit, port, status='stored-no-reset')
            log(6, f'{port}: "{DESIRED}" is stored, but {reason}; no reset now, it applies at the next power-up')
            return False
        save_marker(port, 'reset-sent', **base, pid=os.getpid())
        save_record(unit, port, status='reset-sent')
        final, _ = at.command('AT+CFUN=1,1', timeout=5)
        if final is not None and final != 'OK':
            save_marker(port, 'reset-refused', **base, reply=final)
            save_record(unit, port, status='reset-refused')
            log(4, f'{port}: AT+CFUN=1,1 answered {final}; the module did not restart, '
                   f'"{DESIRED}" applies at its next power-up')
            return False
        log(6, f'{port}: AT+CFUN=1,1 answered {final or "nothing (the module may already be restarting)"}; '
               'watching for it to come back')
        return True
    finally:
        at.close()


def claims_of_others(port):
    """What other runs this boot account for: (claimed names, claimed port paths, busy).

    A newcomer that sits on another pending reset's socket, or that another run
    already named as its return, is never this module. `busy` is True while
    another reset is in flight; then a newcomer that matches no socket can't be
    attributed by elimination."""
    names, paths, busy = set(), set(), False
    for name, marker in markers():
        if name == port:
            continue
        if marker.get('phase') == 'reset-sent':
            busy = True
            paths.update(marker.get('port_paths', []))
        if marker.get('returned_as'):
            names.add(marker['returned_as'])
    return names, paths, busy


def watch_return(port, before, base, unit):
    """After the reset: the module must leave, then return; judge its new link.

    It is recognised by its USB port or that port's peer. A socket whose USB 2
    lines go to another controller (the module returns on an EHCI bus with no
    peer relation) is matched as the only unclaimed new 2c7c:0801, but only
    while no other reset is in flight; otherwise the outcome is `unattributed`,
    which is logged and never counted as a failure."""
    device_dir = SYSFS / 'bus/usb/devices' / port
    deadline = time.monotonic() + min(LEAVE_WAIT, max(0.0, remaining()))
    while device_dir.exists() and time.monotonic() < deadline:
        time.sleep(0.1)
    if device_dir.exists():
        save_marker(port, 'not-reset', **base)
        save_record(unit, port, status='not-reset')
        log(4, f'{port}: still enumerated {LEAVE_WAIT:g} s after AT+CFUN=1,1; the module did not restart, '
               f'"{DESIRED}" applies at its next power-up')
        return
    paths = set(base.get('port_paths', []))
    unexplained = set()
    deadline = time.monotonic() + min(RETURN_WAIT, max(0.0, remaining()))
    while time.monotonic() < deadline:
        claimed_names, claimed_paths, busy = claims_of_others(port)
        new = sorted(rm520_devices() - before)
        located = {n: set(port_paths(SYSFS / 'bus/usb/devices' / n)) for n in new}
        matched = [n for n in new if paths & located[n]]
        loose = [n for n in new if n not in matched and n not in claimed_names
                 and not claimed_paths & located[n]]
        unexplained.update(loose)
        if len(matched) > 1:
            save_marker(port, 'returned-ambiguous', **base, candidates=matched)
            log(4, f'{port}: several RM520N devices appeared on this socket ({", ".join(matched)}); '
                   'cannot tell which one returned')
            return
        pick = matched[0] if matched else (loose[0] if len(loose) == 1 and not busy else None)
        if pick:
            speed = link_speed(SYSFS / 'bus/usb/devices' / pick)
            if speed is None:
                time.sleep(0.1)
                continue
            phase = 'verified' if speed <= USB2_MAX_MBPS else 'failed'
            save_marker(port, phase, **base, speed=speed, returned_as=pick)
            save_record(unit, port, status=phase, speed=speed)
            if phase == 'verified':
                log(6, f'{port}: back as {pick} at {speed} Mbit/s; done for this boot')
            else:
                log(4, f'{port}: back as {pick} still at {speed} Mbit/s after setting "{DESIRED}"; '
                       'recorded as failed, not tried again')
            return
        if len(loose) > 1 and not busy:
            save_marker(port, 'returned-ambiguous', **base, candidates=loose)
            log(4, f'{port}: several RM520N devices appeared ({", ".join(loose)}); cannot tell which one returned')
            return
        time.sleep(0.2)
    if unexplained:
        save_marker(port, 'unattributed', **base, candidates=sorted(unexplained))
        save_record(unit, port, status='unattributed')
        log(4, f'{port}: another RM520N reset at the same time and {", ".join(sorted(unexplained))} '
               'appeared on no known socket; cannot tell whether this module came back at USB 2 '
               '(not counted as a failure)')
        return
    save_marker(port, 'not-back', **base)
    save_record(unit, port, status='not-back')
    log(3, f'{port}: the module left after AT+CFUN=1,1 and has not come back within {RETURN_WAIT:g} s')


def main(argv):
    if len(argv) != 2 or not KERNEL_NAME.fullmatch(argv[1]):
        print(f'usage: {TAG} <usb device kernel name, e.g. 5-1.4>', file=sys.stderr)
        return 2
    return run(argv[1])


if __name__ == '__main__':
    sys.exit(main(sys.argv))

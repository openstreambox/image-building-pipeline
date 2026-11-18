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
  2. Acts at most once per USB port per boot. A marker in /run is written
     before ModemManager is asked for anything, and before the reset, so the
     re-enumeration that follows only verifies the new speed and never starts
     a second attempt.
  3. Holds back while a stream runs (srtla_send, ceracoder or belacoder alive),
     and when /data/ceralive/modem-usbspeed.disabled exists.
  4. Waits for ModemManager to list the modem, and accepts only the models in
     MODELS (2c7c:0801 is shared with the RM530N-GL, which is not verified).
  5. Takes the modem from ModemManager with `mmcli --inhibit-device` (held for
     the whole exchange; ModemManager closes its ports and re-probes when the
     hold ends), then talks to one AT port that ModemManager had listed as
     "(at)" for this device and that no process holds open.
  6. Reads AT+QCFG="usbspeed". If it is not "20", records the old value
     (journal, /run marker and /data/ceralive/modem-usbspeed/<unit>.json),
     writes "20" and reads it back; a mismatch stops before any reset. Then
     AT+CFUN=1,1 restarts the module (about 50 s without that link: back on USB
     in roughly 17 s, data in roughly 50 s). A stored "20" with a fast link
     means the value was never applied, so it is reset once without a write.
  7. Releases the hold. The module re-enumerates; the next instance reads the
     marker and logs whether the link came back at 480 Mbit/s.

Restore by hand: AT+QCFG="usbspeed","<original>" and AT+CFUN=1,1 on the AT
port, with ModemManager held off (mmcli --inhibit-device), after creating the
.disabled file so this service leaves the unit alone.

Test seams (production uses every default):
  CERALIVE_USBSPEED_SYSFS     sysfs root (default /sys)
  CERALIVE_USBSPEED_DEV       device node dir (default /dev)
  CERALIVE_USBSPEED_PROC      procfs root (default /proc)
  CERALIVE_USBSPEED_RUN       volatile markers (default /run/ceralive/modem-usbspeed)
  CERALIVE_USBSPEED_DATA      persistent records (default /data/ceralive/modem-usbspeed)
  CERALIVE_USBSPEED_MMCLI     mmcli binary (default mmcli)
  CERALIVE_USBSPEED_MM_WAIT   seconds to wait for ModemManager (default 90)
  CERALIVE_USBSPEED_POLL      poll interval seconds (default 2)
  CERALIVE_USBSPEED_AT_TIMEOUT seconds per AT command (default 3)
  CERALIVE_USBSPEED_PORT_WAIT seconds for ModemManager to let go of the port (default 10)
"""
import errno
import fcntl
import hashlib
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
STREAM_PROCESSES = {'srtla_send', 'ceracoder', 'belacoder'}
USB2_MAX_MBPS = 480

SYSFS = Path(os.environ.get('CERALIVE_USBSPEED_SYSFS', '/sys'))
DEV = Path(os.environ.get('CERALIVE_USBSPEED_DEV', '/dev'))
PROC = Path(os.environ.get('CERALIVE_USBSPEED_PROC', '/proc'))
RUN = Path(os.environ.get('CERALIVE_USBSPEED_RUN', '/run/ceralive/modem-usbspeed'))
DATA = Path(os.environ.get('CERALIVE_USBSPEED_DATA', '/data/ceralive/modem-usbspeed'))
DISABLED = DATA.parent / 'modem-usbspeed.disabled'
MMCLI = os.environ.get('CERALIVE_USBSPEED_MMCLI', 'mmcli')
MM_WAIT = float(os.environ.get('CERALIVE_USBSPEED_MM_WAIT', '90'))
POLL = float(os.environ.get('CERALIVE_USBSPEED_POLL', '2'))
AT_TIMEOUT = float(os.environ.get('CERALIVE_USBSPEED_AT_TIMEOUT', '3'))
PORT_WAIT = float(os.environ.get('CERALIVE_USBSPEED_PORT_WAIT', '10'))


def log(level, message):
    # journald reads the <n> prefix as the syslog priority (6 info, 4 warning, 3 error).
    print(f'<{level}>{TAG}: {message}', flush=True)


def read(path):
    try:
        return Path(path).read_text().strip()
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
    try:
        done = subprocess.run([MMCLI, *args], capture_output=True, text=True, timeout=timeout)
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
    """The ModemManager record whose generic.device is this USB device, or None."""
    _, lists = keyed(mmcli('-L', '-K'))
    for path in lists.get('modem-list', []):
        values, mlists = keyed(mmcli('-m', path, '-K'))
        if os.path.realpath(values.get('modem.generic.device', '') or '/nonexistent') == device:
            return {
                'path': path,
                'uid': values.get('modem.generic.device'),
                'model': values.get('modem.generic.model', ''),
                'revision': values.get('modem.generic.revision', ''),
                'state': values.get('modem.generic.state', ''),
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
        self.reason = 'no confirmation from mmcli within 15 s'
        fd = self.process.stdout.fileno()
        deadline = time.monotonic() + 15
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
        self.drain()
        os.write(self.fd, (text + '\r').encode())
        deadline = time.monotonic() + (AT_TIMEOUT if timeout is None else timeout)
        buffer, lines = b'', []
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

def unit_name(modem, port):
    """A stable name for the persistent record without storing the IMEI itself."""
    if modem.get('equipment'):
        return hashlib.sha256(modem['equipment'].encode()).hexdigest()[:16]
    return 'port-' + port


def record_original(modem, port, original):
    if not DATA.parent.is_dir():
        log(6, f'{port}: no {DATA.parent}; original value only in the journal and the /run marker')
        return
    try:
        path = DATA / (unit_name(modem, port) + '.json')
        atomic_json(path, {
            'original': original, 'desired': DESIRED, 'time': int(time.time()), 'port': port,
            'model': modem.get('model'), 'revision': modem.get('revision'),
        })
    except OSError as error:
        log(4, f'{port}: could not write the record ({error}); original "{original}" is in this journal')


def verify_after_reset(port, marker, speed):
    kept = {k: v for k, v in marker.items() if k not in ('phase', 'time')}
    kept['speed'] = speed
    if speed is not None and speed <= USB2_MAX_MBPS:
        save_marker(port, 'verified', **kept)
        log(6, f'{port}: back at {speed} Mbit/s after the reset (stored was "{marker.get("original")}"); done for this boot')
    else:
        save_marker(port, 'failed', **kept)
        log(4, f'{port}: still at {speed} Mbit/s after setting usbspeed "{DESIRED}" and a reset; '
               'not trying again this boot')


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
    try:
        speed = int(float(read(device_dir / 'speed') or ''))
    except ValueError:
        speed = None

    marker = load_marker(port)
    if marker and marker.get('phase') == 'reset-sent':
        verify_after_reset(port, marker, speed)
        return 0
    if marker:
        log(6, f'{port}: already handled this boot ({marker.get("phase")}); nothing to do')
        return 0
    if speed is None:
        log(4, f'{port}: link speed unreadable; leaving it alone')
        return 0
    if speed <= USB2_MAX_MBPS:
        log(6, f'{port}: link at {speed} Mbit/s, already USB 2; nothing to do')
        return 0
    if DISABLED.exists():
        log(6, f'{port}: link at {speed} Mbit/s, but {DISABLED} exists; leaving it alone')
        return 0
    stream = streaming()
    if stream:
        log(6, f'{port}: link at {speed} Mbit/s, but a stream is running ({stream}); '
               'checking again at the next appearance or boot')
        return 0

    log(6, f'{port}: link at {speed} Mbit/s; waiting for ModemManager to list the modem')
    deadline = time.monotonic() + MM_WAIT
    modem = find_modem(device)
    while modem is None and time.monotonic() < deadline:
        time.sleep(POLL)
        if not device_dir.exists():
            log(6, f'{port}: device went away while waiting; nothing to do')
            return 0
        modem = find_modem(device)
    if modem is None:
        save_marker(port, 'no-modemmanager', speed=speed)
        log(4, f'{port}: ModemManager did not list the modem within {MM_WAIT:g} s; leaving it alone this boot')
        return 0
    if modem['model'] not in MODELS:
        save_marker(port, 'other-model', model=modem['model'], speed=speed)
        log(6, f'{port}: model "{modem["model"]}" is not on the list ({", ".join(sorted(MODELS))}); leaving it alone')
        return 0
    candidates = [tty for tty in at_ports(modem['ports']) if belongs_to(device, tty)]
    if not candidates:
        save_marker(port, 'no-at-port', model=modem['model'], speed=speed)
        log(4, f'{port}: ModemManager lists no AT port of this device ({", ".join(modem["ports"]) or "none"}); leaving it alone')
        return 0

    base = dict(model=modem['model'], revision=modem['revision'], speed_before=speed)
    # Written before anything is asked of ModemManager: whatever happens next,
    # this port is not tried a second time this boot.
    save_marker(port, 'attempting', **base)
    hold = Hold(modem['uid'])
    if not hold.held:
        save_marker(port, 'inhibit-failed', **base, reason=hold.reason)
        log(4, f'{port}: ModemManager would not release the modem ({hold.reason}); leaving it alone this boot')
        return 0
    try:
        return exchange(port, candidates, base, modem)
    finally:
        hold.release()


def exchange(port, candidates, base, modem):
    stream = streaming()
    if stream:
        marker_path(port).unlink(missing_ok=True)
        log(6, f'{port}: a stream started ({stream}); released the modem untouched, checking again at the next appearance or boot')
        return 0
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
        return 0
    try:
        at = AtPort(node)
    except OSError as error:
        save_marker(port, 'port-failed', **base, reason=str(error))
        log(4, f'{port}: cannot open {node.name} ({error}); leaving it alone this boot')
        return 0
    try:
        final, lines = at.command('AT+QCFG="usbspeed"')
        original = usbspeed_value(lines) if final == 'OK' else None
        if original is None:
            save_marker(port, 'read-failed', **base, reply=final)
            log(4, f'{port}: AT+QCFG="usbspeed" gave no value ({final or "timeout"}); nothing written')
            return 0
        base['original'] = original
        if original != DESIRED:
            log(6, f'{port}: stored usbspeed "{original}" at {base["speed_before"]} Mbit/s; '
                   f'writing "{DESIRED}" (old value recorded)')
            save_marker(port, 'writing', **base)
            record_original(modem, port, original)
            final, _ = at.command(f'AT+QCFG="usbspeed","{DESIRED}"')
            check_final, check_lines = at.command('AT+QCFG="usbspeed"')
            readback = usbspeed_value(check_lines) if check_final == 'OK' else None
            if final != 'OK' or readback != DESIRED:
                save_marker(port, 'write-failed', **base, write=final, readback=readback)
                log(4, f'{port}: write answered {final or "nothing"}, read back "{readback}"; '
                       'no reset, leaving it this boot')
                return 0
        else:
            log(6, f'{port}: stored usbspeed is already "{DESIRED}" but the link is at '
                   f'{base["speed_before"]} Mbit/s, so it was never applied; resetting once')
        save_marker(port, 'reset-sent', **base)
        final, _ = at.command('AT+CFUN=1,1', timeout=5)
        log(6, f'{port}: AT+CFUN=1,1 answered {final or "nothing (the module may already be restarting)"}; '
               'module restarting, back on USB in about 20 s and with data in about a minute')
        return 0
    finally:
        at.close()


def main(argv):
    if len(argv) != 2 or not re.fullmatch(r'\d+-\d+(\.\d+)*', argv[1]):
        print(f'usage: {TAG} <usb device kernel name, e.g. 5-1.4>', file=sys.stderr)
        return 2
    return run(argv[1])


if __name__ == '__main__':
    sys.exit(main(sys.argv))

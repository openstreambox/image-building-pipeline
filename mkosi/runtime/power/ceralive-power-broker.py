#!/usr/bin/python3
"""Admission broker for deliberate power-off and reboot requests.

Every supported deliberate power request goes through this one root service:
the power button's completed hold, a local power action CeraUI has admitted,
and an operator's `ceralive-poweroff` / `ceralive-reboot` at a terminal. The
broker is the only caller allowed to skip shutdown block locks (polkit rule
60-ceralive-power-broker.rules matches its exact unit), so CeraUI's stream lock
still refuses every other plain request.

A request is admitted from the peer's socket-bound pidfd, never from what the
client claims:
  - root in ceralive-button.service: power-off only (the hold is the intent);
  - root in ceralive.service: power-off or reboot (CeraUI's gate and dialog);
  - root, or a member of the operator group, on its own foreground controlling
    terminal: the broker opens that terminal itself and reads one typed word.

Admitted intent is held here, upstream of logind, until the writers settle:
  1. the power fence file exists, so RAUC's pre-install handler refuses any
     install that has not started writing (CLI, direct D-Bus, hawkBit alike);
  2. the shared update lock, then dpkg's frontend lock, fence the update units
     and package installs;
  3. no RAUC install is running: Installer.Operation is idle *and* nothing is
     mounted below RAUC's mount prefix in RAUC's own namespace, both read from
     one stable bus owner (an install keeps its bundle mounted until it has
     finished; RAUC can report idle while a rejected competing install
     unwinds), no writer unit is executing, no slot activation runs.
Only then the broker asks logind over D-Bus (PowerOffWithFlags /
RebootWithFlags with SKIP_INHIBITORS). There is no systemctl and no direct
target start. A typed D-Bus refusal is a failure; no reply, a timeout or a lost
connection is uncertain and is never retried. A waiting request is reported as
stuck after ESCALATE_S and keeps waiting: cutting a write is not this broker's
decision.

Its state lives in one record, state.json, which only Broker.publish writes,
whole and atomically: the latest request at the top level, every request of
this boot by id under "requests". An admission is that one write, and a request
changes in memory only after its write happened.

`drain` is the same writer check used at shutdown by ceralive-write-drain.service,
which is ordered after the writer units, so any shutdown path (also logind's own
power-key handling) waits for running writes before they are stopped.
"""
import errno
import fcntl
import grp
import json
import os
import pwd
import queue
import selectors
import signal
import socket
import stat
import struct
import subprocess
import sys
import termios
import threading
import time
import uuid

RUN_DIR = os.environ.get('CERALIVE_POWER_RUN_DIR', '/run/ceralive-power')
# The broker's one persisted record: the latest request at the top level, and
# every request of this boot under "requests" by id. Written whole, atomically,
# by Broker.publish only.
STATE_FILE = os.path.join(RUN_DIR, 'state.json')
# One fence file per owner: the broker's for its request, the drain's for the
# shutdown. RAUC's pre-install handler refuses while any of them exists.
FENCE_DIR = os.environ.get('CERALIVE_POWER_FENCE_DIR', os.path.join(RUN_DIR, 'fence.d'))
# A finished request's record is kept this long in boot time (CLOCK_BOOTTIME,
# which wall-clock corrections don't move), so whoever submitted it can still
# read its result; one still in progress is never dropped.
KEEP_FINISHED_S = 86400
FINISHED_STATES = ('failed', 'submitted')
BOOT_ID_FILE = '/proc/sys/kernel/random/boot_id'
# After a restart that lost the record of a request, nothing new is admitted
# until no shutdown and no write has been seen for this long.
RESOLVE_S = 60
SHUTDOWN_TARGETS = ('poweroff.target', 'reboot.target', 'halt.target', 'kexec.target',
                    'shutdown.target', 'final.target')
UPDATE_LOCK = os.environ.get('CERALIVE_UPDATE_LOCK_PATH', '/run/lock/ceralive-update.lock')
DPKG_LOCK = os.environ.get('CERALIVE_DPKG_LOCK_PATH', '/var/lib/dpkg/lock-frontend')
ACTIVATION_LOCK = os.environ.get('CERALIVE_ACTIVATION_LOCK', '/run/lock/ceralive-rauc-activate.lock')
RAUC_SYSTEM_CONF = '/etc/rauc/system.conf'
RAUC_DEFAULT_MOUNT_PREFIX = '/mnt/rauc'
PROC_ROOT = '/proc'
SYSTEM_MOUNT_NS = '/proc/1/ns/mnt'
OPERATOR_GROUP = 'ceralive-power'
BUTTON_UNIT = 'ceralive-button.service'
CERAUI_UNIT = 'ceralive.service'
WRITER_UNITS = ('ceralive-software-update.service', 'ceralive-os-stage-guard.service',
                'ceralive-slot-sync.service', 'ceralive-boot-script-sync.service')
WRITER_UNIT_PATTERNS = ('ceralive-kernel-stage-*.service', 'ceralive-rauc-arm@*.service')
ESCALATE_S = 900
PROMPT_S = 60
FIRST_READ_S = 5
MAX_CONNECTIONS = 32
MAX_PROMPTS = 4
SO_PEERPIDFD = getattr(socket, 'SO_PEERPIDFD', 77)
SKIP_INHIBITORS = 1 << 4
ACTIONS = {'POWEROFF': 'poweroff', 'REBOOT': 'reboot'}
# Errors that say the call may or may not have reached logind.
UNCERTAIN_ERRORS = ('org.freedesktop.DBus.Error.NoReply', 'org.freedesktop.DBus.Error.Timeout',
                    'org.freedesktop.DBus.Error.TimedOut', 'org.freedesktop.DBus.Error.Disconnected',
                    'org.freedesktop.DBus.Error.IOError', 'org.freedesktop.DBus.Error.NoServer')
ACTIVE_STATES = ('admitted', 'waiting', 'stuck', 'submitting', 'submitted', 'uncertain')


def log(message):
    print(message, flush=True)


def boot_clock():
    return time.clock_gettime(time.CLOCK_BOOTTIME)


def boot_id():
    try:
        with open(BOOT_ID_FILE) as source:
            return source.read().strip()
    except OSError:
        return ''


# --- the shared writer check (broker and shutdown drain) ---------------------

def run(argv, timeout):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)


def rauc_operation_busy(runner=run):
    """RAUC's own answer. An unreadable answer counts as busy; only a missing
    service counts as idle."""
    try:
        out = runner(['busctl', '--system', '--timeout=5', 'get-property', 'de.pengutronix.rauc',
                      '/', 'de.pengutronix.rauc.Installer', 'Operation'], 10)
    except (OSError, subprocess.SubprocessError):
        return True
    if out.returncode == 0:
        return out.stdout.split() != ['s', '"idle"']
    unknown = ('ServiceUnknown', 'was not provided by any .service', 'not activatable', 'No such')
    return not any(text in out.stderr for text in unknown)


def rauc_process(runner=run):
    """PID of the process that owns RAUC's D-Bus name (the packaged unit or a
    manual `rauc service`), None when no RAUC service runs."""
    out = runner(['busctl', '--system', '--timeout=5', 'call', 'org.freedesktop.DBus', '/org/freedesktop/DBus',
                  'org.freedesktop.DBus', 'GetConnectionUnixProcessID', 's', 'de.pengutronix.rauc'], 10)
    if out.returncode == 0:
        fields = out.stdout.split()
        if len(fields) == 2 and fields[0] == 'u' and fields[1].isdigit():
            return int(fields[1])
        raise OSError('unreadable RAUC owner')
    no_owner = ('NameHasNoOwner', 'no such name', 'not have an owner', 'has no owner',
                'was not provided by any .service', 'ServiceUnknown')
    if any(text in out.stderr for text in no_owner):
        return None
    raise OSError(out.stderr.strip() or 'RAUC owner unknown')


def rauc_mount_prefix(pid):
    """RAUC's effective mount prefix: its --mount argument, else system.conf's
    mount-prefix, else the built-in default."""
    with open(f'{PROC_ROOT}/{pid}/cmdline', 'rb') as source:
        args = source.read().decode(errors='replace').split('\0')
    for index, arg in enumerate(args):
        if arg.startswith('--mount='):
            return arg.split('=', 1)[1]
        if arg == '--mount' and index + 1 < len(args):
            return args[index + 1]
    try:
        with open(RAUC_SYSTEM_CONF) as conf:
            for line in conf:
                key, _, value = line.partition('=')
                if key.strip() == 'mount-prefix' and value.strip():
                    return value.strip()
    except OSError:
        pass
    return RAUC_DEFAULT_MOUNT_PREFIX


def process_start(pid):
    """(pid, start time): a process identity that a reused pid doesn't share."""
    with open(f'{PROC_ROOT}/{pid}/stat', 'rb') as source:
        data = source.read()
    return pid, int(data[data.rindex(b')') + 2:].split()[19])


def mounts_of(pid):
    """Mounts below RAUC's prefix in the namespace of process `pid` (the
    packaged unit runs with MountFlags=slave, so they never reach PID 1). An
    install keeps its bundle mounted from before its pre-install handler until
    it has finished. Raises OSError when unreadable."""
    prefix = rauc_mount_prefix(pid).rstrip('/') + '/'
    with open(f'{PROC_ROOT}/{pid}/mountinfo') as source:
        lines = source.read().splitlines()
    # Only mounts below the prefix: systemd bind-mounts the prefix itself
    # (RuntimeDirectory=rauc/mnt) into the namespace for the service's lifetime.
    points = []
    for line in lines:
        fields = line.split()
        if len(fields) > 4 and fields[4].startswith(prefix):
            points.append(fields[4])
    return points


def rauc_mounts(runner=run):
    """Mounts the current RAUC owner holds under its prefix. Anything
    unreadable counts as a mount."""
    try:
        pid = rauc_process(runner)
    except (OSError, subprocess.SubprocessError) as error:
        return [f'(RAUC process unknown: {error})']
    if pid is None:
        return []
    try:
        return mounts_of(pid)
    except OSError:
        return ['(RAUC mount table unreadable)']


def rauc_unit_state(runner=run):
    try:
        out = runner(['systemctl', 'show', '--property=ActiveState', '--value', 'rauc.service'], 10)
    except (OSError, subprocess.SubprocessError):
        return 'unknown'
    return out.stdout.strip() if out.returncode == 0 and out.stdout.strip() else 'unknown'


def rauc_busy(runner=run, attempts=3):
    """What says a RAUC install may run, or '' when none can. RAUC's Operation
    and its mount table are read between two lookups of the bus owner, and count
    only when both lookups found the same process (pid and start time); a
    changing owner is looked at again, and one that never holds still is busy.
    Without a bus owner, rauc.service must be inactive: a worker tearing down
    after the name is gone may still hold its bundle. With the fence in place, a
    RAUC that starts later can't write: its install passes the pre-install
    handler after mounting."""
    for _ in range(attempts):
        try:
            pid = rauc_process(runner)
            if pid is None:
                unit = rauc_unit_state(runner)
                if unit in ('inactive', 'failed') and rauc_process(runner) is None:
                    return ''
                if unit in ('inactive', 'failed'):
                    continue  # it came up meanwhile
                return f'os-install (rauc.service {unit} without its bus name)'
            before = process_start(pid)
            operation = rauc_operation_busy(runner)
            mounts = mounts_of(pid)
            again = rauc_process(runner)
            if again is None or process_start(again) != before:
                continue
        except (OSError, ValueError, IndexError, subprocess.SubprocessError) as error:
            return f'os-install (RAUC unreadable: {error})'
        if operation:
            return 'os-install (rauc.service)'
        if mounts:
            return 'os-install (rauc mounts)'
        return ''
    return 'os-install (RAUC owner changing)'


def rauc_installing(runner=run):
    return bool(rauc_busy(runner))


def executing_writer_units(runner=run):
    """Writer units that are executing. A unit kept active after it finished
    (RemainAfterExit=yes, sub-state `exited`) is a receipt, not work."""
    try:
        out = runner(['systemctl', 'list-units', '--no-legend', '--plain', '--all', '--type=service',
                      *WRITER_UNITS, *WRITER_UNIT_PATTERNS], 10)
    except (OSError, subprocess.SubprocessError):
        return ['(unit state unreadable)']
    if out.returncode != 0:
        return ['(unit state unreadable)']
    busy = []
    for line in out.stdout.splitlines():
        fields = line.split()
        if len(fields) < 4:
            continue
        unit, _load, active, sub = fields[:4]
        if active in ('activating', 'deactivating', 'reloading') or (active == 'active' and sub != 'exited'):
            busy.append(unit)
    return busy


def dpkg_lock_holder(path=None):
    """PID holding dpkg's frontend lock (fcntl), else None. It opens and closes
    the lock file, which drops any fcntl lock this process holds on it: only a
    process that holds no such lock may call it (the drain, never the broker)."""
    path = path or DPKG_LOCK
    try:
        fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
    except FileNotFoundError:
        return None
    except OSError:
        return -1
    try:
        query = struct.pack('hhqqi', fcntl.F_WRLCK, os.SEEK_SET, 0, 0, 0)
        kind, _, _, _, pid = struct.unpack('hhqqi', fcntl.fcntl(fd, fcntl.F_GETLK, query))
        return None if kind == fcntl.F_UNLCK else pid
    except OSError:
        return -1
    finally:
        os.close(fd)


def activation_busy(path=None):
    """The slot activation lock is a flock: probing it is safe in any process."""
    try:
        fd = os.open(path or ACTIVATION_LOCK, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o644)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    except BlockingIOError:
        return True
    finally:
        os.close(fd)


def shutdown_in_flight(runner=run):
    """What says a power action is already under way: logind preparing for
    shutdown (its delay phase), a queued shutdown job, or the manager stopping.
    Unreadable answers count."""
    seen = []
    try:
        out = runner(['busctl', '--system', '--timeout=5', 'get-property', 'org.freedesktop.login1',
                      '/org/freedesktop/login1', 'org.freedesktop.login1.Manager', 'PreparingForShutdown'], 10)
        if out.returncode != 0 or out.stdout.split() != ['b', 'false']:
            seen.append('logind preparing for shutdown' if out.stdout.split() == ['b', 'true']
                        else '(logind state unreadable)')
        out = runner(['systemctl', 'list-jobs', '--no-legend', '--plain'], 10)
        if out.returncode != 0:
            seen.append('(job queue unreadable)')
        else:
            seen += [f'{fields[1]} queued' for fields in (line.split() for line in out.stdout.splitlines())
                     if len(fields) > 1 and fields[1] in SHUTDOWN_TARGETS]
        out = runner(['systemctl', 'is-system-running'], 10)
        if out.stdout.strip() == 'stopping':
            seen.append('the system is stopping')
    except (OSError, subprocess.SubprocessError) as error:
        seen.append(f'(shutdown state unreadable: {error})')
    return seen


def busy_writers(runner=run, check_dpkg=True):
    busy = []
    rauc = rauc_busy(runner)
    if rauc:
        busy.append(rauc)
    busy.extend(executing_writer_units(runner))
    if check_dpkg:
        holder = dpkg_lock_holder()
        if holder is not None:
            busy.append(f'package-install (dpkg, pid {holder})')
    if activation_busy():
        busy.append('slot activation')
    return busy


def put_fence(owner, content):
    """Create the owner's fence (atomically). Raises when it can't."""
    os.makedirs(FENCE_DIR, exist_ok=True)
    path = os.path.join(FENCE_DIR, owner)
    temp = path + '.new'
    with open(temp, 'w') as out:
        out.write(content + '\n')
    os.replace(temp, path)


def read_fence(owner):
    """The id in the owner's fence, None when there is none, 'unknown' when
    one exists but can't be read."""
    try:
        with open(os.path.join(FENCE_DIR, owner)) as source:
            return source.read().strip() or 'unknown'
    except FileNotFoundError:
        return None
    except OSError:
        return 'unknown'


def drop_fence(owner):
    """Only the owner removes its fence; the drain never removes its own."""
    try:
        os.unlink(os.path.join(FENCE_DIR, owner))
    except FileNotFoundError:
        pass


def drain(sleep=time.sleep, now=time.monotonic, runner=run):
    """ExecStop of ceralive-write-drain.service: wait for running writes while
    the system is shutting down. Only a state that says the system is up counts
    as a manual stop; an empty or unreadable answer waits like a shutdown."""
    try:
        state = runner(['systemctl', 'is-system-running'], 10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        state = ''
    if state in ('running', 'degraded', 'starting', 'initializing', 'maintenance'):
        return 0
    started, last, escalated, fenced = now(), None, False, False
    while True:
        if not fenced:
            # No install that hasn't started writing may begin now. Without the
            # fence the shutdown doesn't go ahead: it keeps trying.
            try:
                put_fence('shutdown', 'shutdown')
                fenced = True
            except OSError as error:
                busy = [f'install fence ({error.strerror or error})']
        busy = busy_writers(runner=runner) if fenced else busy
        if not busy:
            if last:
                log('All writes finished; shutdown continues.')
            return 0
        waited = now() - started
        if busy != last or int(waited) % 30 == 0:
            log(f'Shutdown waits for: {", ".join(busy)} ({int(waited)} s)')
            last = busy
        if waited >= ESCALATE_S and not escalated:
            escalated = True
            message = ('Power-off is still waiting for a system write ('
                       + ', '.join(busy) + '). It will continue when the write finishes. '
                       'Holding the power button for about 10 s cuts power and may damage the update.')
            log(message)
            try:
                runner(['wall', message], 10)
            except (OSError, subprocess.SubprocessError):
                pass
        sleep(1)


# --- peer identity from the socket-bound pidfd ---------------------------------

class PeerError(Exception):
    pass


def pidfd_pid(pidfd):
    with open(f'/proc/self/fdinfo/{pidfd}') as info:
        for line in info:
            if line.startswith('Pid:'):
                return int(line.split()[1])
    raise PeerError('pidfd has no pid')


def peer_identity(conn):
    """Credentials and the socket-bound peer pidfd. There is no fallback to a
    bare PID: without SO_PEERPIDFD the caller is unverifiable."""
    pid, uid, gid = struct.unpack('3i', conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
    try:
        pidfd = struct.unpack('i', conn.getsockopt(socket.SOL_SOCKET, SO_PEERPIDFD, 4))[0]
    except OSError as error:
        raise PeerError(f'no peer pidfd ({error.strerror})') from error
    if pidfd < 0:
        raise PeerError('no peer pidfd')
    return pid, uid, gid, pidfd


def read_bracketed(pidfd, name):
    """Read /proc/<pid>/<name> only while the pidfd still names that pid."""
    pid = pidfd_pid(pidfd)
    if pid <= 0:
        raise PeerError('peer exited')
    try:
        with open(f'/proc/{pid}/{name}', 'rb') as source:
            data = source.read()
    except OSError as error:
        raise PeerError(f'peer {name} unreadable') from error
    if pidfd_pid(pidfd) != pid:
        raise PeerError('peer exited')
    return pid, data


def parse_stat(data):
    text = data.decode(errors='replace')
    fields = text[text.rindex(')') + 2:].split()
    # state ppid pgrp session tty_nr tpgid
    return {'pgrp': int(fields[2]), 'session': int(fields[3]), 'tty_nr': int(fields[4]), 'tpgid': int(fields[5])}


def system_unit(pidfd):
    _, data = read_bracketed(pidfd, 'cgroup')
    for line in data.decode(errors='replace').splitlines():
        if line.startswith('0::'):
            parts = line[3:].strip('/').split('/')
            # Only a unit directly under system.slice counts; user units and
            # nested scopes never match a service name here.
            if len(parts) == 2 and parts[0] == 'system.slice':
                return parts[1]
            return None
    return None


def is_operator(uid, gid):
    if uid == 0:
        return True
    try:
        name = pwd.getpwuid(uid).pw_name
        return grp.getgrnam(OPERATOR_GROUP).gr_gid in os.getgrouplist(name, gid)
    except KeyError:
        return False


def same_mount_namespace(pid):
    # The system's namespace, not the broker's: PrivateTmp/ProtectHome give the
    # broker its own, but its /dev (and devpts instance) is still the system's.
    return os.readlink(f'/proc/{pid}/ns/mnt') == os.readlink(SYSTEM_MOUNT_NS)


def tty_path(rdev):
    major, minor = os.major(rdev), os.minor(rdev)
    if 136 <= major <= 143:
        return f'/dev/pts/{(major - 136) * 256 + minor}'
    if major == 4 and 1 <= minor <= 63:
        return f'/dev/tty{minor}'
    if major == 4 and minor >= 64:
        return f'/dev/ttyS{minor - 64}'
    return None


def check_terminal(uid, pidfd, fd=None, expected_rdev=None):
    """The caller's own foreground controlling terminal, in the system's mount
    namespace; with an opened fd, also that fd's device and owner."""
    pid, data = read_bracketed(pidfd, 'stat')
    proc = parse_stat(data)
    if proc['tty_nr'] == 0:
        raise PeerError('no controlling terminal')
    if expected_rdev is not None and proc['tty_nr'] != expected_rdev:
        raise PeerError('terminal changed')
    if proc['tpgid'] != proc['pgrp']:
        raise PeerError('not in the foreground of its terminal')
    if not same_mount_namespace(pid):
        raise PeerError('terminal in another mount namespace')
    if fd is not None:
        info = os.fstat(fd)
        if not stat.S_ISCHR(info.st_mode) or info.st_rdev != proc['tty_nr']:
            raise PeerError('terminal changed')
        # A root shell that shares the login user's terminal is refused: the
        # operator connects directly, root only from its own terminal.
        if info.st_uid != uid:
            raise PeerError('terminal owned by another account')
    if pidfd_pid(pidfd) != pid:
        raise PeerError('peer exited')
    return proc


def open_terminal(uid, pidfd):
    proc = check_terminal(uid, pidfd)
    path = tty_path(proc['tty_nr'])
    if path is None:
        raise PeerError('unsupported terminal')
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        proc = check_terminal(uid, pidfd, fd, proc['tty_nr'])
    except BaseException:
        os.close(fd)
        raise
    return fd, proc


# --- logind submission ----------------------------------------------------------

def submit_to_logind(action, runner=run):
    """('submitted'|'failed'|'uncertain', detail). Direct logind D-Bus call with
    typed error names; no manager fallback, no retry."""
    method = 'RebootWithFlags' if action == 'reboot' else 'PowerOffWithFlags'
    argv = ['dbus-send', '--system', '--print-reply', '--reply-timeout=25000',
            '--dest=org.freedesktop.login1', '/org/freedesktop/login1',
            f'org.freedesktop.login1.Manager.{method}', f'uint64:{SKIP_INHIBITORS}']
    try:
        out = runner(argv, 40)
    except subprocess.TimeoutExpired:
        return 'uncertain', 'logind did not answer'
    except OSError as error:
        return 'failed', f'dbus-send unavailable ({error.strerror})'
    if out.returncode == 0:
        return 'submitted', ''
    text = (out.stderr or '') + (out.stdout or '')
    for line in text.splitlines():
        if line.startswith('Error '):
            name, _, message = line[len('Error '):].partition(': ')
            if name.strip() in UNCERTAIN_ERRORS:
                return 'uncertain', f'{name.strip()}: {message}'.strip()
            return 'failed', f'{name.strip()}: {message}'.strip()
    return 'uncertain', (text.strip().splitlines() or ['no error name'])[-1]


# --- the broker ------------------------------------------------------------------

def write_json(path, record):
    """Replace `path` atomically. Raises unless the rename happened; after it,
    the new content is what anyone (also a restarted broker) reads."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temp = path + '.new'
    with open(temp, 'w') as out:
        json.dump(record, out)
        out.flush()
        os.fsync(out.fileno())
    os.chmod(temp, 0o644)
    os.replace(temp, path)
    try:
        directory = os.open(os.path.dirname(path), os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except OSError as error:
        log(f'state directory not synced: {error}')


def kept_records(records, boot, now, current=None):
    """Finished requests of this boot are kept for KEEP_FINISHED_S of boot
    time; the rest always (also a record without boot time)."""
    def keep(key, value):
        if key == current or value.get('state') not in FINISHED_STATES or 'boottime' not in value:
            return True
        if value.get('boot_id') != boot:
            return False
        return now - float(value['boottime']) < KEEP_FINISHED_S
    return {key: value for key, value in records.items() if keep(key, value)}


class Request:
    def __init__(self, conn, now):
        self.conn = conn
        self.buffer = b''
        self.deadline = now + FIRST_READ_S
        self.action = None
        self.origin = None
        self.pidfd = None
        self.uid = None
        self.tty = None  # [fd, rdev, proc, answer bytes]
        self.confirmed = False  # an operator's typed word, checked on its own terminal
        self.closed = False


class Committer(threading.Thread):
    """Fences, waits for writers and submits one committed action. Runs apart
    from the socket and terminal I/O, so slow probes never delay admission."""

    def __init__(self, broker, runner, clock, interval=1.0):
        super().__init__(daemon=True)
        self.broker, self.runner, self.clock, self.interval = broker, runner, clock, interval
        self.locks = {}
        self.wake = threading.Event()
        self.stop_requested = False

    def take_update(self):
        if 'update' in self.locks:
            return True
        fd = os.open(UPDATE_LOCK, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            return False
        self.locks['update'] = fd
        return True

    def take_dpkg(self):
        """One owned fd for the fcntl lock; nothing in this process opens the
        file again while it is held."""
        if 'dpkg' in self.locks:
            return True
        try:
            fd = os.open(DPKG_LOCK, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o640)
        except FileNotFoundError:
            self.locks['dpkg'] = None
            return True
        try:
            fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            os.close(fd)
            if error.errno in (errno.EACCES, errno.EAGAIN):
                return False
            raise
        self.locks['dpkg'] = fd
        return True

    def release(self, *names):
        for name in names or list(self.locks):
            fd = self.locks.pop(name, None)
            if fd is not None:
                os.close(fd)

    def step(self):
        broker = self.broker
        with broker.lock:
            c = broker.committed
            if c and c['stage'] == 'failing':
                return broker.fail(c['failure'])  # not recorded yet: try again
            if c and c['stage'] == 'recovered':
                pass
            elif not c or c['stage'] not in ('fence', 'drain'):
                return False
        if c['stage'] == 'recovered':
            return self.settle_recovered(c)
        if c['stage'] == 'fence':
            put_fence('broker', c['id'])  # raises: retried on the next step
            with broker.lock:
                if broker.committed is c:
                    c['stage'] = 'drain'
        waiting = []
        if not self.take_update():
            waiting.append('update lock (an update or slot sync is running)')
        elif not self.take_dpkg():
            waiting.append('package-install (dpkg)')
        if not waiting:
            # The broker holds dpkg's lock, so dpkg isn't probed (probing would
            # open the lock file and drop that lock).
            waiting = busy_writers(runner=self.runner, check_dpkg=False)
        with broker.lock:
            if broker.committed is not c:
                return False
            if waiting:
                waited = self.clock() - c['since']
                detail = ', '.join(waiting)
                if waited >= ESCALATE_S and not c['escalated']:
                    c['escalated'] = True
                    broker.publish('stuck', detail=detail, waited=int(waited))
                elif c.get('detail') != detail:
                    broker.publish('stuck' if c['escalated'] else 'waiting', detail=detail, waited=int(waited))
                c['detail'] = detail
                return False
            # Durable before logind is asked: a restart after the call must find
            # "submitting" (reported uncertain, never resubmitted).
            c['stage'] = 'submitting'
            if not broker.publish('submitting'):
                c['stage'] = 'drain'
                log('could not record the submission; not submitting yet')
                return False
        outcome, detail = submit_to_logind(c['action'], self.runner)
        with broker.lock:
            if outcome == 'submitted':
                c['stage'] = 'submitted'
                # The shutdown transaction is queued; new units can no longer
                # start. dpkg's lock goes so the shutdown drain doesn't wait on us.
                self.release('dpkg')
                broker.publish('submitted')
            elif outcome == 'uncertain':
                c['stage'] = 'uncertain'
                broker.publish('uncertain', detail=detail + '; not retried')
            else:
                self.release()
                drop_fence('broker')
                broker.fail(detail)
        return True

    def settle_recovered(self, c):
        """A request whose record was lost: it may have reached logind. It
        keeps its fence and the update lock, and nothing new is admitted, until
        nothing is shutting down and nothing writes for RESOLVE_S. Then it is
        recorded as uncertain (never resubmitted) and new requests are taken."""
        seen = busy_writers(runner=self.runner, check_dpkg='dpkg' not in self.locks)
        seen += shutdown_in_flight(self.runner)
        broker = self.broker
        with broker.lock:
            if broker.committed is not c:
                return False
            if seen:
                c['quiet_since'] = None
                return False
            if c['quiet_since'] is None:
                c['quiet_since'] = self.clock()
                return False
            if self.clock() - c['quiet_since'] < RESOLVE_S:
                return False
            detail = f'{c["why"]}; no shutdown or write seen for {RESOLVE_S} s, so new requests are taken again'
            if not broker.publish('uncertain', detail=detail, replace_unreadable=True):
                return False
            broker.state_unreadable = False
            broker.committed = None
            self.release()
            drop_fence('broker')
        return True

    def run(self):
        while not self.stop_requested:
            try:
                self.step()
            except Exception as error:  # keep the fence; report and retry later
                log(f'commit step failed: {error!r}')
            self.wake.wait(self.interval)
            self.wake.clear()


class Broker:
    def __init__(self, listener, sel=None, runner=run, clock=time.monotonic, start_committer=True):
        self.listener = listener
        self.sel = sel or selectors.DefaultSelector()
        self.runner = runner
        self.clock = clock
        self.lock = threading.RLock()
        self.requests = {}
        self.prompts = {}  # tty rdev -> Request
        self.committed = None
        self.records = {}  # what state.json holds under "requests"
        self.state_unreadable = False  # never written over until resolved
        self.waiters = []
        self.outbox = queue.Queue()
        self.wake_r, self.wake_w = os.pipe()
        os.set_blocking(self.wake_r, False)
        os.set_blocking(self.wake_w, False)
        listener.setblocking(False)
        self.sel.register(listener, selectors.EVENT_READ, ('accept', None))
        self.sel.register(self.wake_r, selectors.EVENT_READ, ('wake', None))
        self.committer = Committer(self, runner, clock)
        self.recover()
        if start_committer:
            self.committer.start()

    @property
    def locks(self):
        return self.committer.locks

    def release(self):
        self.committer.release()

    # state published for CeraUI, the button light and operators
    def publish(self, state, request=None, notify=True, replace_unreadable=False, **extra):
        """The one writer of the broker's record (call with the lock held): the
        new state of `request` (default: the committed one) becomes the latest
        and its entry under "requests", in one atomic replacement of
        state.json. Nothing in memory changes unless that write happened, so
        what a client is told and what a restarted broker reads agree. Returns
        False when it couldn't be recorded."""
        if self.state_unreadable and not replace_unreadable:
            log(f'state not recorded ({state}): the earlier record was unreadable and is kept')
            return False
        request = request if request is not None else self.committed
        boot, uptime = boot_id(), boot_clock()
        record = {'state': state, 'time': int(time.time()), 'boot_id': boot, 'boottime': int(uptime)}
        if request:
            record.update({k: request[k] for k in ('id', 'action', 'origin')})
        record.update(extra)
        records = dict(self.records)
        if record.get('id'):
            records[record['id']] = record
        records = kept_records(records, boot, uptime, record.get('id'))
        try:
            write_json(STATE_FILE, dict(record, requests=records))
        except OSError as error:
            log(f'state not recorded ({state}): {error}')
            return False
        self.records = records
        if notify:
            self.notify(state, extra.get('detail'))
        log(f'state {record}')
        return True

    def notify(self, state, detail=None):
        line = state.upper() + (' ' + detail if detail else '')
        for request in list(self.waiters):
            self.outbox.put((request, line))
        self.poke()

    def recover(self):
        """A restarted broker never forgets an admitted request: one not yet
        submitted keeps waiting; one that may have reached logind is reported
        uncertain, keeps its fence and is not submitted again."""
        fence = read_fence('broker')
        try:
            with open(STATE_FILE) as source:
                record = json.load(source)
        except FileNotFoundError:
            record = {}
        except (OSError, ValueError):
            record = None
        if not isinstance(record, dict):
            # Never written over: it may hold a request that reached logind.
            self.state_unreadable = True
            return self.recover_unknown(fence or 'unknown', "the broker's record is unreadable")
        requests = record.get('requests')
        if isinstance(requests, dict):
            self.records = {k: v for k, v in requests.items() if isinstance(v, dict)}
        state = record.get('state')
        if state in ACTIVE_STATES and record.get('id') and record.get('action') in ('poweroff', 'reboot'):
            self.committed = {'id': record['id'], 'action': record['action'], 'origin': record.get('origin', 'unknown'),
                              'since': self.clock(), 'escalated': False}
            if state in ('admitted', 'waiting', 'stuck'):
                self.committed['stage'] = 'fence'
                self.publish('waiting', detail='resumed after a broker restart')
            else:
                self.committed['stage'] = 'uncertain'
                try:
                    put_fence('broker', record['id'])
                except OSError as error:
                    log(f'install fence not restored: {error}')
                self.committer.take_update()
                self.publish('uncertain', detail='the broker restarted after submitting; not resubmitted')
            return
        if fence is not None and (self.records.get(fence) or {}).get('state') != 'failed':
            # The fence is written after admission: a request got this far, and
            # its record is gone.
            return self.recover_unknown(fence, 'an install fence survived without its record')
        drop_fence('broker')
        self.publish('idle')

    def recover_unknown(self, request_id, why):
        """Evidence of a request without its record: it may have reached logind.
        Keep the fence and the update lock, report uncertain (when the record can
        be written) and admit nothing until settle_recovered clears it."""
        self.committed = {'id': request_id, 'action': 'unknown', 'origin': 'unknown', 'since': self.clock(),
                          'escalated': False, 'stage': 'recovered', 'why': why, 'quiet_since': None}
        try:
            put_fence('broker', request_id)
        except OSError as error:
            log(f'install fence not restored: {error}')
        self.committer.take_update()
        self.publish('uncertain', detail=f'{why}; nothing new is taken until no shutdown or write is seen for {RESOLVE_S} s')

    def fail(self, detail):
        """A definite failure. The request is let go only once its failure is
        recorded under its id; until then it stays (stage `failing`, retried by
        the committer) and no newer request can replace it."""
        failed = self.committed
        failed['stage'], failed['failure'] = 'failing', detail
        if not self.publish('failed', notify=False, detail=detail):
            if not failed.get('told'):
                # Whoever waits learns the outcome now, not only once it is written.
                failed['told'] = True
                self.notify('failed', f'{detail} (not recorded yet; the broker keeps this request until it is)')
                for request in list(self.waiters):
                    self.outbox.put((request, None))
                self.poke()
            return False
        self.committed = None
        self.notify('failed', detail)
        for request in list(self.waiters):
            self.outbox.put((request, None))
        self.poke()
        return True

    def poke(self):
        try:
            os.write(self.wake_w, b'.')
        except OSError:
            pass

    def send(self, request, line):
        if request.closed:
            return
        try:
            request.conn.send((line + '\n').encode())
        except OSError:
            self.close(request)

    def close(self, request):
        if request.closed:
            return
        request.closed = True
        if request in self.waiters:
            self.waiters.remove(request)
        self.close_tty(request)
        for fileobj in (request.conn, request.pidfd):
            if fileobj is None:
                continue
            try:
                self.sel.unregister(fileobj)
            except (KeyError, ValueError):
                pass
        if request.pidfd is not None:
            os.close(request.pidfd)
            request.pidfd = None
        self.requests.pop(request.conn, None)
        request.conn.close()

    def close_tty(self, request):
        if not request.tty:
            return
        fd, rdev = request.tty[0], request.tty[1]
        if self.prompts.get(rdev) is request:
            self.prompts.pop(rdev, None)
        try:
            self.sel.unregister(fd)
        except (KeyError, ValueError):
            pass
        os.close(fd)
        request.tty = None

    def refuse(self, request, reason):
        log(f'refused {request.action or "request"} from uid {request.uid}: {reason}')
        self.send(request, f'REFUSED {reason}')
        self.close(request)

    def service_peer(self, conn):
        try:
            _, uid, _, pidfd = peer_identity(conn)
        except (PeerError, OSError):
            return False
        try:
            return uid == 0 and system_unit(pidfd) in (BUTTON_UNIT, CERAUI_UNIT)
        except (PeerError, OSError):
            return False
        finally:
            os.close(pidfd)

    def accept(self):
        try:
            conn, _ = self.listener.accept()
        except BlockingIOError:
            return
        if len(self.requests) >= MAX_CONNECTIONS and not self.service_peer(conn):
            # Operators flooding the socket can't take the button's capacity.
            conn.close()
            return
        conn.setblocking(False)
        request = Request(conn, self.clock())
        self.requests[conn] = request
        self.sel.register(conn, selectors.EVENT_READ, ('client', request))

    def on_client(self, request):
        try:
            data = request.conn.recv(64)
        except OSError:
            data = b''
        if not data:
            # A client that leaves after commit does not cancel the action.
            self.close(request)
            return
        if request.action:
            return  # nothing else is read after the request line
        request.buffer += data
        if len(request.buffer) > 32:
            return self.refuse(request, 'bad request')
        if b'\n' not in request.buffer:
            return
        line = request.buffer.split(b'\n', 1)[0].decode(errors='replace').strip()
        if line not in ACTIONS:
            return self.refuse(request, 'bad request')
        request.action = ACTIONS[line]
        self.admit(request)

    def admit(self, request):
        try:
            _pid, uid, gid, pidfd = peer_identity(request.conn)
            request.pidfd, request.uid = pidfd, uid
            self.sel.register(pidfd, selectors.EVENT_READ, ('peer-exit', request))
            unit = system_unit(pidfd)
        except (PeerError, OSError) as error:
            return self.refuse(request, f'unverifiable caller: {error}')
        if uid == 0 and unit == BUTTON_UNIT:
            if request.action != 'poweroff':
                return self.refuse(request, 'the button may only power off')
            request.origin = 'button'
            return self.commit(request)
        if uid == 0 and unit == CERAUI_UNIT:
            request.origin = 'ceraui'
            return self.commit(request)
        if not is_operator(uid, gid):
            return self.refuse(request, 'not an operator')
        with self.lock:
            # Looked up and joined under one lock. Joining only follows a request
            # already admitted; it never creates one.
            if self.committed is not None:
                return self.join_committed(request)
        if len(self.prompts) >= MAX_PROMPTS:
            return self.refuse(request, 'too many confirmations pending')
        try:
            fd, proc = open_terminal(uid, pidfd)
        except (PeerError, OSError) as error:
            return self.refuse(request, f'needs your own terminal ({error})')
        rdev = proc['tty_nr']
        request.tty = [fd, rdev, proc, b'']
        if rdev in self.prompts:
            return self.refuse(request, 'a confirmation is already pending on this terminal')
        self.prompts[rdev] = request
        request.origin = 'terminal'
        request.deadline = self.clock() + PROMPT_S
        word = request.action
        what = 'power off' if word == 'poweroff' else 'restart'
        prompt = (f'\r\nThis will {what} the box. A stream or carried connection ends; a running '
                  f'update finishes first.\r\nType {word} and press Enter within {PROMPT_S} s: ')
        try:
            termios.tcflush(fd, termios.TCIFLUSH)  # input typed before the prompt never counts
            os.write(fd, prompt.encode())
        except (termios.error, OSError):
            return self.refuse(request, 'terminal not usable')
        self.sel.register(fd, selectors.EVENT_READ, ('tty', request))

    def on_tty(self, request):
        if self.clock() >= request.deadline:
            return self.refuse(request, 'timed out')
        fd, rdev, proc, answer = request.tty
        try:
            data = os.read(fd, 64)
        except BlockingIOError:
            return
        except OSError:
            return self.refuse(request, 'terminal closed')
        if not data:
            return self.refuse(request, 'terminal closed')
        answer += data
        if len(answer) > 64:
            return self.refuse(request, 'answer too long')
        request.tty[3] = answer
        if b'\n' not in answer and b'\r' not in answer:
            return
        typed = answer.replace(b'\r', b'\n').split(b'\n', 1)[0].decode(errors='replace').strip()
        try:
            # The peer, its foreground group, namespace and the opened terminal,
            # once more, right before committing.
            now = check_terminal(request.uid, request.pidfd, fd, rdev)
            if now['pgrp'] != proc['pgrp'] or now['session'] != proc['session']:
                raise PeerError('terminal or foreground changed')
        except (PeerError, OSError) as error:
            return self.refuse(request, f'not confirmed ({error})')
        if typed != request.action:
            return self.refuse(request, 'not confirmed')
        self.close_tty(request)
        request.confirmed = True
        self.commit(request)

    def join_committed(self, request):
        """Follow the pending request, or refuse. Never creates one."""
        with self.lock:
            c = self.committed
            if c is None:
                return self.refuse(request, 'nothing pending to join')
            if c['stage'] == 'failing':
                return self.refuse(request, f'the last request was refused by logind ({c["failure"]}) and could not be '
                                            'recorded yet; nothing is submitted until it is')
            if c['stage'] == 'recovered':
                return self.refuse(request, f"an earlier request's outcome is unknown ({c['why']}); new requests are "
                                            f'taken once no shutdown or write is seen for {RESOLVE_S} s')
            if c['action'] != request.action:
                return self.refuse(request, f'{c["action"]} already pending')
            self.send(request, f'PENDING {c["action"]} {c["id"]}')
            self.waiters.append(request)

    def commit(self, request):
        """Create the request: only for a service origin or an operator whose
        typed word was checked on their own terminal."""
        if request.origin not in ('button', 'ceraui') and not request.confirmed:
            return self.refuse(request, 'not confirmed')
        with self.lock:
            if self.committed:
                return self.join_committed(request)
            c = {'id': uuid.uuid4().hex[:12], 'action': request.action, 'origin': request.origin,
                 'since': self.clock(), 'stage': 'fence', 'escalated': False}
            # Recorded (one atomic write) before it exists here or is acknowledged.
            if not self.publish('admitted', request=c, detail=f'{request.action} {c["id"]}'):
                return self.refuse(request, 'could not record the request')
            self.committed = c
            log(f'admitted {request.action} from {request.origin} (uid {request.uid}) as {c["id"]}')
            self.waiters.append(request)
            self.outbox.put((request, f'ADMITTED {request.action} {self.committed["id"]}'))
            self.poke()
        self.committer.wake.set()

    def deliver(self):
        try:
            while os.read(self.wake_r, 4096):
                pass
        except BlockingIOError:
            pass
        while True:
            try:
                request, line = self.outbox.get_nowait()
            except queue.Empty:
                return
            if line is None:
                self.close(request)
            else:
                self.send(request, line)

    def tick(self):
        now = self.clock()
        for request in list(self.requests.values()):
            if not request.closed and request not in self.waiters and now >= request.deadline:
                self.refuse(request, 'timed out')

    def step(self, timeout=1.0):
        for key, _ in self.sel.select(timeout):
            kind, request = key.data
            if kind == 'accept':
                self.accept()
            elif kind == 'wake':
                self.deliver()
            elif request.closed:
                continue
            elif kind == 'client':
                self.on_client(request)
            elif kind == 'tty':
                self.on_tty(request)
            elif kind == 'peer-exit':
                if request.tty:
                    self.refuse(request, 'caller exited')
                else:
                    try:
                        self.sel.unregister(request.pidfd)
                    except (KeyError, ValueError):
                        pass
        self.deliver()
        self.tick()


def listener_from_systemd():
    if os.environ.get('LISTEN_PID') == str(os.getpid()) and os.environ.get('LISTEN_FDS') == '1':
        return socket.socket(fileno=3)
    raise SystemExit('ceralive-power-broker must be started by its socket unit')


def main(argv):
    if argv[1:] == ['drain']:
        return drain()
    if argv[1:]:
        print('usage: ceralive-power-broker [drain]', file=sys.stderr)
        return 64
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)
    broker = Broker(listener_from_systemd())
    while True:
        broker.step()


if __name__ == '__main__':
    sys.exit(main(sys.argv))

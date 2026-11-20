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

Admitted intent is queued here, upstream of logind: new writers are fenced
(the shared update lock and dpkg's frontend lock), running writers drain (RAUC's
Installer.Operation, the writer units), and only then the broker asks logind
directly over D-Bus (PowerOffWithFlags/RebootWithFlags with SKIP_INHIBITORS).
There is no systemctl and no fallback to a direct target start: a refusal is
reported as failed, an unanswered call as uncertain, and neither is retried.
After ESCALATE_S a waiting request is reported as stuck and keeps waiting;
cutting a write takes a separate, deliberate emergency action.

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
import selectors
import signal
import socket
import stat
import struct
import subprocess
import sys
import termios
import time

RUN_DIR = os.environ.get('CERALIVE_POWER_RUN_DIR', '/run/ceralive-power')
STATE_FILE = os.path.join(RUN_DIR, 'state.json')
UPDATE_LOCK = os.environ.get('CERALIVE_UPDATE_LOCK_PATH', '/run/lock/ceralive-update.lock')
DPKG_LOCK = os.environ.get('CERALIVE_DPKG_LOCK_PATH', '/var/lib/dpkg/lock-frontend')
ACTIVATION_LOCK = os.environ.get('CERALIVE_ACTIVATION_LOCK', '/run/lock/ceralive-rauc-activate.lock')
OPERATOR_GROUP = 'ceralive-power'
BUTTON_UNIT = 'ceralive-button.service'
CERAUI_UNIT = 'ceralive.service'
WRITER_UNITS = ('ceralive-software-update.service', 'ceralive-os-stage-guard.service',
                'ceralive-slot-sync.service')
WRITER_UNIT_PATTERNS = ('ceralive-kernel-stage-*.service',)
HAWKBIT_UNIT = 'rauc-hawkbit-updater.service'
SYSTEM_MOUNT_NS = '/proc/1/ns/mnt'
ESCALATE_S = 900
PROMPT_S = 60
FIRST_READ_S = 5
MAX_CONNECTIONS = 32
MAX_PROMPTS = 4
SO_PEERPIDFD = getattr(socket, 'SO_PEERPIDFD', 77)
SKIP_INHIBITORS = 1 << 4
ACTIONS = {'POWEROFF': ('poweroff', 'PowerOffWithFlags'), 'REBOOT': ('reboot', 'RebootWithFlags')}


def log(message):
    print(message, flush=True)


# --- the shared writer check (broker and shutdown drain) ---------------------

def run(argv, timeout):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)


def rauc_installing(runner=run):
    """True while RAUC's service is installing, whoever started it (CLI, D-Bus,
    hawkBit) and even after its client went away. An unreadable answer counts as
    installing; only a missing service counts as idle."""
    try:
        out = runner(['busctl', '--system', '--timeout=5', 'get-property', 'de.pengutronix.rauc',
                      '/', 'de.pengutronix.rauc.Installer', 'Operation'], 10)
    except (OSError, subprocess.SubprocessError):
        return True
    if out.returncode == 0:
        return out.stdout.split() != ['s', '"idle"']
    unknown = ('ServiceUnknown', 'was not provided by any .service', 'not activatable', 'No such')
    return not any(text in out.stderr for text in unknown)


def active_writer_units(runner=run):
    try:
        out = runner(['systemctl', 'list-units', '--no-legend', '--plain', '--state=active,activating,deactivating',
                      '--type=service', *WRITER_UNITS, *WRITER_UNIT_PATTERNS], 10)
    except (OSError, subprocess.SubprocessError):
        return ['(unit state unreadable)']
    if out.returncode != 0:
        return ['(unit state unreadable)']
    return [line.split()[0] for line in out.stdout.splitlines() if line.strip()]


def dpkg_lock_holder(path=None, ignore_pid=None):
    """PID holding dpkg's frontend lock (fcntl, like apt and dpkg), else None."""
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
        if kind == fcntl.F_UNLCK or pid == ignore_pid:
            return None
        return pid
    except OSError:
        return -1
    finally:
        os.close(fd)


def busy_writers(ignore_pid=None, runner=run):
    busy = []
    if rauc_installing(runner):
        busy.append('os-install (rauc.service)')
    busy.extend(active_writer_units(runner))
    holder = dpkg_lock_holder(ignore_pid=ignore_pid)
    if holder is not None:
        busy.append(f'package-install (dpkg, pid {holder})')
    return busy


def drain(sleep=time.sleep, now=time.monotonic, runner=run):
    """ExecStop of ceralive-write-drain.service: wait for running writes, only
    while the system is shutting down; a manual stop returns at once."""
    try:
        state = runner(['systemctl', 'is-system-running'], 10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        state = 'stopping'
    if state != 'stopping':
        return 0
    started, last, escalated = now(), None, False
    while True:
        busy = busy_writers(runner=runner)
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
    pid, uid, gid = struct.unpack('3i', conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
    try:
        pidfd = struct.unpack('i', conn.getsockopt(socket.SOL_SOCKET, SO_PEERPIDFD, 4))[0]
    except OSError as error:
        raise PeerError(f'no peer pidfd ({error.strerror})') from error
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


def open_terminal(uid, pidfd):
    """Open the peer's own foreground controlling terminal, verified on the fd."""
    pid, data = read_bracketed(pidfd, 'stat')
    proc = parse_stat(data)
    if proc['tty_nr'] == 0:
        raise PeerError('no controlling terminal')
    if proc['tpgid'] != proc['pgrp']:
        raise PeerError('not in the foreground of its terminal')
    if not same_mount_namespace(pid):
        raise PeerError('terminal in another mount namespace')
    path = tty_path(proc['tty_nr'])
    if path is None:
        raise PeerError('unsupported terminal')
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISCHR(info.st_mode) or info.st_rdev != proc['tty_nr']:
            raise PeerError('terminal changed')
        # A root shell reached through sudo still sits on the login user's
        # terminal: the login account connects directly, root only from its own.
        if info.st_uid != uid:
            raise PeerError('terminal owned by another account')
        # Foreground: the caller's tpgid is the kernel's view of its terminal's
        # foreground group (tcgetpgrp only works on one's own terminal).
    except BaseException:
        os.close(fd)
        raise
    return fd, info.st_rdev, proc


def revalidate(uid, pidfd, fd, rdev, proc):
    _, data = read_bracketed(pidfd, 'stat')
    now = parse_stat(data)
    info = os.fstat(fd)
    if (now['tty_nr'] != rdev or now['pgrp'] != proc['pgrp'] or now['session'] != proc['session']
            or now['tpgid'] != now['pgrp'] or info.st_rdev != rdev or info.st_uid != uid):
        raise PeerError('terminal or foreground changed')


# --- the broker ------------------------------------------------------------------

class Request:
    def __init__(self, conn, now):
        self.conn = conn
        self.buffer = b''
        self.deadline = now + FIRST_READ_S
        self.action = None
        self.origin = None
        self.pidfd = None
        self.uid = None
        self.tty = None  # (fd, rdev, proc, answer bytes)
        self.closed = False


class Broker:
    def __init__(self, listener, sel=None, runner=run, clock=time.monotonic):
        self.listener = listener
        self.sel = sel or selectors.DefaultSelector()
        self.runner = runner
        self.clock = clock
        self.requests = {}
        self.prompts = {}  # tty rdev -> Request
        self.committed = None  # {'action', 'origin', 'since', 'stage', ...}
        self.waiters = []
        self.locks = {}
        listener.setblocking(False)
        self.sel.register(listener, selectors.EVENT_READ, ('accept', None))
        self.publish('idle')

    # state published for CeraUI, the button light and operators
    def publish(self, state, **extra):
        record = {'state': state, 'time': int(time.time())}
        if self.committed:
            record.update({k: self.committed[k] for k in ('action', 'origin')})
        record.update(extra)
        try:
            os.makedirs(RUN_DIR, exist_ok=True)
            temp = STATE_FILE + '.new'
            with open(temp, 'w') as out:
                json.dump(record, out)
            os.chmod(temp, 0o644)
            os.replace(temp, STATE_FILE)
        except OSError as error:
            log(f'state not published: {error}')
        line = state.upper() + (' ' + extra['detail'] if extra.get('detail') else '')
        for request in list(self.waiters):
            self.send(request, line)
        log(f'state {record}')

    def send(self, request, line):
        if request.closed:
            return
        try:
            request.conn.send((line + '\n').encode())
        except OSError:
            self.close(request, keep_waiting=False)

    def close(self, request, keep_waiting=False):
        if request.closed:
            return
        request.closed = True
        if request in self.waiters:
            self.waiters.remove(request)
        if request.tty:
            self.prompts.pop(request.tty[1], None)
            try:
                self.sel.unregister(request.tty[0])
            except (KeyError, ValueError):
                pass
            os.close(request.tty[0])
            request.tty = None
        for fileobj in (request.conn,):
            try:
                self.sel.unregister(fileobj)
            except (KeyError, ValueError):
                pass
        if request.pidfd is not None:
            try:
                self.sel.unregister(request.pidfd)
            except (KeyError, ValueError):
                pass
            os.close(request.pidfd)
            request.pidfd = None
        self.requests.pop(request.conn, None)
        request.conn.close()

    def refuse(self, request, reason):
        log(f'refused {request.action or "request"} from uid {request.uid}: {reason}')
        self.send(request, f'REFUSED {reason}')
        self.close(request)

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
        if len(request.buffer) > 32 or (b'\n' not in request.buffer and len(request.buffer) >= 32):
            return self.refuse(request, 'bad request')
        if b'\n' not in request.buffer:
            return
        line = request.buffer.split(b'\n', 1)[0].decode(errors='replace').strip()
        if line not in ACTIONS:
            return self.refuse(request, 'bad request')
        request.action = ACTIONS[line][0]
        self.admit(request)

    def admit(self, request):
        try:
            pid, uid, gid, pidfd = peer_identity(request.conn)
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
        if self.committed:
            return self.join_committed(request)
        if len(self.prompts) >= MAX_PROMPTS:
            return self.refuse(request, 'too many confirmations pending')
        try:
            fd, rdev, proc = open_terminal(uid, pidfd)
        except (PeerError, OSError) as error:
            return self.refuse(request, f'needs your own terminal ({error})')
        if rdev in self.prompts:
            os.close(fd)
            return self.refuse(request, 'a confirmation is already pending on this terminal')
        termios.tcflush(fd, termios.TCIFLUSH)  # input typed before the prompt never counts
        request.tty = (fd, rdev, proc, b'')
        request.origin = 'terminal'
        request.deadline = self.clock() + PROMPT_S
        self.prompts[rdev] = request
        word = request.action
        what = 'power off' if word == 'poweroff' else 'restart'
        prompt = (f'\r\nThis will {what} the box. A stream or carried connection ends; a running '
                  f'update finishes first.\r\nType {word} and press Enter within {PROMPT_S} s: ')
        try:
            os.write(fd, prompt.encode())
        except OSError:
            return self.refuse(request, 'terminal not writable')
        self.sel.register(fd, selectors.EVENT_READ, ('tty', request))

    def on_tty(self, request):
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
        request.tty = (fd, rdev, proc, answer)
        if b'\n' not in answer and b'\r' not in answer:
            return
        typed = answer.replace(b'\r', b'\n').split(b'\n', 1)[0].decode(errors='replace').strip()
        try:
            revalidate(request.uid, request.pidfd, fd, rdev, proc)
        except (PeerError, OSError) as error:
            return self.refuse(request, f'not confirmed ({error})')
        if typed != request.action:
            return self.refuse(request, 'not confirmed')
        self.sel.unregister(fd)
        os.close(fd)
        self.prompts.pop(rdev, None)
        request.tty = None
        self.commit(request)

    def join_committed(self, request):
        if self.committed['action'] != request.action:
            return self.refuse(request, f'{self.committed["action"]} already pending')
        self.send(request, f'PENDING {self.committed["action"]}')
        self.waiters.append(request)

    def commit(self, request):
        if self.committed:
            return self.join_committed(request)
        self.committed = {'action': request.action, 'origin': request.origin,
                          'since': self.clock(), 'stage': 'fence', 'escalated': False}
        log(f'admitted {request.action} from {request.origin} (uid {request.uid})')
        self.waiters.append(request)
        self.publish('admitted', detail=request.action)
        self.advance()

    # fencing and draining, one non-blocking step per tick
    def take_flock(self, name, path):
        if name in self.locks:
            return True
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            return False
        self.locks[name] = fd
        return True

    def take_dpkg(self):
        if 'dpkg' in self.locks:
            return True
        try:
            fd = os.open(DPKG_LOCK, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o640)
        except FileNotFoundError:
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

    def activation_idle(self):
        try:
            fd = os.open(ACTIVATION_LOCK, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o644)
        except OSError:
            return True
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(fd, fcntl.LOCK_UN)
            return True
        except BlockingIOError:
            return False
        finally:
            os.close(fd)

    def release(self, *names):
        for name in names or list(self.locks):
            fd = self.locks.pop(name, None)
            if fd is not None:
                os.close(fd)

    def advance(self):
        c = self.committed
        if not c or c['stage'] not in ('fence', 'drain'):
            return
        waiting = []
        if not self.take_flock('update', UPDATE_LOCK):
            waiting.append('update lock (an update or slot sync is running)')
        if not self.take_dpkg():
            waiting.append('package-install (dpkg)')
        if not waiting:
            if c['stage'] == 'fence':
                c['stage'] = 'drain'
                self.stop_hawkbit()
            waiting = busy_writers(ignore_pid=os.getpid(), runner=self.runner)
            if not waiting and not self.activation_idle():
                waiting = ['slot activation']
        if waiting:
            waited = self.clock() - c['since']
            detail = ', '.join(waiting)
            if waited >= ESCALATE_S and not c['escalated']:
                c['escalated'] = True
                self.publish('stuck', detail=detail, waited=int(waited))
            elif c.get('detail') != detail:
                self.publish('stuck' if c['escalated'] else 'waiting', detail=detail, waited=int(waited))
            c['detail'] = detail
            return
        self.submit()

    def stop_hawkbit(self):
        try:
            out = self.runner(['systemctl', 'is-active', HAWKBIT_UNIT], 10)
            if out.stdout.strip() in ('active', 'activating', 'reloading'):
                log('stopping the dormant-by-default hawkBit updater so it cannot start an install')
                self.runner(['systemctl', 'stop', HAWKBIT_UNIT], 60)
        except (OSError, subprocess.SubprocessError):
            pass

    def submit(self):
        c = self.committed
        c['stage'] = 'submitting'
        method = 'RebootWithFlags' if c['action'] == 'reboot' else 'PowerOffWithFlags'
        self.publish('submitting')
        argv = ['busctl', '--system', '--timeout=25', 'call', 'org.freedesktop.login1',
                '/org/freedesktop/login1', 'org.freedesktop.login1.Manager', method, 't', str(SKIP_INHIBITORS)]
        try:
            out = self.runner(argv, 40)
        except subprocess.TimeoutExpired:
            c['stage'] = 'uncertain'
            return self.publish('uncertain', detail='logind did not answer; not retried')
        except OSError as error:
            out = subprocess.CompletedProcess(argv, 127, '', str(error))
        if out.returncode == 0:
            c['stage'] = 'submitted'
            # The shutdown transaction is queued; new units can no longer start.
            # dpkg's lock goes so the shutdown drain is not waiting on us.
            self.release('dpkg')
            return self.publish('submitted')
        reason = (out.stderr or out.stdout).strip().splitlines()[-1:] or ['refused']
        if 'Timeout' in reason[0] or 'timed out' in reason[0] or 'Connection reset' in reason[0]:
            c['stage'] = 'uncertain'
            return self.publish('uncertain', detail=reason[0] + '; not retried')
        self.release()
        failed = self.committed
        self.committed = None
        self.publish('failed', detail=reason[0], action=failed['action'], origin=failed['origin'])
        for request in list(self.waiters):
            self.close(request)

    def tick(self):
        now = self.clock()
        for request in list(self.requests.values()):
            if not request.closed and request not in self.waiters and now >= request.deadline:
                self.refuse(request, 'timed out')
        self.advance()

    def step(self, timeout=1.0):
        for key, _ in self.sel.select(timeout):
            kind, request = key.data
            if kind == 'accept':
                self.accept()
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

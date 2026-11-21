"""Hardware-free contracts for the power admission broker.

Real Unix sockets with socket-bound peer pidfds, a real pseudo-terminal for the
operator prompt and real flock/fcntl locks; only systemd, logind and RAUC are
answered by a fake command runner. The real-logind behaviour is covered by the
opt-in tests/real-power-admission.sh.
"""
import atexit
import fcntl
import json
import importlib.util
import os
import pty
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
RUN = tempfile.mkdtemp(prefix='power-admission-')
atexit.register(shutil.rmtree, RUN, ignore_errors=True)
os.environ['CERALIVE_POWER_RUN_DIR'] = RUN
spec = importlib.util.spec_from_file_location('broker', ROOT / 'mkosi/runtime/power/ceralive-power-broker.py')
broker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(broker)


class FakeSystem:
    """Answers the commands the broker and drain run."""

    def __init__(self):
        self.installing = False
        self.units = []
        self.receipts = []
        self.rauc_pid = None
        self.rauc_pids = []  # successive owners, one per lookup (the last one stays)
        self.on_lookup = None
        self.rauc_unit = 'inactive'
        self.preparing = False  # logind's PreparingForShutdown
        self.jobs = []  # queued systemd jobs, as `systemctl list-jobs` rows
        self.system_state = 'running'
        self.logind = 'ok'  # ok | refuse | hang
        self.calls = []

    def __call__(self, argv, timeout):
        self.calls.append(argv)
        out = lambda code=0, stdout='', stderr='': subprocess.CompletedProcess(argv, code, stdout, stderr)
        if argv[:1] == ['busctl'] and 'PreparingForShutdown' in argv:
            return out(0, 'b true\n' if self.preparing else 'b false\n')
        if argv[:1] == ['busctl'] and 'get-property' in argv:
            return out(0, 's "installing"\n' if self.installing else 's "idle"\n')
        if argv[:2] == ['systemctl', 'list-jobs']:
            return out(0, ''.join(f'{i} {unit} start waiting\n' for i, unit in enumerate(self.jobs, 1)))
        if argv[:1] == ['busctl'] and 'GetConnectionUnixProcessID' in argv:
            if self.on_lookup:
                self.on_lookup()
            if self.rauc_pids:
                self.rauc_pid = self.rauc_pids.pop(0) if len(self.rauc_pids) > 1 else self.rauc_pids[0]
            if self.rauc_pid is None:
                return out(1, '', 'Call failed: The name de.pengutronix.rauc does not have an owner (NameHasNoOwner)\n')
            return out(0, f'u {self.rauc_pid}\n')
        if argv[:1] == ['dbus-send']:
            if self.logind == 'hang':
                raise subprocess.TimeoutExpired(argv, timeout)
            if self.logind == 'refuse':
                return out(1, '', 'Error org.freedesktop.DBus.Error.AccessDenied: Access denied\n')
            if self.logind == 'noreply':
                return out(1, '', 'Error org.freedesktop.DBus.Error.NoReply: Did not receive a reply\n')
            if self.logind == 'unknown':
                return out(1, '', 'Error org.freedesktop.DBus.Error.ServiceUnknown: The name is not activatable\n')
            if self.logind == 'noname':
                return out(1, '', 'Failed to open connection to "system" message bus\n')
            return out(0, 'method return time=1\n')
        if argv[:2] == ['systemctl', 'list-units']:
            rows = [f'{unit} loaded active running x' for unit in self.units]
            rows += [f'{unit} loaded active exited x' for unit in self.receipts]
            return out(0, ''.join(row + '\n' for row in rows))
        if argv[:2] == ['systemctl', 'show'] and 'rauc.service' in argv:
            return out(0, self.rauc_unit + '\n')
        if argv[:2] == ['systemctl', 'is-system-running']:
            return out(0, self.system_state + '\n')
        if argv[:2] == ['systemctl', 'is-active']:
            return out(3, 'inactive\n')
        return out(0)

    def submissions(self):
        return [argv for argv in self.calls if argv[:1] == ['dbus-send']]


class Harness(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix='broker-')
        # Cleanups run after tearDown, so the broker and listener are gone first.
        self.addCleanup(shutil.rmtree, self.dir)
        self.paths = {name: os.path.join(self.dir, name) for name in ('update.lock', 'lock-frontend', 'activate.lock')}
        for path in self.paths.values():
            Path(path).touch()
        self.fence_dir = os.path.join(self.dir, 'fence.d')
        self.fence = os.path.join(self.fence_dir, 'broker')
        self.state = os.path.join(self.dir, 'state.json')
        self.proc = os.path.join(self.dir, 'proc')
        os.makedirs(os.path.join(self.proc, '4242'))
        Path(self.proc, '4242', 'cmdline').write_bytes(b'/usr/bin/rauc\0--mount=/run/rauc/mnt\0service\0')
        Path(self.proc, '4242', 'mountinfo').write_text('')
        self.rauc_proc(4242, start=777)
        self.patches = [
            patch.object(broker, 'UPDATE_LOCK', self.paths['update.lock']),
            patch.object(broker, 'DPKG_LOCK', self.paths['lock-frontend']),
            patch.object(broker, 'ACTIVATION_LOCK', self.paths['activate.lock']),
            # Unprivileged tests can't read PID 1's namespace; same host namespace.
            patch.object(broker, 'SYSTEM_MOUNT_NS', '/proc/self/ns/mnt'),
            patch.object(broker, 'PROC_ROOT', self.proc),
            patch.object(broker, 'RAUC_SYSTEM_CONF', os.path.join(self.dir, 'system.conf')),
            patch.object(broker, 'FENCE_DIR', self.fence_dir),
            patch.object(broker, 'STATE_FILE', self.state),
            patch.object(broker, 'RUN_DIR', self.dir),
        ]
        for p in self.patches:
            p.start()
        # A socket path stops at 107 bytes and TMPDIR can be long: bind and
        # connect through a descriptor of this directory, a short path that
        # resolves to it in this process and in children that inherit it.
        self.dir_fd = os.open(self.dir, os.O_RDONLY | os.O_DIRECTORY)
        self.addCleanup(os.close, self.dir_fd)
        self.sock_path = f'/proc/self/fd/{self.dir_fd}/request.sock'
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.sock_path)
        self.listener.listen(8)
        self.system = FakeSystem()
        self.system.rauc_pid = 4242  # RAUC's service runs, idle
        self.system.rauc_unit = 'active'
        self.clock = [1000.0]
        self.broker = self.new_broker()
        self.children = []

    def tearDown(self):
        for pid, fd in self.children:
            try:
                os.kill(pid, 9)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
            if fd is not None:
                os.close(fd)
        self.broker.release()
        self.listener.close()
        for p in self.patches:
            p.stop()

    def rauc_proc(self, pid, start, mounts=()):
        os.makedirs(os.path.join(self.proc, str(pid)), exist_ok=True)
        Path(self.proc, str(pid), 'cmdline').write_bytes(b'/usr/bin/rauc\0--mount=/run/rauc/mnt\0service\0')
        Path(self.proc, str(pid), 'mountinfo').write_text(
            ''.join(f'36 25 0:31 / {m} ro - squashfs /dev/loop3 ro\n' for m in mounts))
        Path(self.proc, str(pid), 'stat').write_text(
            f'{pid} (rauc) S 1 {pid} {pid} 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 3 0 {start} 1000 100\n')

    def persisted(self, request_id):
        """The broker's persisted record of one request, as CeraUI reads it."""
        try:
            document = json.loads(self.state_json())
        except (OSError, ValueError):
            return None
        if isinstance(document.get('requests'), dict):
            return document['requests'].get(request_id)
        try:
            return json.loads(Path(self.dir, 'requests', request_id + '.json').read_text())
        except OSError:
            return None

    def new_broker(self):
        return broker.Broker(self.listener, runner=self.system, clock=lambda: self.clock[0], start_committer=False)

    def state_json(self):
        return Path(self.state).read_text()

    def pump(self, until, rounds=200):
        for _ in range(rounds):
            self.broker.step(0.02)
            with self.broker.lock:
                self.broker.committer.step()
            self.broker.deliver()
            if until():
                return True
        return False

    def connect(self, action=b'POWEROFF\n'):
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.connect(self.sock_path)
        conn.sendall(action)
        conn.setblocking(False)
        return conn

    def lines(self, conn):
        try:
            return conn.recv(4096).decode().splitlines()
        except BlockingIOError:
            return []

    def operator_on_pty(self, action=b'POWEROFF\n', before_connect=None):
        """A client in its own session with a pty as its controlling terminal,
        in the foreground, like an interactive shell command."""
        out_r, out_w = os.pipe()
        pid, master = pty.fork()
        if pid == 0:
            os.close(out_r)
            # A real client is its own process: drop the copies of the broker's
            # lock descriptors this fork inherited (a flock lives as long as any
            # copy of its descriptor).
            for fd in list(self.broker.locks.values()):
                if fd is not None:
                    os.close(fd)
            if before_connect:
                before_connect()
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.connect(self.sock_path)
            conn.sendall(action)
            while True:
                data = conn.recv(4096)
                if not data:
                    break
                os.write(out_w, data)
            os._exit(0)
        os.close(out_w)
        self.children.append((pid, master))
        os.set_blocking(out_r, False)
        return pid, master, out_r

    @staticmethod
    def read_pipe(fd):
        try:
            return os.read(fd, 4096).decode()
        except BlockingIOError:
            return ''

    @staticmethod
    def read_master(master):
        data = b''
        while select.select([master], [], [], 0.05)[0]:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break
            if not chunk:
                break
            data += chunk
        return data.decode(errors='replace')


class Operator(Harness):
    def setUp(self):
        super().setUp()
        self.op = patch.object(broker, 'is_operator', lambda uid, gid: True)
        self.op.start()

    def tearDown(self):
        self.op.stop()
        super().tearDown()

    def test_typed_word_on_own_terminal_admits_and_submits_to_logind_only(self):
        pid, master, out = self.operator_on_pty()
        self.assertTrue(self.pump(lambda: 'Type poweroff' in self.read_master(master)), 'no prompt on the terminal')
        os.write(master, b'poweroff\n')
        self.assertTrue(self.pump(lambda: self.system.submissions()))
        submitted = self.system.submissions()
        self.assertEqual(len(submitted), 1)
        self.assertEqual(submitted[0][-2:], ['org.freedesktop.login1.Manager.PowerOffWithFlags', f'uint64:{broker.SKIP_INHIBITORS}'])
        self.assertNotIn('systemctl', [argv[0] for argv in self.system.calls if 'poweroff' in argv])
        self.assertTrue(self.pump(lambda: 'SUBMITTED' in self.read_pipe(out) or self.broker.committed['stage'] == 'submitted'))
        self.assertEqual(self.broker.committed['stage'], 'submitted')
        self.assertIn('update', self.broker.locks, 'new writers stay fenced after submission')
        self.assertNotIn('dpkg', self.broker.locks, 'dpkg released so the shutdown drain cannot wait on the broker')

    def test_input_typed_before_the_prompt_never_counts(self):
        pid, master, out = self.operator_on_pty()
        os.write(master, b'poweroff\n')  # queued before the broker prompts
        self.assertTrue(self.pump(lambda: 'Type poweroff' in self.read_master(master)))
        self.pump(lambda: False, rounds=20)
        self.assertEqual(self.system.submissions(), [])
        self.assertIsNone(self.broker.committed)

    def test_wrong_word_is_refused(self):
        pid, master, out = self.operator_on_pty()
        self.assertTrue(self.pump(lambda: 'Type poweroff' in self.read_master(master)))
        os.write(master, b'yes\n')
        self.assertTrue(self.pump(lambda: 'REFUSED not confirmed' in self.read_pipe(out)))
        self.assertIsNone(self.broker.committed)
        self.assertEqual(self.system.submissions(), [])

    def test_no_terminal_is_refused(self):
        conn = self.connect()
        self.assertTrue(self.pump(lambda: any('REFUSED needs your own terminal' in l for l in self.lines(conn))))
        self.assertIsNone(self.broker.committed)

    def test_prompt_times_out(self):
        pid, master, out = self.operator_on_pty()
        self.assertTrue(self.pump(lambda: 'Type poweroff' in self.read_master(master)))
        self.clock[0] += broker.PROMPT_S + 1
        self.assertTrue(self.pump(lambda: 'REFUSED timed out' in self.read_pipe(out)))
        self.assertIsNone(self.broker.committed)

    def test_caller_exit_during_prompt_is_refused(self):
        pid, master, out = self.operator_on_pty()
        self.assertTrue(self.pump(lambda: 'Type poweroff' in self.read_master(master)))
        os.kill(pid, 9)
        os.waitpid(pid, 0)
        self.children = [(p, m) for p, m in self.children if p != pid] + [(pid, master)]
        self.assertTrue(self.pump(lambda: not self.broker.prompts, rounds=50), 'prompt outlived its caller')
        self.assertIsNone(self.broker.committed)

    def test_a_pending_prompt_never_blocks_the_button(self):
        pid, master, out = self.operator_on_pty()
        self.assertTrue(self.pump(lambda: 'Type poweroff' in self.read_master(master)))
        self.assertEqual(len(self.broker.prompts), 1)
        # The operator hasn't answered; the button's hold arrives meanwhile.
        with patch.object(broker, 'system_unit', lambda pidfd: 'ceralive-button.service'), \
             patch.object(broker, 'peer_identity', lambda c, real=broker.peer_identity: (lambda r: (r[0], 0, r[2], r[3]))(real(c))), \
             patch.object(broker, 'is_operator', lambda uid, gid: False):
            conn = self.connect()
            got = []
            self.assertTrue(self.pump(lambda: got.extend(self.lines(conn)) or any(l.startswith('SUBMITTED') for l in got)))
        self.assertEqual(self.broker.committed['origin'], 'button')
        self.assertEqual(len(self.system.submissions()), 1)
        # The late answer joins the committed power-off instead of a second submission.
        os.write(master, b'poweroff\n')
        self.pump(lambda: 'PENDING poweroff' in self.read_pipe(out), rounds=50)
        self.assertEqual(len(self.system.submissions()), 1)

    def test_button_is_served_when_operators_fill_the_socket(self):
        flood = [socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) for _ in range(broker.MAX_CONNECTIONS + 4)]
        for c in flood:
            c.connect(self.sock_path)
            self.broker.step(0)  # accept as they come; the listen backlog is small
        self.pump(lambda: len(self.broker.requests) >= broker.MAX_CONNECTIONS, rounds=50)
        self.assertEqual(len(self.broker.requests), broker.MAX_CONNECTIONS)
        with patch.object(broker, 'system_unit', lambda pidfd: 'ceralive-button.service'), \
             patch.object(broker, 'peer_identity', lambda c, real=broker.peer_identity: (lambda r: (r[0], 0, r[2], r[3]))(real(c))):
            conn = self.connect()
            got = []
            self.assertTrue(self.pump(lambda: got.extend(self.lines(conn)) or any(l.startswith('SUBMITTED') for l in got)))
        for c in flood:
            c.close()

    def test_one_prompt_per_terminal(self):
        pid, master, out = self.operator_on_pty()
        self.assertTrue(self.pump(lambda: 'Type poweroff' in self.read_master(master)))
        rdev = next(iter(self.broker.prompts))
        self.assertEqual(len(self.broker.prompts), 1)
        self.assertIn(rdev, self.broker.prompts)


class NamespacedTerminal(Operator):
    """A shell in another mount namespace that still uses the system's devpts,
    like a Tailscale SSH session (tailscaled.service has its own namespace from
    ReadOnlyPaths=, and its sessions inherit it): its terminal is proven by the
    open file itself. A private devpts instance, whose pty numbers can collide
    with a system terminal, is still refused."""

    def setUp(self):
        if not hasattr(os, 'unshare'):
            self.skipTest('os.unshare needs Python 3.12')
        probe = subprocess.run(['unshare', '-Urm', 'true'], capture_output=True)
        if probe.returncode != 0:
            self.skipTest('unprivileged user namespaces are not available')
        super().setUp()

    @staticmethod
    def own_mount_namespace():
        os.unshare(os.CLONE_NEWUSER | os.CLONE_NEWNS)

    def test_a_shell_in_another_mount_namespace_on_the_system_devpts_is_prompted(self):
        pid, master, out = self.operator_on_pty(before_connect=self.own_mount_namespace)
        self.assertTrue(self.pump(lambda: 'Type poweroff' in self.read_master(master)),
                        'no prompt: ' + self.read_pipe(out))
        os.write(master, b'poweroff\n')
        self.assertTrue(self.pump(lambda: self.system.submissions()))

    def test_its_redirected_standard_streams_are_no_proof(self):
        def namespaced_without_terminal_fds():
            self.own_mount_namespace()
            null = os.open(os.devnull, os.O_RDWR)
            for fd in (0, 1, 2):
                os.dup2(null, fd)
        pid, master, out = self.operator_on_pty(before_connect=namespaced_without_terminal_fds)
        self.assertTrue(self.pump(lambda: 'another mount namespace' in self.read_pipe(out)))
        self.assertIsNone(self.broker.committed)

    def test_a_terminal_of_a_private_devpts_instance_is_refused(self):
        # A system terminal of this user with the number the private one gets:
        # taken for the caller's, the prompt would go there.
        sys_master, sys_slave = os.openpty()
        self.addCleanup(os.close, sys_master)
        self.addCleanup(os.close, sys_slave)
        number = int(os.ttyname(sys_slave).rsplit('/', 1)[1])
        r, w = os.pipe()
        pid = os.fork()
        if pid == 0:
            try:
                os.close(r)
                uid, gid = os.getuid(), os.getgid()
                self.own_mount_namespace()
                Path('/proc/self/setgroups').write_text('deny')
                Path('/proc/self/uid_map').write_text(f'0 {uid} 1')
                Path('/proc/self/gid_map').write_text(f'0 {gid} 1')
                subprocess.run(['mount', '-t', 'devpts', '-o', 'newinstance,ptmxmode=0666', 'devpts', '/dev/pts'],
                               check=True, capture_output=True)
                subprocess.run(['mount', '--bind', '/dev/pts/ptmx', '/dev/ptmx'], check=True, capture_output=True)
                for fd in list(self.broker.locks.values()):
                    if fd is not None:
                        os.close(fd)
                held = []
                while True:  # numbered from 0 in the private instance
                    master, slave = os.openpty()
                    held.append((master, slave))
                    if int(os.ttyname(slave).rsplit('/', 1)[1]) >= number:
                        break
                os.setsid()
                fcntl.ioctl(slave, __import__('termios').TIOCSCTTY, 0)
                for fd in (0, 1, 2):
                    os.dup2(slave, fd)
                conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                conn.connect(self.sock_path)
                conn.sendall(b'POWEROFF\n')
                while True:
                    data = conn.recv(4096)
                    if not data:
                        break
                    os.write(w, data)
            finally:
                os._exit(0)
        os.close(w)
        self.children.append((pid, None))
        os.set_blocking(r, False)
        self.addCleanup(os.close, r)
        self.assertTrue(self.pump(lambda: 'another mount namespace' in self.read_pipe(r)))
        self.assertIsNone(self.broker.committed)
        self.assertNotIn('Type poweroff', self.read_master(sys_master), 'prompted on another terminal')

    def test_a_terminal_of_another_session_of_the_same_account_is_refused(self):
        # Session V: a system terminal that is its controlling terminal. The
        # caller, another session of the same account, holds that terminal on
        # its standard input, while its own controlling terminal is a private
        # devpts pty with the same number. The prompt must not go to V.
        v_master, v_slave = os.openpty()
        self.addCleanup(os.close, v_master)
        name = os.ttyname(v_slave)
        number = int(name.rsplit('/', 1)[1])
        victim = os.fork()
        if victim == 0:
            try:
                os.setsid()
                fcntl.ioctl(v_slave, __import__('termios').TIOCSCTTY, 0)
                time.sleep(60)
            finally:
                os._exit(0)
        os.close(v_slave)
        self.children.append((victim, None))
        r, w = os.pipe()
        pid = os.fork()
        if pid == 0:
            try:
                os.close(r)
                held = os.open(name, os.O_RDWR | os.O_NOCTTY)  # V's terminal, same account
                uid, gid = os.getuid(), os.getgid()
                self.own_mount_namespace()
                Path('/proc/self/setgroups').write_text('deny')
                Path('/proc/self/uid_map').write_text(f'0 {uid} 1')
                Path('/proc/self/gid_map').write_text(f'0 {gid} 1')
                subprocess.run(['mount', '-t', 'devpts', '-o', 'newinstance,ptmxmode=0666', 'devpts', '/dev/pts'],
                               check=True, capture_output=True)
                subprocess.run(['mount', '--bind', '/dev/pts/ptmx', '/dev/ptmx'], check=True, capture_output=True)
                for fd in list(self.broker.locks.values()):
                    if fd is not None:
                        os.close(fd)
                ptys = []
                while True:
                    master, slave = os.openpty()
                    ptys.append((master, slave))
                    if int(os.ttyname(slave).rsplit('/', 1)[1]) >= number:
                        break
                os.setsid()
                fcntl.ioctl(slave, __import__('termios').TIOCSCTTY, 0)
                os.dup2(held, 0)
                os.dup2(slave, 1)
                os.dup2(slave, 2)
                conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                conn.connect(self.sock_path)
                conn.sendall(b'POWEROFF\n')
                while True:
                    data = conn.recv(4096)
                    if not data:
                        break
                    os.write(w, data)
            finally:
                os._exit(0)
        os.close(w)
        self.children.append((pid, None))
        os.set_blocking(r, False)
        self.addCleanup(os.close, r)
        answer = ''
        def refused():
            nonlocal answer
            answer += self.read_pipe(r)
            return 'REFUSED' in answer
        self.pump(refused)
        self.assertNotIn('Type poweroff', self.read_master(v_master), 'prompted on another session\'s terminal')
        self.assertIn('REFUSED', answer)
        self.assertIsNone(self.broker.committed)

    def test_a_private_pty_passed_into_the_system_namespace_does_not_reach_another_session(self):
        # The same confusion without a namespaced caller: a helper in its own
        # namespace makes a private devpts pty numbered like session V's system
        # terminal and passes it over a socket; the caller, in the system's
        # namespace, makes it its controlling terminal.
        v_master, v_slave = os.openpty()
        self.addCleanup(os.close, v_master)
        number = int(os.ttyname(v_slave).rsplit('/', 1)[1])
        victim = os.fork()
        if victim == 0:
            try:
                os.setsid()
                fcntl.ioctl(v_slave, __import__('termios').TIOCSCTTY, 0)
                time.sleep(60)
            finally:
                os._exit(0)
        os.close(v_slave)
        self.children.append((victim, None))
        r, w = os.pipe()
        pid = os.fork()
        if pid == 0:
            try:
                os.close(r)
                for fd in list(self.broker.locks.values()):
                    if fd is not None:
                        os.close(fd)
                here, there = socket.socketpair()
                helper = os.fork()
                if helper == 0:
                    try:
                        uid, gid = os.getuid(), os.getgid()
                        self.own_mount_namespace()
                        Path('/proc/self/setgroups').write_text('deny')
                        Path('/proc/self/uid_map').write_text(f'0 {uid} 1')
                        Path('/proc/self/gid_map').write_text(f'0 {gid} 1')
                        subprocess.run(['mount', '-t', 'devpts', '-o', 'newinstance,ptmxmode=0666', 'devpts',
                                        '/dev/pts'], check=True, capture_output=True)
                        subprocess.run(['mount', '--bind', '/dev/pts/ptmx', '/dev/ptmx'], check=True,
                                       capture_output=True)
                        ptys = []
                        while True:
                            master, slave = os.openpty()
                            ptys.append((master, slave))
                            if int(os.ttyname(slave).rsplit('/', 1)[1]) >= number:
                                break
                        socket.send_fds(there, [b'x'], [master, slave])
                        time.sleep(30)
                    finally:
                        os._exit(0)
                _, (master, slave), _, _ = socket.recv_fds(here, 1, 2)
                os.setsid()
                fcntl.ioctl(slave, __import__('termios').TIOCSCTTY, 0)
                for fd in (0, 1, 2):
                    os.dup2(slave, fd)
                conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                conn.connect(self.sock_path)
                conn.sendall(b'POWEROFF\n')
                while True:
                    data = conn.recv(4096)
                    if not data:
                        break
                    os.write(w, data)
                os.kill(helper, 9)
            finally:
                os._exit(0)
        os.close(w)
        self.children.append((pid, None))
        os.set_blocking(r, False)
        self.addCleanup(os.close, r)
        answer = ''
        def refused():
            nonlocal answer
            answer += self.read_pipe(r)
            return 'REFUSED' in answer
        self.pump(refused)
        self.assertNotIn('Type poweroff', self.read_master(v_master), 'prompted on another session\'s terminal')
        self.assertIn('another session', answer)
        self.assertIsNone(self.broker.committed)


class Origins(Harness):
    def as_unit(self, unit, uid=0):
        return [patch.object(broker, 'system_unit', lambda pidfd: unit),
                patch.object(broker, 'peer_identity', self.fake_identity(uid))]

    def fake_identity(self, uid):
        real = broker.peer_identity
        def identity(conn):
            pid, _, gid, pidfd = real(conn)
            return pid, uid, gid, pidfd
        return identity

    def run_as(self, unit, action=b'POWEROFF\n', uid=0):
        patches = self.as_unit(unit, uid)
        for p in patches:
            p.start()
        try:
            conn = self.connect(action)
            got = []
            self.pump(lambda: got.extend(self.lines(conn)) or any(l.split()[0] in ('SUBMITTED', 'REFUSED', 'FAILED', 'UNCERTAIN', 'PENDING') for l in got))
            return conn, got
        finally:
            for p in patches:
                p.stop()

    def test_button_hold_is_its_own_intent(self):
        conn, got = self.run_as('ceralive-button.service')
        self.assertTrue(any(l.startswith('ADMITTED poweroff ') for l in got), got)
        self.assertEqual(self.broker.committed['origin'], 'button')
        self.assertEqual(len(self.system.submissions()), 1)

    def test_button_may_not_reboot(self):
        conn, got = self.run_as('ceralive-button.service', b'REBOOT\n')
        self.assertIn('REFUSED the button may only power off', got)
        self.assertIsNone(self.broker.committed)

    def test_ceraui_admitted_reboot(self):
        conn, got = self.run_as('ceralive.service', b'REBOOT\n')
        self.assertTrue(any(l.startswith('ADMITTED reboot ') for l in got), got)
        self.assertEqual(self.system.submissions()[0][-2], 'org.freedesktop.login1.Manager.RebootWithFlags')

    def test_lookalike_units_and_non_root_get_no_service_origin(self):
        for unit, uid in (('ceralive.service', 1000), ('ceralive-button.service', 65534),
                          ('evil-ceralive.service', 0), (None, 0)):
            with patch.object(broker, 'is_operator', lambda u, g: False):
                conn, got = self.run_as(unit, uid=uid)
            self.assertIn('REFUSED not an operator', got, (unit, uid))
            self.assertIsNone(self.broker.committed)

    def test_unverifiable_peer_fails_closed(self):
        def broken(conn):
            raise broker.PeerError('no peer pidfd (Protocol not available)')
        with patch.object(broker, 'peer_identity', broken):
            conn = self.connect()
            got = []
            self.pump(lambda: got.extend(self.lines(conn)) or bool(got))
        self.assertTrue(got[0].startswith('REFUSED unverifiable caller'))

    def test_duplicate_joins_and_conflict_is_refused(self):
        self.system.installing = True  # keep the first request waiting
        conn, got = self.run_as('ceralive-button.service')
        self.assertEqual(self.broker.committed['stage'], 'drain')
        conn2, got2 = self.run_as('ceralive.service')
        self.assertTrue(any(l.startswith('PENDING poweroff ') for l in got2), got2)
        conn3, got3 = self.run_as('ceralive.service', b'REBOOT\n')
        self.assertIn('REFUSED poweroff already pending', got3)
        self.assertEqual(self.system.submissions(), [])

    def test_client_leaving_after_admission_does_not_cancel(self):
        self.system.installing = True
        conn, got = self.run_as('ceralive.service')
        conn.close()
        self.pump(lambda: False, rounds=5)
        self.system.installing = False
        self.assertTrue(self.pump(lambda: self.system.submissions()))
        self.assertEqual(len(self.system.submissions()), 1)


class Client(Harness):
    def run_client(self, unit, name='ceralive-poweroff'):
        client = os.path.join(self.dir, name)
        os.symlink(ROOT / 'mkosi/runtime/power/ceralive-poweroff', client)
        env = dict(os.environ, CERALIVE_POWER_SOCKET=self.sock_path)
        with patch.object(broker, 'system_unit', lambda pidfd: unit), \
             patch.object(broker, 'peer_identity', lambda c, real=broker.peer_identity: (lambda r: (r[0], 0, r[2], r[3]))(real(c))):
            proc = subprocess.Popen([sys.executable, '-I', client, '--no-wait'], env=env, pass_fds=(self.dir_fd,),
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.pump(lambda: proc.poll() is not None, rounds=300)
        out, _ = proc.communicate(timeout=5)
        return proc.returncode, out.strip()

    def test_no_wait_returns_on_admission_for_ceraui(self):
        self.system.installing = True  # admitted, still waiting for the write
        code, out = self.run_client('ceralive.service', 'ceralive-reboot')
        self.assertEqual(code, 0)
        self.assertRegex(out, r'^ADMITTED reboot [0-9a-f]{12}$')
        self.assertEqual(self.system.submissions(), [])

    def test_no_wait_reports_a_refusal(self):
        code, out = self.run_client('ceralive-button.service', 'ceralive-reboot')
        self.assertEqual(code, 1)
        self.assertEqual(out, 'REFUSED the button may only power off')

    def test_other_arguments_are_rejected(self):
        out = subprocess.run([sys.executable, '-I', str(ROOT / 'mkosi/runtime/power/ceralive-poweroff'), '--now'],
                             capture_output=True, text=True)
        self.assertEqual(out.returncode, 64)


class Draining(Harness):
    def admit_button(self):
        with patch.object(broker, 'system_unit', lambda pidfd: 'ceralive-button.service'), \
             patch.object(broker, 'peer_identity', lambda c, real=broker.peer_identity: (lambda r: (r[0], 0, r[2], r[3]))(real(c))):
            conn = self.connect()
            self.pump(lambda: self.broker.committed is not None)
        return conn

    def test_running_rauc_install_is_waited_for_then_submitted(self):
        self.system.installing = True
        self.admit_button()
        self.pump(lambda: False, rounds=10)
        self.assertEqual(self.system.submissions(), [])
        state = self.state_json()
        self.assertIn('"waiting"', state)
        self.assertIn('os-install', state)
        self.system.installing = False
        self.assertTrue(self.pump(lambda: self.system.submissions()))

    def test_a_writer_holding_the_update_lock_is_waited_for(self):
        holder = os.open(self.paths['update.lock'], os.O_RDWR)
        fcntl.flock(holder, fcntl.LOCK_EX)
        try:
            self.admit_button()
            self.pump(lambda: False, rounds=10)
            self.assertEqual(self.system.submissions(), [])
            self.assertIn('update lock', self.state_json())
        finally:
            os.close(holder)
        self.assertTrue(self.pump(lambda: self.system.submissions()))

    def test_new_writers_are_fenced_once_admitted(self):
        self.system.installing = True
        self.admit_button()
        self.pump(lambda: 'update' in self.broker.locks)
        writer = os.open(self.paths['update.lock'], os.O_RDWR)
        try:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(writer, fcntl.LOCK_EX | fcntl.LOCK_NB)  # what the update units do (flock -n)
        finally:
            os.close(writer)

    def test_dpkg_held_by_another_process_is_waited_for(self):
        r, w = os.pipe()
        pid = os.fork()
        if pid == 0:
            fd = os.open(self.paths['lock-frontend'], os.O_RDWR)
            fcntl.lockf(fd, fcntl.LOCK_EX)
            os.write(w, b'x')
            time.sleep(30)
            os._exit(0)
        os.read(r, 1)
        try:
            self.admit_button()
            self.pump(lambda: False, rounds=10)
            self.assertEqual(self.system.submissions(), [])
            self.assertIn('package-install', self.state_json())
        finally:
            os.kill(pid, 9)
            os.waitpid(pid, 0)
        self.assertTrue(self.pump(lambda: self.system.submissions()))

    def test_escalation_reports_stuck_and_keeps_waiting(self):
        self.system.installing = True
        self.admit_button()
        self.clock[0] += broker.ESCALATE_S + 1
        self.pump(lambda: False, rounds=5)
        self.assertIn('"stuck"', self.state_json())
        self.assertEqual(self.system.submissions(), [], 'the bound never cuts a write')

    def test_logind_refusal_fails_closed_and_releases_the_fence(self):
        self.system.logind = 'refuse'
        self.admit_button()
        self.pump(lambda: self.broker.committed is None)
        self.assertEqual(len(self.system.submissions()), 1)
        self.assertIn('"failed"', self.state_json())
        self.assertEqual(self.broker.locks, {})

    def test_unanswered_logind_is_uncertain_and_never_retried(self):
        self.system.logind = 'hang'
        self.admit_button()
        self.pump(lambda: False, rounds=20)
        self.assertEqual(len(self.system.submissions()), 1)
        self.assertEqual(self.broker.committed['stage'], 'uncertain')
        self.assertIn('update', self.broker.locks)


class ReviewFindings(Harness):
    """One regression per finding of the implementation review."""

    def admit_button(self):
        with patch.object(broker, 'system_unit', lambda pidfd: 'ceralive-button.service'), \
             patch.object(broker, 'peer_identity', lambda c, real=broker.peer_identity: (lambda r: (r[0], 0, r[2], r[3]))(real(c))):
            conn = self.connect()
            self.pump(lambda: self.broker.committed is not None)
        return conn

    def other_process_can_lock_dpkg(self):
        r, w = os.pipe()
        pid = os.fork()
        if pid == 0:
            fd = os.open(self.paths['lock-frontend'], os.O_RDWR)
            try:
                fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                os.write(w, b'1')
            except OSError:
                os.write(w, b'0')
            os._exit(0)
        got = os.read(r, 1)
        os.waitpid(pid, 0)
        return got == b'1'

    def test_the_dpkg_fence_survives_the_writer_check(self):
        self.system.installing = True  # keep waiting, re-checking writers each step
        self.admit_button()
        self.pump(lambda: 'dpkg' in self.broker.locks)
        self.pump(lambda: False, rounds=5)  # several writer checks while fenced
        self.assertFalse(self.other_process_can_lock_dpkg(), 'the fence opened while waiting')

    def test_dpkg_is_not_taken_while_an_update_holds_the_update_lock(self):
        holder = os.open(self.paths['update.lock'], os.O_RDWR)
        fcntl.flock(holder, fcntl.LOCK_EX)
        try:
            self.admit_button()
            self.pump(lambda: False, rounds=5)
            self.assertNotIn('dpkg', self.broker.locks)
            self.assertTrue(self.other_process_can_lock_dpkg(), "an update's apt phase would be blocked")
        finally:
            os.close(holder)

    def test_a_rauc_mount_counts_as_installing_even_when_rauc_says_idle(self):
        # The packaged unit: --mount=/run/rauc/mnt and MountFlags=slave, so the
        # bundle mount exists only in RAUC's own namespace, never in PID 1's.
        self.system.rauc_pid = 4242
        Path(self.proc, '4242', 'mountinfo').write_text('36 25 0:31 / /run/rauc/mnt/bundle ro,relatime - squashfs /dev/loop3 ro\n')
        self.admit_button()
        self.pump(lambda: False, rounds=10)
        self.assertEqual(self.system.submissions(), [])
        self.assertIn('rauc mounts', self.state_json())
        Path(self.proc, '4242', 'mountinfo').write_text('')
        self.assertTrue(self.pump(lambda: self.system.submissions()))

    def test_the_mount_prefix_follows_rauc(self):
        self.system.rauc_pid = 4242
        Path(self.proc, '4242', 'mountinfo').write_text('36 25 0:31 / /mnt/rauc/bundle ro - squashfs /dev/loop3 ro\n')
        self.assertEqual(broker.rauc_mounts(self.system), [], 'RAUC was started with --mount=/run/rauc/mnt')
        Path(self.proc, '4242', 'cmdline').write_bytes(b'/usr/bin/rauc\0service\0')
        self.assertEqual(broker.rauc_mounts(self.system), ['/mnt/rauc/bundle'], 'default prefix')
        Path(self.dir, 'system.conf').write_text('[system]\nmount-prefix=/srv/rauc\n')
        Path(self.proc, '4242', 'mountinfo').write_text('36 25 0:31 / /srv/rauc/bundle ro - squashfs /dev/loop3 ro\n')
        self.assertEqual(broker.rauc_mounts(self.system), ['/srv/rauc/bundle'], 'system.conf prefix')

    def test_the_prefix_itself_is_not_an_install(self):
        # With RuntimeDirectory=rauc/mnt and its own namespace, systemd bind-mounts
        # the prefix itself into RAUC's namespace for the whole life of the
        # service. Only mounts below it belong to an install.
        self.system.rauc_pid = 4242
        Path(self.proc, '4242', 'mountinfo').write_text(
            '7162 7149 0:146 / /run rw - tmpfs tmpfs rw\n'
            '7169 7162 0:146 /rauc/mnt /run/rauc/mnt rw - tmpfs tmpfs rw\n'
            '7170 7162 0:146 /systemd/propagate/rauc.service /run/systemd/incoming ro - tmpfs tmpfs rw\n')
        self.assertEqual(broker.rauc_mounts(self.system), [])
        self.admit_button()
        self.assertTrue(self.pump(lambda: self.system.submissions()))

    def test_an_unreadable_rauc_namespace_counts_as_busy(self):
        self.system.rauc_pid = 4243  # no /proc entry
        self.assertTrue(broker.rauc_mounts(self.system))
        self.system.rauc_pid = None
        self.assertEqual(broker.rauc_mounts(self.system), [])

    def test_a_broker_failure_never_removes_the_shutdown_fence(self):
        os.makedirs(self.fence_dir, exist_ok=True)
        Path(self.fence_dir, 'shutdown').write_text('shutdown\n')
        self.system.logind = 'refuse'
        self.admit_button()
        self.pump(lambda: self.broker.committed is None)
        self.assertFalse(os.path.exists(self.fence))
        self.assertTrue(os.path.exists(os.path.join(self.fence_dir, 'shutdown')))
        self.broker.release()
        self.broker = self.new_broker()  # idle recovery
        self.assertTrue(os.path.exists(os.path.join(self.fence_dir, 'shutdown')))

    def test_the_admission_lock_is_free_while_writers_are_probed(self):
        import threading
        seen = []
        original = self.system.__call__
        def try_lock():
            got = self.broker.lock.acquire(timeout=0.5)
            seen.append(got)
            if got:
                self.broker.lock.release()
        def slow(argv, timeout):
            if argv[:2] == ['systemctl', 'list-units']:
                # The I/O thread, as an incoming admission would.
                other = threading.Thread(target=try_lock)
                other.start()
                other.join(2)
            return original(argv, timeout)
        self.system.installing = True
        self.admit_button()
        self.broker.runner = slow
        self.broker.committer.runner = slow
        thread = threading.Thread(target=self.broker.committer.step)
        thread.start()
        thread.join(5)
        self.assertTrue(seen and all(seen), 'the committer held the admission lock while probing')

    def test_nothing_is_submitted_without_a_recorded_submitting_state(self):
        self.system.installing = True
        self.admit_button()
        self.pump(lambda: '"waiting"' in self.state_json())
        self.system.installing = False
        real = broker.write_json
        def failing(path, record):
            if record.get('state') == 'submitting':
                raise OSError(28, 'No space left on device')
            return real(path, record)
        with patch.object(broker, 'write_json', failing):
            self.pump(lambda: False, rounds=5)
        self.assertEqual(self.system.submissions(), [])
        self.assertTrue(self.pump(lambda: self.system.submissions()))

    def test_an_unrecorded_admission_is_refused(self):
        real = broker.write_json
        def failing(path, record):
            if record.get('state') == 'admitted':
                raise OSError(28, 'No space left on device')
            return real(path, record)
        with patch.object(broker, 'write_json', failing), \
             patch.object(broker, 'system_unit', lambda pidfd: 'ceralive-button.service'), \
             patch.object(broker, 'peer_identity', lambda c, real=broker.peer_identity: (lambda r: (r[0], 0, r[2], r[3]))(real(c))):
            conn = self.connect()
            got = []
            self.pump(lambda: got.extend(self.lines(conn)) or bool(got))
        self.assertEqual(got[0], 'REFUSED could not record the request')
        self.assertIsNone(self.broker.committed)

    def test_each_request_keeps_its_own_result(self):
        self.system.logind = 'refuse'
        self.admit_button()
        self.pump(lambda: self.broker.committed is None)
        failed = json.loads(self.state_json())
        self.system.logind = 'ok'
        self.system.installing = True
        self.admit_button()  # a newer request replaces state.json
        self.pump(lambda: '"waiting"' in self.state_json())
        self.assertEqual(self.persisted(failed['id'])['state'], 'failed')
        self.assertNotEqual(json.loads(self.state_json())['id'], failed['id'])

    def test_the_install_fence_exists_from_admission_and_goes_with_a_failure(self):
        self.system.installing = True
        self.admit_button()
        self.pump(lambda: os.path.exists(self.fence))
        self.assertTrue(os.path.exists(self.fence))
        self.assertEqual(Path(self.fence).read_text().strip(), self.broker.committed['id'])
        self.system.installing = False
        self.system.logind = 'refuse'
        self.pump(lambda: self.broker.committed is None)
        self.assertFalse(os.path.exists(self.fence))

    def test_typed_logind_outcomes(self):
        for mode, outcome in (('refuse', 'failed'), ('unknown', 'failed'), ('noreply', 'uncertain'),
                              ('noname', 'uncertain'), ('hang', 'uncertain'), ('ok', 'submitted')):
            self.system.logind = mode
            self.assertEqual(broker.submit_to_logind('poweroff', self.system)[0], outcome, mode)

    def test_no_reply_keeps_the_fence_and_is_not_retried(self):
        self.system.logind = 'noreply'
        self.admit_button()
        self.pump(lambda: False, rounds=20)
        self.assertEqual(len(self.system.submissions()), 1)
        self.assertEqual(self.broker.committed['stage'], 'uncertain')
        self.assertIn('update', self.broker.locks)
        self.assertTrue(os.path.exists(self.fence))

    def test_a_restarted_broker_resumes_a_waiting_request(self):
        self.system.installing = True
        self.admit_button()
        request_id = self.broker.committed['id']
        self.pump(lambda: '"waiting"' in self.state_json())
        self.broker.release()
        self.broker = self.new_broker()
        self.assertEqual(self.broker.committed['id'], request_id)
        self.system.installing = False
        self.assertTrue(self.pump(lambda: self.system.submissions()))

    def test_a_restarted_broker_never_resubmits(self):
        self.admit_button()
        self.pump(lambda: self.system.submissions())
        self.broker.release()
        self.broker = self.new_broker()
        self.pump(lambda: False, rounds=10)
        self.assertEqual(len(self.system.submissions()), 1)
        self.assertIn('"uncertain"', self.state_json())
        self.assertIn('not resubmitted', self.state_json())

    def test_a_terminal_that_cannot_be_flushed_is_refused_cleanly(self):
        with patch.object(broker, 'is_operator', lambda uid, gid: True), \
             patch.object(broker.termios, 'tcflush', side_effect=broker.termios.error(5, 'Input/output error')):
            pid, master, out = self.operator_on_pty()
            self.assertTrue(self.pump(lambda: 'REFUSED terminal not usable' in self.read_pipe(out)))
        self.assertEqual(self.broker.prompts, {})

    def test_an_answer_after_the_deadline_is_refused(self):
        with patch.object(broker, 'is_operator', lambda uid, gid: True):
            pid, master, out = self.operator_on_pty()
            self.assertTrue(self.pump(lambda: 'Type poweroff' in self.read_master(master)))
            os.write(master, b'poweroff\n')
            time.sleep(0.1)
            self.clock[0] += broker.PROMPT_S + 1
            request = next(iter(self.broker.prompts.values()))
            self.broker.on_tty(request)  # input readiness before the timeout sweep
        self.assertIsNone(self.broker.committed)
        self.assertEqual(self.system.submissions(), [])


class Drain(unittest.TestCase):
    def setUp(self):
        proc = tempfile.mkdtemp(prefix='drain-proc-')
        self.addCleanup(shutil.rmtree, proc)
        os.makedirs(os.path.join(proc, '4242'))
        Path(proc, '4242', 'cmdline').write_bytes(b'/usr/bin/rauc\0service\0')
        Path(proc, '4242', 'mountinfo').write_text('')
        Path(proc, '4242', 'stat').write_text('4242 (rauc) S 1 4242 4242 0 -1 0 0 0 0 0 0 0 0 0 20 0 3 0 777 1 1\n')
        self.proc = patch.object(broker, 'PROC_ROOT', proc)
        self.proc.start()
        self.addCleanup(self.proc.stop)

    def scratch_dir(self):
        """A new empty directory, removed after the test."""
        path = tempfile.mkdtemp(prefix='drain-')
        self.addCleanup(shutil.rmtree, path)
        return path

    def scratch_path(self):
        """A path that does not exist yet, in a directory removed after the test."""
        return os.path.join(self.scratch_dir(), 'activate.lock')

    @staticmethod
    def fake():
        system = FakeSystem()
        system.rauc_pid, system.rauc_unit = 4242, 'active'
        return system

    def test_manual_stop_returns_at_once(self):
        system = self.fake()
        system.installing = True
        self.assertEqual(broker.drain(sleep=lambda s: self.fail('waited'), runner=system), 0)

    def test_shutdown_waits_for_rauc_and_units_then_continues(self):
        system = self.fake()
        system.system_state = 'stopping'
        system.installing = True
        system.units = ['ceralive-kernel-stage-7.service']
        ticks = []
        def sleep(_):
            ticks.append(1)
            if len(ticks) == 3:
                system.installing = False
            if len(ticks) == 5:
                system.units = []
        with patch.object(broker, 'DPKG_LOCK', '/nonexistent/lock-frontend'):
            self.assertEqual(broker.drain(sleep=sleep, now=lambda: len(ticks), runner=system), 0)
        self.assertEqual(len(ticks), 5)

    def test_drain_has_no_deadline_and_warns_once(self):
        system = self.fake()
        system.system_state = 'stopping'
        system.installing = True
        clock = [0]
        def sleep(_):
            clock[0] += 300
            if clock[0] > 3000:
                system.installing = False
        with patch.object(broker, 'DPKG_LOCK', '/nonexistent/lock-frontend'):
            broker.drain(sleep=sleep, now=lambda: clock[0], runner=system)
        walls = [argv for argv in system.calls if argv[0] == 'wall']
        self.assertEqual(len(walls), 1)

    def test_a_retained_finished_unit_is_not_work(self):
        system = self.fake()
        system.system_state = 'stopping'
        system.receipts = ['ceralive-os-stage-guard.service', 'ceralive-software-update.service']
        with patch.object(broker, 'DPKG_LOCK', '/nonexistent/lock-frontend'), \
             patch.object(broker, 'FENCE_DIR', self.scratch_dir()), \
             patch.object(broker, 'ACTIVATION_LOCK', self.scratch_path()):
            self.assertEqual(broker.drain(sleep=lambda s: self.fail('waited on a receipt'), runner=system), 0)

    def test_an_unreadable_system_state_waits_like_a_shutdown(self):
        system = self.fake()
        system.system_state = ''
        system.installing = True
        ticks = []
        def sleep(_):
            ticks.append(1)
            system.installing = len(ticks) < 3
        with patch.object(broker, 'DPKG_LOCK', '/nonexistent/lock-frontend'), \
             patch.object(broker, 'FENCE_DIR', self.scratch_dir()), \
             patch.object(broker, 'ACTIVATION_LOCK', self.scratch_path()):
            broker.drain(sleep=sleep, now=lambda: len(ticks), runner=system)
        self.assertEqual(len(ticks), 3)

    def test_the_drain_fences_new_installs_first(self):
        system = self.fake()
        system.system_state = 'stopping'
        fences = self.scratch_dir()
        with patch.object(broker, 'DPKG_LOCK', '/nonexistent/lock-frontend'), \
             patch.object(broker, 'FENCE_DIR', fences), \
             patch.object(broker, 'ACTIVATION_LOCK', self.scratch_path()):
            broker.drain(sleep=lambda s: None, runner=system)
        self.assertTrue(os.path.exists(os.path.join(fences, 'shutdown')))

    def test_the_drain_holds_the_shutdown_until_its_fence_is_written(self):
        system = self.fake()
        system.system_state = 'stopping'
        fences = os.path.join(self.scratch_dir(), 'fence.d')
        Path(fences).write_text('not a directory')  # the fence can't be created
        ticks = []
        def sleep(_):
            ticks.append(1)
            if len(ticks) == 3:
                os.unlink(fences)  # now it can
        with patch.object(broker, 'DPKG_LOCK', '/nonexistent/lock-frontend'), \
             patch.object(broker, 'FENCE_DIR', fences), \
             patch.object(broker, 'ACTIVATION_LOCK', self.scratch_path()):
            broker.drain(sleep=sleep, now=lambda: len(ticks), runner=system)
        self.assertEqual(len(ticks), 3)
        self.assertTrue(os.path.exists(os.path.join(fences, 'shutdown')))

    def test_unreadable_rauc_counts_as_busy_and_absent_service_as_idle(self):
        def absent(argv, t):
            if argv[:2] == ['systemctl', 'show']:
                return subprocess.CompletedProcess(argv, 0, 'inactive\n', '')
            return subprocess.CompletedProcess(argv, 1, '', 'Call failed: The name de.pengutronix.rauc was not provided by any .service files\n')
        broken = lambda argv, t: subprocess.CompletedProcess(argv, 1, '', 'Failed to connect to bus\n')
        self.assertFalse(broker.rauc_installing(absent))
        self.assertTrue(broker.rauc_installing(broken))


class RecheckThree(Harness):
    """Third re-check: joins never create, one consistent record, a stable RAUC owner."""

    def as_unit(self, unit, action=b'POWEROFF\n'):
        with patch.object(broker, 'system_unit', lambda pidfd: unit), \
             patch.object(broker, 'peer_identity', lambda c, real=broker.peer_identity: (lambda r: (r[0], 0, r[2], r[3]))(real(c))):
            conn = self.connect(action)
            got = []
            self.pump(lambda: got.extend(self.lines(conn)) or bool(got))
        return conn, got

    # P1: a join must never create a request without the operator's confirmation
    def test_a_request_ending_between_lookup_and_join_never_admits_an_unconfirmed_operator(self):
        self.system.installing = True
        self.as_unit('ceralive-button.service')
        first = self.broker.committed['id']
        inner = self.broker.lock
        armed = []

        class RacingLock:
            """The committer records a failure right after the I/O thread's
            first look at the pending request."""
            def __init__(self):
                self.depth = 0
            def acquire(self, *a, **k):
                got = inner.acquire(*a, **k)
                if got:
                    self.depth += 1
                return got
            def release(self):
                self.depth -= 1
                inner.release()
                if self.depth == 0 and armed:
                    armed.clear()
                    with inner:
                        test.broker.fail('refused by logind')
            __enter__ = acquire
            def __exit__(self, *exc):
                self.release()

        test = self
        self.broker.lock = RacingLock()
        with patch.object(broker, 'is_operator', lambda uid, gid: armed.append(1) or True):
            pid, master, out = self.operator_on_pty()
            self.pump(lambda: self.broker.committed is None and 'FAILED' in self.read_pipe(out) or self.broker.committed not in (None,) and self.broker.committed['id'] != first, rounds=100)
            self.pump(lambda: False, rounds=10)
        self.broker.lock = inner
        if self.broker.committed is not None:
            self.assertEqual(self.broker.committed['id'], first, 'a new request was created without a typed confirmation')
        self.assertEqual(self.system.submissions(), [])
        self.assertEqual(self.persisted(first)['state'], 'failed')

    def test_commit_requires_a_service_origin_or_a_confirmed_terminal(self):
        a, b = socket.socketpair()
        request = broker.Request(a, 0)
        request.action, request.origin, request.uid = 'poweroff', 'terminal', 1000
        self.broker.commit(request)
        self.assertIsNone(self.broker.committed)
        self.assertTrue(b.recv(100).startswith(b'REFUSED'))
        b.close()

    # P1: what the client is told and what a restarted broker resumes agree
    def test_every_admission_write_boundary_leaves_answer_and_record_in_agreement(self):
        real_replace, real_fsync = os.replace, os.fsync
        state = self.state
        def nth(n, real):
            calls = []
            def failing(*a, **k):
                if real is real_replace and a[1] != state:
                    return real(*a, **k)  # only writes of the broker's record count
                calls.append(1)
                if len(calls) == n:
                    raise OSError(28, 'No space left on device')
                return real(*a, **k)
            return failing
        boundaries = {'first rename': ('replace', 1), 'second rename': ('replace', 2),
                      'first fsync': ('fsync', 1), 'second fsync': ('fsync', 2)}
        for name, (call, n) in boundaries.items():
            with self.subTest(boundary=name):
                self.broker.release()
                for leftover in (self.state, self.fence):
                    if os.path.exists(leftover):
                        os.unlink(leftover)
                self.broker = self.new_broker()
                self.system.installing = True
                target = 'replace' if call == 'replace' else 'fsync'
                with patch.object(broker.os, target, nth(n, real_replace if target == 'replace' else real_fsync)):
                    _, got = self.as_unit('ceralive.service')
                admitted = bool(got) and got[0].startswith('ADMITTED')
                self.broker.release()
                self.broker = self.new_broker()
                resumed = self.broker.committed is not None
                self.assertEqual(admitted, resumed, f'told {got}, a restart resumes: {resumed}')

    def test_a_failure_is_recorded_before_a_newer_request_can_replace_it(self):
        self.system.logind = 'refuse'
        real = broker.write_json
        blocked = [True]
        def failing(path, record):
            if blocked[0] and record.get('state') == 'failed':
                raise OSError(28, 'No space left on device')
            return real(path, record)
        with patch.object(broker, 'write_json', failing):
            self.as_unit('ceralive-button.service')
            first = json.loads(self.state_json())['id']
            self.pump(lambda: len(self.system.submissions()) == 1)
            self.pump(lambda: False, rounds=5)
            self.system.logind = 'ok'
            self.system.installing = True
            _, got = self.as_unit('ceralive.service')
            if got and got[0].startswith('ADMITTED'):
                self.assertEqual(self.persisted(first)['state'], 'failed', 'a newer request replaced an unrecorded failure')
            blocked[0] = False
            self.pump(lambda: (self.persisted(first) or {}).get('state') == 'failed')
        self.assertEqual(self.persisted(first)['state'], 'failed')
        _, got = self.as_unit('ceralive.service')
        self.assertTrue(got[0].startswith(('ADMITTED', 'PENDING')), got)

    # CeraUI's reservation: a failure stays readable by id
    def test_a_failure_outlives_many_newer_requests(self):
        self.system.logind = 'refuse'
        _, got = self.as_unit('ceralive.service')
        first = got[0].split()[2]
        self.pump(lambda: self.broker.committed is None)
        for _ in range(40):
            self.as_unit('ceralive.service')
            self.pump(lambda: self.broker.committed is None)
        self.assertEqual((self.persisted(first) or {}).get('state'), 'failed')

    def test_only_finished_records_older_than_a_day_are_dropped(self):
        now, boot = broker.boot_clock(), broker.boot_id()
        at = lambda age: {'time': int(time.time()), 'boot_id': boot, 'boottime': now - age}
        Path(self.state).write_text(json.dumps({'state': 'idle', 'time': int(time.time()), 'requests': {
            'aaaaaaaaaaaa': {'state': 'failed', 'id': 'aaaaaaaaaaaa', **at(2 * 86400)},
            'bbbbbbbbbbbb': {'state': 'failed', 'id': 'bbbbbbbbbbbb', **at(3600)},
            'cccccccccccc': {'state': 'uncertain', 'id': 'cccccccccccc', **at(2 * 86400)},
        }}))
        self.broker.release()
        self.broker = self.new_broker()
        self.as_unit('ceralive.service')
        requests = json.loads(self.state_json())['requests']
        self.assertNotIn('aaaaaaaaaaaa', requests)
        self.assertIn('bbbbbbbbbbbb', requests)
        self.assertIn('cccccccccccc', requests)
        self.assertIn(self.broker.committed['id'], requests)

    # P2: RAUC's Operation and mounts are read from one stable owner
    def test_an_owner_change_mid_check_is_observed_again(self):
        self.rauc_proc(4343, start=900, mounts=['/run/rauc/mnt/bundle'])
        self.system.rauc_pids = [4242, 4343]
        self.assertTrue(broker.rauc_installing(self.system))

    def test_an_owner_that_never_holds_still_counts_as_busy(self):
        self.rauc_proc(4343, start=900)
        self.system.rauc_pids = [4242, 4343] * 20
        self.assertTrue(broker.rauc_installing(self.system))

    def test_a_reused_pid_is_not_the_same_owner(self):
        lookups = []
        def restart():
            lookups.append(1)
            if len(lookups) == 2:  # RAUC restarted under the same pid, mid-install
                self.rauc_proc(4242, start=999, mounts=['/run/rauc/mnt/bundle'])
        self.system.on_lookup = restart
        self.assertTrue(broker.rauc_installing(self.system))

    def test_a_lost_bus_name_while_the_unit_still_runs_is_busy(self):
        self.system.rauc_pids = [4242, None]
        for unit, busy in (('deactivating', True), ('active', True), ('activating', True), ('inactive', False), ('failed', False)):
            with self.subTest(unit=unit):
                self.system.rauc_pids = [4242, None]
                self.system.rauc_unit = unit
                self.assertEqual(broker.rauc_installing(self.system), busy)


class RecheckFour(Harness):
    """Fourth re-check: recovery keeps evidence, an unrecorded failure is told,
    retention follows boot time."""

    def as_unit(self, unit, action=b'POWEROFF\n', keep=False):
        with patch.object(broker, 'system_unit', lambda pidfd: unit), \
             patch.object(broker, 'peer_identity', lambda c, real=broker.peer_identity: (lambda r: (r[0], 0, r[2], r[3]))(real(c))):
            conn = self.connect(action)
            got = []
            self.pump(lambda: got.extend(self.lines(conn)) or bool(got))
        return conn, got

    def restart_with(self, state=None, fence=None):
        self.broker.release()
        for path in (self.state, self.fence):
            if os.path.exists(path):
                os.unlink(path)
        if state is not None:
            Path(self.state).write_bytes(state)
        if fence is not None:
            os.makedirs(self.fence_dir, exist_ok=True)
            Path(self.fence).write_text(fence + '\n')
        self.broker = self.new_broker()

    # P1: recovery never turns lost evidence into idle
    def test_a_surviving_fence_without_state_is_uncertain_not_idle(self):
        self.restart_with(fence='abcabcabcabc')
        self.assertTrue(os.path.exists(self.fence), 'the fence of an unknown request was removed')
        record = json.loads(self.state_json())
        self.assertEqual(record['state'], 'uncertain')
        self.assertEqual(record['id'], 'abcabcabcabc')
        _, got = self.as_unit('ceralive-button.service')
        self.assertTrue(got[0].startswith('REFUSED'), got)
        self.assertIn('unknown', got[0])
        self.pump(lambda: False, rounds=5)
        self.assertEqual(self.system.submissions(), [])

    def test_unreadable_state_is_never_written_over(self):
        for fence in ('abcabcabcabc', None):
            with self.subTest(fence=fence):
                garbage = b'{"state": "submitting", "id": "abcab'
                self.restart_with(state=garbage, fence=fence)
                self.assertEqual(Path(self.state).read_bytes(), garbage)
                if fence:
                    self.assertTrue(os.path.exists(self.fence))
                _, got = self.as_unit('ceralive.service')
                self.assertTrue(got[0].startswith('REFUSED'), got)
                self.assertEqual(Path(self.state).read_bytes(), garbage)
                self.assertEqual(self.system.submissions(), [])

    def test_a_fresh_start_is_idle(self):
        self.restart_with()
        self.assertEqual(json.loads(self.state_json())['state'], 'idle')
        _, got = self.as_unit('ceralive.service')
        self.assertTrue(got[0].startswith('ADMITTED'), got)

    def test_a_fence_whose_request_is_recorded_failed_is_stale(self):
        now = int(time.time())
        record = {'state': 'failed', 'time': now, 'id': 'abcabcabcabc', 'action': 'poweroff', 'origin': 'button'}
        self.restart_with(state=json.dumps(dict(record, requests={'abcabcabcabc': record})).encode(), fence='abcabcabcabc')
        self.assertFalse(os.path.exists(self.fence))
        self.assertIsNone(self.broker.committed)

    # P2: an unrecorded failure is told, not hidden
    def block_failed_writes(self):
        real = broker.write_json
        def failing(path, record):
            if record.get('state') == 'failed':
                raise OSError(28, 'No space left on device')
            return real(path, record)
        return patch.object(broker, 'write_json', failing)

    def test_waiters_learn_a_failure_that_could_not_be_recorded(self):
        self.system.logind = 'refuse'
        with self.block_failed_writes():
            conn, got = self.as_unit('ceralive.service')
            self.assertTrue(got[0].startswith('ADMITTED'), got)
            self.pump(lambda: got.extend(self.lines(conn)) or any(l.startswith('FAILED') for l in got), rounds=50)
        failed = [l for l in got if l.startswith('FAILED')]
        self.assertTrue(failed, f'a waiter saw only {got}')
        self.assertIn('not recorded', failed[0])

    def test_new_requests_during_an_unrecorded_failure_are_told_why(self):
        self.system.logind = 'refuse'
        with self.block_failed_writes():
            self.as_unit('ceralive-button.service')
            self.pump(lambda: self.broker.committed and self.broker.committed['stage'] == 'failing')
            _, got = self.as_unit('ceralive.service')
        self.assertTrue(got[0].startswith('REFUSED'), got)
        self.assertIn('refused by logind', got[0])
        self.assertIn('could not be recorded', got[0])

    # P3: a finished result is kept for 24 h of boot time, whatever the wall clock does
    def test_retention_follows_boot_time_not_the_wall_clock(self):
        boot = [5000.0]
        wall = [time.time()]
        with patch.object(broker, 'boot_clock', lambda: boot[0], create=True), \
             patch.object(broker.time, 'time', lambda: wall[0]):
            self.system.logind = 'refuse'
            _, got = self.as_unit('ceralive.service')
            first = got[0].split()[2]
            self.pump(lambda: self.broker.committed is None)
            wall[0] += 3 * 86400  # the clock is corrected forward by three days
            self.as_unit('ceralive.service')
            self.pump(lambda: self.broker.committed is None)
            self.assertEqual((self.persisted(first) or {}).get('state'), 'failed', 'pruned after a wall-clock step')
            boot[0] += 86400 + 1
            self.as_unit('ceralive.service')
            self.pump(lambda: self.broker.committed is None)
            self.assertIsNone(self.persisted(first), 'kept beyond 24 h of boot time')


class RecheckFive(Harness):
    """Fifth re-check: a lost request clears only by reboot or an operator's
    typed recovery; the in-flight check fails closed; fence and lock retried."""

    def setUp(self):
        super().setUp()
        self.op = patch.object(broker, 'is_operator', lambda uid, gid: True)
        self.op.start()
        self.addCleanup(self.op.stop)

    restart_with = RecheckFour.restart_with
    as_unit = RecheckFour.as_unit

    def recover_on_pty(self, word=b'recover'):
        pid, master, out = self.operator_on_pty(b'RECOVER\n')
        prompt = []
        self.pump(lambda: prompt.append(self.read_master(master)) or 'press Enter' in ''.join(prompt))
        os.write(master, word + b'\n')
        got = []
        self.pump(lambda: got.append(self.read_pipe(out)) or any(w in ''.join(got) for w in ('RECOVERED', 'REFUSED')))
        return ''.join(prompt), ''.join(got)

    def test_a_lost_request_never_clears_by_itself(self):
        self.restart_with(fence='abcabcabcabc')
        for _ in range(20):
            self.clock[0] += 60
            self.pump(lambda: False, rounds=2)
        self.assertIsNotNone(self.broker.committed, 'cleared without reboot or recovery')
        self.assertTrue(os.path.exists(self.fence))
        _, got = self.as_unit('ceralive.service')
        self.assertTrue(got[0].startswith('REFUSED'), got)
        for what in ('ceralive-poweroff --recover', 'systemctl poweroff', 'holding the button'):
            self.assertIn(what, got[0])

    def test_an_operator_clears_it_with_a_typed_word(self):
        self.restart_with(fence='abcabcabcabc')
        prompt, got = self.recover_on_pty()
        self.assertIn('may still be in flight', prompt)
        self.assertIn('Type recover', prompt)
        self.assertIn('RECOVERED abcabcabcabc', got)
        self.assertIsNone(self.broker.committed)
        self.assertFalse(os.path.exists(self.fence))
        self.assertEqual(self.persisted('abcabcabcabc')['state'], 'uncertain')
        self.assertEqual(self.system.submissions(), [], 'the lost request was resubmitted')
        _, got = self.as_unit('ceralive.service')
        self.assertTrue(got[0].startswith('ADMITTED'), got)

    def test_recovery_clears_unreadable_state_too(self):
        self.restart_with(state=b'not json', fence='abcabcabcabc')
        _, got = self.recover_on_pty()
        self.assertIn('RECOVERED', got)
        self.assertEqual(json.loads(self.state_json())['state'], 'uncertain')

    def test_a_wrong_word_or_a_shutdown_in_flight_keeps_it(self):
        self.restart_with(fence='abcabcabcabc')
        _, got = self.recover_on_pty(b'poweroff')
        self.assertIn('REFUSED', got)
        self.assertIsNotNone(self.broker.committed)
        self.system.preparing = True
        _, got = self.recover_on_pty()
        self.assertIn('REFUSED', got)
        self.assertIn('may be in flight', got)
        self.assertIsNotNone(self.broker.committed)
        self.assertTrue(os.path.exists(self.fence))

    def test_recovery_needs_an_operator_terminal_and_something_to_recover(self):
        self.restart_with(fence='abcabcabcabc')
        _, got = self.as_unit('ceralive.service', b'RECOVER\n')
        self.assertEqual(got[0], 'REFUSED recovery needs an operator at their own terminal')
        self.assertIsNotNone(self.broker.committed)
        self.restart_with()
        _, got = self.recover_on_pty()
        self.assertIn('REFUSED nothing to recover', got)

    def test_an_unreadable_manager_state_is_not_quiet(self):
        def system(answer, code):
            def runner(argv, timeout):
                if argv[:1] == ['busctl']:
                    return subprocess.CompletedProcess(argv, 0, 'b false\n', '')
                if argv[:2] == ['systemctl', 'list-jobs']:
                    return subprocess.CompletedProcess(argv, 0, '', '')
                return subprocess.CompletedProcess(argv, code, answer, 'Failed to connect to bus\n' if not answer else '')
            return runner
        self.assertTrue(broker.shutdown_in_flight(system('', 1)), 'a failed manager query with empty stdout counted as quiet')
        self.assertTrue(broker.shutdown_in_flight(system('stopping\n', 1)))
        self.assertTrue(broker.shutdown_in_flight(system('offline\n', 1)))
        self.assertEqual(broker.shutdown_in_flight(system('running\n', 0)), [])
        self.assertEqual(broker.shutdown_in_flight(system('degraded\n', 1)), [])

    def test_fence_and_update_lock_are_retried_until_held(self):
        blocker = os.open(self.paths['update.lock'], os.O_RDWR)
        fcntl.flock(blocker, fcntl.LOCK_EX)
        os.makedirs(self.dir, exist_ok=True)
        real_dir = self.fence_dir
        self.restart_with()
        self.broker.release()
        Path(real_dir).mkdir(exist_ok=True)
        os.rmdir(real_dir)
        Path(real_dir).write_text('not a directory')  # the fence can't be written yet
        Path(self.state).write_bytes(b'not json')
        self.broker = self.new_broker()
        self.assertNotIn('update', self.broker.locks)
        _, got = self.as_unit('ceralive.service')
        self.assertIn('REFUSED', got[0])
        os.unlink(real_dir)
        os.close(blocker)
        for _ in range(12):
            self.clock[0] += 30
            self.pump(lambda: False, rounds=2)
        self.assertTrue(os.path.exists(self.fence), 'the fence was not restored')
        self.assertIn('update', self.broker.locks, 'the update lock was not taken')
        self.assertIsNotNone(self.broker.committed)

    def test_a_record_missing_required_fields_is_lost_evidence(self):
        for bad in (b'{"time": 1}', b'{"state": "waiting"}', b'{"state": "idle", "requests": []}', b'[]'):
            with self.subTest(record=bad):
                self.restart_with(state=bad)
                self.assertIsNotNone(self.broker.committed, 'a malformed record became idle')
                self.assertEqual(Path(self.state).read_bytes(), bad)


class RecheckSix(RecheckFive):
    """Sixth re-check: a recovery confirms the request it showed, one at a time;
    unknown outcomes refuse joins; only a literal cleared: true is stale."""

    # RecheckFive's tests are not run again here.
    for name in [n for n in vars(RecheckFive) if n.startswith('test_')]:
        locals()[name] = None
    del name

    def prompt_recover(self):
        pid, master, out = self.operator_on_pty(b'RECOVER\n')
        seen = []
        self.assertTrue(self.pump(lambda: seen.append(self.read_master(master)) or 'press Enter' in ''.join(seen)))
        return master, out, ''.join(seen)

    def answers(self, out):
        got = []
        self.pump(lambda: got.append(self.read_pipe(out)) or any(w in ''.join(got) for w in ('RECOVERED', 'REFUSED')))
        return ''.join(got)

    def test_an_old_prompt_never_clears_a_later_unknown_request(self):
        self.restart_with(fence='aaaaaaaaaaaa')
        master_a, out_a, prompt = self.prompt_recover()  # shows request A, left open
        self.assertIn('aaaaaaaaaaaa', prompt)
        _, got = self.recover_on_pty()  # another terminal clears A
        self.assertIn('RECOVERED aaaaaaaaaaaa', got)
        self.system.logind = 'noreply'
        _, admitted = self.as_unit('ceralive.service')
        b = admitted[0].split()[2]
        self.assertTrue(self.pump(lambda: self.broker.committed and self.broker.committed['stage'] == 'uncertain'))
        self.assertEqual(self.broker.committed['id'], b)
        os.write(master_a, b'recover\n')  # the old confirmation, for A
        got = self.answers(out_a)
        self.assertIn('REFUSED', got)
        self.assertIn('changed', got)
        self.assertEqual(self.broker.committed['id'], b, 'a confirmation for A cleared B')
        self.assertEqual(Path(self.fence).read_text().strip(), b)

    def test_one_recovery_at_a_time_and_every_operator_gets_an_answer(self):
        self.restart_with(fence='aaaaaaaaaaaa')
        master_1, out_1, _ = self.prompt_recover()
        master_2, out_2, _ = self.prompt_recover()
        os.write(master_1, b'recover\n')
        os.write(master_2, b'recover\n')
        for _ in range(20):  # both answers read before the committer runs
            self.broker.step(0.02)
            self.broker.deliver()
        got_1, got_2 = self.answers(out_1), self.answers(out_2)
        self.pump(lambda: False, rounds=5)
        got_1 += self.read_pipe(out_1)
        got_2 += self.read_pipe(out_2)
        finals = [g for g in (got_1, got_2) if 'RECOVERED' in g or 'REFUSED' in g]
        self.assertEqual(len(finals), 2, f'an operator got no answer: {got_1!r} / {got_2!r}')
        self.assertEqual(sum('RECOVERED' in g for g in (got_1, got_2)), 1)
        self.assertIsNone(self.broker.committed)

    def test_a_no_reply_request_refuses_every_other_request(self):
        self.system.logind = 'noreply'
        self.as_unit('ceralive.service')
        self.pump(lambda: self.broker.committed and self.broker.committed['stage'] == 'uncertain')
        for unit, action in (('ceralive.service', b'POWEROFF\n'), ('ceralive-button.service', b'POWEROFF\n'),
                             ('ceralive.service', b'REBOOT\n')):
            _, got = self.as_unit(unit, action)
            self.assertTrue(got[0].startswith('REFUSED'), (unit, got))
            self.assertIn('ceralive-poweroff --recover', got[0])
        self.assertEqual(self.broker.waiters, [])

    def test_only_a_literal_cleared_true_makes_a_fence_stale(self):
        for cleared in ('false', 1, 'true', [True]):
            with self.subTest(cleared=cleared):
                entry = {'state': 'uncertain', 'id': 'aaaaaaaaaaaa', 'action': 'poweroff', 'origin': 'ceraui',
                         'time': int(time.time()), 'cleared': cleared}
                self.restart_with(state=json.dumps(dict(entry, requests={'aaaaaaaaaaaa': entry})).encode(),
                                  fence='aaaaaaaaaaaa')
                self.assertIsNotNone(self.broker.committed, 'a non-boolean cleared value released the fence')
                self.assertTrue(os.path.exists(self.fence))
        entry = dict(entry, cleared=True)
        self.restart_with(state=json.dumps(dict(entry, state='idle', requests={'aaaaaaaaaaaa': entry})).encode(),
                          fence='aaaaaaaaaaaa')
        self.assertIsNone(self.broker.committed)
        self.assertFalse(os.path.exists(self.fence))


class Parsing(unittest.TestCase):
    def test_stat_fields_after_a_command_name_with_spaces(self):
        sample = b'123 (a b) c) S 1 123 123 34817 123 4194560 0'
        self.assertEqual(broker.parse_stat(sample), {'pgrp': 123, 'session': 123, 'tty_nr': 34817, 'tpgid': 123})

    def test_terminal_paths(self):
        self.assertEqual(broker.tty_path(os.makedev(136, 3)), '/dev/pts/3')
        self.assertEqual(broker.tty_path(os.makedev(137, 1)), '/dev/pts/257')
        self.assertEqual(broker.tty_path(os.makedev(4, 1)), '/dev/tty1')
        self.assertEqual(broker.tty_path(os.makedev(4, 66)), '/dev/ttyS2')
        self.assertIsNone(broker.tty_path(os.makedev(5, 0)))  # /dev/tty is never trusted
        self.assertIsNone(broker.tty_path(os.makedev(5, 1)))  # /dev/console

    def test_only_a_direct_system_service_is_a_unit_origin(self):
        cases = {
            b'0::/system.slice/ceralive.service\n': 'ceralive.service',
            b'0::/system.slice/ceralive.service/sub\n': None,
            b'0::/user.slice/user-0.slice/user@0.service/app.slice/ceralive.service\n': None,
            b'0::/user.slice/user-1000.slice/session-c1.scope\n': None,
        }
        for data, expected in cases.items():
            with patch.object(broker, 'read_bracketed', lambda pidfd, name, d=data: (1, d)):
                self.assertEqual(broker.system_unit(3), expected, data)


if __name__ == '__main__':
    unittest.main(argv=sys.argv[:1] + sys.argv[1:], verbosity=1)

"""Hardware-free contracts for the power admission broker.

Real Unix sockets with socket-bound peer pidfds, a real pseudo-terminal for the
operator prompt and real flock/fcntl locks; only systemd, logind and RAUC are
answered by a fake command runner. The real-logind behaviour is covered by the
opt-in tests/real-power-admission.sh.
"""
import fcntl
import importlib.util
import os
import pty
import select
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
os.environ['CERALIVE_POWER_RUN_DIR'] = RUN
spec = importlib.util.spec_from_file_location('broker', ROOT / 'mkosi/runtime/power/ceralive-power-broker.py')
broker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(broker)


class FakeSystem:
    """Answers the commands the broker and drain run."""

    def __init__(self):
        self.installing = False
        self.units = []
        self.system_state = 'running'
        self.logind = 'ok'  # ok | refuse | hang
        self.calls = []

    def __call__(self, argv, timeout):
        self.calls.append(argv)
        out = lambda code=0, stdout='', stderr='': subprocess.CompletedProcess(argv, code, stdout, stderr)
        if argv[:1] == ['busctl'] and 'get-property' in argv:
            return out(0, 's "installing"\n' if self.installing else 's "idle"\n')
        if argv[:1] == ['busctl'] and 'call' in argv:
            if self.logind == 'hang':
                raise subprocess.TimeoutExpired(argv, timeout)
            if self.logind == 'refuse':
                return out(1, '', 'Call failed: Access denied\n')
            return out(0)
        if argv[:2] == ['systemctl', 'list-units']:
            return out(0, ''.join(f'{unit} loaded active running x\n' for unit in self.units))
        if argv[:2] == ['systemctl', 'is-system-running']:
            return out(0, self.system_state + '\n')
        if argv[:2] == ['systemctl', 'is-active']:
            return out(3, 'inactive\n')
        return out(0)

    def submissions(self):
        return [argv for argv in self.calls if argv[:1] == ['busctl'] and 'call' in argv]


class Harness(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix='broker-')
        self.paths = {name: os.path.join(self.dir, name) for name in ('update.lock', 'lock-frontend', 'activate.lock')}
        for path in self.paths.values():
            Path(path).touch()
        self.patches = [
            patch.object(broker, 'UPDATE_LOCK', self.paths['update.lock']),
            patch.object(broker, 'DPKG_LOCK', self.paths['lock-frontend']),
            patch.object(broker, 'ACTIVATION_LOCK', self.paths['activate.lock']),
            # Unprivileged tests can't read PID 1's namespace; same host namespace.
            patch.object(broker, 'SYSTEM_MOUNT_NS', '/proc/self/ns/mnt'),
        ]
        for p in self.patches:
            p.start()
        self.sock_path = os.path.join(self.dir, 'request.sock')
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.sock_path)
        self.listener.listen(8)
        self.system = FakeSystem()
        self.clock = [1000.0]
        self.broker = broker.Broker(self.listener, runner=self.system, clock=lambda: self.clock[0])
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

    def pump(self, until, rounds=200):
        for _ in range(rounds):
            self.broker.step(0.02)
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
        self.assertEqual(submitted[0][-3:], ['PowerOffWithFlags', 't', str(broker.SKIP_INHIBITORS)])
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

    def test_one_prompt_per_terminal(self):
        pid, master, out = self.operator_on_pty()
        self.assertTrue(self.pump(lambda: 'Type poweroff' in self.read_master(master)))
        rdev = next(iter(self.broker.prompts))
        self.assertEqual(len(self.broker.prompts), 1)
        self.assertIn(rdev, self.broker.prompts)


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
        self.assertIn('ADMITTED poweroff', got)
        self.assertEqual(self.broker.committed['origin'], 'button')
        self.assertEqual(len(self.system.submissions()), 1)

    def test_button_may_not_reboot(self):
        conn, got = self.run_as('ceralive-button.service', b'REBOOT\n')
        self.assertIn('REFUSED the button may only power off', got)
        self.assertIsNone(self.broker.committed)

    def test_ceraui_admitted_reboot(self):
        conn, got = self.run_as('ceralive.service', b'REBOOT\n')
        self.assertIn('ADMITTED reboot', got)
        self.assertEqual(self.system.submissions()[0][-3], 'RebootWithFlags')

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
        self.assertIn('PENDING poweroff', got2)
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
            proc = subprocess.Popen([sys.executable, '-I', client, '--no-wait'], env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.pump(lambda: proc.poll() is not None, rounds=300)
        out, _ = proc.communicate(timeout=5)
        return proc.returncode, out.strip()

    def test_no_wait_returns_on_admission_for_ceraui(self):
        self.system.installing = True  # admitted, still waiting for the write
        code, out = self.run_client('ceralive.service', 'ceralive-reboot')
        self.assertEqual((code, out), (0, 'ADMITTED reboot'))
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
        state = Path(RUN, 'state.json').read_text()
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
            self.assertIn('update lock', Path(RUN, 'state.json').read_text())
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
            self.assertIn('package-install', Path(RUN, 'state.json').read_text())
        finally:
            os.kill(pid, 9)
            os.waitpid(pid, 0)
        self.assertTrue(self.pump(lambda: self.system.submissions()))

    def test_escalation_reports_stuck_and_keeps_waiting(self):
        self.system.installing = True
        self.admit_button()
        self.clock[0] += broker.ESCALATE_S + 1
        self.pump(lambda: False, rounds=5)
        self.assertIn('"stuck"', Path(RUN, 'state.json').read_text())
        self.assertEqual(self.system.submissions(), [], 'the bound never cuts a write')

    def test_logind_refusal_fails_closed_and_releases_the_fence(self):
        self.system.logind = 'refuse'
        self.admit_button()
        self.pump(lambda: self.broker.committed is None)
        self.assertEqual(len(self.system.submissions()), 1)
        self.assertIn('"failed"', Path(RUN, 'state.json').read_text())
        self.assertEqual(self.broker.locks, {})

    def test_unanswered_logind_is_uncertain_and_never_retried(self):
        self.system.logind = 'hang'
        self.admit_button()
        self.pump(lambda: False, rounds=20)
        self.assertEqual(len(self.system.submissions()), 1)
        self.assertEqual(self.broker.committed['stage'], 'uncertain')
        self.assertIn('update', self.broker.locks)


class Drain(unittest.TestCase):
    def test_manual_stop_returns_at_once(self):
        system = FakeSystem()
        system.installing = True
        self.assertEqual(broker.drain(sleep=lambda s: self.fail('waited'), runner=system), 0)

    def test_shutdown_waits_for_rauc_and_units_then_continues(self):
        system = FakeSystem()
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
        system = FakeSystem()
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

    def test_unreadable_rauc_counts_as_busy_and_absent_service_as_idle(self):
        absent = lambda argv, t: subprocess.CompletedProcess(argv, 1, '', 'Call failed: The name de.pengutronix.rauc was not provided by any .service files\n')
        broken = lambda argv, t: subprocess.CompletedProcess(argv, 1, '', 'Failed to connect to bus\n')
        self.assertFalse(broker.rauc_installing(absent))
        self.assertTrue(broker.rauc_installing(broken))


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

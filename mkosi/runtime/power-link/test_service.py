"""Host-only, single-process PTY contract tests; never opens hardware."""
import binascii
import json
import os
from pathlib import Path
import pty
import select
import shlex
import signal
import shutil
import sys
import subprocess
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent


def frame(seq, extra=""):
    body = (f'OSB1 up=100 thermal=normal pack=ready/25.0C/00 '
            'a=healthy/na/na/22.0C/00 b=healthy/5.0V/1.0A/uncal/00 '
            f'pack_cal=datasheet start=on gaps=0000 seq={seq} boot=12345678 '
            'rst=poweron alive=1 hot=none shutdowns=0 fw=field-12345678').encode()
    body += extra.encode()
    return body + f' crc={binascii.crc_hqx(body, 0xffff):04X}\n'.encode()


@unittest.skipUnless(sys.platform.startswith("linux"), "Linux PTY and /proc contracts")
class ServiceTest(unittest.TestCase):
    def test_udev_identity_and_read_only_permissions(self):
        rule = (HERE / '79-power-supervisor.rules').read_text()
        clauses = [part.strip() for part in rule.splitlines()[-1].split(',')]
        # Pin the complete match: no broad tty or enumeration-order fallback.
        matches = [part for part in clauses if '==' in part]
        self.assertEqual(matches, ['SUBSYSTEM=="tty"', 'ATTRS{idVendor}=="303a"',
                                  'ATTRS{idProduct}=="1001"',
                                  'ENV{ID_USB_INTERFACE_NUM}=="00"'])
        self.assertEqual([part for part in clauses if '==' not in part],
                         ['GROUP="supervisor-power"', 'MODE="0440"',
                          'ENV{ID_MM_DEVICE_IGNORE}="1"', 'TAG+="systemd"'])

    def test_renamed_staged_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            subprocess.run(['make', '-C', str(HERE), f'DESTDIR={tmp}', 'install'], check=True)
            unit = 'supervisor-power-link.service'
            self.assertEqual((root / 'usr/lib/systemd/system' / unit).read_bytes(),
                             (HERE / unit).read_bytes())
            self.assertEqual(os.readlink(root / 'etc/systemd/system/multi-user.target.wants' / unit),
                             f'/usr/lib/systemd/system/{unit}')
            for directory, name, source in [
                ('sysusers.d', 'supervisor-power.conf', 'supervisor-power.conf'),
                ('tmpfiles.d', 'supervisor-power.conf', 'supervisor-power-tmpfiles.conf'),
                ('udev/rules.d', '79-power-supervisor.rules', '79-power-supervisor.rules')]:
                self.assertEqual((root / 'usr/lib' / directory / name).read_bytes(),
                                 (HERE / source).read_bytes())
            binary = root / 'usr/libexec/supervisor-power-link'
            self.assertEqual(binary.stat().st_mode & 0o777, 0o755)
            self.assertIn('u supervisor-power -', (HERE / 'supervisor-power.conf').read_text())

    def test_consumer_documentation(self):
        doc = (HERE.parents[2] / 'docs/supervisor-power-link.md').read_text()
        self.assertIn('| `silent` |', doc)
        self.assertIn('Check `schema_version` first', doc)
        self.assertIn('once per second (heartbeat), plus once at stop', doc)
        self.assertIn('its age is 3000 ms or more', doc)
        self.assertIn('expected false and persist_error false', doc)

    def test_missing_data_at_startup(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root / 'tty').mkdir()
            binary = root / 'reader'
            # Production mount check, with an absent mountpoint in this fixture.
            source = (HERE / 'power_link.c').read_text().replace('stat("/data",', 'stat("/nonexistent-supervisor-data",')
            (root / 'reader.c').write_text(source)
            subprocess.run(['cc', str(root / 'reader.c'), '-o', str(binary)], check=True)
            proc = subprocess.Popen([str(binary), '--sysfs-dir', str(root / 'tty'), '--state-dir', tmp], stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 3
                while not (root / 'supervisor.json').exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                state = json.loads((root / 'supervisor.json').read_text())
                self.assertEqual(state['link'], 'absent')
                self.assertFalse(state['expected'])
                self.assertTrue(state['persist_error'])
            finally:
                proc.terminate(); _, logs = proc.communicate(timeout=3)
                self.assertIn("persistence unavailable at startup", logs)

    def test_discovery_during_backoff(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); sysfs = root / 'tty'; sysfs.mkdir()
            # Redirect only discovered device paths to regular fixture files:
            # open succeeds, tty setup fails, and backoff reaches eight seconds.
            source = (HERE / 'power_link.c').read_text().replace('"/dev/%s"', '"' + tmp + '/%s"')
            (root / 'reader.c').write_text(source)
            binary = root / 'reader'
            subprocess.run(['cc', str(root / 'reader.c'), '-o', str(binary)], check=True)
            def match(i):
                usb = root / f'usb{i}'; interface = usb / 'interface'; interface.mkdir(parents=True)
                (usb / 'idVendor').write_text('303a')
                (usb / 'idProduct').write_text('1001')
                (interface / 'bInterfaceNumber').write_text('00')
                tty = sysfs / f'ttyACM{i}'; tty.mkdir(); (tty / 'device').symlink_to(interface)
                (root / f'ttyACM{i}').touch()
            match(0)
            proc = subprocess.Popen([str(binary), '--sysfs-dir', str(sysfs), '--state-dir', tmp, '--persistent-dir', tmp])
            try:
                time.sleep(7.4)  # attempts at 0, 1, 3, 7; next open at 15
                match(1)
                time.sleep(1.8)
                self.assertTrue(json.loads((root / 'supervisor.json').read_text())['ambiguous'])
                shutil.rmtree(sysfs / 'ttyACM0'); shutil.rmtree(sysfs / 'ttyACM1')
                time.sleep(1.8)
                state = json.loads((root / 'supervisor.json').read_text())
                self.assertFalse(state['ambiguous'])
                self.assertEqual(state['link'], 'absent')
                self.assertEqual(state['open_error'], 0)
            finally:
                proc.terminate(); proc.wait(timeout=3)

    def test_no_device_is_idle(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); sysfs = root / 'tty'; sysfs.mkdir()
            binary = root / 'reader'
            subprocess.run(['cc', str(HERE / 'power_link.c'), '-o', str(binary)], check=True)
            proc = subprocess.Popen([str(binary), '--sysfs-dir', str(sysfs),
                                     '--state-dir', tmp, '--persistent-dir', tmp])
            try:
                deadline = time.monotonic() + 3
                state = None
                first = None
                while time.monotonic() < deadline:
                    try:
                        state = json.loads((root / 'supervisor.json').read_text())
                        if first is None: first = state['published_mono_ms']
                        elif state['published_mono_ms'] > first: break
                    except FileNotFoundError: pass
                    time.sleep(.02)
                self.assertEqual(state['link'], 'absent')
                self.assertFalse(state['expected'])
                self.assertFalse(state['ambiguous'])
                self.assertEqual(state['accepted_lines'], 0)
                self.assertGreater(state['published_mono_ms'], first)
                self.assertFalse((root / 'expected').exists())
                self.assertFalse(any(os.readlink(fd).startswith('/dev/tty')
                                     for fd in Path(f'/proc/{proc.pid}/fd').iterdir()))
            finally:
                proc.terminate(); proc.wait(timeout=3)

    def test_unit_lifecycle_and_persistent_path(self):
        unit = (HERE / 'supervisor-power-link.service').read_text()
        self.assertIn('RuntimeDirectoryPreserve=yes', unit)
        self.assertNotIn('RequiresMountsFor=', unit)
        self.assertIn('data.mount', unit.split('After=')[1].splitlines()[0])
        self.assertIn('mountpoint -q /data', unit)
        self.assertIn('ExecStartPre=+-', unit)
        self.assertNotIn('StateDirectory=', unit)
        self.assertIn('ReadWritePaths=/run/ceralive/power -/data/supervisor-power', unit)
        self.assertNotIn('d /data/', (HERE / 'supervisor-power-tmpfiles.conf').read_text())
        self.assertIn('tmpfiles.d/supervisor-power.conf', (HERE / 'Makefile').read_text())

    def test_mount_checked_directory_preparation(self):
        # Execute the unit's actual shell fragment with host-only fake tools.
        unit = (HERE / 'supervisor-power-link.service').read_text()
        command = shlex.split(unit.split('ExecStartPre=+-', 1)[1].splitlines()[0])
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); calls = root / 'calls'
            mountpoint = root / 'mountpoint'; install = root / 'install'
            mountpoint.write_text('#!/bin/sh\nexit "$MOUNT_RESULT"\n')
            install.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$CALLS"\n')
            mountpoint.chmod(0o755); install.chmod(0o755)
            env = dict(os.environ, PATH=tmp, CALLS=str(calls), MOUNT_RESULT='1')
            self.assertNotEqual(subprocess.run(command, env=env).returncode, 0)
            self.assertFalse(calls.exists())
            env['MOUNT_RESULT'] = '0'
            subprocess.run(command, env=env, check=True)
            self.assertEqual(calls.read_text().splitlines(),
                             ['-d', '-o', 'supervisor-power', '-g', 'supervisor-power', '-m', '0755', '/data/supervisor-power'])

    @unittest.skipUnless(shutil.which('systemd-analyze'), 'systemd-analyze unavailable')
    def test_unit_verifies(self):
        with tempfile.TemporaryDirectory() as tmp:
            unit = Path(tmp) / 'supervisor-power-link.service'
            unit.write_text((HERE / unit.name).read_text().replace('/usr/libexec/supervisor-power-link', '/usr/bin/true'))
            subprocess.run(['systemd-analyze', 'verify', str(unit)], check=True)

    def test_permission_failure_is_not_absent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); device = root / 'unreadable'; device.touch(); device.chmod(0)
            binary = root / 'power-link'
            subprocess.run(['cc', *shlex.split(os.environ.get('POWER_LINK_TEST_CFLAGS', '')),
                            str(HERE / 'power_link.c'), '-o', str(binary)], check=True)
            def drop_root():
                os.setgid(65534); os.setuid(65534)
            if os.geteuid() == 0: root.chmod(0o777)
            proc = subprocess.Popen([str(binary), '--device', str(device),
                                     '--state-dir', tmp, '--persistent-dir', tmp],
                                    preexec_fn=drop_root if os.geteuid() == 0 else None)
            try:
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    try:
                        state = json.loads((root / 'supervisor.json').read_text())
                        if state['link'] == 'error': break
                    except FileNotFoundError: pass
                    time.sleep(.02)
                self.assertEqual(state['link'], 'error')
                self.assertEqual(state['open_error'], 13)
                self.assertFalse(state['expected'])
            finally:
                proc.terminate(); proc.wait(timeout=3)

    def test_stop_marker_failure_retry_and_event_generation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            binary = root / 'power-link'
            subprocess.run(['cc', *shlex.split(os.environ.get('POWER_LINK_TEST_CFLAGS', '')), '-std=c11', '-Wall', '-Wextra', '-Werror',
                            str(HERE / 'power_link.c'), '-o', str(binary)], check=True)
            persist = root / 'not-created'
            master, slave = pty.openpty()
            proc = subprocess.Popen([str(binary), '--device', os.ttyname(slave),
                                     '--state-dir', tmp, '--persistent-dir', str(persist)], stderr=subprocess.PIPE)
            def wait_for(predicate):
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    self.assertIsNone(proc.poll(), 'marker error killed reader')
                    try:
                        state = json.loads((root / 'supervisor.json').read_text())
                        if predicate(state): return state
                    except FileNotFoundError:
                        pass
                    time.sleep(.02)
                self.fail('state deadline exceeded')
            try:
                wait_for(lambda s: s['link'] == 'silent')
                heartbeat = wait_for(lambda s: 'published_mono_ms' in s)['published_mono_ms']
                wait_for(lambda s: s['published_mono_ms'] > heartbeat)
                before = (root / 'events.jsonl').stat().st_mtime_ns
                os.write(master, frame(0))
                wait_for(lambda s: s['expected'])
                state = wait_for(lambda s: s.get('persist_error') is True)
                self.assertEqual(state['link'], 'ok')
                self.assertEqual((root / 'events.jsonl').stat().st_mtime_ns, before)
                time.sleep(2.1)
                persist.mkdir()
                wait_for(lambda s: s.get('persist_error') is False)
                self.assertEqual((persist / 'expected').stat().st_mode & 0o777, 0o644)
                self.assertEqual((root / 'events.jsonl').stat().st_mode & 0o777, 0o644)
                proc.terminate(); self.assertEqual(proc.wait(timeout=3), 0)
                self.assertEqual(json.loads((root / 'supervisor.json').read_text())['link'], 'stopped')
                log = proc.stderr.read()
                self.assertEqual(log.count(b'persist expected'), 1)
                self.assertIn(os.strerror(2).encode(), log)
                proc.stderr.close()
            finally:
                if proc.poll() is None: proc.terminate(); proc.wait(timeout=3)
                os.close(master); os.close(slave)

    @unittest.skipUnless(shutil.which('strace'), 'strace unavailable')
    def test_post_open_retry_backoff(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); binary = root / 'power-link'; device = root / 'not-a-tty'
            device.touch()
            subprocess.run(['cc', *shlex.split(os.environ.get('POWER_LINK_TEST_CFLAGS', '')),
                            str(HERE / 'power_link.c'), '-o', str(binary)], check=True)
            trace = root / 'trace'
            trace_env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0')  # LSan cannot run under ptrace.
            proc = subprocess.Popen(['strace', '-o', str(trace), '-e', 'openat', str(binary),
                                     '--device', str(device), '--state-dir', tmp, '--persistent-dir', tmp], env=trace_env)
            try:
                time.sleep(7.5)
                # SIGTERM the tracee rather than its tracing parent.
                children = Path(f'/proc/{proc.pid}/task/{proc.pid}/children').read_text().split()
                self.assertEqual(len(children), 1)
                os.kill(int(children[0]), signal.SIGTERM)
                self.assertEqual(proc.wait(timeout=3), 0)
                attempts = [line for line in trace.read_text().splitlines() if str(device) in line]
                self.assertEqual(len(attempts), 4)  # 0, 1, 3, 7 s; next at 15 s
            finally:
                if proc.poll() is None: proc.terminate(); proc.wait(timeout=3)

    def test_enumeration_debounce_and_reconnect(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); binary = root / 'power-link'
            subprocess.run(['cc', *shlex.split(os.environ.get('POWER_LINK_TEST_CFLAGS', '')),
                            str(HERE / 'power_link.c'), '-o', str(binary)], check=True)
            device = root / 'device'
            # A regular file opens but fails tty setup. Its first error is debounced.
            device.touch()
            proc = subprocess.Popen([str(binary), '--device', str(device), '--state-dir', tmp,
                                     '--persistent-dir', tmp])
            def wait_for(predicate, timeout=6):
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    try:
                        state = json.loads((root / 'supervisor.json').read_text())
                        if predicate(state): return state
                    except FileNotFoundError: pass
                    time.sleep(.02)
                self.fail('state deadline exceeded')
            master = slave = None
            try:
                first = wait_for(lambda s: True)
                self.assertEqual(first['link'], 'silent')
                wait_for(lambda s: s['link'] == 'error')
                master, slave = pty.openpty()
                device.unlink(); device.symlink_to(os.ttyname(slave))
                wait_for(lambda s: s['link'] == 'silent' and s['open_error'] == 0)
                os.write(master, frame(0))
                wait_for(lambda s: s['link'] == 'ok')
                os.write(master, b'OSB1 truncated')
                time.sleep(.15)
                os.close(master); master = None
                os.close(slave); slave = None
                wait_for(lambda s: s['link'] != 'ok')
                master, slave = pty.openpty()
                device.unlink(); device.symlink_to(os.ttyname(slave))
                wait_for(lambda s: s['link'] == 'silent' and s['open_error'] == 0)
                os.write(master, frame(1))
                state = wait_for(lambda s: s['link'] == 'ok')
                self.assertEqual(state['accepted_lines'], 2)
                self.assertEqual(state['rejected']['crc'], 0)
            finally:
                proc.terminate(); proc.wait(timeout=3)
                if master is not None: os.close(master)
                if slave is not None: os.close(slave)

    def test_open_failure_and_existing_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root / 'expected').write_text('1\n')
            binary = root / 'power-link'
            subprocess.run(['cc', *shlex.split(os.environ.get('POWER_LINK_TEST_CFLAGS', '')), str(HERE / 'power_link.c'), '-o', str(binary)], check=True)
            master, slave = pty.openpty()
            import fcntl
            import termios
            fcntl.ioctl(slave, termios.TIOCEXCL)
            def drop_root():
                os.setgid(65534); os.setuid(65534)
            if os.geteuid() == 0:
                root.chmod(0o777)
                os.chmod(os.ttyname(slave), 0o666)
            proc = subprocess.Popen([str(binary), '--device', os.ttyname(slave),
                                     '--state-dir', tmp, '--persistent-dir', tmp],
                                    preexec_fn=drop_root if os.geteuid() == 0 else None)
            try:
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    try:
                        state = json.loads((root / 'supervisor.json').read_text())
                        if state['link'] == 'error': break
                    except FileNotFoundError: pass
                    time.sleep(.02)
                self.assertEqual(state['link'], 'error')
                self.assertEqual(state['open_error'], 16)  # Linux EBUSY
                self.assertTrue(state['expected'])
                proc.terminate(); self.assertEqual(proc.wait(timeout=3), 0)
                stopped = json.loads((root / 'supervisor.json').read_text())
                self.assertEqual(stopped['link'], 'stopped')
                self.assertEqual(stopped['open_error'], 16)
            finally:
                proc.terminate(); proc.wait(timeout=3)
                os.close(master); os.close(slave)

    def test_ambiguous_devices_are_not_opened(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            binary = root / 'power-link'
            subprocess.run(['cc', *shlex.split(os.environ.get('POWER_LINK_TEST_CFLAGS', '')), '-std=c11', '-Wall', '-Wextra', '-Werror',
                            '-O1', str(HERE / 'power_link.c'), '-o', str(binary)], check=True)
            sysfs = root / 'tty'
            sysfs.mkdir()
            for i in range(2):
                usb = root / f'usb{i}'
                interface = usb / 'interface'
                interface.mkdir(parents=True)
                (usb / 'idVendor').write_text('303a\n')
                (usb / 'idProduct').write_text('1001\n')
                (interface / 'bInterfaceNumber').write_text('00\n')
                tty = sysfs / f'ttyACM{i}'
                tty.mkdir()
                (tty / 'device').symlink_to(interface)
            proc = subprocess.Popen([str(binary), '--sysfs-dir', str(sysfs),
                                     '--state-dir', tmp, '--persistent-dir', tmp])
            try:
                deadline = time.monotonic() + 3
                while not (root / 'supervisor.json').exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                state = json.loads((root / 'supervisor.json').read_text())
                self.assertTrue(state['ambiguous'])
                self.assertEqual(state['link'], 'absent')
                self.assertFalse(state['expected'])
            finally:
                proc.terminate()
                proc.wait(timeout=2)

    def test_pty_atomic_files_stale_and_no_transmit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            binary = root / 'power-link'
            subprocess.run(['cc', *shlex.split(os.environ.get('POWER_LINK_TEST_CFLAGS', '')), '-std=c11', '-Wall', '-Wextra', '-Werror',
                            '-O1', str(HERE / 'power_link.c'), '-o', str(binary)], check=True)
            master, slave = pty.openpty()
            proc = subprocess.Popen([str(binary), '--device', os.ttyname(slave),
                                     '--state-dir', tmp, '--persistent-dir', tmp])
            def wait_for(predicate, timeout=4):
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    try:
                        state = json.loads((root / 'supervisor.json').read_text())
                        if predicate(state):
                            return state
                    except FileNotFoundError:
                        pass
                    time.sleep(.02)
                self.fail('state deadline exceeded')
            try:
                wait_for(lambda s: s['link'] == 'silent')
                serial_fds = [fd for fd in Path(f'/proc/{proc.pid}/fd').iterdir()
                              if os.readlink(fd) == os.ttyname(slave)]
                self.assertEqual(len(serial_fds), 1)
                info = Path(f'/proc/{proc.pid}/fdinfo/{serial_fds[0].name}').read_text()
                flags = int(next(row.split()[1] for row in info.splitlines()
                                 if row.startswith('flags:')), 8)
                self.assertEqual(flags & os.O_ACCMODE, os.O_RDONLY)
                os.write(master, frame(0, " power=ok gaps2=0000"))
                state = wait_for(lambda s: s['link'] == 'ok')
                self.assertEqual(state['temperatures']['pack']['celsius'], 25)
                self.assertEqual(state['temperatures']['a']['celsius'], 22)
                self.assertIsNone(state['temperatures']['b']['celsius'])
                self.assertEqual(state['temperatures']['b']['quality'], 'uncal')
                self.assertTrue(state['semantics']['power_healthy'])
                self.assertTrue(state['expected'])
                self.assertEqual((root / 'supervisor.json').stat().st_mode & 0o777, 0o644)
                os.write(master, b'OSB1 truncated')
                stale = wait_for(lambda s: s['stale'], timeout=7)
                self.assertFalse(stale['semantics']['power_healthy'])
                self.assertEqual(stale['semantics']['protection'], 'unknown')
                self.assertEqual(select.select([master], [], [], 0)[0], [])
                os.kill(proc.pid, signal.SIGKILL)
                proc.wait(timeout=2)
                self.assertGreaterEqual(time.monotonic() * 1000 - state['rx_mono_ms'], 5000)
                self.assertTrue((root / 'expected').exists())
                frozen = json.loads((root / 'supervisor.json').read_text())
                time.sleep(3.05)
                self.assertEqual(json.loads((root / 'supervisor.json').read_text()), frozen)
                self.assertGreaterEqual(time.monotonic()*1000 - frozen['published_mono_ms'], 3000)
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    proc.wait(timeout=2)
                os.close(master)
                os.close(slave)


if __name__ == '__main__':
    unittest.main()

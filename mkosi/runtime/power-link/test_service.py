"""Host-only, single-process PTY contract tests; never opens hardware."""
import binascii
import json
import os
from pathlib import Path
import pty
import select
import shlex
import signal
import subprocess
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent


def frame(seq):
    body = (f'OSB1 up=100 thermal=normal pack=ready/25.0C/00 '
            'a=healthy/na/na/22.0C/00 b=healthy/5.0V/1.0A/uncal/00 '
            f'pack_cal=datasheet start=on gaps=0000 seq={seq} boot=12345678 '
            'rst=poweron alive=1 hot=none shutdowns=0 fw=field-12345678').encode()
    return body + f' crc={binascii.crc_hqx(body, 0xffff):04X}\n'.encode()


class ServiceTest(unittest.TestCase):
    def test_unit_lifecycle_and_persistent_path(self):
        unit = (HERE / 'osb-power-link.service').read_text()
        self.assertIn('RuntimeDirectoryPreserve=yes', unit)
        self.assertIn('RequiresMountsFor=/data/osb-power', unit)
        self.assertNotIn('StateDirectory=', unit)
        self.assertIn('ReadWritePaths=/run/ceralive/power -/data/osb-power', unit)
        self.assertIn('/data/osb-power', (HERE / 'osb-power-tmpfiles.conf').read_text())
        self.assertIn('tmpfiles.d/osb-power.conf', (HERE / 'Makefile').read_text())

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
                while not (root / 'supervisor.json').exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                state = json.loads((root / 'supervisor.json').read_text())
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
                                     '--state-dir', tmp, '--persistent-dir', str(persist)])
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
                before = (root / 'events.jsonl').stat().st_mtime_ns
                os.write(master, frame(0))
                wait_for(lambda s: s['expected'])
                state = wait_for(lambda s: s.get('persist_error') is True)
                self.assertEqual(state['link'], 'ok')
                self.assertEqual((root / 'events.jsonl').stat().st_mtime_ns, before)
                persist.mkdir()
                wait_for(lambda s: s.get('persist_error') is False)
                self.assertEqual((persist / 'expected').stat().st_mode & 0o777, 0o644)
                self.assertEqual((root / 'events.jsonl').stat().st_mode & 0o777, 0o644)
                proc.terminate(); self.assertEqual(proc.wait(timeout=3), 0)
                self.assertEqual(json.loads((root / 'supervisor.json').read_text())['link'], 'absent')
            finally:
                if proc.poll() is None: proc.terminate(); proc.wait(timeout=3)
                os.close(master); os.close(slave)

    def test_open_failure_and_existing_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root / 'expected').write_text('1\n')
            binary = root / 'power-link'
            subprocess.run(['cc', *shlex.split(os.environ.get('POWER_LINK_TEST_CFLAGS', '')), str(HERE / 'power_link.c'), '-o', str(binary)], check=True)
            master, slave = pty.openpty()
            import fcntl
            import termios
            fcntl.ioctl(slave, termios.TIOCEXCL)
            proc = subprocess.Popen([str(binary), '--device', os.ttyname(slave),
                                     '--state-dir', tmp, '--persistent-dir', tmp])
            try:
                deadline = time.monotonic() + 3
                while not (root / 'supervisor.json').exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                state = json.loads((root / 'supervisor.json').read_text())
                self.assertEqual(state['link'], 'error')
                self.assertEqual(state['open_error'], 16)  # Linux EBUSY
                self.assertTrue(state['expected'])
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
                os.write(master, frame(0))
                state = wait_for(lambda s: s['link'] == 'ok')
                self.assertEqual(state['temperatures']['pack']['celsius'], 25)
                self.assertEqual(state['temperatures']['a']['celsius'], 22)
                self.assertIsNone(state['temperatures']['b']['celsius'])
                self.assertEqual(state['temperatures']['b']['quality'], 'uncal')
                self.assertTrue(state['expected'])
                self.assertEqual((root / 'supervisor.json').stat().st_mode & 0o777, 0o644)
                os.write(master, b'OSB1 truncated')
                wait_for(lambda s: s['stale'], timeout=7)
                self.assertEqual(select.select([master], [], [], 0)[0], [])
                os.kill(proc.pid, signal.SIGKILL)
                proc.wait(timeout=2)
                self.assertGreaterEqual(time.monotonic() * 1000 - state['rx_mono_ms'], 5000)
                self.assertTrue((root / 'expected').exists())
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    proc.wait(timeout=2)
                os.close(master)
                os.close(slave)


if __name__ == '__main__':
    unittest.main()

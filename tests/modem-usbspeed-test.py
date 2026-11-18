#!/usr/bin/env python3
"""ceralive-modem-usbspeed against a fake sysfs, a fake mmcli and a pty AT modem.

The script runs as a real subprocess with only its documented seams changed.
The fake modem answers on a pseudo-terminal the way an RM520N does (echo on,
`+QCFG: "usbspeed","312"` then OK), records every command it receives, and the
fake mmcli logs every call, so each test can assert exactly what was sent.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / 'mkosi/runtime/ceralive-modem-usbspeed.py'
PORT = '5-1.4'
DEVICE = f'/sys/devices/platform/usb5/{PORT}'
ALLOWED = {'AT+QCFG="usbspeed"', 'AT+QCFG="usbspeed","20"', 'AT+CFUN=1,1'}

FAKE_MMCLI = textwrap.dedent('''\
    #!/usr/bin/env python3
    import json, os, signal, sys, time
    state = json.load(open(os.environ['FAKE_MM_STATE']))
    with open(os.environ['FAKE_MM_LOG'], 'a') as log:
        log.write(' '.join(sys.argv[1:]) + '\\n')
    args = sys.argv[1:]
    modems = state.get('modems', [])
    if args == ['-L', '-K']:
        print(f'modem-list.length : {len(modems)}')
        for i, m in enumerate(modems, 1):
            print(f'modem-list.value[{i}] : {m["path"]}')
        sys.exit(0)
    if len(args) == 3 and args[0] == '-m' and args[2] == '-K':
        for m in modems:
            if m['path'] == args[1]:
                for key in ('device', 'model', 'revision', 'state', 'equipment-identifier'):
                    print(f'modem.generic.{key} : {m.get(key, "--")}')
                print(f'modem.generic.ports.length : {len(m["ports"])}')
                for i, p in enumerate(m['ports'], 1):
                    print(f'modem.generic.ports.value[{i}] : {p}')
                sys.exit(0)
        print('error: modem not found', file=sys.stderr); sys.exit(1)
    if len(args) == 1 and args[0].startswith('--inhibit-device='):
        if state.get('inhibit') == 'fail':
            print("error: couldn't inhibit device: 'busy'"); sys.exit(1)
        def release(*_):
            with open(os.environ['FAKE_MM_LOG'], 'a') as log:
                log.write('released\\n')
            sys.exit(0)
        signal.signal(signal.SIGINT, release)
        signal.signal(signal.SIGTERM, release)
        print("successfully inhibited device with uid '%s'" % args[0].split('=', 1)[1], flush=True)
        print('type Ctrl+C to abort this program and remove the inhibition', flush=True)
        while True:
            time.sleep(1)
    print('unexpected mmcli call', file=sys.stderr); sys.exit(64)
''')


class FakeModem(threading.Thread):
    """An RM520N AT port on the master side of a pty."""

    def __init__(self, stored='312', echo=True, read_error=False, ignore_write=False, cfun_silent=False):
        super().__init__(daemon=True)
        self.master, self.slave = os.openpty()
        self.path = os.ttyname(self.slave)
        self.stored, self.echo = stored, echo
        self.read_error, self.ignore_write, self.cfun_silent = read_error, ignore_write, cfun_silent
        self.commands, self.stop = [], threading.Event()

    def reply(self, text):
        os.write(self.master, text.encode())

    def run(self):
        import select
        buffer = b''
        while not self.stop.is_set():
            ready, _, _ = select.select([self.master], [], [], 0.05)
            if not ready:
                continue
            try:
                buffer += os.read(self.master, 1024)
            except OSError:
                time.sleep(0.01)
                continue
            while b'\r' in buffer:
                line, buffer = buffer.split(b'\r', 1)
                command = line.decode().strip()
                if not command:
                    continue
                self.commands.append(command)
                if self.echo:
                    self.reply(command + '\r\n')
                if command == 'AT+QCFG="usbspeed"':
                    if self.read_error:
                        self.reply('\r\n+CME ERROR: 50\r\n')
                    else:
                        self.reply(f'\r\n+QCFG: "usbspeed","{self.stored}"\r\n\r\nOK\r\n')
                elif command == 'AT+QCFG="usbspeed","20"':
                    if not self.ignore_write:
                        self.stored = '20'
                    self.reply('\r\nOK\r\n')
                elif command == 'AT+CFUN=1,1':
                    if not self.cfun_silent:
                        self.reply('\r\nOK\r\n')
                else:
                    self.reply('\r\nERROR\r\n')

    def close(self):
        self.stop.set()
        self.join(timeout=2)
        os.close(self.master)
        os.close(self.slave)


class UsbSpeed(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usbspeed-'))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.sys = self.tmp / 'sys'
        self.dev = self.tmp / 'dev'
        self.proc = self.tmp / 'proc'
        self.run_dir = self.tmp / 'run'
        self.data = self.tmp / 'data/ceralive'
        for d in (self.dev, self.proc, self.run_dir, self.data, self.sys / 'bus/usb/devices'):
            d.mkdir(parents=True)
        self.device = self.sys / DEVICE.lstrip('/').removeprefix('sys/')
        for iface in ('1.2', '1.3'):
            tty = 'ttyUSB2' if iface == '1.2' else 'ttyUSB3'
            (self.device / f'{PORT}:{iface}' / tty).mkdir(parents=True)
        (self.sys / 'bus/usb/devices' / PORT).symlink_to(self.device)
        self.usb('2c7c', '0801', 5000)
        self.modem = FakeModem()
        self.modem.start()
        self.addCleanup(self.modem.close)
        (self.dev / 'ttyUSB2').symlink_to(self.modem.path)
        (self.dev / 'ttyUSB3').symlink_to(self.modem.path)
        bin_dir = self.tmp / 'bin'
        bin_dir.mkdir()
        self.mmcli = bin_dir / 'mmcli'
        self.mmcli.write_text(FAKE_MMCLI)
        self.mmcli.chmod(0o755)
        self.mm_log = self.tmp / 'mmcli.log'
        self.mm_log.touch()
        self.state = self.tmp / 'mm.json'
        self.mm(model='RM520N-GL')

    def usb(self, vendor, product, speed):
        (self.device / 'idVendor').write_text(vendor + '\n')
        (self.device / 'idProduct').write_text(product + '\n')
        (self.device / 'speed').write_text(f'{speed}\n')

    def mm(self, listed=True, inhibit='ok', **fields):
        modem = {
            'path': '/org/freedesktop/ModemManager1/Modem/3', 'device': str(self.device),
            'model': 'RM520N-GL', 'revision': 'RM520NGLAAR03A03M4G', 'state': 'registered',
            'equipment-identifier': '490154203237518',
            'ports': ['cdc-wdm0 (qmi)', 'ttyUSB0 (qcdm)', 'ttyUSB1 (gps)', 'ttyUSB2 (at)', 'ttyUSB3 (at)', 'wwan0 (net)'],
        }
        modem.update(fields)
        self.state.write_text(json.dumps({'modems': [modem] if listed else [], 'inhibit': inhibit}))

    def process(self, name, holds=None):
        pid = self.proc / str(40000 + len(list(self.proc.iterdir())))
        (pid / 'fd').mkdir(parents=True)
        (pid / 'comm').write_text(name + '\n')
        if holds:
            (pid / 'fd' / '3').symlink_to(holds)

    def invoke(self, port=PORT):
        env = dict(os.environ,
                   CERALIVE_USBSPEED_SYSFS=str(self.sys), CERALIVE_USBSPEED_DEV=str(self.dev),
                   CERALIVE_USBSPEED_PROC=str(self.proc), CERALIVE_USBSPEED_RUN=str(self.run_dir),
                   CERALIVE_USBSPEED_DATA=str(self.data / 'modem-usbspeed'),
                   CERALIVE_USBSPEED_MMCLI=str(self.mmcli), CERALIVE_USBSPEED_MM_WAIT='0.5',
                   CERALIVE_USBSPEED_POLL='0.05', CERALIVE_USBSPEED_AT_TIMEOUT='1',
                   CERALIVE_USBSPEED_PORT_WAIT='0.5',
                   FAKE_MM_STATE=str(self.state), FAKE_MM_LOG=str(self.mm_log))
        done = subprocess.run([sys.executable, str(SCRIPT), port], env=env, capture_output=True,
                              text=True, timeout=30)
        time.sleep(0.05)
        return done

    def marker(self):
        path = self.run_dir / f'{PORT}.json'
        return json.loads(path.read_text()) if path.exists() else None

    def mm_calls(self):
        return self.mm_log.read_text().splitlines()

    def inhibits(self):
        return [c for c in self.mm_calls() if c.startswith('--inhibit-device=')]

    def assertUntouched(self, done):
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(self.modem.commands, [])
        self.assertEqual(self.inhibits(), [])

    # --- the main path ------------------------------------------------------

    def test_usb3_link_with_stored_312_is_set_to_20_and_reset_once(self):
        done = self.invoke()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(self.modem.commands,
                         ['AT+QCFG="usbspeed"', 'AT+QCFG="usbspeed","20"', 'AT+QCFG="usbspeed"', 'AT+CFUN=1,1'])
        self.assertEqual(self.modem.stored, '20')
        self.assertEqual(self.inhibits(), [f'--inhibit-device={self.device}'])
        self.assertEqual(self.mm_calls()[-1], 'released')
        marker = self.marker()
        self.assertEqual((marker['phase'], marker['original'], marker['speed_before']), ('reset-sent', '312', 5000))
        records = list((self.data / 'modem-usbspeed').glob('*.json'))
        self.assertEqual(len(records), 1)
        record = json.loads(records[0].read_text())
        self.assertEqual((record['original'], record['desired'], record['model']), ('312', '20', 'RM520N-GL'))
        self.assertNotIn('490154203237518', records[0].read_text() + records[0].name)
        self.assertIn('stored usbspeed "312" at 5000 Mbit/s', done.stdout)
        self.assertIn('AT+CFUN=1,1 answered OK', done.stdout)

    def test_reenumeration_at_480_is_verified_without_touching_the_modem(self):
        self.invoke()
        sent, calls = list(self.modem.commands), len(self.mm_calls())
        self.usb('2c7c', '0801', 480)
        done = self.invoke()
        self.assertEqual(self.modem.commands, sent)
        self.assertEqual(len(self.mm_calls()), calls)
        self.assertEqual(self.marker()['phase'], 'verified')
        self.assertIn('back at 480 Mbit/s', done.stdout)

    def test_still_fast_after_the_reset_is_reported_and_never_retried(self):
        self.invoke()
        sent = list(self.modem.commands)
        for _ in range(3):
            done = self.invoke()
        self.assertEqual(self.modem.commands, sent)
        self.assertEqual(len(self.inhibits()), 1)
        self.assertEqual(self.marker()['phase'], 'failed')
        self.assertIn('already handled this boot (failed)', done.stdout)

    def test_echo_off_replies_parse_the_same(self):
        self.modem.echo = False
        self.invoke()
        self.assertEqual(self.modem.stored, '20')
        self.assertEqual(self.marker()['phase'], 'reset-sent')

    def test_silent_cfun_still_counts_as_reset_sent(self):
        self.modem.cfun_silent = True
        done = self.invoke()
        self.assertEqual(self.marker()['phase'], 'reset-sent')
        self.assertIn('module may already be restarting', done.stdout)

    def test_stored_20_with_a_fast_link_is_reset_once_without_a_write(self):
        self.modem.stored = '20'
        self.invoke()
        self.assertEqual(self.modem.commands, ['AT+QCFG="usbspeed"', 'AT+CFUN=1,1'])
        self.assertEqual(self.marker()['phase'], 'reset-sent')

    def test_no_record_dir_still_acts_and_logs_the_original(self):
        shutil.rmtree(self.data)
        done = self.invoke()
        self.assertEqual(self.marker()['original'], '312')
        self.assertIn('original value only in the journal', done.stdout)

    # --- nothing is sent ----------------------------------------------------

    def test_usb2_link_does_nothing_at_all(self):
        for speed in (480, 12):
            self.usb('2c7c', '0801', speed)
            done = self.invoke()
            self.assertUntouched(done)
            self.assertEqual(self.mm_calls(), [])
            self.assertIsNone(self.marker())
            self.assertIn('already USB 2', done.stdout)

    def test_other_usb_ids_are_left_alone(self):
        for vendor, product in (('2c7c', '0800'), ('2c7c', '0125'), ('1199', '90d3')):
            self.usb(vendor, product, 5000)
            done = self.invoke()
            self.assertUntouched(done)
            self.assertEqual(self.mm_calls(), [])

    def test_rm530_sharing_the_id_is_left_alone(self):
        self.mm(model='RM530N-GL')
        done = self.invoke()
        self.assertUntouched(done)
        self.assertEqual(self.marker()['phase'], 'other-model')

    def test_a_running_stream_holds_it_back_without_a_marker(self):
        for name in ('srtla_send', 'ceracoder', 'belacoder'):
            shutil.rmtree(self.proc)
            self.proc.mkdir()
            self.process(name)
            done = self.invoke()
            self.assertUntouched(done)
            self.assertIsNone(self.marker())
            self.assertIn(f'a stream is running ({name})', done.stdout)

    def test_kill_switch(self):
        (self.data / 'modem-usbspeed.disabled').touch()
        done = self.invoke()
        self.assertUntouched(done)
        self.assertIsNone(self.marker())

    def test_modem_modemmanager_never_lists_is_given_up_once(self):
        self.mm(listed=False)
        done = self.invoke()
        self.assertUntouched(done)
        self.assertEqual(self.marker()['phase'], 'no-modemmanager')

    def test_failed_inhibit_sends_nothing(self):
        self.mm(inhibit='fail')
        done = self.invoke()
        self.assertEqual(self.modem.commands, [])
        marker = self.marker()
        self.assertEqual(marker['phase'], 'inhibit-failed')
        self.assertIn("couldn't inhibit", marker['reason'])

    def test_port_held_by_another_process_is_not_opened(self):
        self.process('picocom', holds=self.modem.path)
        self.invoke()
        self.assertEqual(self.modem.commands, [])
        self.assertEqual(self.marker()['phase'], 'port-busy')
        self.assertEqual(self.mm_calls()[-1], 'released')

    def test_at_port_must_belong_to_this_device(self):
        self.mm(ports=['cdc-wdm0 (qmi)', 'ttyUSB9 (at)'])
        done = self.invoke()
        self.assertUntouched(done)
        self.assertEqual(self.marker()['phase'], 'no-at-port')

    def test_ignored_port_is_not_used(self):
        self.mm(ports=['ttyUSB2 (ignored)', 'ttyUSB3 (ignored)'])
        done = self.invoke()
        self.assertUntouched(done)
        self.assertEqual(self.marker()['phase'], 'no-at-port')

    def test_read_error_writes_nothing(self):
        self.modem.read_error = True
        self.invoke()
        self.assertEqual(self.modem.commands, ['AT+QCFG="usbspeed"'])
        self.assertEqual(self.marker()['phase'], 'read-failed')
        self.assertEqual(self.mm_calls()[-1], 'released')

    def test_readback_mismatch_stops_before_the_reset(self):
        self.modem.ignore_write = True
        self.invoke()
        self.assertNotIn('AT+CFUN=1,1', self.modem.commands)
        self.assertEqual(self.marker()['phase'], 'write-failed')

    def test_existing_marker_means_once_per_boot(self):
        self.run_dir.mkdir(exist_ok=True)
        (self.run_dir / f'{PORT}.json').write_text(json.dumps({'phase': 'attempting'}))
        done = self.invoke()
        self.assertUntouched(done)
        self.assertIn('already handled this boot', done.stdout)

    def test_unreadable_process_list_counts_as_streaming(self):
        shutil.rmtree(self.proc)
        done = self.invoke()
        self.assertUntouched(done)
        self.assertIn('unreadable process list', done.stdout)

    def test_bad_argument_is_refused(self):
        for arg in ('../5-1', '5-1:1.2', ''):
            done = self.invoke(port=arg)
            self.assertEqual(done.returncode, 2)
        self.assertEqual(self.mm_calls(), [])

    def test_only_allowlisted_commands_ever_reach_the_modem(self):
        self.invoke()
        self.assertTrue(set(self.modem.commands) <= ALLOWED, self.modem.commands)


if __name__ == '__main__':
    unittest.main(verbosity=2)

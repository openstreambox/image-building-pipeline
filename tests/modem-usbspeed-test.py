#!/usr/bin/env python3
"""ceralive-modem-usbspeed against a fake sysfs, a fake mmcli and a pty AT modem.

The script runs as a real subprocess with only its documented seams changed.
The fake modem answers on a pseudo-terminal the way an RM520N does (echo on,
`+QCFG: "usbspeed","312"` then OK), records every command it receives, and on
AT+CFUN=1,1 makes the USB device leave and come back the way the hardware
does: by default the SuperSpeed device 4-1 returns as 1-1 on the High Speed
bus, found through the port's peer link. The fake mmcli logs every call.
"""
import hashlib
import hmac
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
PORT = '4-1'
IMEI = '490154203237518'
MACHINE_ID = '0123456789abcdef0123456789abcdef'
ALLOWED = {'AT+QCFG="usbspeed"', 'AT+QCFG="usbspeed","20"', 'AT+CFUN=1,1'}

FAKE_MMCLI = textwrap.dedent('''\
    #!/usr/bin/env python3
    import json, os, signal, sys, time
    from pathlib import Path
    state = json.load(open(os.environ['FAKE_MM_STATE']))
    with open(os.environ['FAKE_MM_LOG'], 'a') as log:
        log.write(' '.join(sys.argv[1:]) + '\\n')
    args = sys.argv[1:]
    modems = state.get('modems', [])
    if args == ['-L', '-K']:
        if state.get('hang'):
            time.sleep(30)
        for path in state.get('on_list_touch', []):
            Path(path).parent.mkdir(parents=True, exist_ok=True)
            Path(path).write_text(state.get('touch_text', '') + '\\n')
        print(f'modem-list.length : {len(modems)}')
        for i, m in enumerate(modems, 1):
            print(f'modem-list.value[{i}] : {m["path"]}')
        sys.exit(0)
    if len(args) == 3 and args[0] == '-m' and args[2] == '-K':
        for m in modems:
            if m['path'] == args[1]:
                for key in ('device', 'physdev', 'model', 'revision', 'state', 'equipment-identifier'):
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

    def __init__(self):
        super().__init__(daemon=True)
        self.master, self.slave = os.openpty()
        self.path = os.ttyname(self.slave)
        self.stored, self.echo = '312', True
        self.read_error = self.ignore_write = self.cfun_silent = False
        self.cfun_reply = 'OK'
        self.hooks = {}          # command -> callable run after the reply
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
                        self.reply(f'\r\n{self.cfun_reply}\r\n')
                else:
                    self.reply('\r\nERROR\r\n')
                hook = self.hooks.get(command)
                if hook:
                    hook()

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
        self.machine_id = self.tmp / 'machine-id'
        self.machine_id.write_text(MACHINE_ID + '\n')
        # One physical socket: SuperSpeed root port usb4-port1, High Speed peer usb1-port1.
        xhci = self.sys / 'devices/platform/fc000000.usb/xhci-hcd.0.auto'
        self.ss_port = xhci / 'usb4/4-0:1.0/usb4-port1'
        self.hs_port = xhci / 'usb1/1-0:1.0/usb1-port1'
        self.ss_port.mkdir(parents=True)
        self.hs_port.mkdir(parents=True)
        (self.ss_port / 'peer').symlink_to(self.hs_port)
        (self.hs_port / 'peer').symlink_to(self.ss_port)
        self.device = self.add_device(PORT, xhci / 'usb4' / PORT, 5000, self.ss_port)
        self.modem = FakeModem()
        self.modem.start()
        self.addCleanup(self.modem.close)
        (self.dev / 'ttyUSB2').symlink_to(self.modem.path)
        (self.dev / 'ttyUSB3').symlink_to(self.modem.path)
        self.modem.hooks['AT+CFUN=1,1'] = lambda: self.reenumerate('1-1', 480, self.hs_port)
        bin_dir = self.tmp / 'bin'
        bin_dir.mkdir()
        self.mmcli = bin_dir / 'mmcli'
        self.mmcli.write_text(FAKE_MMCLI)
        self.mmcli.chmod(0o755)
        self.mm_log = self.tmp / 'mmcli.log'
        self.mm_log.touch()
        self.state = self.tmp / 'mm.json'
        self.mm()

    # --- fixture helpers ------------------------------------------------------

    def add_device(self, name, directory, speed, port=None, vendor='2c7c', product='0801'):
        for iface, tty in (('1.2', 'ttyUSB2'), ('1.3', 'ttyUSB3')):
            (directory / f'{name}:{iface}' / tty).mkdir(parents=True, exist_ok=True)
        (directory / 'idVendor').write_text(vendor + '\n')
        (directory / 'idProduct').write_text(product + '\n')
        (directory / 'speed').write_text(f'{speed}\n')
        if port is not None:
            (directory / 'port').symlink_to(port)
        (self.sys / 'bus/usb/devices' / name).symlink_to(directory)
        return directory

    def remove_device(self, name):
        link = self.sys / 'bus/usb/devices' / name
        target = link.resolve()
        link.unlink()
        shutil.rmtree(target)

    def reenumerate(self, name, speed, port, leave_after=0.2, back_after=0.4):
        """What AT+CFUN=1,1 does to the USB side, on a timer like the hardware."""
        def later():
            time.sleep(leave_after)
            self.remove_device(PORT)
            if name is None:
                return
            time.sleep(back_after)
            bus = 'usb1' if port == self.hs_port else 'usb4'
            directory = self.device.parent.parent / bus / name if port is not None else self.sys / 'devices/platform/ehci' / name
            self.add_device(name, directory, speed, port)
        threading.Thread(target=later, daemon=True).start()

    def usb(self, speed, vendor='2c7c', product='0801'):
        (self.device / 'idVendor').write_text(vendor + '\n')
        (self.device / 'idProduct').write_text(product + '\n')
        (self.device / 'speed').write_text(f'{speed}\n')

    def mm(self, listed=True, inhibit='ok', extra=None, **fields):
        modem = {
            'path': '/org/freedesktop/ModemManager1/Modem/3', 'device': str(self.device),
            'physdev': str(self.device),
            'model': 'RM520N-GL', 'revision': 'RM520NGLAAR03A03M4G', 'state': 'registered',
            'equipment-identifier': IMEI,
            'ports': ['cdc-wdm0 (qmi)', 'ttyUSB0 (qcdm)', 'ttyUSB1 (gps)', 'ttyUSB2 (at)', 'ttyUSB3 (at)', 'wwan0 (net)'],
        }
        modem.update(fields)
        state = {'modems': [modem] if listed else [], 'inhibit': inhibit}
        state.update(extra or {})
        self.state.write_text(json.dumps(state))

    def process(self, name, holds=None, pid=None):
        pid = self.proc / str(pid or 40000 + len(list(self.proc.iterdir())))
        (pid / 'fd').mkdir(parents=True)
        (pid / 'comm').write_text(name + '\n')
        if holds:
            (pid / 'fd' / '3').symlink_to(holds)

    def stream_starts(self):
        self.process('srtla_send')

    def invoke(self, port=PORT, **env_extra):
        env = dict(os.environ,
                   CERALIVE_USBSPEED_SYSFS=str(self.sys), CERALIVE_USBSPEED_DEV=str(self.dev),
                   CERALIVE_USBSPEED_PROC=str(self.proc), CERALIVE_USBSPEED_RUN=str(self.run_dir),
                   CERALIVE_USBSPEED_DATA=str(self.data / 'modem-usbspeed'),
                   CERALIVE_USBSPEED_MACHINE_ID=str(self.machine_id),
                   CERALIVE_USBSPEED_MMCLI=str(self.mmcli), CERALIVE_USBSPEED_MM_WAIT='0.5',
                   CERALIVE_USBSPEED_POLL='0.05', CERALIVE_USBSPEED_AT_TIMEOUT='1',
                   CERALIVE_USBSPEED_PORT_WAIT='0.5', CERALIVE_USBSPEED_LEAVE_WAIT='2',
                   CERALIVE_USBSPEED_RETURN_WAIT='2',
                   FAKE_MM_STATE=str(self.state), FAKE_MM_LOG=str(self.mm_log))
        env.update(env_extra)
        done = subprocess.run([sys.executable, str(SCRIPT), port], env=env, capture_output=True,
                              text=True, timeout=60)
        time.sleep(0.05)
        return done

    def new_boot(self):
        shutil.rmtree(self.run_dir)
        self.run_dir.mkdir()
        self.modem.commands.clear()
        self.mm_log.write_text('')

    def marker(self, port=PORT):
        path = self.run_dir / f'{port}.json'
        return json.loads(path.read_text()) if path.exists() else None

    def unit(self):
        return hmac.new(MACHINE_ID.encode(), IMEI.encode(), hashlib.sha256).hexdigest()[:16]

    def record(self):
        path = self.data / 'modem-usbspeed' / f'{self.unit()}.json'
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

    def test_usb3_link_is_set_to_20_reset_and_verified_on_the_high_speed_bus(self):
        done = self.invoke()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(self.modem.commands,
                         ['AT+QCFG="usbspeed"', 'AT+QCFG="usbspeed","20"', 'AT+QCFG="usbspeed"', 'AT+CFUN=1,1'])
        self.assertEqual(self.modem.stored, '20')
        self.assertEqual(self.inhibits(), [f'--inhibit-device={self.device}'])
        self.assertEqual(self.mm_calls()[-1], 'released')
        marker = self.marker()
        self.assertEqual((marker['phase'], marker['original'], marker['speed_before']), ('verified', '312', 5000))
        self.assertEqual((marker['returned_as'], marker['speed']), ('1-1', 480))
        record = self.record()
        self.assertEqual((record['original'], record['desired'], record['status']), ('312', '20', 'verified'))
        self.assertIn('stored usbspeed "312" at 5000 Mbit/s', done.stdout)
        self.assertIn('back as 1-1 at 480 Mbit/s', done.stdout)

    def test_the_returned_device_instance_does_nothing(self):
        self.invoke()
        sent, calls = list(self.modem.commands), len(self.mm_calls())
        done = self.invoke(port='1-1')
        self.assertEqual(self.modem.commands, sent)
        self.assertEqual(len(self.mm_calls()), calls)
        self.assertEqual(self.marker()['phase'], 'verified')
        self.assertIsNone(self.marker('1-1'))
        self.assertIn('already USB 2', done.stdout)

    def test_return_on_a_bus_without_peer_link_is_matched_as_the_only_new_modem(self):
        self.modem.hooks['AT+CFUN=1,1'] = lambda: self.reenumerate('5-1', 480, None)
        self.invoke()
        marker = self.marker()
        self.assertEqual((marker['phase'], marker['returned_as']), ('verified', '5-1'))

    def test_record_name_is_keyed_by_machine_id_not_a_plain_imei_hash(self):
        self.invoke()
        names = [p.name for p in (self.data / 'modem-usbspeed').glob('*.json')]
        self.assertEqual(names, [f'{self.unit()}.json'])
        self.assertNotEqual(self.unit(), hashlib.sha256(IMEI.encode()).hexdigest()[:16])
        stored = (self.data / 'modem-usbspeed' / names[0]).read_text() + json.dumps(self.marker())
        self.assertNotIn(IMEI, stored)

    def test_no_machine_id_means_no_unit_record(self):
        self.machine_id.unlink()
        done = self.invoke()
        self.assertEqual(self.marker()['phase'], 'verified')
        self.assertEqual(list((self.data).glob('modem-usbspeed/*.json')), [])
        self.assertEqual(done.returncode, 0)

    def test_still_fast_after_the_reset_fails_once_and_is_left_alone_on_later_boots(self):
        self.modem.hooks['AT+CFUN=1,1'] = lambda: self.reenumerate(PORT, 5000, self.ss_port)
        done = self.invoke()
        self.assertEqual(self.marker()['phase'], 'failed')
        self.assertEqual(self.record()['status'], 'failed')
        self.assertIn('recorded as failed', done.stdout)
        self.new_boot()
        done = self.invoke()
        self.assertUntouched(done)
        self.assertEqual(self.marker()['phase'], 'gave-up')
        self.assertIn('earlier attempt on this unit ended "failed"', done.stdout)

    def test_module_that_never_leaves_is_reported(self):
        self.modem.hooks.pop('AT+CFUN=1,1')
        self.invoke()
        self.assertEqual(self.marker()['phase'], 'not-reset')
        self.assertEqual(self.record()['status'], 'not-reset')

    def test_module_that_never_comes_back_is_reported_and_given_up(self):
        self.modem.hooks['AT+CFUN=1,1'] = lambda: self.reenumerate(None, None, None)
        done = self.invoke()
        self.assertEqual(self.marker()['phase'], 'not-back')
        self.assertIn('<3>', done.stdout)
        self.new_boot()
        self.device = self.add_device(PORT, self.device, 5000, self.ss_port)
        self.mm()
        self.assertUntouched(self.invoke())

    def test_cfun_error_is_not_reported_as_a_restart(self):
        self.modem.cfun_reply = 'ERROR'
        self.modem.hooks.pop('AT+CFUN=1,1')
        done = self.invoke()
        self.assertEqual(self.marker()['phase'], 'reset-refused')
        self.assertNotIn('watching for it to come back', done.stdout)

    def test_silent_cfun_still_counts_as_sent(self):
        self.modem.cfun_silent = True
        done = self.invoke()
        self.assertEqual(self.marker()['phase'], 'verified')
        self.assertIn('module may already be restarting', done.stdout)

    def test_echo_off_replies_parse_the_same(self):
        self.modem.echo = False
        self.invoke()
        self.assertEqual(self.modem.stored, '20')
        self.assertEqual(self.marker()['phase'], 'verified')

    def test_stored_20_with_a_fast_link_is_reset_once_without_a_write(self):
        self.modem.stored = '20'
        self.invoke()
        self.assertEqual(self.modem.commands, ['AT+QCFG="usbspeed"', 'AT+CFUN=1,1'])
        self.assertEqual(self.marker()['phase'], 'verified')

    def test_no_record_dir_still_acts_and_logs(self):
        shutil.rmtree(self.data)
        done = self.invoke()
        self.assertEqual(self.marker()['original'], '312')
        self.assertIn('only in the journal', done.stdout)

    def test_slot_name_uid_is_matched_by_physdev_and_used_for_the_hold(self):
        self.mm(device='internal_4g')
        self.invoke()
        self.assertEqual(self.inhibits(), ['--inhibit-device=internal_4g'])
        self.assertEqual(self.marker()['phase'], 'verified')

    def test_secondary_at_port_alone_is_used_under_the_hold(self):
        self.mm(ports=['cdc-wdm0 (qmi)', 'ttyUSB3 (at)'])
        self.invoke()
        self.assertEqual(self.modem.stored, '20')

    # --- two RM520Ns reset at the same time ----------------------------------

    def other_socket(self):
        """Socket B: SS root port usb8-port1 with HS peer usb7-port1."""
        xhci = self.device.parent.parent
        ss, hs = xhci / 'usb8/8-0:1.0/usb8-port1', xhci / 'usb7/7-0:1.0/usb7-port1'
        ss.mkdir(parents=True)
        hs.mkdir(parents=True)
        (ss / 'peer').symlink_to(hs)
        (hs / 'peer').symlink_to(ss)
        return ss, hs

    def pending_b(self, ss, hs, **extra):
        marker = dict({'phase': 'reset-sent', 'pid': 99999, 'port_paths': [str(ss), str(hs)]}, **extra)
        (self.run_dir / '8-1.json').write_text(json.dumps(marker))

    def two_returns(self, first, second):
        """A leaves; `first` then `second` appear: (name, directory, speed, port)."""
        def later():
            time.sleep(0.2)
            self.remove_device(PORT)
            for name, directory, speed, port in (first, second):
                time.sleep(0.4)
                self.add_device(name, directory, speed, port)
        threading.Thread(target=later, daemon=True).start()

    def test_another_modems_return_is_never_credited_to_this_one(self):
        ss, hs = self.other_socket()
        self.pending_b(ss, hs)
        xhci = self.device.parent.parent
        self.modem.hooks['AT+CFUN=1,1'] = lambda: self.two_returns(
            ('7-1', xhci / 'usb7/7-1', 480, hs), (PORT, self.device, 5000, self.ss_port))
        done = self.invoke(CERALIVE_USBSPEED_RETURN_WAIT='4')
        marker = self.marker()
        self.assertEqual((marker['phase'], marker['returned_as'], marker['speed']), ('failed', PORT, 5000))
        self.assertNotIn('back as 7-1', done.stdout)

    def test_unclaimed_return_while_another_reset_is_pending_is_unattributed_not_failed(self):
        ss, hs = self.other_socket()
        self.pending_b(ss, hs)
        self.modem.hooks['AT+CFUN=1,1'] = lambda: self.reenumerate('5-1', 480, None)
        done = self.invoke()
        self.assertEqual(self.marker()['phase'], 'unattributed')
        self.assertEqual(self.record()['status'], 'unattributed')
        self.assertIn('not counted as a failure', done.stdout)
        self.new_boot()
        (self.sys / 'bus/usb/devices/5-1').unlink()
        self.device = self.add_device(PORT, self.device, 5000, self.ss_port)
        self.mm()
        self.modem.hooks['AT+CFUN=1,1'] = lambda: self.reenumerate('1-1', 480, self.hs_port)
        self.invoke()
        self.assertEqual(self.marker()['phase'], 'verified')

    def test_unclaimed_return_is_attributed_once_the_other_reset_is_judged(self):
        ss, hs = self.other_socket()
        self.pending_b(ss, hs)
        def b_judged():
            time.sleep(1.0)
            self.pending_b(ss, hs, phase='verified', returned_as='7-1')
        def cfun():
            self.reenumerate('5-1', 480, None)
            threading.Thread(target=b_judged, daemon=True).start()
        self.modem.hooks['AT+CFUN=1,1'] = cfun
        self.invoke(CERALIVE_USBSPEED_RETURN_WAIT='4')
        marker = self.marker()
        self.assertEqual((marker['phase'], marker['returned_as']), ('verified', '5-1'))

    def test_newcomer_another_run_already_named_is_skipped(self):
        (self.run_dir / '9-1.json').write_text(json.dumps({'phase': 'verified', 'returned_as': '5-1'}))
        self.modem.hooks['AT+CFUN=1,1'] = lambda: self.reenumerate('5-1', 480, None)
        self.invoke()
        self.assertEqual(self.marker()['phase'], 'not-back')

    def test_retry_file_clears_a_give_up_and_keeps_the_original(self):
        self.modem.hooks['AT+CFUN=1,1'] = lambda: self.reenumerate(PORT, 5000, self.ss_port)
        self.invoke()
        self.assertEqual(self.record()['status'], 'failed')
        self.new_boot()
        self.assertUntouched(self.invoke())
        self.assertEqual(self.marker()['phase'], 'gave-up')
        self.new_boot()
        (self.data / 'modem-usbspeed.retry').touch()
        self.modem.hooks['AT+CFUN=1,1'] = lambda: self.reenumerate('1-1', 480, self.hs_port)
        done = self.invoke()
        self.assertIn('original values kept', done.stdout)
        self.assertFalse((self.data / 'modem-usbspeed.retry').exists())
        self.assertEqual(self.marker()['phase'], 'verified')
        record = self.record()
        self.assertEqual((record['original'], record['status']), ('312', 'verified'))

    # --- the once-per-boot rules ------------------------------------------

    def test_same_name_fallback_judges_a_pending_reset(self):
        (self.run_dir / f'{PORT}.json').write_text(json.dumps({'phase': 'reset-sent', 'original': '312'}))
        for _ in range(3):
            done = self.invoke()
        self.assertUntouched(done)
        self.assertEqual(self.marker()['phase'], 'failed')

    def test_usb2_appearance_adopts_a_pending_reset_whose_run_is_gone(self):
        self.add_device('1-1', self.device.parent.parent / 'usb1/1-1', 480, self.hs_port)
        pending = {'phase': 'reset-sent', 'original': '312', 'pid': 99999,
                   'port_paths': [str(self.ss_port), str(self.hs_port)]}
        (self.run_dir / f'{PORT}.json').write_text(json.dumps(pending))
        done = self.invoke(port='1-1')
        self.assertUntouched(done)
        self.assertEqual((self.marker()['phase'], self.marker()['returned_as']), ('verified', '1-1'))

    def test_usb2_appearance_leaves_a_live_run_to_judge_itself(self):
        self.add_device('1-1', self.device.parent.parent / 'usb1/1-1', 480, self.hs_port)
        self.process('python3', pid=4242)
        pending = {'phase': 'reset-sent', 'pid': 4242, 'port_paths': [str(self.ss_port), str(self.hs_port)]}
        (self.run_dir / f'{PORT}.json').write_text(json.dumps(pending))
        self.invoke(port='1-1')
        self.assertEqual(self.marker()['phase'], 'reset-sent')

    def test_existing_marker_means_once_per_port(self):
        (self.run_dir / f'{PORT}.json').write_text(json.dumps({'phase': 'attempting'}))
        done = self.invoke()
        self.assertUntouched(done)
        self.assertIn('already handled this boot', done.stdout)

    def test_unit_handled_on_another_port_this_boot_is_left_alone(self):
        (self.run_dir / '9-1.json').write_text(json.dumps({'phase': 'verified', 'unit': self.unit()}))
        done = self.invoke()
        self.assertUntouched(done)
        self.assertEqual(self.marker()['phase'], 'unit-handled')

    # --- nothing is sent ----------------------------------------------------

    def test_usb2_link_does_nothing_at_all(self):
        for speed in (480, 12):
            self.usb(speed)
            done = self.invoke()
            self.assertUntouched(done)
            self.assertEqual(self.mm_calls(), [])
            self.assertIsNone(self.marker())
            self.assertIn('already USB 2', done.stdout)

    def test_other_usb_ids_are_left_alone(self):
        for vendor, product in (('2c7c', '0800'), ('2c7c', '0125'), ('1199', '90d3')):
            self.usb(5000, vendor, product)
            done = self.invoke()
            self.assertUntouched(done)
            self.assertEqual(self.mm_calls(), [])

    def test_rm530_sharing_the_id_is_left_alone(self):
        self.mm(model='RM530N-GL')
        done = self.invoke()
        self.assertUntouched(done)
        self.assertEqual(self.marker()['phase'], 'other-model')

    def test_a_running_stream_holds_it_back_without_a_marker(self):
        self.stream_starts()
        done = self.invoke()
        self.assertUntouched(done)
        self.assertIsNone(self.marker())
        self.assertIn('a stream is running (srtla_send)', done.stdout)

    def test_retired_engine_names_are_not_stream_signals(self):
        for name in ('ceracoder', 'belacoder', 'cerastream'):
            self.process(name)
        self.invoke()
        self.assertEqual(self.marker()['phase'], 'verified')

    def test_stream_starting_during_the_modemmanager_wait_prevents_the_hold(self):
        self.mm(extra={'on_list_touch': [str(self.proc / '41000/comm')], 'touch_text': 'srtla_send'})
        done = self.invoke()
        self.assertUntouched(done)
        self.assertIsNone(self.marker())
        self.assertIn('not asking ModemManager', done.stdout)

    def test_kill_switch_appearing_during_the_wait_prevents_the_hold(self):
        self.mm(extra={'on_list_touch': [str(self.data / 'modem-usbspeed.disabled')]})
        self.assertUntouched(self.invoke())

    def test_stream_starting_after_the_read_stops_before_the_write(self):
        self.modem.hooks['AT+QCFG="usbspeed"'] = self.stream_starts
        done = self.invoke()
        self.assertEqual(self.modem.commands, ['AT+QCFG="usbspeed"'])
        self.assertEqual(self.modem.stored, '312')
        self.assertEqual(self.mm_calls()[-1], 'released')
        self.assertIsNone(self.marker())
        self.assertIn('nothing written, released', done.stdout)

    def test_stream_starting_after_the_write_stops_before_the_reset(self):
        self.modem.hooks['AT+QCFG="usbspeed","20"'] = self.stream_starts
        self.invoke()
        self.assertNotIn('AT+CFUN=1,1', self.modem.commands)
        self.assertEqual(self.modem.stored, '20')
        self.assertEqual(self.marker()['phase'], 'stored-no-reset')
        self.assertEqual(self.mm_calls()[-1], 'released')

    def test_kill_switch(self):
        (self.data / 'modem-usbspeed.disabled').touch()
        done = self.invoke()
        self.assertUntouched(done)
        self.assertIsNone(self.marker())

    def test_modemmanager_never_listing_it_is_given_up_once(self):
        self.mm(listed=False)
        done = self.invoke()
        self.assertUntouched(done)
        self.assertEqual(self.marker()['phase'], 'no-modemmanager')

    def test_a_hanging_mmcli_is_bounded_by_the_run_budget(self):
        self.mm(extra={'hang': True})
        started = time.monotonic()
        done = self.invoke(CERALIVE_USBSPEED_BUDGET='3', CERALIVE_USBSPEED_MM_WAIT='90')
        self.assertLess(time.monotonic() - started, 10)
        self.assertUntouched(done)
        self.assertEqual(self.marker()['phase'], 'no-modemmanager')

    def test_failed_inhibit_sends_nothing(self):
        self.mm(inhibit='fail')
        self.invoke()
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


class AtPortWrite(unittest.TestCase):
    """The AT write never raises and never blocks past its deadline."""

    def setUp(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('usbspeed', SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.master, slave = os.openpty()
        self.path = os.ttyname(slave)
        os.close(slave)
        self.port = self.module.AtPort(self.path)
        self.addCleanup(self.port.close)

    def test_hung_up_port_is_no_reply(self):
        os.close(self.master)
        self.assertEqual(self.port.command('AT+QCFG="usbspeed"', timeout=0.5), (None, []))

    def test_full_output_buffer_is_bounded(self):
        self.addCleanup(os.close, self.master)
        import errno as e
        try:
            while True:
                os.write(self.port.fd, b'x' * 4096)
        except OSError as error:
            self.assertEqual(error.errno, e.EAGAIN)
        started = time.monotonic()
        self.assertEqual(self.port.command('AT+QCFG="usbspeed"', timeout=0.5), (None, []))
        self.assertLess(time.monotonic() - started, 2)


if __name__ == '__main__':
    unittest.main(verbosity=2)

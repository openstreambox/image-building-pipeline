#!/usr/bin/env python3
"""ceralive-modem-carrierlock against a fake sysfs, a fake mmcli and a pty FM350.

The script runs as a real subprocess with only its documented seams changed.
The fake FM350 replays the answers recorded on two FM350-GL units (firmware
81600.0000.00.29.18.01, 23-24 Nov 2026): `+GTLOCKCAR: 1,203`, the
HTML-escaped `+GTCURCAR: 201,"AT&amp;T"`, unsolicited `+EDSBP`/`+CIEV` lines
inside answers, the one-parameter `AT+GTLOCKCAR=0` accepted only with the
radio off, and every two-parameter unlock form refused. It records every
command it receives. The fake mmcli logs every call.
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
SCRIPT = ROOT / 'mkosi/runtime/ceralive-modem-carrierlock.py'
PORT = '10-1.4'
IMEI = '490154203237518'
TMO_IMSI = '310240123456789'
ATT_IMSI = '310410123456789'
VZW_IMSI = '311480123456789'
MACHINE_ID = '0123456789abcdef0123456789abcdef'
ALLOWED = {'AT+CIMI', 'AT+GTLOCKCAR?', 'AT+GTCURCAR?', 'AT+CFUN?', 'AT+CFUN=4', 'AT+CFUN=1',
           'AT+GTLOCKCAR=0'}
READS = ['AT+CIMI', 'AT+GTLOCKCAR?', 'AT+GTCURCAR?']
UNLOCK = READS + ['AT+CFUN?', 'AT+CFUN=4', 'AT+CFUN?', 'AT+GTLOCKCAR=0', 'AT+GTLOCKCAR?',
                  'AT+GTCURCAR?', 'AT+CFUN=1']
PROFILES = {'1': 'Generic', '101': 'Verizon', '201': 'AT&amp;T', '203': 'T-Mobile'}
SIM_PROFILE = {'310240': '203', '310260': '203', '310410': '201', '310280': '201', '311480': '101'}

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
                for key in ('device', 'physdev', 'model', 'revision', 'state', 'equipment-identifier', 'sim'):
                    print(f'modem.generic.{key} : {m.get(key, "--")}')
                print(f'modem.generic.ports.length : {len(m["ports"])}')
                for i, p in enumerate(m['ports'], 1):
                    print(f'modem.generic.ports.value[{i}] : {p}')
                sys.exit(0)
        print('error: modem not found', file=sys.stderr); sys.exit(1)
    if len(args) == 3 and args[0] == '-i' and args[2] == '-K':
        for m in modems:
            if m.get('sim') == args[1]:
                print(f'sim.dbus-path : {args[1]}')
                print(f'sim.properties.imsi : {m.get("imsi", "--")}')
                sys.exit(0)
        print('error: SIM not found', file=sys.stderr); sys.exit(1)
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
            time.sleep(0.05)
            if state.get('drop_hold') and Path(state['drop_hold']).exists():
                with open(os.environ['FAKE_MM_LOG'], 'a') as log:
                    log.write('hold-ended\\n')
                sys.exit(0)
    print('unexpected mmcli call', file=sys.stderr); sys.exit(64)
''')


class FakeFm350(threading.Thread):
    """An FM350-GL AT port (interface 6) on the master side of a pty."""

    def __init__(self):
        super().__init__(daemon=True)
        self.master, self.slave = os.openpty()
        self.path = os.ttyname(self.slave)
        self.lock = ('1', '203')
        self.profile = '203'
        self.radio = '1'
        self.imsi = TMO_IMSI
        self.echo = True
        self.unsolicited = False   # +CIEV/+CTZV/+EDSBP lines inside answers, as recorded
        self.ignore_unlock = False  # answers OK but the lock stays
        self.unlock_reply = None    # forced final answer to AT+GTLOCKCAR=0
        self.radio_off_reply = None
        self.radio_on_reply = None
        self.read_error = None      # command whose answer is ERROR
        self.silent = set()         # commands that get no answer at all
        self.no_final = set()       # commands answered without the final OK (as recorded once)
        self.hooks = {}             # command -> callable run after the reply
        self.before = {}            # command -> callable run before the reply
        self.commands, self.stop = [], threading.Event()

    def reply(self, text):
        os.write(self.master, text.encode())

    def noise(self):
        if self.unsolicited:
            self.reply('\r\n+CTZV: -20,0\r\n\r\n+CIEV: 10,"310410","AT&T","AT&T", 0, 0\r\n')

    def answer(self, command):
        if command == self.read_error:
            return '\r\nERROR\r\n'
        if command == 'AT+CIMI':
            return f'\r\n{self.imsi}\r\n\r\nOK\r\n'
        if command == 'AT+GTLOCKCAR?':
            edsbp = '\r\n+EDSBP: 8,1,310,240,-1\r\n' if self.unsolicited else ''
            return f'{edsbp}\r\n+GTLOCKCAR: {self.lock[0]},{self.lock[1]}\r\n\r\nOK\r\n'
        if command == 'AT+GTCURCAR?':
            return f'\r\n+GTCURCAR: {self.profile},"{PROFILES.get(self.profile, "?")}"\r\n\r\nOK\r\n'
        if command == 'AT+CFUN?':
            return f'\r\n+CFUN: {self.radio}\r\n\r\nOK\r\n'
        if command == 'AT+CFUN=4':
            if self.radio_off_reply:
                return f'\r\n{self.radio_off_reply}\r\n'
            self.radio = '4'
            return '\r\n+CIREPI: 0,0\r\n\r\nOK\r\n'
        if command == 'AT+CFUN=1':
            if self.radio_on_reply:
                return f'\r\n{self.radio_on_reply}\r\n'
            self.radio = '1'
            return '\r\nOK\r\n'
        if command == 'AT+GTLOCKCAR=0':
            if self.unlock_reply:
                return f'\r\n{self.unlock_reply}\r\n'
            if self.radio != '4':
                return '\r\nERROR\r\n'          # measured: refused with the radio on
            if not self.ignore_unlock:
                self.lock = ('0', '65535')
                self.profile = SIM_PROFILE.get(self.imsi[:6], '1')
            return '\r\nOK\r\n'
        if command.startswith('AT+GTLOCKCAR=0,'):
            return '\r\n+CME ERROR: 0\r\n'
        if command.startswith('AT+GTLOCKCAR=1,'):
            mode, ident = command.split('=', 1)[1].split(',')
            if (mode, ident) == self.lock:
                return '\r\nERROR\r\n'          # a same-value write is refused
            self.lock, self.profile = (mode, ident), ident
            return '\r\nOK\r\n'
        return '\r\nERROR\r\n'

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
                early = self.before.get(command)
                if early:
                    early()
                if self.echo:
                    self.reply(command + '\r\n')
                if command not in self.silent:
                    self.noise()
                    answer = self.answer(command)
                    if command in self.no_final:
                        answer = answer.replace('\r\nOK\r\n', '')
                    self.reply(answer)
                hook = self.hooks.get(command)
                if hook:
                    hook()

    def close(self):
        self.stop.set()
        self.join(timeout=2)
        os.close(self.master)
        os.close(self.slave)


class CarrierLock(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='carrierlock-'))
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
        self.boot_id = self.tmp / 'boot_id'
        self.boot_id.write_text('boot-1\n')
        self.enabled = self.data / 'modem-carrierlock.enabled'
        self.enabled.touch()
        self.device = self.sys / 'devices/platform/fcd00000.usb/xhci-hcd.9.auto/usb10/10-1' / PORT
        self.add_device()
        self.modem = FakeFm350()
        self.modem.start()
        self.addCleanup(self.modem.close)
        (self.dev / 'ttyUSB6').symlink_to(self.modem.path)
        (self.dev / 'ttyUSB5').symlink_to(self.modem.path)
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

    def add_device(self, vendor='0e8d', product='7127'):
        """Mode 41: ttys on interfaces 2-9, the AT port on interface 6 (ttyUSB6)."""
        for number in range(2, 10):
            iface = self.device / f'{PORT}:1.{number}'
            (iface / f'ttyUSB{number}').mkdir(parents=True, exist_ok=True)
            (iface / 'bInterfaceNumber').write_text(f'{number:02x}\n')
        (self.device / 'idVendor').write_text(vendor + '\n')
        (self.device / 'idProduct').write_text(product + '\n')
        link = self.sys / 'bus/usb/devices' / PORT
        if not link.is_symlink():
            link.symlink_to(self.device)

    def remove_device(self):
        (self.sys / 'bus/usb/devices' / PORT).unlink()
        shutil.rmtree(self.device)

    def restart_on(self, command, back=True, radio_after='1'):
        """The module applies `command`, sends no answer and drops off the bus
        (and comes back, its radio as the module's own boot leaves it)."""
        self.modem.silent.add(command)

        def later():
            self.modem.answer(command)
            time.sleep(0.2)
            self.remove_device()
            if back:
                time.sleep(0.3)
                self.modem.radio = radio_after
                self.add_device()
        self.modem.hooks[command] = lambda: threading.Thread(target=later, daemon=True).start()

    def mm(self, listed=True, inhibit='ok', extra=None, **fields):
        ports = [f'ttyUSB{n} (ignored)' for n in (2, 3, 4, 5, 7, 8, 9)] + ['ttyUSB6 (at)',
                                                                              'enx000011121314 (net)']
        modem = {
            'path': '/org/freedesktop/ModemManager1/Modem/2', 'device': str(self.device),
            'physdev': str(self.device), 'model': 'FM350-GL', 'revision': '81600.0000.00.29.18.01',
            'state': 'registered', 'equipment-identifier': IMEI,
            'sim': '/org/freedesktop/ModemManager1/SIM/1', 'imsi': self.modem.imsi, 'ports': ports,
        }
        modem.update(fields)
        state = {'modems': [modem] if listed else [], 'inhibit': inhibit}
        state.update(extra or {})
        self.state.write_text(json.dumps(state))

    def sim(self, imsi):
        self.modem.imsi = imsi
        self.mm()

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
                   CERALIVE_CARRIERLOCK_SYSFS=str(self.sys), CERALIVE_CARRIERLOCK_DEV=str(self.dev),
                   CERALIVE_CARRIERLOCK_PROC=str(self.proc), CERALIVE_CARRIERLOCK_RUN=str(self.run_dir),
                   CERALIVE_CARRIERLOCK_DATA=str(self.data / 'modem-carrierlock'),
                   CERALIVE_CARRIERLOCK_MACHINE_ID=str(self.machine_id),
                   CERALIVE_CARRIERLOCK_BOOT_ID=str(self.boot_id),
                   CERALIVE_CARRIERLOCK_MMCLI=str(self.mmcli), CERALIVE_CARRIERLOCK_MM_WAIT='0.5',
                   CERALIVE_CARRIERLOCK_POLL='0.05', CERALIVE_CARRIERLOCK_AT_TIMEOUT='0.5',
                   CERALIVE_CARRIERLOCK_LOCK_TIMEOUT='0.5', CERALIVE_CARRIERLOCK_PORT_WAIT='0.5',
                   CERALIVE_CARRIERLOCK_LEAVE_WAIT='2',
                   FAKE_MM_STATE=str(self.state), FAKE_MM_LOG=str(self.mm_log))
        env.update(env_extra)
        self.child = subprocess.Popen([sys.executable, str(SCRIPT), port], env=env, text=True,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stdout, stderr = self.child.communicate(timeout=60)
        time.sleep(0.05)
        return subprocess.CompletedProcess(self.child.args, self.child.returncode, stdout, stderr)

    def new_boot(self):
        self.boot_id.write_text(f'boot-{time.monotonic_ns()}\n')
        shutil.rmtree(self.run_dir)
        self.run_dir.mkdir()
        self.modem.commands.clear()
        self.mm_log.write_text('')

    def markers(self):
        return {p.stem: json.loads(p.read_text()) for p in self.run_dir.glob('*.json')}

    def marker(self):
        found = list(self.markers().values())
        self.assertLessEqual(len(found), 1, found)
        return found[0] if found else None

    def unit(self):
        return hmac.new(MACHINE_ID.encode(), IMEI.encode(), hashlib.sha256).hexdigest()[:16]

    def record(self):
        path = self.data / 'modem-carrierlock' / f'{self.unit()}.json'
        return json.loads(path.read_text()) if path.exists() else None

    def mm_calls(self):
        return self.mm_log.read_text().splitlines()

    def inhibits(self):
        return [c for c in self.mm_calls() if c.startswith('--inhibit-device=')]

    def assertUntouched(self, done):
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(self.modem.commands, [])
        self.assertEqual(self.inhibits(), [])

    def assertReleased(self):
        self.assertEqual(self.inhibits(), [f'--inhibit-device={self.device}'])
        self.assertEqual(self.mm_calls()[-1], 'released')

    def assertNoWrite(self):
        self.assertNotIn('AT+GTLOCKCAR=0', self.modem.commands)

    # --- the unlock -----------------------------------------------------------

    def test_locked_unit_is_unlocked_with_the_radio_off_and_put_back_on(self):
        done = self.invoke()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(self.modem.commands, UNLOCK)
        self.assertEqual((self.modem.lock, self.modem.profile, self.modem.radio), (('0', '65535'), '203', '1'))
        self.assertReleased()
        marker = self.marker()
        self.assertEqual((marker['phase'], marker['old_lock'], marker['lock']),
                         ('unlocked-by-service', '1,203', '0,65535'))
        record = self.record()
        self.assertEqual((record['original_lock'], record['original_profile'], record['lock'], record['status']),
                         ('1,203', '203', '0,65535', 'unlocked-by-service'))
        self.assertEqual([e['outcome'] for e in record['history']], ['unlocking', 'unlocked-by-service'])
        self.assertIn('unlocked (1,203 -> 0,65535), profile 203 -> 203 "T-Mobile"', done.stdout)

    def test_verizon_lock_with_a_t_mobile_sim_is_unlocked_to_the_sims_profile(self):
        # FM350 #1 as found after the SIM swap: lock 1,101, profile Verizon, T-Mobile SIM.
        self.modem.lock, self.modem.profile = ('1', '101'), '101'
        done = self.invoke()
        self.assertEqual((self.modem.lock, self.modem.profile), (('0', '65535'), '203'))
        self.assertIn('profile 101 -> 203', done.stdout)

    def test_recorded_noise_and_escaped_att_name_parse(self):
        self.modem.unsolicited = True
        self.modem.lock, self.modem.profile = ('1', '203'), '203'
        self.sim(ATT_IMSI)
        done = self.invoke()
        self.assertEqual(self.modem.lock, ('0', '65535'))
        self.assertEqual(self.marker()['profile'], '201')
        self.assertIn('"AT&T"', done.stdout)
        self.assertNotIn('&amp;', done.stdout)

    def test_echo_off_answers_parse_the_same(self):
        self.modem.echo = False
        self.invoke()
        self.assertEqual(self.marker()['phase'], 'unlocked-by-service')

    def test_sims_outside_the_measured_carriers_are_left_alone(self):
        for imsi in ('310150123456789', '262011234567890', '311490123456789'):
            with self.subTest(imsi=imsi):
                self.sim(imsi)
                done = self.invoke()
                self.assertUntouched(done)
                self.assertIn(f'SIM home network {imsi[:6]} is not one', done.stdout)

    def test_every_qualified_row_unlocks(self):
        for imsi in ('310280123456789', '310410123456789', '310240123456789', '310260123456789'):
            with self.subTest(imsi=imsi):
                self.new_boot()
                shutil.rmtree(self.data / 'modem-carrierlock', ignore_errors=True)
                self.modem.lock, self.modem.profile = ('1', '101'), '101'
                self.sim(imsi)
                self.invoke()
                self.assertEqual(self.modem.lock, ('0', '65535'))

    def test_radio_already_off_is_left_off(self):
        self.modem.radio = '4'
        self.invoke()
        self.assertEqual(self.modem.commands, READS + ['AT+CFUN?', 'AT+GTLOCKCAR=0', 'AT+GTLOCKCAR?',
                                                       'AT+GTCURCAR?'])
        self.assertEqual((self.modem.lock, self.modem.radio), (('0', '65535'), '4'))

    # --- later boots ----------------------------------------------------------

    def test_unlock_is_read_once_more_then_trusted(self):
        self.invoke()
        self.new_boot()
        done = self.invoke()
        self.assertEqual(self.modem.commands, READS)
        self.assertIn("the unlock held across a restart", done.stdout, done.stderr)
        self.assertEqual(self.record()['status'], 'unlocked')
        self.new_boot()
        done = self.invoke()
        self.assertUntouched(done)
        self.assertEqual(self.marker()['phase'], 'unlocked')
        self.assertIn('recorded as unlocked', done.stdout)

    def test_unlocked_unit_is_read_once_and_trusted_after(self):
        self.modem.lock, self.modem.profile = ('0', '65535'), '201'
        self.sim(ATT_IMSI)
        done = self.invoke()
        self.assertEqual(self.modem.commands, READS)
        self.assertReleased()
        record = self.record()
        self.assertEqual((record['status'], record['original_lock'], record['original_profile']),
                         ('unlocked', '0,65535', '201'))
        self.assertIn('unlocked (profile 201 "AT&T" picked from the SIM); left alone', done.stdout)
        self.new_boot()
        self.sim(TMO_IMSI)          # a new SIM changes nothing for an unlocked unit
        self.assertUntouched(self.invoke())

    def test_a_lock_that_comes_back_is_unlocked_again_and_read_every_boot(self):
        self.invoke()
        self.new_boot()
        self.modem.lock = ('1', '203')
        done = self.invoke()
        self.assertEqual(self.modem.commands, UNLOCK)
        self.assertIn('locked to 1,203 again after an earlier unlock', done.stdout)
        self.assertTrue(self.record()['lock_returned'])
        for _ in range(2):
            self.new_boot()
            self.invoke()
            self.assertEqual(self.modem.commands, READS)

    def test_a_second_sim_in_the_same_boot_does_not_prove_the_unlock_held(self):
        self.invoke()
        self.modem.commands.clear()
        self.sim(ATT_IMSI)
        done = self.invoke()
        self.assertEqual(self.modem.commands, READS)
        self.assertEqual(self.record()['status'], 'unlocked-by-service')
        self.assertIn('unlocked earlier this boot', done.stdout)
        self.new_boot()
        self.invoke()
        self.assertEqual(self.modem.commands, READS)
        self.assertEqual(self.record()['status'], 'unlocked')

    def test_a_trusted_record_expires(self):
        self.modem.lock = ('0', '65535')
        self.invoke()
        self.new_boot()
        self.assertUntouched(self.invoke())
        self.new_boot()
        self.invoke(CERALIVE_CARRIERLOCK_RECHECK_DAYS='0')
        self.assertEqual(self.modem.commands, READS)

    def test_a_lock_that_keeps_returning_is_given_up(self):
        for _ in range(3):
            self.modem.lock = ('1', '203')
            self.invoke()
            self.assertEqual(self.modem.lock, ('0', '65535'))
            self.new_boot()
        self.modem.lock = ('1', '203')
        done = self.invoke()
        self.assertEqual(self.modem.commands, READS)
        self.assertEqual(self.record()['status'], 'lock-keeps-returning')
        self.assertIn('after 3 unlocks', done.stdout)
        self.new_boot()
        self.assertUntouched(self.invoke())

    def test_once_per_unit_and_sim_per_boot(self):
        self.invoke()
        sent = list(self.modem.commands)
        done = self.invoke()
        self.assertEqual(self.modem.commands, sent)
        self.assertIn('already handled this boot', done.stdout)

    def test_a_new_sim_in_the_same_boot_is_its_own_attempt(self):
        self.modem.read_error = 'AT+GTLOCKCAR?'
        self.invoke()
        self.assertEqual(self.marker()['phase'], 'read-failed')
        self.modem.read_error = None
        self.modem.commands.clear()
        self.sim(ATT_IMSI)
        self.invoke()
        self.assertEqual(len(self.markers()), 2)
        self.assertEqual(self.modem.lock, ('0', '65535'))

    # --- the module restarting ------------------------------------------------

    def test_restart_on_the_unlock_is_verified_read_only_by_the_return(self):
        self.restart_on('AT+GTLOCKCAR=0')
        done = self.invoke()
        self.assertEqual((self.marker()['phase'], self.marker()['radio']), ('restarted', '1'))
        self.assertIn('module restarted on AT+GTLOCKCAR=0', done.stdout)
        self.assertEqual(self.mm_calls()[-1], 'released')
        self.modem.commands.clear()
        self.modem.silent.clear()
        self.modem.hooks.clear()
        done = self.invoke()
        self.assertEqual(self.modem.commands, READS + ['AT+CFUN?'], done.stdout + done.stderr)
        self.assertEqual(self.marker()['phase'], 'unlocked-by-service')
        self.assertEqual(self.record()['status'], 'unlocked-by-service')

    def test_return_still_locked_after_a_restart_is_failed_and_never_rewritten(self):
        self.modem.ignore_unlock = True
        self.restart_on('AT+GTLOCKCAR=0')
        self.invoke()
        self.modem.commands.clear()
        self.modem.silent.clear()
        self.modem.hooks.clear()
        done = self.invoke()
        self.assertEqual(self.modem.commands, READS + ['AT+CFUN?'])
        self.assertEqual(self.record()['status'], 'failed')
        self.assertIn('recorded as failed', done.stdout)
        self.new_boot()
        self.assertUntouched(self.invoke())
        self.assertEqual(self.marker()['phase'], 'gave-up')

    def test_silence_without_a_restart_is_failed_and_the_radio_put_back(self):
        self.modem.silent.add('AT+GTLOCKCAR=0')
        self.modem.hooks['AT+GTLOCKCAR=0'] = lambda: self.modem.silent.add('AT+GTLOCKCAR?')
        self.invoke()
        self.assertEqual(self.marker()['phase'], 'failed')
        self.assertEqual(self.modem.commands[-1], 'AT+CFUN=1')
        self.assertEqual(self.modem.radio, '1')

    def test_restart_on_radio_on_after_a_verified_unlock_counts_as_unlocked(self):
        self.restart_on('AT+CFUN=1')
        self.invoke()
        self.assertEqual(self.marker()['phase'], 'restarted')
        self.assertEqual(self.record()['status'], 'unlocked-by-service')

    def test_return_with_the_radio_left_off_switches_it_back_on(self):
        self.restart_on('AT+GTLOCKCAR=0', radio_after='4')
        self.invoke()
        self.modem.commands.clear()
        self.modem.silent.clear()
        self.modem.hooks.clear()
        done = self.invoke()
        self.assertEqual(self.modem.commands, READS + ['AT+CFUN?', 'AT+CFUN=1'])
        self.assertEqual(self.modem.radio, '1')
        self.assertEqual(self.marker()['phase'], 'unlocked-by-service')
        self.assertIn('switching it on', done.stdout)

    def test_return_whose_radio_will_not_come_on_is_an_error(self):
        self.restart_on('AT+GTLOCKCAR=0', radio_after='4')
        self.invoke()
        self.modem.commands.clear()
        self.modem.silent.clear()
        self.modem.hooks.clear()
        self.modem.radio_on_reply = 'ERROR'
        done = self.invoke()
        self.assertEqual(self.record()['status'], 'radio-not-back')
        self.assertIn('<3>', done.stdout)

    def test_return_of_a_unit_that_was_off_leaves_its_radio_alone(self):
        self.modem.radio = '4'
        self.restart_on('AT+GTLOCKCAR=0', radio_after='4')
        self.invoke()
        self.modem.commands.clear()
        self.modem.silent.clear()
        self.modem.hooks.clear()
        self.invoke()
        self.assertEqual(self.modem.commands, READS)
        self.assertEqual(self.modem.radio, '4')

    # --- refusals and odd answers ---------------------------------------------

    def test_refused_unlock_puts_the_radio_back_and_gives_up_until_retry(self):
        self.modem.unlock_reply = '+CME ERROR: phone failure'
        done = self.invoke()
        self.assertEqual(self.modem.commands[-1], 'AT+CFUN=1')
        self.assertEqual((self.modem.lock, self.modem.radio), (('1', '203'), '1'))
        self.assertEqual(self.record()['status'], 'unlock-refused')
        self.assertIn('answered +CME ERROR: phone failure', done.stdout)
        self.new_boot()
        self.assertUntouched(self.invoke())
        self.new_boot()
        self.modem.unlock_reply = None
        (self.data / 'modem-carrierlock.retry').touch()
        done = self.invoke()
        self.assertIn('original values kept', done.stdout)
        self.assertFalse((self.data / 'modem-carrierlock.retry').exists())
        self.assertEqual(self.modem.lock, ('0', '65535'))
        self.assertEqual(self.record()['original_lock'], '1,203')

    def test_refused_unlock_whose_radio_will_not_come_back_is_an_error(self):
        self.modem.unlock_reply = 'ERROR'
        self.modem.radio_on_reply = 'ERROR'
        done = self.invoke()
        self.assertEqual(self.record()['status'], 'radio-not-back')
        self.assertIn('<3>', done.stdout)

    def test_unlock_that_does_not_take_is_failed(self):
        self.modem.ignore_unlock = True
        done = self.invoke()
        self.assertEqual(self.marker()['phase'], 'failed')
        self.assertEqual(self.modem.radio, '1')
        self.assertIn('the lock reads 1,203', done.stdout)

    def test_radio_off_refused_writes_nothing(self):
        self.modem.radio_off_reply = 'ERROR'
        self.invoke()
        self.assertNoWrite()
        self.assertEqual(self.marker()['phase'], 'radio-off-failed')

    def test_radio_in_another_state_writes_nothing(self):
        self.modem.radio = '0'
        self.invoke()
        self.assertEqual(self.modem.commands, READS + ['AT+CFUN?'])
        self.assertEqual(self.marker()['phase'], 'radio-unexpected')

    def test_radio_that_will_not_come_back_is_an_error(self):
        self.modem.radio_on_reply = 'ERROR'
        done = self.invoke()
        self.assertEqual(self.modem.lock, ('0', '65535'))
        self.assertEqual(self.record()['status'], 'radio-not-back')
        self.assertIn('<3>', done.stdout)

    def test_answer_without_its_final_ok_writes_nothing(self):
        self.modem.unsolicited = True
        self.modem.no_final.add('AT+GTLOCKCAR?')
        self.invoke()
        self.assertEqual(self.modem.commands, READS)
        self.assertEqual(self.marker()['phase'], 'read-failed')

    def test_unexpected_lock_mode_writes_nothing(self):
        self.modem.lock = ('2', '5')
        self.invoke()
        self.assertEqual(self.modem.commands, READS)
        self.assertEqual(self.marker()['phase'], 'unexpected-lock')

    def test_read_errors_write_nothing(self):
        for command in READS:
            with self.subTest(command=command):
                self.new_boot()
                self.modem.read_error = command
                self.invoke()
                self.assertNoWrite()
                self.assertNotIn('AT+CFUN=4', self.modem.commands)
                self.assertEqual(self.mm_calls()[-1], 'released')
        self.assertEqual(self.modem.lock, ('1', '203'))

    def test_cimi_disagreeing_with_modemmanager_writes_nothing(self):
        self.mm(imsi=ATT_IMSI)
        self.invoke()
        self.assertEqual(self.modem.commands, ['AT+CIMI'])
        self.assertEqual(self.marker()['phase'], 'sim-mismatch')

    # --- left alone -----------------------------------------------------------

    def test_verizon_sim_is_never_unlocked_and_never_held(self):
        self.modem.lock, self.modem.profile = ('1', '203'), '203'
        self.sim(VZW_IMSI)
        done = self.invoke()
        self.assertUntouched(done)
        self.assertIn('Verizon SIM (311480)', done.stdout)

    def test_every_verizon_row_is_guarded(self):
        for plmn in ('310590', '310890', '311270', '311480', '312770'):
            self.sim(plmn + '123456789')
            self.assertUntouched(self.invoke())

    def test_no_sim_leaves_it_alone(self):
        self.mm(sim='--')
        done = self.invoke()
        self.assertUntouched(done)
        self.assertIn('no readable SIM', done.stdout)

    def test_other_usb_ids_are_left_alone(self):
        for vendor, product in (('0e8d', '7126'), ('2c7c', '0801'), ('413c', '81d7')):
            (self.device / 'idVendor').write_text(vendor + '\n')
            (self.device / 'idProduct').write_text(product + '\n')
            self.assertUntouched(self.invoke())
            self.assertEqual(self.mm_calls(), [])

    def test_other_model_is_left_alone(self):
        self.mm(model='FM350-AE')
        self.assertUntouched(self.invoke())

    def test_a_running_stream_holds_it_back_without_a_marker(self):
        self.stream_starts()
        done = self.invoke()
        self.assertUntouched(done)
        self.assertEqual(self.mm_calls(), [])
        self.assertIsNone(self.marker())
        self.assertIn('a stream is running (srtla_send)', done.stdout)

    def test_stream_starting_during_the_modemmanager_wait_prevents_the_hold(self):
        self.mm(extra={'on_list_touch': [str(self.proc / '41000/comm')], 'touch_text': 'srtla_send'})
        done = self.invoke()
        self.assertUntouched(done)
        self.assertIsNone(self.marker())
        self.assertIn('not asking ModemManager', done.stdout)

    def test_stream_starting_during_the_read_stops_before_the_radio(self):
        self.modem.before['AT+GTCURCAR?'] = self.stream_starts
        done = self.invoke()
        self.assertEqual(self.modem.commands, READS)
        self.assertEqual(self.mm_calls()[-1], 'released')
        self.assertIsNone(self.marker())
        self.assertIn('nothing written, released', done.stdout)

    def test_off_by_default(self):
        self.enabled.unlink()
        done = self.invoke()
        self.assertUntouched(done)
        self.assertEqual(self.mm_calls(), [])
        self.assertIn('off by default', done.stdout)

    def test_kill_switch_wins_over_the_enable_file(self):
        (self.data / 'modem-carrierlock.disabled').touch()
        self.assertUntouched(self.invoke())
        self.assertEqual(self.mm_calls(), [])

    def test_no_data_dir_leaves_it_alone(self):
        shutil.rmtree(self.data)
        done = self.invoke()
        self.assertUntouched(done)
        self.assertEqual(self.mm_calls(), [])
        self.assertIn('missing or not writable', done.stdout)

    def test_read_only_data_dir_leaves_it_alone(self):
        self.data.chmod(0o555)
        self.addCleanup(self.data.chmod, 0o755)
        if os.access(self.data, os.W_OK):
            self.skipTest('running as root')
        self.assertUntouched(self.invoke())

    def test_stream_starting_during_the_radio_read_stops_before_the_radio(self):
        self.modem.before['AT+CFUN?'] = self.stream_starts
        self.invoke()
        self.assertEqual(self.modem.commands, READS + ['AT+CFUN?'])
        self.assertEqual(self.modem.radio, '1')
        self.assertIsNone(self.marker())

    def test_kill_switch_appearing_with_the_radio_off_stops_before_the_unlock(self):
        self.modem.before['AT+CFUN=4'] = lambda: (self.data / 'modem-carrierlock.disabled').touch()
        done = self.invoke()
        self.assertNoWrite()
        self.assertEqual(self.modem.commands[-1], 'AT+CFUN=1')
        self.assertEqual((self.modem.radio, self.modem.lock), ('1', ('1', '203')))
        self.assertEqual(self.marker()['phase'], 'interrupted')
        self.assertIn('nothing written, radio put back', done.stdout)
        self.new_boot()
        (self.data / 'modem-carrierlock.disabled').unlink()
        self.modem.before.clear()
        done = self.invoke()
        self.assertEqual(self.modem.lock, ('0', '65535'), done.stdout)

    def test_a_hold_that_ends_stops_before_the_unlock(self):
        drop = self.tmp / 'drop-hold'
        self.mm(extra={'drop_hold': str(drop)})

        def lose_hold():
            drop.touch()
            time.sleep(0.3)
        self.modem.before['AT+CFUN=4'] = lose_hold
        done = self.invoke()
        self.assertNoWrite()
        self.assertEqual(self.modem.radio, '1')
        self.assertIn('the ModemManager hold ended', done.stdout)

    def test_kill_switch(self):
        (self.data / 'modem-carrierlock.disabled').touch()
        done = self.invoke()
        self.assertUntouched(done)
        self.assertEqual(self.mm_calls(), [])
        self.assertIsNone(self.marker())

    def test_kill_switch_appearing_during_the_wait_prevents_the_hold(self):
        self.mm(extra={'on_list_touch': [str(self.data / 'modem-carrierlock.disabled')]})
        self.assertUntouched(self.invoke())

    def test_modemmanager_never_listing_it(self):
        self.mm(listed=False)
        done = self.invoke()
        self.assertUntouched(done)
        self.assertIn('did not list the modem in time', done.stdout)

    def test_a_hanging_mmcli_is_bounded_by_the_run_budget(self):
        self.mm(extra={'hang': True})
        started = time.monotonic()
        done = self.invoke(CERALIVE_CARRIERLOCK_BUDGET='3', CERALIVE_CARRIERLOCK_MM_WAIT='90')
        self.assertLess(time.monotonic() - started, 10)
        self.assertUntouched(done)

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

    def test_only_interface_6_is_used(self):
        self.mm(ports=['ttyUSB5 (at)', 'enx000011121314 (net)'])
        done = self.invoke()
        self.assertUntouched(done)
        self.assertEqual(self.marker()['phase'], 'no-at-port')

    def test_no_machine_id_leaves_it_alone(self):
        self.machine_id.unlink()
        done = self.invoke()
        self.assertUntouched(done)
        self.assertIn('no IMEI or machine-id', done.stdout)

    def test_bad_argument_is_refused(self):
        for arg in ('../10-1', '10-1.4:1.6', ''):
            self.assertEqual(self.invoke(port=arg).returncode, 2)
        self.assertEqual(self.mm_calls(), [])

    def test_slot_name_uid_is_matched_by_physdev_and_used_for_the_hold(self):
        self.mm(device='internal_4g')
        self.invoke()
        self.assertEqual(self.inhibits(), ['--inhibit-device=internal_4g'])
        self.assertEqual(self.marker()['phase'], 'unlocked-by-service')

    def test_unreadable_process_list_counts_as_streaming(self):
        shutil.rmtree(self.proc)
        done = self.invoke()
        self.assertUntouched(done)
        self.assertIn('unreadable process list', done.stdout)

    def test_sigterm_during_the_unlock_puts_the_radio_back(self):
        import signal
        self.modem.before['AT+GTLOCKCAR=0'] = lambda: self.child.send_signal(signal.SIGTERM)
        self.modem.silent.add('AT+GTLOCKCAR=0')
        done = self.invoke()
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertEqual(self.modem.commands[-2:], ['AT+GTLOCKCAR=0', 'AT+CFUN=1'])
        self.assertEqual(self.modem.radio, '1')
        self.assertEqual(self.marker()['phase'], 'stopped')
        self.assertEqual(self.mm_calls()[-1], 'released')
        self.assertIn('radio put back as found', done.stdout)

    def test_no_unlock_starts_without_the_budget_to_finish_it(self):
        done = self.invoke(CERALIVE_CARRIERLOCK_BUDGET='30', CERALIVE_CARRIERLOCK_LOCK_TIMEOUT='10',
                           CERALIVE_CARRIERLOCK_LEAVE_WAIT='15')
        self.assertEqual(self.modem.commands, READS)
        self.assertEqual(self.marker()['phase'], 'no-time')
        self.assertEqual(self.modem.radio, '1')
        self.assertIn('nothing written', done.stdout)

    # --- what may reach the module and the disk -------------------------------

    def test_only_allowlisted_commands_ever_reach_the_module(self):
        sent = []
        for setup in (lambda: None, lambda: setattr(self.modem, 'unlock_reply', 'ERROR'),
                      lambda: setattr(self.modem, 'ignore_unlock', True)):
            self.new_boot()
            shutil.rmtree(self.data / 'modem-carrierlock', ignore_errors=True)
            self.modem.lock, self.modem.unlock_reply, self.modem.ignore_unlock = ('1', '101'), None, False
            setup()
            self.invoke()
            sent += self.modem.commands
        self.assertTrue(set(sent) <= ALLOWED, sent)
        self.assertFalse([c for c in sent if c.startswith(('AT+GTLOCKCAR=1', 'AT+GTACT'))])

    def test_records_hold_neither_imei_nor_imsi(self):
        self.invoke()
        stored = ''.join(p.read_text() for p in (self.data / 'modem-carrierlock').glob('*.json'))
        stored += json.dumps(self.markers())
        self.assertNotIn(IMEI, stored)
        self.assertNotIn(TMO_IMSI, stored)
        self.assertIn('310240', stored)



class AtPortWrite(unittest.TestCase):
    """The AT write never raises and never blocks past its deadline."""

    def setUp(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('carrierlock', SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.master, slave = os.openpty()
        self.path = os.ttyname(slave)
        os.close(slave)
        self.port = self.module.AtPort(self.path)
        self.addCleanup(self.port.close)

    def test_hung_up_port_is_no_reply(self):
        os.close(self.master)
        self.assertEqual(self.port.command('AT+GTLOCKCAR?', timeout=0.5), (None, []))

    def test_full_output_buffer_is_bounded(self):
        self.addCleanup(os.close, self.master)
        import errno as e
        try:
            while True:
                os.write(self.port.fd, b'x' * 4096)
        except OSError as error:
            self.assertEqual(error.errno, e.EAGAIN)
        started = time.monotonic()
        self.assertEqual(self.port.command('AT+GTLOCKCAR?', timeout=0.5), (None, []))
        self.assertLess(time.monotonic() - started, 2)


if __name__ == '__main__':
    unittest.main(verbosity=2)

#!/usr/bin/env python3
"""Status screen page, snapshot contract and qrencode parsing; no console or device access."""
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import unittest
import unittest.mock

SPEC = importlib.util.spec_from_file_location(
    'status_screen', Path(__file__).resolve().parents[1] / 'mkosi/runtime/ceralive-status-screen.py')
s = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(s)

NOW = 1_800_000_000
ADDRESSES = [('wlan0', '192.168.42.1'), ('wwan0', '10.64.1.2')]
FACTS = {'image': 'us-boxes-5', 'uptime': 3725.0, 'code': '3F9A',
         'addresses': ADDRESSES, 'attention': None, 'now': NOW}


def fake_matrix(size=25):
    """A stand-in module matrix with finder-like corners; layout tests only."""
    return [[(x + y) % 3 == 0 for x in range(size)] for y in range(size)]


def fake_qr(size=25):
    return lambda url: fake_matrix(size)


def snapshot(**over):
    item = {
        'schema': 2,
        'expires': NOW + 60,
        'ceraui': '2026.11.21',
        'url': 'https://192.168.42.1/',
        'uplinks': [{'kind': 'cellular', 'state': 'up'}, {'kind': 'ethernet', 'state': 'down'}],
        'modems': [{'sim': 'present'}, {'sim': 'absent'}],
        'ready': {'ready': False, 'code': 'no_uplink_passes'},
        'last_error': {'code': 'receiver_refused', 'at': NOW - 30},
    }
    item.update(over)
    return item


class Temp(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)
        self.path = self.dir / 'snapshot.json'

    def load(self, item):
        self.path.write_text(json.dumps(item) if not isinstance(item, str) else item)
        return s.load_snapshot(self.path, now=NOW)


class QrTests(unittest.TestCase):
    def test_parses_qrencode_ascii(self):
        class Done:
            stdout = '##  ##\n  ##  \n##    \n'
        matrix = s.qr_matrix('x', run=lambda *a, **k: Done())
        self.assertEqual(matrix, [[True, False, True], [False, True, False], [True, False, False]])

    def test_rejects_unexpected_output_or_failure(self):
        class Odd:
            stdout = '## #\n'
        self.assertIsNone(s.qr_matrix('x', run=lambda *a, **k: Odd()))
        def broken(*_a, **_k):
            raise OSError('missing')
        self.assertIsNone(s.qr_matrix('x', run=broken))

    def test_passes_the_text_as_one_argument_after_a_separator(self):
        seen = []
        class Done:
            stdout = '##\n'
        def run(args, **_k):
            seen.append(args)
            return Done()
        s.qr_matrix('-v https://x/', run=run)
        self.assertEqual(seen[0][-2:], ['--', '-v https://x/'])

    def test_quiet_zone_is_four_light_modules_two_cells_each(self):
        cells = s.qr_cells(fake_matrix(21))
        self.assertEqual(len(cells), 21 + 8)
        self.assertTrue(all(len(row) == 2 * (21 + 8) for row in cells))
        for row in cells[:4] + cells[-4:]:
            self.assertEqual(set(row), {s.LIGHT})
        for row in cells:
            self.assertEqual(row[:8], s.LIGHT * 8)
            self.assertEqual(row[-8:], s.LIGHT * 8)

    def test_console_output_is_ascii_with_reverse_video(self):
        text = s.to_console(['ab' + s.LIGHT * 4 + '  ' + s.LIGHT * 2, 'cd'])
        self.assertEqual(text, 'ab\x1b[7m    \x1b[27m  \x1b[7m  \x1b[27m\ncd')
        self.assertFalse(text.endswith('\n'))

    @unittest.skipUnless(shutil.which(s.QRENCODE) or os.path.exists(s.QRENCODE), 'qrencode not installed')
    def test_real_qrencode_gives_a_square_version_2_matrix(self):
        matrix = s.qr_matrix('https://192.168.42.1/')
        self.assertIsNotNone(matrix)
        self.assertEqual(len(matrix), 25)
        self.assertTrue(all(len(row) == 25 for row in matrix))
        self.assertTrue(all(matrix[y][x] for y, x in ((0, 0), (0, 6), (6, 0), (6, 6))))


class SnapshotTests(Temp):
    def test_last_start_failure_classes_get_fixed_wording(self):
        result = self.load(snapshot(last_error={'code': 'start_timeout', 'at': NOW - 5}))
        self.assertEqual(result['last_error'], 'the stream did not start in time')
        result = self.load(snapshot(last_error={'code': 'recovery_pending', 'at': NOW - 5}))
        self.assertEqual(result['last_error'], 'the box is restoring its last session')
        # Start failure wording is for the last error only; the ready line keeps its own table.
        result = self.load(snapshot(ready={'ready': False, 'code': 'start_timeout'}))
        self.assertEqual(result['ready']['line'], s.OTHER_REASON)

    def test_current_snapshot_becomes_role_labels_and_fixed_text(self):
        result = self.load(snapshot(stream_key='live_secret', imei='35000000000000',
                                    uplinks=[{'kind': 'wifi', 'state': 'up', 'name': 'HomeSSID'},
                                             {'kind': 'cellular', 'state': 'up'},
                                             {'kind': 'cellular', 'state': 'down'}]))
        self.assertEqual(result['uplinks'], [{'name': 'Wi-Fi 1', 'state': 'up'},
                                             {'name': 'Cellular 1', 'state': 'up'},
                                             {'name': 'Cellular 2', 'state': 'down'}])
        self.assertEqual(result['modems'], [{'name': 'Modem 1', 'sim': 'present'},
                                            {'name': 'Modem 2', 'sim': 'absent'}])
        self.assertEqual(result['ready'], {'ready': False, 'line': 'no uplink reaches the internet'})
        self.assertEqual(result['last_error'], 'the destination refused the last test')
        flat = json.dumps(result)
        for secret in ('live_secret', '35000000000000', 'HomeSSID'):
            self.assertNotIn(secret, flat)

    def test_free_text_never_reaches_the_page(self):
        result = self.load(snapshot(ready={'ready': False, 'code': 'relay.example.com'},
                                    last_error={'code': 'srt://relay.example:5000'}))
        self.assertIsNone(result['ready']['line'])
        self.assertNotIn('last_error', result)
        for leaky in ('new_code', '350000000000000', 'live_secret', 'HomeSSID'):
            result = self.load(snapshot(ready={'ready': False, 'code': leaky}, last_error={'code': leaky}))
            self.assertEqual(result['ready']['line'], s.OTHER_REASON)
            self.assertEqual(result['last_error'], s.OTHER_REASON)
            self.assertNotIn(leaky, json.dumps(result))

    def test_untrusted_snapshots_are_ignored(self):
        self.assertIsNone(s.load_snapshot(self.path, now=NOW))  # missing
        self.assertIsNone(self.load('{not json'))
        self.assertIsNone(self.load(snapshot(schema=1)))
        self.assertIsNone(self.load(snapshot(schema=True)))
        self.assertIsNone(self.load(snapshot(schema=2.0)))
        self.assertIsNone(self.load(snapshot(expires=NOW - 1)))
        self.assertIsNone(self.load(snapshot(expires=NOW + 7200)))
        self.assertIsNone(self.load(snapshot(expires=True)))
        self.assertIsNone(self.load('{"schema": 2, "expires": NaN}'))
        self.assertIsNone(self.load('{"schema": 2, "expires": Infinity}'))
        self.assertIsNone(self.load('[' * 5000 + ']' * 5000))
        self.assertIsNone(self.load(json.dumps(snapshot(pad='x' * s.MAX_SNAPSHOT))))

    def test_symlinks_fifos_and_directories_are_refused_without_blocking(self):
        target = self.dir / 'real.json'
        target.write_text(json.dumps(snapshot()))
        os.symlink(target, self.path)
        self.assertIsNone(s.load_snapshot(self.path, now=NOW))
        fifo = self.dir / 'fifo'
        os.mkfifo(fifo)
        self.assertIsNone(s.load_snapshot(fifo, now=NOW))
        self.assertIsNone(s.load_snapshot(self.dir, now=NOW))

    def test_read_is_bounded(self):
        self.path.write_bytes(b'x' * (s.MAX_SNAPSHOT + 100))
        with self.assertRaises(s.BadSnapshot):
            s.read_bounded(self.path)
        self.path.write_bytes(b'y' * s.MAX_SNAPSHOT)
        self.assertEqual(len(s.read_bounded(self.path)), s.MAX_SNAPSHOT)

    def test_bad_values_are_dropped(self):
        result = self.load(snapshot(ceraui='v1\x1b[2J', url='x' * 200,
                                    uplinks=[{'kind': 'cellular', 'state': 'up'}, {'kind': 'satellite', 'state': 'up'},
                                             {'kind': 'wifi', 'state': 'weird'}, {'kind': [], 'state': 'up'},
                                             {'kind': {}, 'state': 'up'}, {'kind': 'wifi', 'state': []}, 'x'],
                                    modems=[{'sim': 'present'}, {'sim': '8949000000000000000'}, {'sim': []}, []]))
        self.assertIsNone(result['ceraui'])
        self.assertIsNone(result['url'])
        self.assertEqual(result['uplinks'], [{'name': 'Cellular 1', 'state': 'up'}])
        self.assertEqual(result['modems'], [{'name': 'Modem 1', 'sim': 'present'}])


class TextTests(unittest.TestCase):
    def test_clean_keeps_printable_ascii_only(self):
        self.assertEqual(s.clean('RØDE  ‮evil x', 40), 'RDE evil x')
        self.assertEqual(s.clean('ＡＢ', 10), 'AB')
        self.assertIsNone(s.clean('\ud800', 10))
        self.assertIsNone(s.clean('\x1b\x07', 10))
        self.assertEqual(s.clean('a' * 50, 10), 'a' * 10)


class UrlTests(unittest.TestCase):
    def test_only_this_box_is_encoded(self):
        self.assertEqual(s.ui_url('https://192.168.42.1/', ADDRESSES), 'https://192.168.42.1/')
        self.assertEqual(s.ui_url('http://10.64.1.2:8080/x', ADDRESSES), 'https://10.64.1.2/')
        for bad in ('https://relay.example/', 'https://:', 'https://192.168.42.1:99999/',
                    'https://user@192.168.42.1/', 'https://10.64.1.2/x?y', 'https://10.64.1.2#f',
                    'https://192.168.42.10/', None, 7):
            self.assertEqual(s.ui_url(bad, ADDRESSES), 'https://192.168.42.1/', bad)
        self.assertIsNone(s.ui_url('https://relay.example/', []))


class PageTests(Temp):
    def snap(self, **over):
        return self.load(snapshot(**over))

    def check_bounds(self, lines, columns, rows):
        self.assertLessEqual(len(lines), rows)
        self.assertTrue(all(len(line) <= columns for line in lines), lines)
        console = s.to_console(lines)
        self.assertTrue(re.fullmatch(r'[\x20-\x7e\n\x1b\[\]7;m2]*', console) is not None)

    def test_wide_screen_puts_the_code_beside_the_facts(self):
        lines = s.page_lines(FACTS, self.snap(), columns=128, rows=37, qr=fake_qr())
        self.check_bounds(lines, 128, 37)
        page = '\n'.join(lines)
        for expected in ('support code 3F9A', 'Ready     no: no uplink reaches the internet',
                         'us-boxes-5', '2026.11.21', '1 h 02 min', 'Cellular 1 up, Ethernet 1 down',
                         'Modem 2: SIM absent', 'the destination refused the last test',
                         '192.168.42.1, 10.64.1.2', 'https://192.168.42.1/'):
            self.assertIn(expected, page)
        self.assertIn(s.LIGHT * 66, lines[0])
        self.assertEqual(lines[-1], s.FOOTER)

    def test_crowded_page_keeps_the_footer_last(self):
        crowded = self.snap(uplinks=[{'kind': 'cellular', 'state': 'degraded'}] * 8,
                            modems=[{'sim': 'unknown'}] * 8)
        for columns, rows in ((80, 16), (128, 37), (35, 60), (20, 5), (200, 2), (10, 1)):
            lines = s.page_lines(FACTS, crowded, columns=columns, rows=rows, qr=fake_qr())
            self.check_bounds(lines, columns, rows)
            self.assertIn('Alt+F1', lines[-1])

    def test_crowded_page_without_room_for_the_code_keeps_the_address(self):
        crowded = self.snap(uplinks=[{'kind': 'cellular', 'state': 'degraded'}] * 8,
                            modems=[{'sim': 'unknown'}] * 8)
        facts = dict(FACTS, attention='x' * 120)
        lines = s.page_lines(facts, crowded, columns=80, rows=16, qr=fake_qr())
        self.check_bounds(lines, 80, 16)
        self.assertIn('https://192.168.42.1/', '\n'.join(lines))
        self.assertIn('Alt+F1', lines[-1])

    def test_versions_must_look_like_releases(self):
        for good in ('2026.11.21', '1.2.3', '2026.11.21-osb', '1.2.3+git.abc'):
            self.assertEqual(self.snap(ceraui=good)['ceraui'], good, good)
        # Other scripts' digits (Arabic-Indic, fullwidth) are not ASCII and never reach the page.
        for bad in ('350000000000000', 'live_secret', 'HomeSSID', '2026', '1.2.3-' + 'x' * 20,
                    '\u0662\u0660\u0662\u0666.\u0661\u0661', '\uff12\uff10\uff12\uff16.1.2', '2026.\u0661\u0661.21'):
            self.assertIsNone(self.snap(ceraui=bad)['ceraui'], bad)

    def test_small_panel_drops_the_code_but_keeps_the_address(self):
        lines = s.page_lines(FACTS, self.snap(), columns=64, rows=18, qr=fake_qr())
        self.check_bounds(lines, 64, 18)
        self.assertNotIn(s.LIGHT, '\n'.join(lines))
        self.assertIn('https://192.168.42.1/', '\n'.join(lines))

    def test_stacked_code_sits_above_the_footer(self):
        lines = s.page_lines(FACTS, self.snap(), columns=70, rows=60, qr=fake_qr())
        self.check_bounds(lines, 70, 60)
        self.assertIn(s.LIGHT, lines[-2])
        self.assertEqual(lines[-1], s.FOOTER)

    def test_off_box_snapshot_url_is_not_encoded(self):
        seen = []
        def qr(url):
            seen.append(url)
            return fake_matrix()
        page = '\n'.join(s.page_lines(FACTS, self.snap(url='https://relay.example/'), 128, 37, qr=qr))
        self.assertEqual(seen, ['https://192.168.42.1/'])
        self.assertNotIn('relay.example', page)

    def test_without_the_application_the_box_facts_remain(self):
        page = '\n'.join(s.page_lines(FACTS, None, columns=128, rows=37, qr=fake_qr()))
        self.assertIn('not reporting', page)
        self.assertIn('the application has not reported', page)
        self.assertIn('https://192.168.42.1/', page)
        self.assertNotIn('Ready ', page)

    def test_no_address_means_no_code(self):
        page = '\n'.join(s.page_lines(dict(FACTS, addresses=[]), None, columns=128, rows=37, qr=fake_qr()))
        self.assertIn('no local address', page)
        self.assertNotIn(s.LIGHT, page)


class AttentionTextTests(unittest.TestCase):
    def test_attention_shows_fixed_wording_never_the_producer_text(self):
        leaky = {'id': 'modem-sim', 'severity': 'warn', 'line': 'Joined HomeSSID with hunter2', 'fix': 'x', 'detail': 'y'}
        self.assertEqual(s.attention_text(leaky), 'a warning is reported (see the device page)')
        self.assertEqual(s.attention_text(dict(leaky, id='clock-unset')), 'the clock is not set')
        self.assertEqual(s.attention_text(dict(leaky, id='temperature-high', severity='critical')),
                         'the device is hot')
        self.assertEqual(s.attention_text(dict(leaky, severity='info')), 'a notice is reported (see the device page)')
        for bad in (None, 'text', {'id': 'Bad Id', 'severity': 'warn'}, {'id': 'x', 'severity': 'loud'}):
            self.assertIsNone(s.attention_text(bad))

    def test_the_page_never_prints_attention_prose(self):
        with tempfile.TemporaryDirectory() as temp:
            status = Path(temp) / 'status.json'
            status.write_text(json.dumps({'highest': {'id': 'modem-sim', 'severity': 'warn',
                                                      'line': 'Joined HomeSSID'}}))
            with unittest.mock.patch.object(s, 'ATTENTION', status):
                facts = s.facts()
        self.assertNotIn('HomeSSID', json.dumps(facts))
        self.assertEqual(facts['attention'], 'a warning is reported (see the device page)')

    def test_local_destination_settings_are_not_called_unavailable(self):
        self.assertEqual(s.READY_TEXT['receiver_invalid'], 'the destination settings are incomplete')


class FactTests(unittest.TestCase):
    def test_support_code_is_the_setup_hotspot_suffix(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'machine-id'
            path.write_text('0123456789abcdef0123456789ab3f9a\n')
            self.assertEqual(s.support_code(path), '3F9A')
            path.write_text('')
            self.assertIsNone(s.support_code(path))
            self.assertIsNone(s.support_code(Path(temp) / 'missing'))

    def test_addresses_come_from_ip_json_client_interfaces_first(self):
        class Done:
            stdout = json.dumps([{'ifname': 'wwan0', 'addr_info': [{'local': '10.64.1.2'}]},
                                 {'ifname': 'wlan0', 'addr_info': [{'local': '192.168.42.1'}, {}]},
                                 {'ifname': 'eth0', 'addr_info': [{'local': 'not-an-ip'}]}])
        self.assertEqual(s.ipv4_addresses(lambda *a, **k: Done()),
                         [('wlan0', '192.168.42.1'), ('wwan0', '10.64.1.2')])
        def broken(*_a, **_k):
            raise OSError('no ip')
        self.assertEqual(s.ipv4_addresses(broken), [])


if __name__ == '__main__':
    unittest.main()

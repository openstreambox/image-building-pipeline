#!/usr/bin/env python3
"""VT ownership regressions; fake devices never touch the host's consoles."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('attention', Path(__file__).resolve().parents[1] / 'mkosi/runtime/ceralive-attention.py')
a = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(a)
TOP = dict(id='example', severity='fatal', line='The card is not ready.',
           fix='Check the card.', detail='Storage check failed.', led='auto')


class ConsoleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tty = self.root / 'tty8'
        self.tty.write_text('')
        self.login = self.root / 'tty1'
        self.login.write_text('Device login: ')
        self.vt = '1'
        self.font = b'original-font-and-unicode-map'
        self.calls = []
        self.fail_save = False
        self.fail_switch = False
        self.fail_restore = False
        self.logged_in = getattr(self, 'logged_in', set())
        self.controller = self.owner()

    def owner(self):
        return a.Console(self.root / 'state', str(self.tty), self.run_command,
                         lambda: self.vt, operator=lambda vt: vt in self.logged_in)

    def run_command(self, *args):
        self.calls.append(args)
        if args[0] == 'chvt':
            if self.fail_switch:
                return False
            self.vt = args[1]
        elif args[0] == 'setfont':
            self.assertEqual(args[2], str(self.tty))
            if '-O' in args:
                Path(args[-1]).write_bytes(self.font)
                return not self.fail_save
            elif args[-1].endswith('.psf.gz'):
                self.font = b'large-font' if args[-1] == a.ATTENTION_FONT else b'status-font'
            else:
                if self.fail_restore:
                    return False
                self.font = Path(args[-1]).read_bytes()
        else:
            self.fail(args)
        return True

    def test_startup_getty_and_unchanged_fatal(self):
        self.controller.update(TOP)
        self.assertEqual(self.vt, '8')
        self.login.write_text('Late startup login: ')
        self.tty.write_text('Transient console noise')
        self.controller.update(TOP)
        self.assertIn(TOP['line'], self.tty.read_text())
        self.assertIn('Alt+F1 to log in. Alt+F8 returns here.', self.tty.read_text())
        self.assertEqual(self.login.read_text(), 'Late startup login: ')
        self.assertEqual(self.calls.count(('chvt', '8')), 1)

    def test_info_clear_restores_font_and_login(self):
        self.controller.update(TOP)
        self.assertEqual(self.font, b'large-font')
        self.controller.update(TOP | dict(severity='info'))
        self.assertEqual(self.font, b'original-font-and-unicode-map')
        self.assertEqual(self.vt, '1')
        self.assertEqual(self.login.read_text(), 'Device login: ')
        self.assertFalse(self.controller.state.exists())
        self.assertNotIn(TOP['line'], self.tty.read_text())
        previous_calls = self.calls.copy()
        self.controller.update(None)
        self.assertEqual(self.calls, previous_calls)

    def test_login_remains_reachable_and_not_stolen(self):
        self.controller.update(TOP)
        self.vt = '1'  # Operator uses the shortcut while fatal remains active.
        self.controller.update(TOP)
        self.assertEqual(self.vt, '1')
        self.assertIn(TOP['line'], self.tty.read_text())
        self.controller.update(None)
        self.assertEqual(self.vt, '1')
        self.assertEqual(self.calls.count(('chvt', '8')), 1)
        self.assertNotIn(('chvt', '1'), self.calls)

    def test_restart_keeps_original_snapshot_and_does_not_steal_login(self):
        self.controller.update(TOP)
        self.vt = '2'
        owner = self.owner()
        owner.update(TOP)
        self.assertEqual(self.vt, '2')
        owner.release()
        self.assertEqual(self.font, b'original-font-and-unicode-map')
        self.assertEqual(self.vt, '2')

    def test_return_to_previous_vt_on_critical_clear_and_stop(self):
        self.vt = '2'
        self.controller.update(TOP | dict(severity='critical'))
        self.controller.release()
        self.assertEqual(self.vt, '2')
        self.assertEqual(self.font, b'original-font-and-unicode-map')

    def test_failed_save_never_changes_font_and_failed_restore_retries(self):
        self.fail_save = True
        self.controller.update(TOP)
        self.assertEqual(self.font, b'original-font-and-unicode-map')
        self.assertFalse(self.controller.font.exists())
        self.controller.release()
        self.fail_save = False
        self.controller.update(TOP)
        self.fail_restore = True
        self.controller.release()
        self.assertTrue(self.controller.state.exists())
        self.assertEqual(self.vt, '1')
        self.assertEqual(self.login.read_text(), 'Device login: ')
        self.fail_restore = False
        self.controller.release()
        self.assertFalse(self.controller.state.exists())
        self.assertEqual(self.vt, '1')

    def test_failed_switch_keeps_message_and_shortcut_until_retry(self):
        self.controller.update(TOP)
        self.fail_switch = True
        self.controller.release()
        self.assertEqual(self.vt, '8')
        self.assertIn('Alt+F1 to log in.', self.tty.read_text())
        self.assertTrue(self.controller.state.exists())
        self.fail_switch = False
        self.controller.release()
        self.assertEqual(self.vt, '1')
        self.assertEqual(self.font, b'original-font-and-unicode-map')

    def test_warning_has_no_console_effect_and_long_detail_keeps_shortcut(self):
        self.controller.update(TOP | dict(severity='warn'))
        self.assertEqual(self.calls, [])
        with mock.patch.object(a.os, 'get_terminal_size', return_value=(80, 12)):
            self.controller.update(TOP | dict(detail='Detailed explanation. ' * 100))
        self.assertLess(len(self.tty.read_text().splitlines()), 12)
        self.assertIn('Alt+F1 to log in.', self.tty.read_text())
        self.assertIn(TOP['line'], self.tty.read_text())

    def test_condition_never_pulls_from_a_logged_in_vt(self):
        self.logged_in.add('1')
        self.controller.update(TOP)
        self.controller.update(TOP)
        self.assertEqual(self.vt, '1')
        self.assertNotIn(('chvt', '8'), self.calls)
        self.assertIn(TOP['line'], self.tty.read_text())  # still there for Alt+F8
        self.logged_in.clear()  # logging out later does not pull either
        self.controller.update(TOP)
        self.assertEqual(self.vt, '1')

    def test_service_restart_during_a_condition_never_pulls_again(self):
        self.controller.update(TOP)
        self.assertEqual(self.vt, '8')
        self.vt = '1'  # Alt+F1 to the login prompt
        self.controller.release()  # SIGTERM: watch() releases on the way out
        self.controller = self.owner()
        self.controller.update(TOP)
        self.assertEqual(self.vt, '1')
        self.logged_in.add('1')
        self.controller.release()
        self.controller = self.owner()
        self.controller.update(TOP)
        self.assertEqual(self.vt, '1')
        self.assertEqual(self.calls.count(('chvt', '8')), 1)
        self.controller.update(None)  # cleared: a later condition may pull again
        self.logged_in.clear()
        self.controller.update(TOP)
        self.assertEqual(self.vt, '8')

    def test_watch_repaints_every_tick_and_releases_on_stop(self):
        frames, stops = [], []
        def sleep(_):
            frames.append(self.tty.read_text())
            if len(frames) == 1:
                self.tty.write_text('Transient startup output')
            else:
                stops[0]()
        with mock.patch.object(a, 'Console', return_value=self.controller), \
             mock.patch.object(a, 'probes'), mock.patch.object(a, 'conditions', return_value=[TOP]), \
             mock.patch.object(a, 'render', return_value=TOP), mock.patch.object(a, 'command'), \
             mock.patch.object(a, 'listener'), mock.patch.object(a.time, 'sleep', side_effect=sleep), \
             mock.patch.object(a.signal, 'signal', side_effect=lambda _, cb: stops.append(cb)):
            a.watch()
        self.assertEqual(len(frames), 2)
        self.assertTrue(all(TOP['line'] in frame for frame in frames))
        self.assertEqual(self.font, b'original-font-and-unicode-map')
        self.assertEqual(self.vt, '1')


class LegacyTests(ConsoleTests):
    """Without the renderer VT8 behaves as before the status page existed."""

    def test_return_target_is_the_vt_found_at_acquisition(self):
        self.fail_switch = True
        self.controller.update(TOP)
        self.vt = '2'
        self.fail_switch = False
        self.controller.update(TOP)
        self.assertEqual(self.vt, '8')
        self.controller.update(None)
        self.assertEqual(self.vt, '1')

    def test_large_font_is_loaded_once_per_acquisition(self):
        self.controller.update(TOP)
        self.controller.update(TOP)
        self.controller = self.owner()  # process replaced while the condition holds
        self.controller.update(TOP)
        loads = [c for c in self.calls if c[0] == 'setfont' and c[-1] == a.ATTENTION_FONT]
        self.assertEqual(len(loads), 1)


PAGE = ['BOX STATUS  support code 3F9A', 'Open      https://192.168.42.1/',
        'Photograph this screen for support. Alt+F1 to log in.']


class FakePage:
    def __init__(self):
        self.fail = False
        self.sizes = []
        self.lines = PAGE

    def __call__(self, columns, rows):
        self.sizes.append((columns, rows))
        if self.fail:
            raise RuntimeError('renderer fault')
        return list(self.lines)

    def console(self, line):
        return line


class StatusConsoleTests(ConsoleTests):
    """VT8 with the status page installed; fake VT, fake monitors, fake logins."""

    def setUp(self):
        self.page = FakePage()
        self.monitors = set()
        self.logged_in = set()
        super().setUp()

    def owner(self):
        return a.Console(self.root / 'state', str(self.tty), self.run_command, lambda: self.vt,
                         status=self.page,
                         connectors=lambda: None if self.monitors is None else set(self.monitors),
                         operator=lambda vt: vt in self.logged_in)

    def switches(self):
        return self.calls.count(('chvt', '8'))

    def test_boot_shows_the_page_once_in_the_small_font(self):
        self.controller.update(None)
        self.assertEqual(self.vt, '8')
        self.assertEqual(self.font, b'status-font')
        screen = self.tty.read_text()
        self.assertIn(PAGE[1], screen)
        self.assertNotIn('\033[2J', screen)  # painted in place, no flash for a camera
        self.vt = '1'  # the operator leaves; repaints never pull them back
        for _ in range(3):
            self.controller.update(None)
        self.assertEqual(self.vt, '1')
        self.assertEqual(self.switches(), 1)
        self.assertEqual([c for c in self.calls if c[0] == 'setfont' and c[-1].endswith('.gz')],
                         [('setfont', '-C', str(self.tty), a.STATUS_FONT)])

    def test_boot_switch_skips_a_logged_in_operator(self):
        self.logged_in.add('1')
        self.controller.update(None)
        self.controller.update(None)
        self.assertEqual(self.vt, '1')
        self.assertEqual(self.switches(), 0)
        self.assertIn(PAGE[0], self.tty.read_text())  # VT8 still holds the page for Alt+F8

    def test_failed_boot_switch_retries_then_stops(self):
        self.fail_switch = True
        self.controller.update(None)
        self.fail_switch = False
        self.controller.update(None)
        self.assertEqual(self.vt, '8')
        self.vt = '1'
        self.controller.update(None)
        self.assertEqual(self.vt, '1')

    def test_hdmi_plug_switches_unless_someone_is_logged_in(self):
        self.monitors = {'card0-HDMI-A-1'}  # connected at boot: the boot switch covers it
        self.controller.update(None)
        self.vt = '1'
        self.controller.update(None)
        self.assertEqual(self.vt, '1')
        self.monitors = set()
        self.controller.update(None)
        self.assertEqual(self.vt, '1')
        self.monitors = {'card0-HDMI-A-1'}
        self.controller.update(None)
        self.assertEqual(self.vt, '8')
        self.vt = '2'
        self.logged_in.add('2')
        self.monitors = {'card0-HDMI-A-1', 'card0-HDMI-A-2'}
        self.controller.update(None)
        self.assertEqual(self.vt, '2')
        self.assertEqual(self.switches(), 2)

    def test_critical_takes_over_and_the_page_returns(self):
        self.controller.update(None)
        self.controller.update(TOP | dict(severity='critical'))
        self.assertIn(TOP['line'], self.tty.read_text())
        self.assertNotIn(PAGE[0], self.tty.read_text())
        self.assertEqual(self.font, b'large-font')
        self.controller.update(TOP | dict(severity='warn'))
        self.assertIn(PAGE[0], self.tty.read_text())
        self.assertNotIn(TOP['line'], self.tty.read_text())
        self.assertEqual(self.font, b'status-font')
        self.assertEqual(self.vt, '8')  # was already watching VT8: stays there
        self.assertNotIn(('chvt', '1'), self.calls)

    def test_condition_pulls_from_a_login_prompt_and_hands_it_back(self):
        self.controller.update(None)
        self.vt = '2'  # a login prompt, nobody logged in
        self.controller.update(TOP)
        self.assertEqual(self.vt, '8')
        self.controller.update(TOP)
        self.controller.update(None)
        self.assertEqual(self.vt, '2')
        self.assertIn(PAGE[0], self.tty.read_text())
        self.controller.update(None)
        self.assertEqual(self.vt, '2')
        self.assertEqual(self.calls.count(('chvt', '2')), 1)

    def test_restart_keeps_the_operator_where_they_are(self):
        self.controller.update(None)
        self.vt = '1'
        self.controller = self.owner()
        self.controller.update(None)
        self.assertEqual(self.vt, '1')
        self.controller.update(TOP)
        self.assertEqual(self.vt, '8')
        self.vt = '1'
        self.controller = self.owner()  # restarted while the condition holds
        self.controller.update(TOP)
        self.controller.update(None)
        self.assertEqual(self.vt, '1')
        self.assertEqual(self.switches(), 2)

    def test_stop_returns_to_the_vt_found_at_start_not_the_last_pull(self):
        self.controller.update(None)  # boot: tty1 -> VT8
        self.vt = '2'
        self.controller.update(TOP)  # pulled from the tty2 prompt
        self.controller.update(None)
        self.assertEqual(self.vt, '2')
        self.vt = '8'  # someone goes back to the page
        self.controller.release()
        self.assertEqual(self.vt, '1')

    def test_hdmi_plug_during_a_condition_does_not_switch(self):
        self.controller.update(None)
        self.controller.update(TOP)  # already on VT8: no pull
        self.vt = '1'  # Alt+F1 to the prompt
        self.monitors = {'card0-HDMI-A-1'}
        self.controller.update(TOP)
        self.assertEqual(self.vt, '1')
        self.controller.update(None)  # cleared; the plug is not replayed as a new edge
        self.controller.update(None)
        self.assertEqual(self.vt, '1')
        self.assertEqual(self.switches(), 1)

    def test_unreadable_connector_is_not_a_plug(self):
        self.monitors = None  # read failed: the boot switch still happens
        self.controller.update(None)
        self.assertEqual(self.vt, '8')
        self.vt = '1'
        self.controller.update(None)
        self.monitors = {'card0-HDMI-A-1'}
        self.controller.update(None)
        self.assertEqual(self.vt, '1')

    def test_renderer_fault_keeps_the_login_line(self):
        self.page.fail = True
        self.controller.update(None)
        self.assertIn('Box status is not available.', self.tty.read_text())
        self.assertIn('Alt+F1 to log in.', self.tty.read_text())

    def test_stop_returns_to_the_login_and_restores_the_font(self):
        self.controller.update(None)
        self.controller.release()
        self.assertEqual(self.vt, '1')
        self.assertEqual(self.font, b'original-font-and-unicode-map')
        self.assertFalse(self.controller.state.exists())
        self.assertTrue(self.controller.booted.exists())  # no second boot switch on restart
        self.controller = self.owner()
        self.controller.update(None)
        self.assertEqual(self.vt, '1')

    def test_full_width_last_line_is_not_erased(self):
        self.controller.update(None)
        width = len(PAGE[-1])
        self.page.lines = ['one', 'two', 'three', 'four', PAGE[-1]]
        with mock.patch.object(a.os, 'get_terminal_size', return_value=(width, 5)):
            self.controller.update(None)
        self.assertTrue(self.tty.read_text().endswith(PAGE[-1]))  # bottom row: nothing below
        self.page.lines = PAGE
        with mock.patch.object(a.os, 'get_terminal_size', return_value=(width, 10)):
            self.controller.update(None)
        # Rows remain below a full-width footer: step down, then erase them.
        self.assertTrue(self.tty.read_text().endswith(PAGE[-1] + '\n\033[J'))
        self.controller.update(None)
        self.assertTrue(self.tty.read_text().endswith(PAGE[-1] + '\033[J'))

    # The legacy behaviors still hold with the page installed, except where the
    # page replaces the cleared VT: these tests cover that instead.
    test_info_clear_restores_font_and_login = None
    test_return_to_previous_vt_on_critical_clear_and_stop = None
    test_warning_has_no_console_effect_and_long_detail_keeps_shortcut = None
    test_watch_repaints_every_tick_and_releases_on_stop = None
    test_return_target_is_the_vt_found_at_acquisition = None
    test_large_font_is_loaded_once_per_acquisition = None
    test_failed_save_never_changes_font_and_failed_restore_retries = None
    test_failed_switch_keeps_message_and_shortcut_until_retry = None


class StatusPageTests(unittest.TestCase):
    """The real renderer loaded by the owner, with qrencode and facts faked."""

    def setUp(self):
        self.page = a.StatusPage.load(Path(__file__).resolve().parents[1] / 'mkosi/runtime/ceralive-status-screen.py')
        m = self.page.module
        self.encodes = []
        def qr_matrix(url):
            self.encodes.append(url)
            return [[(x * y) % 3 == 0 for x in range(25)] for y in range(25)]
        facts = {'image': 'us-boxes-6', 'uptime': 600.0, 'code': '3F9A', 'now': 0,
                 'addresses': [('wlan0', '192.168.42.1')], 'attention': None}
        for name, value in (('qr_matrix', qr_matrix), ('facts', lambda: facts),
                            ('load_snapshot', lambda: None)):
            patcher = mock.patch.object(m, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_page_with_code_on_a_1024x600_panel_and_qrencode_runs_on_change_only(self):
        lines = self.page(128, 37)
        self.assertLessEqual(len(lines), 37)
        self.assertTrue(all(len(line) <= 128 for line in lines))
        self.assertIn('https://192.168.42.1/', '\n'.join(lines))
        self.assertIn('\033[7m', ''.join(self.page.console(line) for line in lines))
        self.page(128, 37)
        self.assertEqual(self.encodes, ['https://192.168.42.1/'])

    def test_owner_paints_the_real_page(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        tty = Path(temp.name) / 'tty8'
        tty.write_text('')
        owner = a.Console(Path(temp.name) / 'state', str(tty), lambda *args: True, lambda: '8',
                          status=self.page, connectors=set, operator=lambda vt: False)
        with mock.patch.object(a.os, 'get_terminal_size', return_value=(128, 37)):
            owner.update(None)
        screen = tty.read_text()
        self.assertIn('support code 3F9A', screen)
        self.assertIn('Alt+F1 to log in.', screen)
        self.assertIn('\033[7m', screen)

    def test_failed_qr_encode_is_retried_at_most_every_30_s(self):
        m = self.page.module
        clock = [100.0]
        tries = []
        with mock.patch.object(m, 'qr_matrix', lambda url: tries.append(url)), \
             mock.patch.object(a.time, 'monotonic', lambda: clock[0]):
            self.page.qr('https://192.168.42.9/')
            self.page.qr('https://192.168.42.9/')
            clock[0] += 31
            self.page.qr('https://192.168.42.9/')
        self.assertEqual(len(tries), 2)

    def test_load_reads_the_install_path_at_call_time(self):
        with mock.patch.object(a, 'STATUS_SCREEN', Path('/nonexistent/ceralive-status-screen')):
            self.assertIsNone(a.StatusPage.load())

    def test_missing_renderer_leaves_vt8_to_conditions(self):
        self.assertIsNone(a.StatusPage.load(Path('/nonexistent/ceralive-status-screen')))

    def test_installed_name_without_suffix_loads_and_writes_no_cache(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        installed = Path(temp.name) / 'ceralive-status-screen'
        installed.write_bytes((Path(__file__).resolve().parents[1] / 'mkosi/runtime/ceralive-status-screen.py').read_bytes())
        page = a.StatusPage.load(installed)
        self.assertTrue(callable(page.module.page_lines))
        self.assertEqual(sorted(p.name for p in Path(temp.name).iterdir()), ['ceralive-status-screen'])

    def test_broken_renderer_does_not_stop_the_owner(self):
        broken = Path(tempfile.mkdtemp()) / 'ceralive-status-screen'
        self.addCleanup(lambda: (broken.unlink(), broken.parent.rmdir()))
        broken.write_text('raise SystemError("broken")\n')
        created = []
        def stop_after_first(_):
            raise KeyboardInterrupt
        with mock.patch.object(a, 'STATUS_SCREEN', broken), \
             mock.patch.object(a, 'Console', side_effect=lambda **kw: created.append(kw) or mock.Mock()), \
             mock.patch.object(a, 'probes'), mock.patch.object(a, 'conditions', return_value=[]), \
             mock.patch.object(a, 'render', return_value=None), mock.patch.object(a, 'command'), \
             mock.patch.object(a, 'listener'), mock.patch.object(a.signal, 'signal'), \
             mock.patch.object(a.time, 'sleep', side_effect=stop_after_first):
            with self.assertRaises(KeyboardInterrupt):
                a.watch()
        self.assertEqual(created, [{'status': None}])
        self.assertFalse((broken.parent / '__pycache__').exists())


class InputTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_unreadable_connector_status_gives_no_answer(self):
        (self.root / 'card0-HDMI-A-1').mkdir()
        (self.root / 'card0-HDMI-A-1' / 'status').mkdir()  # reading a directory fails
        self.assertIsNone(a.hdmi_connected(self.root))

    def test_only_hdmi_connectors_with_a_monitor_count(self):
        for name, status in (('card0-HDMI-A-1', 'connected\n'), ('card0-HDMI-A-2', 'disconnected\n'),
                             ('card1-DP-1', 'connected\n'), ('card1-HDMI-A-1', 'unknown\n')):
            (self.root / name).mkdir()
            (self.root / name / 'status').write_text(status)
        self.assertEqual(a.hdmi_connected(self.root), {'card0-HDMI-A-1'})
        self.assertEqual(a.hdmi_connected(self.root / 'missing'), set())

    def test_a_login_prompt_is_not_an_operator(self):
        def proc(pid, name, tty):
            (self.root / pid).mkdir()
            (self.root / pid / 'stat').write_text('%s (%s) S 1 %s %s %d -1 4194560 0 0\n' % (pid, name, pid, pid, tty))
        proc('100', 'agetty', 1025)
        proc('101', 'login', 1026)
        proc('102', 'bash', 1026)
        proc('103', 'odd) S 1 1 1 1025 (x', 0)  # a name with parentheses cannot fake a terminal
        proc('104', 'kworker/0:1', 0)
        (self.root / 'self').mkdir()
        self.assertFalse(a.operator_on('1', self.root))
        self.assertTrue(a.operator_on('2', self.root))
        self.assertFalse(a.operator_on('3', self.root))
        self.assertFalse(a.operator_on('x', self.root))


if __name__ == '__main__':
    unittest.main()

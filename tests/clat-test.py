import importlib.util
import pathlib
import unittest

path = pathlib.Path(__file__).resolve().parents[1] / 'mkosi/runtime/ceralive-clat.py'
spec = importlib.util.spec_from_file_location('clat', path)
clat = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clat)

class Discovery(unittest.TestCase):
    def test_discovery(self):
        self.assertEqual(clat.prefix_from_answers(['2001:db8:64::c000:aa', '2001:db8:64::c000:ab']), '2001:db8:64::/96')
    def test_all_rfc6052_lengths(self):
        for length in (32,40,48,56,64,96):
            prefix = f'2001:db8::/{length}'
            self.assertEqual(clat.prefix_from_answers([clat.embed(prefix,a) for a in ['192.0.0.170','192.0.0.171']]), prefix)

    def test_confirmed_well_known(self):
        self.assertEqual(clat.prefix_from_answers(['64:ff9b::c000:aa', '64:ff9b::c000:ab']), '64:ff9b::/96')
    def test_no_guess(self):
        for answers in [[], ['2001:db8::1'], ['64:ff9b::c000:aa'], ['2001:db8::c000:aa', '2001:db9::c000:ab']]:
            with self.assertRaises(ValueError): clat.prefix_from_answers(answers)
    def test_short_prefix(self):
        self.assertEqual(clat.prefix_from_answers(['2001:db8:c000:aa::', '2001:db8:c000:ab::']), '2001:db8::/32')

class Admission(unittest.TestCase):
    def test_dual_stack_needs_no_clat(self):
        addresses = [dict(family='inet',scope='global',local='192.0.2.1'),dict(family='inet6',scope='global',local='2001:db8::1')]
        self.assertEqual(clat.eligible(addresses), [])

    def test_usable_ipv6_only(self):
        self.assertEqual(clat.eligible([dict(family='inet6',scope='global',local='2001:db8::1')]), ['2001:db8::1'])
        for flag in ['tentative','deprecated','dadfailed']:
            self.assertEqual(clat.eligible([dict(family='inet6',scope='global',local='2001:db8::1',**{flag: True})]), [])

    def test_link_state_lifecycle(self):
        from unittest.mock import patch
        made = []
        class Fake:
            def __init__(self, *args):
                self.undo = []; self.process = None; made.append(self)
            def start(self): self.undo.append('owned')
            def stop(self): self.undo.clear()
            def status(self,*args): pass
            def repair_routes(self): pass
        with patch.object(clat, 'Link', Fake):
            controller = clat.Controller()
            controller.sync({'wan1': ('a','b',()), 'wan2': ('c','d',())})
            self.assertEqual(len(made), 2)
            controller.sync({'wan2': ('c','d',())})
            self.assertFalse(made[0].undo)
            self.assertTrue(made[1].undo)
            controller.sync({})
            self.assertFalse(made[1].undo)


class Recovery(unittest.TestCase):
    def test_nm_ipv6_dns_wire_shape(self):
        import socket
        self.assertEqual(clat.ip6_dns({'Nameservers': [list(socket.inet_pton(socket.AF_INET6, 'fe80::53'))]}), ('fe80::53',))

    def test_temporary_source_is_excluded_and_order_is_stable(self):
        def a(local, **kw): return dict(family='inet6', scope='global', local=local, **kw)
        addresses = [a('2001:db8::3', temporary=True), a('2001:db8::2'), a('2001:db8::1')]
        self.assertEqual(clat.eligible(addresses), ['2001:db8::1', '2001:db8::2'])
        self.assertEqual(clat.eligible(addresses[::-1]), clat.eligible(addresses))

    def test_revalidation_hysteresis_and_recovery(self):
        from unittest.mock import Mock, patch
        link = Mock(process=None, refreshed=0, failures=0, prefix='64:ff9b::/96')
        controller = clat.Controller()
        signature = ('a', 'b', ())
        controller.links['wan1'] = (signature, link)
        with patch.object(clat.time, 'monotonic', return_value=61), patch.object(clat, 'discover', side_effect=ValueError('timeout')):
            controller.sync({'wan1': signature})
        link.stop.assert_not_called()
        self.assertEqual(link.failures, 1)
        self.assertEqual(link.refreshed, 61)
        with patch.object(clat.time, 'monotonic', return_value=122), patch.object(clat, 'discover', return_value=link.prefix):
            controller.sync({'wan1': signature})
        self.assertEqual(link.failures, 0)
        with patch.object(clat.time, 'monotonic', side_effect=lambda: link.refreshed+61), patch.object(clat, 'discover', side_effect=ValueError('timeout')), patch.object(clat, 'restore_forwarding'):
            for _ in range(3): controller.sync({'wan1': signature})
        link.stop.assert_called_once_with('error', 'timeout')
        self.assertFalse(controller.links)

    def test_validated_prefix_change_withdraws(self):
        from unittest.mock import Mock, patch
        link = Mock(process=None, refreshed=0, failures=0, prefix='64:ff9b::/96')
        controller = clat.Controller()
        signature = ('a', 'b', ())
        controller.links['wan1'] = (signature, link)
        with patch.object(clat.time, 'monotonic', return_value=61), patch.object(clat, 'discover', return_value='2001:db8:64::/96'), patch.object(clat, 'restore_forwarding'):
            controller.sync({'wan1': signature})
        link.stop.assert_called_once_with()
        self.assertFalse(controller.links)

    def test_route_repair_failure_does_not_starve_other_links(self):
        from unittest.mock import Mock, patch
        import subprocess
        for error in (subprocess.CalledProcessError(2, 'ip'), subprocess.TimeoutExpired('ip', 10)):
            with self.subTest(error=type(error).__name__):
                broken = Mock(process=None)
                broken.repair_routes.side_effect = error
                signature = ('a', 'b', ())
                controller = clat.Controller()
                controller.links['wan1'] = (signature, broken)
                healthy = Mock(undo=['owned'])
                with patch.object(clat, 'Link', return_value=healthy):
                    controller.sync({'wan1': signature, 'wan2': signature})
                healthy.start.assert_called_once_with()
                self.assertIn('wan2', controller.links)
                broken.stop.assert_called_once()
                self.assertNotIn('wan1', controller.links)

    def test_retry_survives_sync_exception(self):
        from unittest.mock import Mock
        action = Mock(side_effect=[OSError('status unavailable'), None])
        self.assertTrue(clat.retry(action))
        self.assertTrue(clat.retry(action))
        self.assertEqual(action.call_count, 2)

    def test_journal_precedes_mutation(self):
        from unittest.mock import patch
        import tempfile
        with tempfile.TemporaryDirectory() as directory, patch.object(clat, 'RUN', pathlib.Path(directory)), patch.object(clat.socket, 'if_nametoindex', return_value=3):
            link = clat.Link('wan1', '2001:db8::1', '', ())
            undo = ['ip', 'link', 'del', link.tun]
            def crash(*args, **kw):
                import json
                self.assertEqual(json.loads((clat.RUN/'3.cleanup').read_text()), [undo])
                raise SystemExit('crash')
            with patch.object(clat, 'command', side_effect=crash) as mutate:
                with self.assertRaises(SystemExit): link.add(['create'], undo)
                mutate.assert_called_once()
            self.assertEqual(link.undo, [undo])
            self.assertTrue((clat.RUN/'3.cleanup').exists())

if __name__ == '__main__': unittest.main()

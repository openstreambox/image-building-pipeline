import importlib.util
import json
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

class Isolated(unittest.TestCase):
    def setUp(self):
        import tempfile
        from unittest.mock import patch
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        for target, value in [('RUN', pathlib.Path(self.directory.name))]:
            patcher = patch.object(clat, target, value)
            patcher.start(); self.addCleanup(patcher.stop)
        patcher = patch.object(clat.socket, 'if_nametoindex', return_value=3)
        patcher.start(); self.addCleanup(patcher.stop)

class Admission(Isolated):
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
                self.undo = []; self.process = None; self.index = len(made)+3; self.stopping = False; made.append(self)
            def start(self, **kwargs): self.undo.append('owned')
            def stop(self): self.undo.clear(); return True
            def status(self,*args): pass
            def repair_routes(self): pass
        with patch.object(clat, 'Link', Fake):
            controller = clat.Controller()
            controller.sync({'wan1': ('a','b',()), 'wan2': ('c','d',())})
            self.assertEqual(len(made), 2)
            with patch.object(clat.socket, 'if_nametoindex', side_effect=lambda name: 3 if name == 'wan1' else 4):
                controller.sync({'wan2': ('c','d',())})
            self.assertFalse(made[0].undo)
            self.assertTrue(made[1].undo)
            controller.sync({})
            self.assertFalse(made[1].undo)


class Recovery(Isolated):
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
        link = Mock(process=None, index=3, stopping=False, refreshed=0, failures=0, prefix='64:ff9b::/96')
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
        link = Mock(process=None, index=3, stopping=False, refreshed=0, failures=0, prefix='64:ff9b::/96')
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
                broken = Mock(process=None, index=3, stopping=False)
                broken.repair_routes.side_effect = error
                signature = ('a', 'b', ())
                controller = clat.Controller()
                controller.links['wan1'] = (signature, broken)
                healthy = Mock(undo=['owned'], process=None, index=4, stopping=False, refreshed=clat.time.monotonic())
                with patch.object(clat, 'Link', return_value=healthy), patch.object(clat.socket, 'if_nametoindex', side_effect=lambda name: 3 if name == 'wan1' else 4):
                    controller.sync({'wan1': signature, 'wan2': signature})
                healthy.start.assert_called_once()
                self.assertIn('wan2', controller.links)
                broken.stop.assert_called_once()
                self.assertNotIn('wan1', controller.links)

    def test_status_fault_preserves_link_and_serves_other_links(self):
        from unittest.mock import Mock, patch
        import tempfile
        with tempfile.TemporaryDirectory() as directory, patch.object(clat, 'RUN', pathlib.Path(directory)), patch.object(clat.socket, 'if_nametoindex', return_value=3):
            link = clat.Link('wan1', '2001:db8::1', '', ())
            (clat.RUN/'3.json').mkdir()
            link.refreshed = clat.time.monotonic()
            signature = ('a', 'b', ())
            controller = clat.Controller()
            controller.links['wan1'] = (signature, link)
            healthy = Mock(undo=['owned'], process=None, index=4, stopping=False, refreshed=clat.time.monotonic())
            with patch.object(link, 'repair_routes'), patch.object(link, 'stop') as stop, patch.object(clat, 'Link', return_value=healthy), patch.object(clat.socket, 'if_nametoindex', side_effect=lambda name: 3 if name == 'wan1' else 4):
                for _ in range(2):
                    controller.sync({'wan1': signature, 'wan2': signature})
                stop.assert_not_called()
                self.assertIn('wan1', controller.links)
                healthy.start.assert_called_once()
                healthy.repair_routes.assert_called_once()

    def test_invalidation_fault_preserves_inverse_and_defers_teardown(self):
        from unittest.mock import Mock, patch
        import subprocess
        import tempfile
        with tempfile.TemporaryDirectory() as directory, patch.object(clat, 'RUN', pathlib.Path(directory)), patch.object(clat.socket, 'if_nametoindex', return_value=3):
            link = clat.Link('wan1', '2001:db8::1', '', ())
            (clat.RUN/'3.json').mkdir()
            link.undo = [['first'], ['second']]
            link.save_cleanup()
            signature = ('a', 'b', ())
            controller = clat.Controller()
            controller.links['wan1'] = (signature, link)
            healthy = Mock(undo=['owned'], process=None, index=4, stopping=False, refreshed=clat.time.monotonic())
            with patch.object(clat, 'command', side_effect=[subprocess.TimeoutExpired('second', 10), '']) as command, patch.object(clat, 'Link', return_value=healthy):
                controller.sync({'wan2': signature})
            command.assert_not_called()
            healthy.start.assert_called_once()
            self.assertIn('wan1', controller.links)
            self.assertTrue(link.stopping)
            self.assertEqual(json.loads((clat.RUN/'3.cleanup').read_text()), [['first'], ['second']])

    def test_same_grant_recovers_after_cleanup_timeout(self):
        from unittest.mock import Mock, patch
        import subprocess
        import tempfile
        with tempfile.TemporaryDirectory() as directory, patch.object(clat, 'RUN', pathlib.Path(directory)), patch.object(clat.socket, 'if_nametoindex', return_value=3):
            signature = ('2001:db8::1', '', ())
            link = clat.Link('wan1', *signature)
            link.ipv4_mtu = 1480
            undo = ['ip', 'link', 'del', link.tun]
            link.undo = [undo]
            link.save_cleanup()
            controller = clat.Controller()
            controller.links['wan1'] = (signature, link)
            present = [True]
            attempts = []
            def command(*args, **kwargs):
                if args[:4] == ('ip', '-4', 'route', 'replace'):
                    raise subprocess.TimeoutExpired('ip', 10)
                if list(args) == undo:
                    attempts.append(args)
                    if len(attempts) == 1:
                        raise subprocess.TimeoutExpired('ip', 10)
                    present[0] = False
                if args == ('ip', '-j', 'addr'):
                    return '[]'
                if args[:4] == ('ip', '-j', 'link', 'show'):
                    return '[{"mtu": 1500}]'
                if args[:2] == ('ip', '-j'):
                    return '[]'
                if args == ('nft', '-j', 'list', 'tables'):
                    return '{"nftables": []}'
                if args[:2] == ('sysctl', '-n'):
                    return '1'
                return ''
            process = Mock()
            process.poll.return_value = None
            with patch.object(clat, 'command', side_effect=command), patch.object(clat.socket, 'if_nameindex', side_effect=lambda: [(3, 'wan1')] + ([(4, 'clat3')] if present[0] else [])), patch.object(clat, 'discover', return_value='64:ff9b::/96'), patch.object(clat.subprocess, 'Popen', return_value=process), patch.object(clat.time, 'sleep'):
                controller.sync({'wan1': signature})
                self.assertIn('wan1', controller.links)
                self.assertTrue(link.stopping)
                self.assertEqual(json.loads((clat.RUN/'3.cleanup').read_text()), [undo])
                controller.sync({'wan1': signature})
                self.assertIn('wan1', controller.links)
                self.assertEqual(len(attempts), 2)
                self.assertEqual(json.loads((clat.RUN/'3.json').read_text())['state'], 'up')
                # The new link has replaced the replayed journal with its own undo.
                self.assertGreater(len(json.loads((clat.RUN/'3.cleanup').read_text())), 1)

    def test_failed_replay_preserves_journal_before_setup(self):
        from unittest.mock import patch
        import subprocess
        import tempfile
        for error in (subprocess.TimeoutExpired('ip', 10), subprocess.CalledProcessError(2, 'ip'), OSError('ip unavailable')):
            with self.subTest(error=type(error).__name__), tempfile.TemporaryDirectory() as directory, patch.object(clat, 'RUN', pathlib.Path(directory)), patch.object(clat.socket, 'if_nametoindex', return_value=3):
                journal = clat.RUN/'3.cleanup'
                undo = [['ip', 'link', 'del', 'clat3']]
                journal.write_text(json.dumps(undo))
                with patch.object(clat, 'command', side_effect=error), patch.object(clat, 'discover') as discover:
                    link = clat.Link('wan1', '2001:db8::1', '', ())
                    link.start()
                discover.assert_not_called()
                self.assertFalse(link.undo)
                self.assertEqual(json.loads(journal.read_text()), undo)
                self.assertEqual(json.loads((clat.RUN/'3.json').read_text())['state'], 'error')

    def test_replay_keeps_only_failed_undo_in_original_order(self):
        from unittest.mock import patch
        import subprocess
        import tempfile
        with tempfile.TemporaryDirectory() as directory, patch.object(clat, 'RUN', pathlib.Path(directory)), patch.object(clat.socket, 'if_nametoindex', return_value=3):
            journal = clat.RUN/'3.cleanup'
            undo = [['first'], ['second'], ['third']]
            journal.write_text(json.dumps(undo))
            errors = [subprocess.TimeoutExpired('third', 10), '', subprocess.CalledProcessError(2, 'first')]
            with patch.object(clat, 'command', side_effect=errors) as command, patch.object(clat, 'discover') as discover:
                link = clat.Link('wan1', '2001:db8::1', '', ())
                link.start()
            self.assertEqual([call.args for call in command.call_args_list], [('third',), ('second',), ('first',)])
            self.assertEqual(json.loads(journal.read_text()), [undo[0], undo[2]])
            self.assertFalse(link.undo)
            discover.assert_not_called()

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

def consumer_accepts(address):
    # Mirrors the CeraUI snapshot parser's service-space rule.
    a, b, c, d = map(int, address.split('.'))
    return a == 10 and b == 254 and c < 32 and d != 0


class ServiceAddress(Isolated):
    def test_producer_snapshots_at_block_edges_are_consumer_valid(self):
        from unittest.mock import patch
        expected = {1: '10.254.0.1', 3: '10.254.0.3', 254: '10.254.0.254', 255: '10.254.0.255',
                    256: '10.254.1.1', 257: '10.254.1.2', 510: '10.254.1.255',
                    511: '10.254.2.1', 512: '10.254.2.2', 8160: '10.254.31.255'}
        for index, address in expected.items():
            with self.subTest(index=index), patch.object(clat.socket, 'if_nametoindex', return_value=index):
                clat.Link('wan1', '2001:db8::1', '', ()).status('starting')
                snapshot = json.loads((clat.RUN/f'{index}.json').read_text())
                self.assertEqual(snapshot['ipv4'], address)
                self.assertTrue(consumer_accepts(snapshot['ipv4']))

    def test_allocation_is_unique_and_bounded(self):
        from unittest.mock import patch
        addresses = [clat.service_ipv4(index) for index in range(1, clat.MAX_INDEX + 1)]
        self.assertEqual(len(set(addresses)), len(addresses))
        self.assertTrue(all(consumer_accepts(address) for address in addresses))
        for index in (0, clat.MAX_INDEX + 1):
            with self.subTest(index=index), patch.object(clat.socket, 'if_nametoindex', return_value=index):
                with self.assertRaises(ValueError):
                    clat.Link('wan1', '2001:db8::1', '', ())


class LifecycleV2(Isolated):
    def make_link(self):
        from unittest.mock import Mock
        link = clat.Link('wan1', '2001:db8::1', '', ())
        link.prefix = '64:ff9b::/96'
        link.tun_index = 4
        link.process = Mock()
        link.process.poll.return_value = None
        return link

    def read(self):
        return json.loads((clat.RUN/'3.json').read_text())

    def test_nonzero_delete_retained_in_both_cleanup_entrypoints(self):
        from unittest.mock import patch
        import subprocess
        for mode in ('stop', 'cleanup'):
            with self.subTest(mode=mode):
                link = self.make_link()
                link.undo = [['nft', 'delete', 'table', 'inet', link.nft]]
                link.save_cleanup()
                link.status('up')
                def run(args, **kwargs):
                    code = 1 if args[:2] == ('nft', 'delete') else 0
                    stdout = json.dumps({'nftables': [{'table': {'family': 'inet', 'name': link.nft}}]})
                    if code and kwargs['check']:
                        raise subprocess.CalledProcessError(code, args)
                    return subprocess.CompletedProcess(args, code, stdout=stdout)
                # Exercise the real command helper's check/nonzero behavior.
                with patch.object(clat.subprocess, 'run', side_effect=run), patch.object(clat, 'restore_forwarding') as restore:
                    self.assertFalse(link.stop() if mode == 'stop' else clat.cleanup())
                    self.assertEqual(self.read()['state'], 'error')
                    self.assertEqual(json.loads((clat.RUN/'3.cleanup').read_text()), link.undo)
                    if mode == 'cleanup':
                        self.assertFalse(clat.cleanup())
                    restore.assert_not_called()
                with patch.object(clat, 'command', return_value=''):
                    self.assertTrue(link.stop() if mode == 'stop' else clat.cleanup())
                self.assertFalse((clat.RUN/'3.cleanup').exists())
                self.assertEqual(self.read()['state'], 'down')

    def test_absent_resources_settle_but_failed_existence_query_does_not(self):
        from unittest.mock import patch
        import subprocess
        cases = [(['nft','delete','table','inet','clat_3'], '{"nftables":[]}'),
                 (['ip','link','del','clat3'], '[]'),
                 (['ip','-4','rule','del','priority','10003','from','10.254.0.3','lookup','46003'], '[]'),
                 (['ip','-6','route','del','fd46:4:4::3/128','dev','clat3'], '[]'),
                 (['ip','-4','route','flush','table','46003'], '[]')]
        for undo, absent in cases:
            for query in (absent, subprocess.CalledProcessError(1, 'query')):
                with self.subTest(undo=undo, query=query):
                    journal = clat.RUN/'3.cleanup'
                    journal.write_text(json.dumps([undo]))
                    with patch.object(clat, 'command', side_effect=[subprocess.CalledProcessError(2, undo), query]):
                        pending = clat.replay(journal)
                    self.assertEqual(bool(pending), isinstance(query, Exception))
                    self.assertEqual(journal.exists(), isinstance(query, Exception))

    def test_failed_delete_does_not_misread_present_route_as_absent(self):
        from unittest.mock import patch
        import subprocess
        cases = [(['ip','-6','route','del','fd46:4:4::3/128','dev','clat3'],
                  [{'dst':'default','dev':'wan1'}, {'dst':'fd46:4:4::3','dev':'clat3'}]),
                 (['ip','-4','route','del','default','dev','clat3','metric','46003'],
                  [{'dst':'default','dev':'clat3','metric':46003}])]
        for undo, routes in cases:
            with self.subTest(undo=undo):
                journal = clat.RUN/'3.cleanup'; journal.write_text(json.dumps([undo]))
                with patch.object(clat, 'command', side_effect=[subprocess.CalledProcessError(2,undo), json.dumps(routes)]):
                    self.assertEqual(clat.replay(journal), [undo])
                self.assertEqual(json.loads(journal.read_text()), [undo])

    def test_child_stop_failure_preserves_all_inverses(self):
        from unittest.mock import patch
        import subprocess
        link = self.make_link(); link.undo = [['remove']]; link.save_cleanup()
        link.process.wait.side_effect = subprocess.TimeoutExpired('tayga',3)
        with patch.object(clat, 'command') as run:
            self.assertFalse(link.stop())
        run.assert_not_called()
        self.assertEqual(json.loads((clat.RUN/'3.cleanup').read_text()), [['remove']])
        self.assertEqual(self.read()['state'], 'error')

    def test_timeout_continues_replay_and_retains_order(self):
        from unittest.mock import patch
        import subprocess
        link = self.make_link()
        link.undo = [['first'], ['second'], ['third']]
        link.save_cleanup()
        with patch.object(clat, 'command', side_effect=[subprocess.TimeoutExpired('third',10), '', subprocess.CalledProcessError(1,'first')]) as run:
            self.assertFalse(link.stop())
        self.assertEqual([c.args for c in run.call_args_list], [('third',), ('second',), ('first',)])
        self.assertEqual(json.loads((clat.RUN/'3.cleanup').read_text()), [['first'], ['third']])
        self.assertEqual(self.read()['state'], 'error')

    def test_crash_during_teardown_invalidates_before_kill_and_replays(self):
        from unittest.mock import patch
        link = self.make_link()
        link.undo = [['first'], ['second']]
        link.save_cleanup(); link.status('up')
        def crash(*args):
            self.assertEqual(self.read()['state'], 'unavailable')
            self.assertEqual(self.read()['expires_at'], self.read()['observed_at'])
            raise SystemExit('crash during teardown')
        link.process.terminate.side_effect = crash
        with self.assertRaises(SystemExit): link.stop()
        self.assertTrue((clat.RUN/'3.cleanup').exists())
        # A fresh process/invocation replays the full inverse after a crash.
        with patch.object(clat, 'command', return_value='') as run:
            self.assertTrue(clat.cleanup())
        self.assertEqual([c.args for c in run.call_args_list], [('second',), ('first',)])
        self.assertEqual(self.read()['state'], 'down')

    def test_cleanup_crash_and_retry_does_not_renew_up(self):
        from unittest.mock import patch
        link = self.make_link()
        link.undo = [['remove']]; link.save_cleanup(); link.status('up')
        with patch.object(clat, 'command', side_effect=SystemExit('crash')):
            with self.assertRaises(SystemExit): clat.cleanup()
        self.assertEqual(self.read()['state'], 'unavailable')
        with patch.object(clat, 'command', return_value=''), patch.object(clat, 'boot_time', return_value=900):
            self.assertTrue(clat.cleanup())
        self.assertEqual(self.read()['observed_at'], 900)
        self.assertEqual(self.read()['expires_at'], 900)

    def test_delayed_stale_and_future_observations_fail_closed(self):
        from unittest.mock import patch
        link = self.make_link()
        for observed, now, expected in [(100,100,'up'), (100,129,'up'), (100,130,'unavailable'),
                                         (100,1000,'unavailable'), (101,100,'unavailable')]:
            with self.subTest(observed=observed, now=now), patch.object(clat, 'boot_time', return_value=now):
                link.observed_at = observed
                link.status('up')
                data = self.read()
                self.assertEqual(data['state'], expected)
                self.assertEqual(data['expires_at'], observed+30 if expected=='up' else now)
        # Wall-clock jumps cannot create or prolong a monotonic lease.
        link.observed_at = 100
        for wall in (-1000, 999999999999):
            with patch.object(clat, 'boot_time', return_value=131), patch.object(clat.time, 'time', return_value=wall):
                link.status('up')
                self.assertEqual(self.read()['state'], 'unavailable')

    def test_dead_child_with_live_controller_never_gets_up_heartbeat(self):
        from unittest.mock import patch
        link = self.make_link()
        link.process.poll.return_value = 1
        link.status('up')
        self.assertEqual(self.read()['state'], 'unavailable')
        signature = ('2001:db8::1', '', ())
        controller = clat.Controller(); controller.links['wan1'] = (signature, link)
        with patch.object(link, 'stop', return_value=False) as stop, patch.object(link, 'repair_routes') as repair:
            controller.sync({})
        stop.assert_called_once(); repair.assert_not_called()

    def test_reused_index_new_activation_and_invocation_have_distinct_tokens(self):
        from unittest.mock import patch
        one = self.make_link(); one.status('up'); old = self.read()
        with patch.object(clat, 'INVOCATION_ID', 'b'*32):
            two = self.make_link(); two.status('up'); new = self.read()
        self.assertEqual(new['ifindex'], old['ifindex'])
        self.assertNotEqual(new['generation'], old['generation'])
        self.assertNotEqual(new['invocation_id'], old['invocation_id'])
        self.assertEqual(new['boot_id'], clat.BOOT_ID)
        self.assertEqual(new['tun_ifindex'], 4)
        self.assertEqual(new['schema_version'], 2)
        # Reusing the same name/index with a new NM activation withdraws first.
        controller = clat.Controller()
        controller.links['wan1'] = (('a','b',(),'old-activation'), one)
        def refuse():
            one.stopping = True
            return False
        with patch.object(one, 'stop', side_effect=refuse) as stop, patch.object(one, 'repair_routes') as repair, patch.object(clat, 'Link') as create:
            controller.sync({'wan1': ('a','b',(),'new-activation')})
        stop.assert_called_once(); create.assert_not_called(); repair.assert_not_called()

    def test_delayed_grant_collection_cannot_renew_the_lease(self):
        from unittest.mock import patch
        link = self.make_link()
        link.refreshed = clat.time.monotonic()
        signature = ('2001:db8::1', '', ())
        controller = clat.Controller(); controller.links['wan1'] = (signature, link)
        with patch.object(clat, 'boot_time', return_value=200), patch.object(link, 'repair_routes'):
            controller.sync({'wan1': signature}, observed_at=100)
        self.assertEqual(self.read()['state'], 'unavailable')
        self.assertEqual(self.read()['expires_at'], 200)

    def test_changed_kernel_ifindex_with_unchanged_grant_withdraws(self):
        from unittest.mock import patch
        link = self.make_link()
        signature = ('2001:db8::1', '', ())
        controller = clat.Controller(); controller.links['wan1'] = (signature, link)
        def refuse():
            link.stopping = True
            return False
        with patch.object(clat.socket, 'if_nametoindex', return_value=9), patch.object(link, 'stop', side_effect=refuse) as stop, patch.object(link, 'repair_routes') as repair:
            controller.sync({'wan1': signature})
        stop.assert_called_once(); repair.assert_not_called()

    def test_pending_old_name_blocks_new_name_with_reused_index(self):
        from unittest.mock import patch
        link = self.make_link(); link.stopping = True
        controller = clat.Controller(); controller.links['wan1'] = (('old',), link)
        replacement = self.make_link()
        with patch.object(link, 'stop', return_value=False), patch.object(clat, 'Link', return_value=replacement), patch.object(replacement, 'start') as start:
            controller.sync({'wan2': ('2001:db8::1', '', ())})
        start.assert_not_called()

    def test_setup_attempt_rotates_generation_even_on_same_object(self):
        from unittest.mock import patch
        link = self.make_link()
        first = link.generation
        with patch.object(clat, 'discover', side_effect=ValueError('no DNS64')):
            link.start()
            second = link.generation
            link.start()
        self.assertNotEqual(first, second)
        self.assertNotEqual(second, link.generation)

    def test_forwarding_restore_failure_stays_error_until_settled(self):
        from unittest.mock import patch
        link = self.make_link(); link.status('up')
        with patch.object(clat, 'restore_forwarding', side_effect=OSError('sysctl refused')):
            self.assertFalse(clat.cleanup())
            self.assertEqual(self.read()['state'], 'error')
        with patch.object(clat, 'restore_forwarding'):
            self.assertTrue(clat.cleanup())
        self.assertEqual(self.read()['state'], 'down')

    def test_snapshot_is_atomic_and_failed_replace_keeps_old_snapshot(self):
        from unittest.mock import patch
        link = self.make_link(); link.status('up'); old = (clat.RUN/'3.json').read_text()
        def replace(temp, target):
            self.assertEqual((clat.RUN/'3.json').read_text(), old)
            self.assertEqual(json.loads(temp.read_text())['state'], 'unavailable')
            raise OSError('rename failed')
        with patch.object(pathlib.Path, 'replace', replace):
            self.assertFalse(link.stop())
        self.assertEqual((clat.RUN/'3.json').read_text(), old)
        self.assertTrue(link.stopping)

if __name__ == '__main__': unittest.main()

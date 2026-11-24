import importlib.util
import json
import sys
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

class FakeHost:
    """Answers the controller's commands like an empty kernel and records their order."""
    def __init__(self, mtu=1500, forwarding='0', fail=None):
        self.calls, self.mtu, self.forwarding, self.fail = [], mtu, forwarding, fail
        self.tables, self.processes = set(), []

    def __call__(self, *args, check=True, data=None):
        import re
        args = list(args)
        self.calls.append((args, data))
        if self.fail:
            error = self.fail(args, data)
            if error:
                raise error
        if args == ['ip', '-j', 'addr']:
            return '[]'
        if args[:4] == ['ip', '-j', 'link', 'show']:
            return json.dumps([{'mtu': self.mtu}])
        if args[:2] == ['ip', '-j']:
            return '[]'
        if args == ['nft', '-j', 'list', 'tables']:
            return json.dumps({'nftables': [{'table': {'family': 'inet', 'name': n}} for n in sorted(self.tables)]})
        if args[:2] in (['nft', 'create'], ['nft', 'add']) and args[2] == 'table':
            self.tables.add(args[4])
        if args[:3] == ['nft', 'delete', 'table']:
            self.tables.discard(args[4])
        if args[:2] == ['nft', '-f'] and data:
            self.tables.update(re.findall(r'^(?:create|add) table inet (\S+)', data, re.M))
        if args == ['sysctl', '-n', 'net.ipv6.conf.all.forwarding']:
            return self.forwarding
        return ''

    def set_forwarding(self, value):
        self.calls.append((['set_forwarding', value], None))
        if self.fail:
            error = self.fail(['set_forwarding', value], None)
            if error:
                raise error
        self.forwarding = value

    def popen(self, *args, **kwargs):
        from unittest.mock import Mock
        process = Mock()
        process.poll.return_value = None
        self.processes.append(process)
        return process

    def patched(self, prefix='64:ff9b::/96'):
        from contextlib import ExitStack
        from unittest.mock import patch
        stack = ExitStack()
        stack.enter_context(patch.object(clat, 'command', side_effect=self))
        stack.enter_context(patch.object(clat, 'set_forwarding', side_effect=self.set_forwarding))
        stack.enter_context(patch.object(clat, 'discover', return_value=prefix))
        stack.enter_context(patch.object(clat.subprocess, 'Popen', side_effect=self.popen))
        stack.enter_context(patch.object(clat.socket, 'if_nameindex', return_value=[(3, 'wan1')]))
        stack.enter_context(patch.object(clat.time, 'sleep'))
        return stack

    def index(self, predicate):
        return next(i for i, (args, data) in enumerate(self.calls) if predicate(args, data))

    def commands(self):
        return [args for args, _ in self.calls]


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
        # Never ask the host's own NetworkManager.
        patcher = patch.object(clat, 'ipv6_sharing', return_value=False)
        self.sharing = patcher.start(); self.addCleanup(patcher.stop)

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

    def test_discovery_failure_survives_cleanup_and_warns_on_transitions(self):
        from contextlib import redirect_stderr
        from io import StringIO
        from unittest.mock import patch

        host = FakeHost()
        controller = clat.Controller()
        wanted = {'wan1': ('2001:db8::1', '2001:db8::2', ('2001:db8::53',))}
        log = StringIO()
        snapshot = clat.RUN / '3.json'
        with host.patched(), redirect_stderr(log), patch.object(clat, 'discover') as discover:
            for reason in ('dns64-unreachable', 'dns64-unreachable', 'no-nat64-prefix'):
                discover.side_effect = clat.DiscoveryError(reason)
                controller.sync(wanted, sharing=False)
                status = json.loads(snapshot.read_text())
                self.assertEqual((status['state'], status['last_error']), ('down', reason))
                self.assertEqual(status['expires_at'], status['observed_at'])
                self.assertFalse(controller.links)
                self.assertFalse(host.processes)
                self.assertFalse(host.tables)
                self.assertFalse((clat.RUN / '3.cleanup').exists())
            self.assertEqual(log.getvalue().splitlines(), [
                '<4>CLAT wan1 DNS64 discovery failed: dns64-unreachable',
                '<4>CLAT wan1 DNS64 discovery failed: no-nat64-prefix',
            ])
            controller.sync({}, sharing=False)
            self.assertIsNone(json.loads(snapshot.read_text())['last_error'])
            controller.sync(wanted, sharing=False)
            self.assertEqual(log.getvalue().count('no-nat64-prefix'), 2)
            discover.side_effect = None
            discover.return_value = '64:ff9b::/96'
            controller.sync(wanted, sharing=False)
            status = json.loads(snapshot.read_text())
            self.assertEqual((status['state'], status['last_error']), ('up', None))

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

    def test_revalidation_diagnostic_survives_heartbeats_and_withdrawal(self):
        from contextlib import redirect_stderr
        from io import StringIO
        from unittest.mock import patch

        host = FakeHost()
        controller = clat.Controller()
        wanted = {'wan1': ('2001:db8::1', '2001:db8::2', ('2001:db8::53',))}
        log = StringIO()
        snapshot = clat.RUN / '3.json'
        with host.patched(), redirect_stderr(log), patch.object(clat.time, 'monotonic') as clock:
            clock.return_value = 0
            controller.sync(wanted, sharing=False)
            error = clat.DiscoveryError('dns64-unreachable')
            with patch.object(clat, 'discover', side_effect=error):
                for tick in (61, 71, 122):
                    clock.return_value = tick
                    controller.sync(wanted, sharing=False)
                    status = json.loads(snapshot.read_text())
                    self.assertEqual((status['state'], status['last_error']), ('up', str(error)))
                clock.return_value = 183
                controller.sync(wanted, sharing=False)
                self.assertFalse(controller.links)
                controller.sync(wanted, sharing=False)
                status = json.loads(snapshot.read_text())
                self.assertEqual((status['state'], status['last_error']), ('down', str(error)))
            self.assertEqual(log.getvalue().count('DNS64 discovery failed:'), 1)

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

def advertisement(lifetime=1800, preference=0b00):
    return bytes([134, 0, 0, 0, 64, preference << 3]) + lifetime.to_bytes(2, 'big') + bytes(8)


class NeverDefault(Isolated):
    """A profile with ipv6.never-default: NetworkManager publishes no gateway
    and no main-table default; the router is known only from its RAs."""
    def answers(self, default=(), neighbours=(), flags=('BROADCAST', 'MULTICAST', 'UP', 'LOWER_UP')):
        calls = []
        def command(*args, **kwargs):
            calls.append(list(args))
            if args[:5] == ('ip', '-j', '-6', 'route', 'show'):
                return json.dumps(list(default))
            if args[:5] == ('ip', '-j', '-6', 'neigh', 'show'):
                return json.dumps(list(neighbours))
            if args[:4] == ('ip', '-j', 'link', 'show'):
                return json.dumps([{'ifname': 'wan1', 'flags': list(flags)}])
            raise AssertionError(args)
        return command, calls

    def watch(self):
        from unittest.mock import Mock
        return clat.RouterWatch(sock=Mock())

    def router(self, gateway='', watch=None, **answers):
        from unittest.mock import patch
        command, calls = self.answers(**answers)
        with patch.object(clat, 'command', side_effect=command):
            router, origin = clat.link_router('wan1', gateway, watch)
        return router, calls, origin

    def test_router_sources_in_order(self):
        self.assertEqual(self.router('2001:DB8::1'), ('2001:db8::1', [], 'NetworkManager gateway'))
        self.assertEqual(self.router(default=[{'dst': 'default', 'gateway': 'fe80::1', 'dev': 'wan1'}])[::2],
                         ('fe80::1', 'main-table default'))
        self.assertEqual(self.router(default=[{'dst': 'default', 'dev': 'wan1'}])[::2], ('', 'main-table default'))
        # Raw-IP links need no next hop, whatever RAs say.
        watch = self.watch(); watch.record(3, 'fe80::1', 255, advertisement())
        self.assertEqual(self.router(flags=('POINTOPOINT', 'NOARP', 'UP', 'LOWER_UP'), watch=watch)[::2],
                         ('', 'ARP-less link'))
        # The measured never-default grant: only the RA names the router.
        self.assertEqual(self.router(watch=watch)[::2], ('fe80::1', 'router advertisement'))
        self.assertEqual(self.router()[::2], (None, 'none'))

    def test_kernel_router_bit_without_a_valid_advertisement_is_no_router(self):
        """Linux keeps a neighbour's router bit after a lifetime-0 RA (also with
        accept_ra=0); that bit alone must never admit the link."""
        stale = [{'dst': 'fe80::b46d:57ff:fe45:4545', 'lladdr': '02:00:00:00:00:01', 'router': None, 'state': ['STALE']}]
        watch = self.watch()
        self.assertEqual(self.router(neighbours=stale, watch=watch)[::2], (None, 'none'))
        watch.record(3, 'fe80::b46d:57ff:fe45:4545', 255, advertisement())
        self.assertEqual(self.router(neighbours=stale, watch=watch)[0], 'fe80::b46d:57ff:fe45:4545')
        watch.record(3, 'fe80::b46d:57ff:fe45:4545', 255, advertisement(lifetime=0))
        self.assertEqual(self.router(neighbours=stale, watch=watch)[::2], (None, 'none'))

    def test_router_lifetime_preference_and_replacement(self):
        watch = self.watch()
        self.assertTrue(watch.record(3, 'fe80::9', 255, advertisement(lifetime=100), now=0))
        self.assertFalse(watch.record(3, 'fe80::9', 255, advertisement(lifetime=100), now=50))
        self.assertEqual(watch.router(3, now=120), 'fe80::9')  # refreshed at 50, valid to 150
        self.assertIsNone(watch.router(3, now=151))
        # Preference (RFC 4191) beats address order; reserved counts as medium.
        watch.record(3, 'fe80::1', 255, advertisement(preference=0b11), now=0)
        watch.record(3, 'fe80::5', 255, advertisement(preference=0b10), now=0)
        self.assertEqual(watch.router(3, now=1), 'fe80::5')
        watch.record(3, 'fe80::7', 255, advertisement(preference=0b01), now=0)
        self.assertEqual(watch.router(3, now=1), 'fe80::7')
        # A router that failed reachability yields to a working one.
        self.assertEqual(watch.router(3, failed={'fe80::7'}, now=1), 'fe80::5')
        # A replacement after the old router withdraws.
        watch.record(3, 'fe80::7', 255, advertisement(lifetime=0), now=2)
        watch.record(3, 'fe80::5', 255, advertisement(lifetime=0), now=2)
        watch.record(3, 'fe80::1', 255, advertisement(lifetime=0), now=2)
        watch.record(3, 'fe80::2', 255, advertisement(), now=3)
        self.assertEqual(watch.router(3, now=4), 'fe80::2')
        self.assertIsNone(watch.router(4, now=4))

    def test_only_valid_advertisements_count(self):
        watch = self.watch()
        for source, hops, data in [('fe80::1', 254, advertisement()), ('2001:db8::1', 255, advertisement()),
                                   ('fe80::1', 255, advertisement()[:15]), ('fe80::1', 255, bytes([133]) + advertisement()[1:]),
                                   ('not-an-address', 255, advertisement())]:
            with self.subTest(source=source, hops=hops):
                self.assertFalse(watch.record(3, source, hops, data))
        self.assertIsNone(watch.router(3))

    def test_solicitation_spacing(self):
        watch = self.watch()
        sent = [t for t in range(0, 700, 2) if watch.solicit(3, now=t)]
        self.assertEqual(sent[:4], [0, 4, 8, 308])
        self.assertTrue(all(b - a >= 300 for a, b in zip(sent[3:], sent[4:])))
        watch.sock.sendto.assert_called_with(bytes([133, 0, 0, 0, 0, 0, 0, 0]), ('ff02::2', 0, 0, 3))
        # An RA ends the solicitation series.
        watch.record(3, 'fe80::1', 255, advertisement(), now=701)
        self.assertNotIn(3, watch.solicited)

    def test_admission_of_a_never_default_grant(self):
        """The service admits an IPv6-only link without a published gateway
        once an RA named its router, and logs each router change once."""
        from contextlib import redirect_stderr
        from io import StringIO
        from unittest.mock import patch
        import socket
        v6 = [dict(family='inet6', scope='global', local='2001:db8::1')]
        config = {'Gateway': '', 'Nameservers': [list(socket.inet_pton(socket.AF_INET6, 'fd00:976a::9'))]}
        watch = self.watch()
        command, _ = self.answers()
        log = StringIO()
        with patch.object(clat, 'command', side_effect=command), patch.dict(clat.ROUTER_NOTES, clear=True), \
                redirect_stderr(log):
            self.assertIsNone(clat.grant('wan1', v6, config, watch))
            self.assertIsNone(clat.grant('wan1', v6, config, watch))
            watch.sock.sendto.assert_called_once()
            watch.record(3, 'fe80::b46d:57ff:fe45:4545', 255, advertisement())
            self.assertEqual(clat.grant('wan1', v6, config, watch),
                             ('2001:db8::1', 'fe80::b46d:57ff:fe45:4545', ('fd00:976a::9',)))
            self.assertEqual(clat.grant('wan1', v6, config, watch)[1], 'fe80::b46d:57ff:fe45:4545')
            # Native IPv4 excludes the link before any router lookup.
            self.assertIsNone(clat.grant('wan1', v6 + [dict(family='inet', scope='global', local='192.0.2.1')],
                                         config, watch))
        self.assertEqual(log.getvalue().splitlines(), [
            '<4>CLAT wan1 has no known IPv6 router yet; not translated',
            '<6>CLAT wan1 IPv6 router fe80::b46d:57ff:fe45:4545 from router advertisement',
        ])

    RULE = ['priority', '46003', 'fwmark', '0xc1a70003', 'lookup', '46003']

    def test_discovery_uses_the_links_own_table_and_is_withdrawn_on_failure(self):
        from unittest.mock import patch
        host = FakeHost()
        route = ['ip', '-6', 'route', 'add', 'table', '46003', 'default', 'via', 'fe80::1', 'onlink', 'dev', 'wan1']
        rule = ['ip', '-6', 'rule', 'add'] + self.RULE
        seen = []
        def discover(interface, source, resolvers):
            seen.append(host.commands())
            raise clat.DiscoveryError('no-nat64-prefix')
        with host.patched(), patch.object(clat, 'discover', side_effect=discover):
            link = clat.Link('wan1', '2001:db8::1', 'fe80::1', ('fd00:976a::9',))
            self.assertEqual(link.start(), 'no-nat64-prefix')
        self.assertLess(seen[0].index(route), seen[0].index(rule))
        self.assertFalse(any(args[:3] == ['ip', '-6', 'route'] and 'table' not in args for args in host.commands()),
                         'never the main table')
        after = host.commands()[len(seen[0]):]
        self.assertLess(after.index(['ip', '-6', 'rule', 'del'] + self.RULE),
                        after.index(['ip', '-6', 'route', 'flush', 'table', '46003']))
        self.assertFalse(link.undo)
        self.assertFalse((clat.RUN/'3.cleanup').exists())
        self.assertFalse(host.processes)
        self.assertNotIn(['sysctl', '-n', 'net.ipv6.conf.all.forwarding'], host.commands())
        status = json.loads((clat.RUN/'3.json').read_text())
        self.assertEqual((status['state'], status['last_error']), ('down', 'no-nat64-prefix'))

    def test_translating_link_keeps_the_discovery_route_until_stop(self):
        host = FakeHost()
        with host.patched():
            link = clat.Link('wan1', '2001:db8::1', '', ('fd00:976a::9',))
            link.start()
            journal = json.loads((clat.RUN/'3.cleanup').read_text())
            self.assertEqual(journal[:2], [['ip', '-6', 'route', 'flush', 'table', '46003'],
                                           ['ip', '-6', 'rule', 'del'] + self.RULE])
            self.assertEqual(json.loads((clat.RUN/'3.json').read_text())['state'], 'up')
            self.assertIn(['ip', '-6', 'route', 'add', 'table', '46003', 'default', 'dev', 'wan1'], host.commands())
            self.assertTrue(link.stop())
        self.assertEqual(host.commands()[-2:], [journal[1], journal[0]])

    def test_discovery_socket_carries_the_links_mark(self):
        """Only the marked discovery socket may use the link table; a plain
        device-bound socket keeps the main table."""
        from unittest.mock import MagicMock, patch
        import socket
        try:
            import dns.message  # noqa: F401
        except ImportError:
            self.skipTest('dnspython not installed')
        sock = MagicMock()
        sock.__enter__.return_value = sock
        sock.connect.side_effect = OSError('unreachable')
        with patch.object(clat.socket, 'socket', return_value=sock):
            with self.assertRaises(clat.DiscoveryError):
                clat.discover('wan1', '2001:db8::1', ('fd00:976a::9',))
        sock.setsockopt.assert_any_call(socket.SOL_SOCKET, socket.SO_MARK, (0xc1a70003).to_bytes(4, sys.byteorder))
        self.assertEqual(clat.Link('wan1', '2001:db8::1', '', ()).mark, '0xc1a70003')

    def test_foreign_discovery_priority_or_table_reference_is_refused(self):
        from unittest.mock import patch
        for rule in ({'priority': 46003, 'src': 'all', 'table': 'main'},
                     {'priority': 200, 'src': 'all', 'table': '46003'}):
            with self.subTest(rule=rule):
                host = FakeHost()
                def command(*args, **kwargs):
                    if list(args) == ['ip', '-j', '-6', 'rule']:
                        return json.dumps([rule])
                    return host(*args, **kwargs)
                with host.patched(), patch.object(clat, 'command', side_effect=command), \
                        patch.object(clat, 'discover') as discover:
                    link = clat.Link('wan1', '2001:db8::1', '', ('fd00:976a::9',))
                    link.start()
                discover.assert_not_called()
                self.assertFalse(link.undo)
                self.assertEqual(json.loads((clat.RUN/'3.json').read_text())['state'], 'error')

    def test_failed_starting_write_withdraws_the_discovery_route(self):
        from unittest.mock import patch
        host = FakeHost()
        real = clat.Link.status
        def status(link, state, error=None):
            return False if state == 'starting' else real(link, state, error)
        with host.patched(), patch.object(clat.Link, 'status', status):
            link = clat.Link('wan1', '2001:db8::1', 'fe80::1', ('fd00:976a::9',))
            link.start()
        commands = host.commands()
        self.assertIn(['ip', '-6', 'rule', 'del'] + self.RULE, commands)
        self.assertIn(['ip', '-6', 'route', 'flush', 'table', '46003'], commands)
        self.assertNotIn(['sysctl', '-n', 'net.ipv6.conf.all.forwarding'], commands)
        self.assertFalse(link.undo)
        self.assertFalse((clat.RUN/'3.cleanup').exists())
        self.assertEqual(json.loads((clat.RUN/'3.json').read_text())['state'], 'error')


class MinimumMtu(Isolated):
    def start(self, mtu):
        host = FakeHost(mtu=mtu)
        with host.patched():
            link = clat.Link('wan1', '2001:db8::1', '', ('2001:db8::53',))
            link.start()
        return host, link, json.loads((clat.RUN/'3.json').read_text())

    def test_ipv6_minimum_link_mtu_translates_at_1260(self):
        host, link, snapshot = self.start(1280)
        self.assertEqual(snapshot['state'], 'up', snapshot)
        self.assertEqual(link.ipv4_mtu, 1260)
        self.assertIn(['ip', 'link', 'set', link.tun, 'mtu', '1280'], host.commands())
        routes = [args for args in host.commands() if args[:2] == ['ip', '-4'] and 'route' in args and 'add' in args]
        self.assertEqual(len(routes), 2)
        for route in routes:
            self.assertEqual(route[route.index('mtu') + 1], '1260')
        ruleset = next(data for args, data in host.calls if args[:2] == ['nft', '-f'] and 'maxseg' in data)
        self.assertEqual(ruleset.count('tcp option maxseg size set 1220'), 3)
        self.assertEqual(len(host.processes), 1)

    def test_link_below_ipv6_minimum_fails_closed(self):
        host, link, snapshot = self.start(1279)
        self.assertEqual(snapshot['state'], 'error')
        self.assertIn('1280', snapshot['last_error'])
        self.assertFalse(link.undo)
        self.assertFalse(host.processes)


class ActivationIsolation(Isolated):
    def test_renumbered_source_gets_a_fresh_private_mapping(self):
        import ipaddress
        old = clat.Link('wan1', '2001:db8::1', '', ())
        same = clat.Link('wan1', '2001:db8::1', '', ())
        new = clat.Link('wan1', '2001:db8::2', '', ())
        self.assertEqual(old.v6, same.v6)
        self.assertNotEqual(old.v6, new.v6)
        for link in (old, new):
            address = ipaddress.IPv6Address(link.v6)
            self.assertIn(address, ipaddress.IPv6Network('fd46:4:4::/48'))
            self.assertEqual(int(address) & 0xffffffff, 3)
        self.assertEqual(old.v4, new.v4)

    def test_renumber_through_controller_uses_the_new_mapping_everywhere(self):
        host = FakeHost(forwarding='1')
        controller = clat.Controller()
        with host.patched():
            controller.sync({'wan1': ('2001:db8::1', '', ('2001:db8::53',))})
            old = controller.links['wan1'][1]
            start = len(host.calls)
            controller.sync({'wan1': ('2001:db8::2', '', ('2001:db8::53',))})
            new = controller.links['wan1'][1]
        self.assertIsNot(old, new)
        self.assertNotEqual(old.v6, new.v6)
        later = host.calls[start:]
        self.assertIn(['ip', '-6', 'rule', 'del', 'priority', old.priority, 'from', old.v6, 'lookup', old.table],
                      [args for args, _ in later])
        self.assertIn(['ip', '-6', 'rule', 'add', 'priority', new.priority, 'from', new.v6, 'lookup', new.table],
                      [args for args, _ in later])
        ruleset = next(data for args, data in later if args[:2] == ['nft', '-f'] and 'snat ip6' in data)
        self.assertIn(f'ip6 saddr {new.v6} snat ip6 to 2001:db8::2', ruleset)
        self.assertNotIn(old.v6, ruleset)
        self.assertIn(f'map {new.v4} {new.v6}', (clat.RUN/'3.conf').read_text())


GRANT = {'wan1': ('2001:db8::1', '', ('2001:db8::53',))}


def is_guard(args, data):
    return args[:2] == ['nft', '-f'] and f'create table inet {clat.GUARD}' in (data or '')


class ForwardingGuard(Isolated):
    def test_guard_is_installed_before_forwarding_is_enabled(self):
        record = clat.RUN/'forwarding'
        def check(args, data):
            if is_guard(args, data):
                self.assertEqual(record.read_text(), '0')
        host = FakeHost(fail=check)
        with host.patched():
            clat.Controller().sync(GRANT, sharing=False)
        self.assertLess(host.index(is_guard), host.index(lambda a, d: a == ['set_forwarding', '1']))
        self.assertIn(clat.GUARD, host.tables)
        self.assertEqual(json.loads((clat.RUN/'3.json').read_text())['state'], 'up')

    def test_startup_interrupted_at_either_step_recovers_guarded(self):
        for step in ('guard', 'forwarding'):
            with self.subTest(step=step):
                for leftover in clat.RUN.iterdir():
                    leftover.unlink()
                def crash(args, data):
                    if (step == 'guard' and is_guard(args, data)) or (step == 'forwarding' and args == ['set_forwarding', '1']):
                        return SystemExit('crash during startup')
                host = FakeHost(fail=crash)
                with host.patched(), self.assertRaises(SystemExit):
                    clat.Link('wan1', *GRANT['wan1']).start()
                self.assertTrue((clat.RUN/'forwarding').exists())
                self.assertEqual(host.forwarding, '0')
                host.fail = None
                with host.patched():
                    self.assertTrue(clat.cleanup())
                self.assertEqual(host.forwarding, '0')
                self.assertNotIn(clat.GUARD, host.tables)
                self.assertFalse((clat.RUN/'forwarding').exists())

    def test_failed_later_inverse_keeps_guard_until_forwarding_is_restored(self):
        import subprocess
        host = FakeHost()
        controller = clat.Controller()
        with host.patched():
            controller.sync(GRANT, sharing=False)
            host.fail = lambda args, data: subprocess.TimeoutExpired(args, 10) if args[2:4] == ['route', 'flush'] and args[1] == '-4' else None
            controller.sync({}, sharing=False)
            # The link's own table is gone; global forwarding stays guarded.
            self.assertNotIn('clat_3', host.tables)
            self.assertIn(clat.GUARD, host.tables)
            self.assertEqual(host.forwarding, '1')
            self.assertNotIn(['set_forwarding', '0'], host.commands())
            self.assertTrue((clat.RUN/'forwarding').exists())
            host.fail = None
            controller.sync({}, sharing=False)
        self.assertFalse(controller.links)
        self.assertEqual(host.forwarding, '0')
        self.assertNotIn(clat.GUARD, host.tables)
        self.assertLess(host.index(lambda a, d: a == ['set_forwarding', '0']),
                        host.index(lambda a, d: a == ['nft', 'delete', 'table', 'inet', clat.GUARD]))

    def test_foreign_guard_table_is_refused_and_kept(self):
        host = FakeHost()
        host.tables.add(clat.GUARD)
        with host.patched():
            link = clat.Link('wan1', *GRANT['wan1'])
            link.start()
        self.assertEqual(json.loads((clat.RUN/'3.json').read_text())['state'], 'error')
        self.assertFalse(link.undo)
        self.assertIn(clat.GUARD, host.tables)
        self.assertEqual(host.forwarding, '0')
        self.assertFalse((clat.RUN/'forwarding').exists())

    def test_shutdown_deadline_bounds_commands_and_keeps_the_journal(self):
        from unittest.mock import patch
        link = clat.Link('wan1', *GRANT['wan1'])
        link.undo = [['ip', 'link', 'del', link.tun]]
        link.save_cleanup()
        with patch.object(clat, 'DEADLINE', clat.time.monotonic() - 1), patch.object(clat.subprocess, 'run') as run:
            self.assertFalse(clat.cleanup())
        run.assert_not_called()
        self.assertEqual(json.loads((clat.RUN/'3.cleanup').read_text()), link.undo)
        with patch.object(clat, 'DEADLINE', clat.time.monotonic() + 5), patch.object(clat.subprocess, 'run') as run:
            clat.command('true')
        self.assertLessEqual(run.call_args.kwargs['timeout'], 5)


class ForwardingOwners(Isolated):
    def test_existing_owner_is_neither_recorded_nor_guarded(self):
        host = FakeHost(forwarding='1')
        controller = clat.Controller()
        with host.patched():
            controller.sync(GRANT, sharing=False)
            controller.sync({}, sharing=False)
        self.assertNotIn(clat.GUARD, [args[4] for args in host.commands() if args[:3] == ['nft', 'create', 'table']])
        self.assertFalse(any(is_guard(a, d) for a, d in host.calls))
        self.assertEqual(host.forwarding, '1')
        self.assertFalse(any(a[0] == 'set_forwarding' for a in host.commands()))

    def test_sharing_started_after_clat_takes_over_forwarding(self):
        host = FakeHost()
        controller = clat.Controller()
        with host.patched():
            controller.sync(GRANT, sharing=False)
            self.assertIn(clat.GUARD, host.tables)
            controller.sync(GRANT, sharing=True)
            # The new owner's forwarding is no longer filtered...
            self.assertNotIn(clat.GUARD, host.tables)
            self.assertFalse((clat.RUN/'forwarding').exists())
            # ...and stopping CLAT, with or without sharing, never writes 0.
            controller.sync({}, sharing=True)
            controller.sync({}, sharing=False)
        self.assertFalse(controller.links)
        self.assertEqual(host.forwarding, '1')
        self.assertNotIn(['set_forwarding', '0'], host.commands())

    def test_unknown_owner_keeps_forwarding_guarded(self):
        host = FakeHost()
        controller = clat.Controller()
        self.sharing.return_value = None
        with host.patched():
            controller.sync(GRANT, sharing=False)
            controller.sync({}, sharing=None)
            self.assertNotIn(['set_forwarding', '0'], host.commands())
            self.assertIn(clat.GUARD, host.tables)
            self.assertEqual(json.loads((clat.RUN/'3.json').read_text())['state'], 'error')
            controller.sync({}, sharing=False)
        self.assertEqual(host.forwarding, '0')
        self.assertNotIn(clat.GUARD, host.tables)
        self.assertEqual(json.loads((clat.RUN/'3.json').read_text())['state'], 'down')

    def test_owner_appearing_during_restore_gets_forwarding_back(self):
        host = FakeHost()
        controller = clat.Controller()
        self.sharing.return_value = True
        with host.patched():
            controller.sync(GRANT, sharing=False)
            controller.sync({}, sharing=False)
        self.assertEqual(host.forwarding, '1')
        self.assertEqual([a[1] for a in host.commands() if a[0] == 'set_forwarding'], ['1', '0', '1'])
        self.assertNotIn(clat.GUARD, host.tables)
        self.assertFalse((clat.RUN/'forwarding').exists())

    def test_cleanup_entrypoint_asks_networkmanager(self):
        # ExecStopPost after a crash: no controller state, NM sharing active.
        host = FakeHost()
        with host.patched():
            clat.Link('wan1', *GRANT['wan1']).start()
            self.sharing.return_value = True
            self.assertTrue(clat.cleanup())
        self.sharing.assert_called_with()
        self.assertEqual(host.forwarding, '1')
        self.assertNotIn(['set_forwarding', '0'], host.commands())
        self.assertNotIn(clat.GUARD, host.tables)


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
                 (['ip','-4','route','flush','table','46003'], '[]'),
                 (['ip','-6','rule','del','priority','46003','fwmark','0xc1a70003','lookup','46003'],
                  '[{"priority":46003,"src":"all","fwmark":"0xc1a70004","table":"46003"}]')]
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
                  [{'dst':'default','dev':'clat3','metric':46003}]),
                 (['ip','-6','rule','del','priority','46003','fwmark','0xc1a70003','lookup','46003'],
                  [{'priority':46003,'src':'all','fwmark':'0xc1a70003','table':'46003'}])]
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

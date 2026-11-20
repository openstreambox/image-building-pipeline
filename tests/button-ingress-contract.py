#!/usr/bin/env python3
import asyncio
import collections
import contextlib
import errno
import importlib.util
import ipaddress
import json
import pathlib
import socket
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ingress', ROOT / 'mkosi/runtime/button-ingress/ingress.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class Contract(unittest.TestCase):
    def test_identity_not_name(self):
        base = dict(ifname='eth0', link_type='ether', flags=['UP'], ifindex=2)
        self.assertTrue(m.eligible(base, True))
        self.assertTrue(m.eligible(dict(base, ifname='ap0'), True))
        for change in [dict(linkinfo={'info_kind':'wireguard'}), dict(master='br0'), dict(link_type='loopback'), dict(flags=[]), dict(linkinfo={'info_kind':'bridge'})]:
            self.assertFalse(m.eligible(dict(base, **change), True))
        self.assertFalse(m.eligible(base, False))

    def test_each_upgrade(self):
        good = b'GET /ws HTTP/1.1\r\nHost: box.local\r\nOrigin: http://box.local\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n'
        head = m.parse_head(good)
        self.assertTrue(m.privileged(head, True, '192.168.2.4', '192.168.2.1/24'))
        comma = m.parse_head(good.replace(b'Connection: Upgrade', b'Connection: keep-alive, Upgrade'))
        self.assertTrue(m.privileged(comma, True, '192.168.2.4', '192.168.2.1/24'))
        for name in ['Forwarded', 'X-Forwarded-For', 'x-forwarded-anything', 'Via', 'X-Ceralive-Button-Path']:
            self.assertFalse(m.privileged(m.parse_head(good[:-2] + name.encode() + b':\r\n\r\n'), True, '192.168.2.4', '192.168.2.1/24'))
        for peer in ['10.0.0.2', '::1', '127.0.0.1']:
            self.assertFalse(m.privileged(head, True, peer, '192.168.2.1/24'))
        self.assertFalse(m.privileged(head, False, '192.168.2.4', '192.168.2.1/24'))
        for raw in [good.replace(b'/ws ', b'/preview '), good.replace(b'/ws ', b'/ws?senderId=relay ')]:
            self.assertFalse(m.privileged(m.parse_head(raw), True, '192.168.2.4', '192.168.2.1/24'))
        for raw in [good.replace(b'GET ', b'CONNECT '), good.replace(b'Host:', b' Host:'), good.replace(b'Host: box.local', b'Host: x\r\nHost: y')]:
            with self.assertRaises(ValueError): m.parse_head(raw)

    def test_device_and_address_binding(self):
        fake = Mock()
        m.bound_socket(socket.AF_INET, 'eth7', '192.168.2.1', 80, lambda *a: fake)
        fake.setsockopt.assert_any_call(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, b'eth7\0')
        fake.bind.assert_called_once_with(('192.168.2.1', 80))
        fake.reset_mock()
        fake.setsockopt.side_effect = OSError('denied')
        with self.assertRaises(OSError): m.bound_socket(socket.AF_INET, 'eth7', '192.168.2.1', 80, lambda *a: fake)
        fake.bind.assert_not_called()
        fake.close.assert_called_once()

    def test_ipv6_only(self):
        fake = Mock()
        m.bound_socket(socket.AF_INET6, 'eth7', 'fe80::1', 80, lambda *a: fake, 7)
        fake.setsockopt.assert_any_call(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        fake.bind.assert_called_once_with(('fe80::1', 80, 0, 7))

    def test_parse_link_and_address_events(self):
        index, deleted, family, _, _, _, current = m.parse_event(m.RTM_NEWLINK, link_msg(m.RTM_NEWLINK, 7, 'eth7', master=12, info_kind='macvlan')[16:])
        self.assertEqual((index, deleted, family), (7, False, None))
        self.assertEqual(current, ('eth7', True, True, True, 'macvlan'))
        self.assertEqual(m.parse_event(m.RTM_DELLINK, link_msg(m.RTM_DELLINK, 7, 'eth7', up=False)[16:])[:2], (7, True))
        self.assertIsNone(m.parse_event(m.RTM_NEWLINK, link_msg(m.RTM_NEWLINK, 7, 'eth7', family=7)[16:])[6])
        event = m.parse_event(m.RTM_DELADDR, addr_msg(m.RTM_DELADDR, 7, '192.168.2.1', 24)[16:])
        self.assertEqual(event, (7, True, socket.AF_INET, ipaddress.ip_address('192.168.2.1'), 24, False, None))
        event = m.parse_event(m.RTM_NEWADDR, addr_msg(m.RTM_NEWADDR, 7, 'fe80::1', 64, flags=m.IFA_F_TENTATIVE)[16:])
        self.assertEqual(event[2:6], (socket.AF_INET6, ipaddress.ip_address('fe80::1'), 64, True))
        for kind, body in [(99, b''), (m.RTM_NEWLINK, b'\0' * 8), (m.RTM_NEWADDR, b'\x02\x18\0\0\x07\0\0\0' + rta(1, b'\x01\x02')),
                           (m.RTM_NEWADDR, b'\x02\x18\0\0\x07\0\0\0' + struct.pack('=HH', 64, 1))]:
            with self.assertRaises(ValueError):
                m.parse_event(kind, body)

    def test_basis_scope(self):
        basis = m.Basis(ETH7, ETH7['addr_info'][0], True)
        self.assertTrue(basis.direct)
        def hit(raw):
            return basis.affected(m.parse_event(struct.unpack_from('=H', raw, 4)[0], raw[16:]))
        for raw in [link_msg(m.RTM_NEWLINK, 7, 'eth7'), link_msg(m.RTM_NEWLINK, 9, 'clap-wlan0'),
                    addr_msg(m.RTM_NEWADDR, 7, '192.168.2.1', 24), addr_msg(m.RTM_NEWADDR, 7, '192.168.3.1', 24),
                    addr_msg(m.RTM_DELADDR, 8, '192.168.2.1', 24), addr_msg(m.RTM_DELADDR, 7, '192.168.2.2', 24)]:
            self.assertFalse(hit(raw))
        for raw in [link_msg(m.RTM_DELLINK, 7, 'eth7'), link_msg(m.RTM_NEWLINK, 7, 'eth7', up=False),
                    link_msg(m.RTM_NEWLINK, 7, 'eth9'), link_msg(m.RTM_NEWLINK, 7, 'eth7', master=12),
                    link_msg(m.RTM_NEWLINK, 7, 'eth7', info_kind='macvlan'), link_msg(m.RTM_NEWLINK, 7, 'eth7', arphrd=801),
                    link_msg(m.RTM_NEWLINK, 7, 'eth7', family=7), addr_msg(m.RTM_DELADDR, 7, '192.168.2.1', 24),
                    addr_msg(m.RTM_NEWADDR, 7, '192.168.2.1', 25),
                    addr_msg(m.RTM_NEWADDR, 7, '192.168.2.1', 24, flags=m.IFA_F_DADFAILED)]:
            self.assertTrue(hit(raw))


def rta(kind, payload):
    return struct.pack('=HH', 4 + len(payload), kind) + payload + b'\0' * (-len(payload) % 4)


def message(kind, body, flags=0):
    return struct.pack('=IHHII', 16 + len(body), kind, flags, 0, 0) + body


def link_msg(kind, index, name, up=True, master=0, info_kind=None, family=0, arphrd=1):
    body = struct.pack('=BBHiII', family, 0, arphrd, index, m.IFF_UP if up else 0, 0) + rta(3, name.encode() + b'\0')
    if master:
        body += rta(10, struct.pack('=I', master))
    if info_kind:
        body += rta(18, rta(1, info_kind.encode() + b'\0'))
    return message(kind, body)


def addr_msg(kind, index, address, prefixlen, flags=0):
    value = ipaddress.ip_address(address)
    body = struct.pack('=BBBBI', socket.AF_INET if value.version == 4 else socket.AF_INET6, prefixlen, flags, 0, index)
    body += rta(1, value.packed) + (rta(2, value.packed) if value.version == 4 else b'')
    return message(kind, body)


def link(name, index, *addresses):
    return dict(ifname=name, ifindex=index, link_type='ether', flags=['UP', 'LOWER_UP'],
                addr_info=[dict(family='inet' if ':' not in a else 'inet6', local=a.split('/')[0],
                                prefixlen=int(a.split('/')[1])) for a in addresses])


ETH7 = link('eth7', 7, '192.168.2.1/24', 'fe80::1/64')
WLAN1 = link('wlan1', 8, '10.0.0.1/24')
CLAP = link('clap-wlan0', 9, '10.42.0.1/24')
UPGRADE = b'GET /ws HTTP/1.1\r\nHost: box.local\r\nOrigin: http://box.local\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'


class Box:
    """A FrontDoor on real loopback listeners with synthetic netlink and dumps.

    Only the address/device binding and the physical-device check are
    replaced, so the same harness exercises the real admission, Unix/TCP
    tunnels and session lifetime code for whichever ingress is loaded.
    """
    def __init__(self, links):
        self.links = links
        self.datagrams = collections.deque()
        self.ports = {}
        self.unix_heads = []
        self.clients = []

    async def __aenter__(self):
        self.stack = contextlib.ExitStack()
        real_socket = socket.socket
        def bound(family, name, address, port, factory=None, index=0):
            sock = real_socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.bind(('127.0.0.1', 0))
            sock.listen(64)
            sock.setblocking(False)
            self.ports[(name, address)] = sock.getsockname()[1]
            return sock
        eligible, privileged = m.eligible, m.privileged
        for target, value in [('bound_socket', bound), ('eligible', lambda link, physical: eligible(link, True)),
                              # Loopback stands in for the LAN peer 192.168.2.4.
                              ('privileged', lambda head, direct, peer, cidr: privileged(head, direct, '192.168.2.4', cidr)),
                              ('subprocess', Mock(check_output=lambda *a, **k: json.dumps(self.links).encode(),
                                                  SubprocessError=subprocess.SubprocessError,
                                                  TimeoutExpired=subprocess.TimeoutExpired))]:
            self.stack.enter_context(patch.object(m, target, value))
        async def echo(reader, writer, record=None):
            head = await reader.readuntil(b'\r\n\r\n')
            if record is not None:
                record.append(head)
            writer.write(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n')
            while data := await reader.read(65536):
                writer.write(data)
                await writer.drain()
            writer.close()
        directory = self.stack.enter_context(tempfile.TemporaryDirectory())
        self.unix = await asyncio.start_unix_server(lambda r, w: echo(r, w, self.unix_heads), directory + '/rpc.sock')
        self.tcp = await asyncio.start_server(echo, '127.0.0.1', 0)
        self.front = m.FrontDoor([(80, None)])
        self.front.monitor.close()
        self.front.monitor = Mock()
        self.front.monitor.recvmsg.side_effect = self.receive
        self.front.unix_path = directory + '/rpc.sock'
        self.front.backend_address = self.tcp.sockets[0].getsockname()[:2]
        self.front.schedule = Mock()
        await self.front.reconcile()
        assert self.front.trusted_ready
        return self

    async def __aexit__(self, *exc):
        self.front.event_fence()
        await asyncio.gather(*tuple(self.front.tasks), return_exceptions=True)
        for writer in self.clients:
            writer.close()
        for service in (self.unix, self.tcp):
            service.close()
        await asyncio.sleep(0)
        self.stack.close()

    def receive(self, size):
        if not self.datagrams:
            raise BlockingIOError()
        item = self.datagrams.popleft()
        if isinstance(item, BaseException):
            raise item
        return item if isinstance(item, tuple) else (item, [], 0, None)

    def events(self, *items):
        self.datagrams.extend(items)
        self.front.event()

    async def session(self, extra=b'', address=('eth7', '192.168.2.1')):
        reader, writer = await asyncio.open_connection('127.0.0.1', self.ports[address])
        self.clients.append(writer)
        writer.write(UPGRADE + extra + b'\r\n')
        await writer.drain()
        self.assert_true((await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 2)).startswith(b'HTTP/1.1 101 '))
        return reader, writer

    @staticmethod
    def assert_true(value):
        assert value

    @staticmethod
    async def alive(reader, writer):
        try:
            writer.write(b'ping')
            await writer.drain()
            return await asyncio.wait_for(reader.read(4), 2) == b'ping'
        except (OSError, asyncio.TimeoutError):
            return False


class Scope(unittest.IsolatedAsyncioTestCase):
    """Established sessions survive unrelated changes and close on their own."""

    async def sessions(self, box):
        trusted = await box.session()
        ordinary = await box.session(b'Via: proxy\r\n')
        self.assertIn(b'X-Ceralive-Button-Path:', box.unix_heads[0])
        self.assertEqual(len(box.unix_heads), 1)
        return trusted, ordinary

    async def test_unrelated_changes_keep_sessions(self):
        cases = {
            'new interface and address': ([link_msg(m.RTM_NEWLINK, 9, 'clap-wlan0'), addr_msg(m.RTM_NEWADDR, 9, '10.42.0.1', 24)],
                                          [ETH7, WLAN1, CLAP]),
            'other interface removed': ([addr_msg(m.RTM_DELADDR, 8, '10.0.0.1', 24), link_msg(m.RTM_DELLINK, 8, 'wlan1', up=False)],
                                        [ETH7]),
            'other interface down': ([link_msg(m.RTM_NEWLINK, 8, 'wlan1', up=False)], [ETH7, dict(WLAN1, flags=[])]),
            'address added on the same interface': ([addr_msg(m.RTM_NEWADDR, 7, '192.168.3.1', 24)],
                                                    [dict(ETH7, addr_info=ETH7['addr_info'] + [dict(family='inet', local='192.168.3.1', prefixlen=24)]), WLAN1]),
            'same address removed elsewhere': ([addr_msg(m.RTM_DELADDR, 8, '192.168.2.1', 24)], [ETH7, WLAN1]),
            'carrier and address refresh on the same interface': ([link_msg(m.RTM_NEWLINK, 7, 'eth7'), addr_msg(m.RTM_NEWADDR, 7, '192.168.2.1', 24),
                                                                   addr_msg(m.RTM_NEWADDR, 7, 'fe80::1', 64)], [ETH7, WLAN1]),
        }
        for name, (datagrams, after) in cases.items():
            with self.subTest(name):
                async with Box([ETH7, WLAN1]) as box:
                    sessions = await self.sessions(box)
                    listener = box.ports[('eth7', '192.168.2.1')]
                    box.events(b''.join(datagrams))
                    self.assertFalse(box.front.trusted_ready)
                    for session in sessions:
                        self.assertTrue(await box.alive(*session))
                    box.links = after
                    await box.front.reconcile()
                    self.assertTrue(box.front.trusted_ready)
                    for session in sessions:
                        self.assertTrue(await box.alive(*session))
                    # The listener was kept, and new trusted admission resumes.
                    self.assertEqual(box.ports[('eth7', '192.168.2.1')], listener)
                    await box.session()
                    self.assertEqual(len(box.unix_heads), 2)

    async def test_own_basis_change_closes_sessions(self):
        moved = dict(ETH7, addr_info=[dict(family='inet', local='192.168.2.1', prefixlen=25)])
        cases = {
            'own address removed': ([addr_msg(m.RTM_DELADDR, 7, '192.168.2.1', 24)], [dict(ETH7, addr_info=[]), WLAN1]),
            'own address removed and readded': ([addr_msg(m.RTM_DELADDR, 7, '192.168.2.1', 24), addr_msg(m.RTM_NEWADDR, 7, '192.168.2.1', 24)],
                                                [ETH7, WLAN1]),
            'own mask changed': ([addr_msg(m.RTM_NEWADDR, 7, '192.168.2.1', 25)], [moved, WLAN1]),
            'own address failed duplicate detection': ([addr_msg(m.RTM_NEWADDR, 7, '192.168.2.1', 24, flags=m.IFA_F_DADFAILED)], [ETH7, WLAN1]),
            'own interface removed': ([link_msg(m.RTM_DELLINK, 7, 'eth7', up=False)], [WLAN1]),
            'own interface down and up': ([link_msg(m.RTM_NEWLINK, 7, 'eth7', up=False), link_msg(m.RTM_NEWLINK, 7, 'eth7')], [ETH7, WLAN1]),
            'own interface renamed': ([link_msg(m.RTM_NEWLINK, 7, 'eth9')], [dict(ETH7, ifname='eth9'), WLAN1]),
            'own interface enslaved': ([link_msg(m.RTM_NEWLINK, 7, 'eth7', master=12)], [dict(ETH7, master='br0'), WLAN1]),
            'own interface as a bridge port': ([link_msg(m.RTM_NEWLINK, 7, 'eth7', family=7)], [ETH7, WLAN1]),
        }
        for name, (datagrams, after) in cases.items():
            with self.subTest(name):
                async with Box([ETH7, WLAN1]) as box:
                    sessions = await self.sessions(box)
                    other = await box.session(address=('wlan1', '10.0.0.1'))
                    box.events(b''.join(datagrams))
                    # Closed in the callback that saw the event, before any dump.
                    for session in sessions:
                        self.assertFalse(await box.alive(*session))
                    self.assertTrue(await box.alive(*other))
                    box.links = after
                    await box.front.reconcile()
                    self.assertTrue(box.front.trusted_ready)
                    for session in sessions:
                        self.assertFalse(await box.alive(*session))
                    self.assertTrue(await box.alive(*other))

    async def test_snapshot_without_basis_closes_sessions(self):
        async with Box([ETH7, WLAN1]) as box:
            sessions = await self.sessions(box)
            other = await box.session(address=('wlan1', '10.0.0.1'))
            # Whatever the events said, a basis missing from a synchronized
            # snapshot is retired when the snapshot is applied.
            box.links = [dict(ETH7, flags=['UP'], master='br0'), WLAN1]
            box.events(addr_msg(m.RTM_NEWADDR, 9, '10.42.0.1', 24))
            await box.front.reconcile()
            for session in sessions:
                self.assertFalse(await box.alive(*session))
            self.assertTrue(await box.alive(*other))

    async def test_tentative_addresses_are_not_bound(self):
        # As `ip -j` prints them: a new interface's link-local address is
        # tentative until duplicate detection ends; binding it would fail.
        fresh = dict(CLAP, addr_info=CLAP['addr_info'] + [
            dict(family='inet6', local='fe80::2', prefixlen=64, tentative=True),
            dict(family='inet6', local='fe80::3', prefixlen=64, dadfailed=True, tentative=True)])
        async with Box([ETH7, fresh]) as box:
            self.assertIn(('clap-wlan0', '10.42.0.1'), box.ports)
            self.assertNotIn(('clap-wlan0', 'fe80::2'), box.ports)
            self.assertNotIn(('clap-wlan0', 'fe80::3'), box.ports)
            box.links = [ETH7, CLAP]
            await box.front.reconcile()
            self.assertNotIn(('clap-wlan0', 'fe80::2'), box.ports)

    async def test_failed_dump_withholds_admission_and_keeps_sessions(self):
        async with Box([ETH7, WLAN1]) as box:
            sessions = await self.sessions(box)
            def timeout(*a, **k):
                raise subprocess.TimeoutExpired('ip', 3)
            box.events(link_msg(m.RTM_NEWLINK, 9, 'clap-wlan0'))
            with patch.object(m.subprocess, 'check_output', timeout):
                await box.front.reconcile()
            self.assertFalse(box.front.trusted_ready)
            self.assertFalse(box.front.needs_subscription)
            for session in sessions:
                self.assertTrue(await box.alive(*session))
            # Admission while withheld stays ordinary for its whole lifetime.
            await box.session()
            self.assertEqual(len(box.unix_heads), 1)


class Transport(unittest.IsolatedAsyncioTestCase):
    async def test_event_loss_retires_all_before_identical_snapshot(self):
        # The remove/readd events were lost: the replacement dump is identical.
        for loss in (OSError(errno.ENOBUFS, 'overflow'),
                     (b'lost', [], socket.MSG_TRUNC, None),
                     (b'\x10\x00\x00\x00\x04\x00' + b'\0' * 10, [], 0, None),
                     (b'\x10\x00\x00\x00\x03\x00\x10\x00' + b'\0' * 8, [], 0, None),
                     message(99, b''),
                     message(m.RTM_NEWADDR, b'\x02\x18\0\0\x07\0\0\0' + struct.pack('=HH', 64, 1))):
            with self.subTest(loss=loss):
                async with Box([ETH7, WLAN1]) as box:
                    sessions = [*await Scope.sessions(self, box), await box.session(address=('wlan1', '10.0.0.1'))]
                    old_monitor, fresh_monitor = box.front.monitor, Mock()
                    box.front.loop = Mock()
                    fresh_monitor.recvmsg.side_effect = BlockingIOError()
                    box.events(loss)
                    for session in sessions:
                        self.assertFalse(await box.alive(*session))
                    self.assertFalse(box.front.trusted_ready)
                    self.assertFalse(box.front.bases)
                    old_ports = dict(box.ports)
                    def dump(*args, **kwargs):
                        # A new subscription must exist before taking the dump.
                        fresh_monitor.bind.assert_called_once_with((0, 1 | 0x10 | 0x100))
                        self.assertIs(box.front.monitor, fresh_monitor)
                        return json.dumps(box.links).encode()
                    real_socket = socket.socket
                    def sockets(family, *args):
                        return fresh_monitor if family == socket.AF_NETLINK else real_socket(family, *args)
                    with patch.object(m.socket, 'socket', sockets), patch.object(m.subprocess, 'check_output', side_effect=dump):
                        await box.front.reconcile()
                    old_monitor.close.assert_called_once()
                    box.front.loop.remove_reader.assert_called_once_with(old_monitor)
                    box.front.loop.add_reader.assert_called_once_with(fresh_monitor, box.front.event)
                    self.assertTrue(box.front.trusted_ready)
                    # Recovery cannot revive either side of the old grant path.
                    for session in sessions:
                        self.assertFalse(await box.alive(*session))
                    self.assertNotEqual(old_ports, box.ports)
                    await box.session()

    async def test_real_unix_and_ordinary_paths(self):
        received = []
        release = asyncio.Event()
        async def backend(reader, writer):
            raw = await reader.readuntil(b"\r\n\r\n")
            received.append(raw)
            if raw.startswith(b'POST '):
                body = await reader.readexactly(4)
                writer.write(b'HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n' + body)
                await writer.drain()
                writer.close()
                return
            writer.write(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
            await writer.drain()
            await release.wait()
            writer.close()
        with tempfile.TemporaryDirectory() as directory:
            path = directory + '/rpc.sock'
            unix = await asyncio.start_unix_server(backend, path)
            ordinary = await asyncio.start_server(backend, '127.0.0.1', 0)
            front = m.FrontDoor([])
            front.trusted_ready = True
            front.unix_path = path
            front.backend_address = ordinary.sockets[0].getsockname()[:2]
            class Arrival:
                def __init__(self, writer): self.writer = writer
                def get_extra_info(self, name):
                    if name == 'peername': return ('192.168.2.4', 32000)
                    if name == 'sockname': return ('192.168.2.1', 80)
                    return self.writer.get_extra_info(name)
                def __getattr__(self, name): return getattr(self.writer, name)
            basis = m.Basis(dict(ETH7, ifname='eth7'), ETH7['addr_info'][0], True)
            front.bases[basis.key] = basis
            server = await asyncio.start_server(lambda r,w: front.accept(r, Arrival(w), basis), '127.0.0.1', 0)
            clients = []
            readers = []
            try:
                for extra in [b'', b'Forwarded:\r\n', b'X-Ceralive-Button-Path: forged\r\n', b'Via:\r\n']:
                    r, w = await asyncio.open_connection(*server.sockets[0].getsockname()[:2])
                    clients.append(w)
                    readers.append(r)
                    w.write(b'GET /ws HTTP/1.1\r\nHost: box.local\r\nOrigin: http://box.local\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n' + extra + b'\r\n')
                    await w.drain()
                    await asyncio.wait_for(r.readuntil(b'\r\n\r\n'), 2)
                post_reader, post_writer = await asyncio.open_connection(*server.sockets[0].getsockname()[:2])
                clients.append(post_writer)
                post_writer.write(b'POST /api HTTP/1.1\r\nHost: box.local\r\nContent-Length: 4\r\n\r\ndata')
                await post_writer.drain()
                self.assertTrue((await asyncio.wait_for(post_reader.read(), 2)).endswith(b'data'))
                self.assertIn(b'"interface":"eth7"', received[0])
                self.assertIn(b'Origin: http://box.local', received[0])
                self.assertNotIn(b'X-Ceralive-Button-Path:', received[1])
                self.assertIn(b'X-Ceralive-Button-Path: forged', received[2])
                self.assertIn(b'Via:', received[3])
                # Lose a remove/readd interval, then recover the exact same
                # address/mask. Old upgraded Unix/TCP sessions must stay dead.
                front.monitor.close()
                front.monitor = Mock()
                front.monitor.recvmsg.side_effect = OSError(errno.ENOBUFS, 'overflow')
                front.schedule = Mock()
                front.event()
                self.assertFalse(basis.alive)
                fresh = Mock()
                fresh.recvmsg.side_effect = BlockingIOError()
                snapshot = b'[{"ifname":"eth7","ifindex":7,"addr_info":[{"family":"inet","local":"192.168.2.1","prefixlen":24}]}]'
                with patch.object(m.socket, 'socket', return_value=fresh), patch.object(m.subprocess, 'check_output', return_value=snapshot):
                    await front.reconcile()
                self.assertTrue(front.trusted_ready)
                for r in readers:
                    self.assertEqual(await asyncio.wait_for(r.read(), 2), b'')
                for w in clients: w.close()
                release.set()
                await asyncio.gather(*tuple(front.tasks), return_exceptions=True)
            finally:
                release.set()
                front.event_fence()
                front.monitor.close()
                for service in (server, unix, ordinary):
                    service.close()
                    await service.wait_closed()

if __name__ == '__main__': unittest.main()

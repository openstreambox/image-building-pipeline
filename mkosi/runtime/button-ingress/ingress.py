#!/usr/bin/python3
"""Bounded, device-bound HTTP/WebSocket front door. Linux, stdlib only."""
import asyncio
import ipaddress
import json
import logging
from pathlib import Path
import socket
import ssl
import struct
import subprocess

UNIX = '/run/ceralive-button-ingress/rpc.sock'
MAX_CONNECTIONS = 128
HEADER_LIMIT = 16384


def eligible(link, physical):
    return (physical and link.get('link_type') == 'ether'
            and 'UP' in link.get('flags', []) and not link.get('master')
            and not link.get('linkinfo', {}).get('info_kind'))


def parse_head(raw):
    if len(raw) > HEADER_LIMIT or not raw.endswith(b'\r\n\r\n'):
        raise ValueError('header size/framing')
    lines = raw[:-4].decode('ascii').split('\r\n')
    method, target, version = lines[0].split(' ')
    if version != 'HTTP/1.1' or method == 'CONNECT' or not target.startswith('/') or target.startswith('//'):
        raise ValueError('request target')
    headers = {}
    for line in lines[1:]:
        name, value = line.split(':', 1)
        if not name or any(c not in "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" for c in name):
            raise ValueError('header name')
        name = name.lower()
        if name in headers or any(ord(c) < 32 and c != '\t' for c in value) or '\x7f' in value:
            raise ValueError('ambiguous header')
        headers[name] = value.strip()
    if 'host' not in headers or ('transfer-encoding' in headers and 'content-length' in headers):
        raise ValueError('ambiguous framing')
    return method, target, headers


def privileged(head, direct, peer, cidr):
    method, target, headers = head
    if not direct or method != 'GET' or target != '/ws':
        return False
    if any(k in ('forwarded', 'via', 'x-ceralive-button-path') or k.startswith('x-forwarded-') for k in headers):
        return False
    if headers.get('upgrade', '').lower() != 'websocket' or 'upgrade' not in [token.strip().lower() for token in headers.get('connection', '').split(',')]:
        return False
    if 'content-length' in headers or 'transfer-encoding' in headers:
        return False
    try:
        address = ipaddress.ip_address(peer)
        return address.version == 4 and not address.is_loopback and address in ipaddress.ip_interface(cidr).network
    except ValueError:
        return False


def bound_socket(family, name, address, port, factory=socket.socket, index=0):
    sock = factory(family, socket.SOCK_STREAM)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, name.encode() + b'\0')
        if family == socket.AF_INET6:
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        sock.bind((address, port) if family == socket.AF_INET else (address, port, 0, index))
        sock.listen(64)
        sock.setblocking(False)
        return sock
    except BaseException:
        sock.close()
        raise


# rtnetlink multicast messages on the subscribed link/address groups.
RTM_NEWLINK, RTM_DELLINK, RTM_NEWADDR, RTM_DELADDR = 16, 17, 20, 21
IFLA_IFNAME, IFLA_MASTER, IFLA_LINKINFO, IFLA_INFO_KIND = 3, 10, 18, 1
IFA_ADDRESS, IFA_LOCAL, IFA_FLAGS = 1, 2, 8
IFF_UP, ARPHRD_ETHER = 0x1, 1
IFA_F_DADFAILED, IFA_F_TENTATIVE = 0x08, 0x40


def attributes(data, offset):
    found = {}
    while offset + 4 <= len(data):
        length, kind = struct.unpack_from('=HH', data, offset)
        if length < 4 or offset + length > len(data):
            raise ValueError('netlink attribute')
        found.setdefault(kind & 0x3fff, data[offset + 4:offset + length])
        offset += (length + 3) & ~3
    return found


def identity(link):
    """Link facts a trust basis depends on, from an `ip -j -d` dump entry."""
    return (link['ifname'], 'UP' in link.get('flags', []), link.get('link_type') == 'ether',
            bool(link.get('master')), link.get('linkinfo', {}).get('info_kind'))


def parse_event(kind, body):
    """One rtnetlink event as (index, deleted, family, address, prefixlen, unusable, identity).

    Link events carry family None and the new link identity (None for
    non-generic link families). Address events carry identity None. Anything
    unexpected raises ValueError so the caller treats it as lost history.
    """
    if kind in (RTM_NEWLINK, RTM_DELLINK):
        if len(body) < 16:
            raise ValueError('short link message')
        family, _, link_type, index, flags, _ = struct.unpack_from('=BBHiII', body)
        found = attributes(body, 16)
        current = None
        if family == socket.AF_UNSPEC:
            if IFLA_IFNAME not in found:
                raise ValueError('link without name')
            master = found.get(IFLA_MASTER, b'')
            info = attributes(found.get(IFLA_LINKINFO, b''), 0).get(IFLA_INFO_KIND)
            current = (found[IFLA_IFNAME].split(b'\0', 1)[0].decode(), bool(flags & IFF_UP),
                       link_type == ARPHRD_ETHER, len(master) >= 4 and struct.unpack_from('=I', master)[0] != 0,
                       info.split(b'\0', 1)[0].decode() if info else None)
        return index, kind == RTM_DELLINK, None, None, None, False, current
    if kind in (RTM_NEWADDR, RTM_DELADDR):
        if len(body) < 8:
            raise ValueError('short address message')
        family, prefixlen, flags, _, index = struct.unpack_from('=BBBBI', body)
        found = attributes(body, 8)
        if family not in (socket.AF_INET, socket.AF_INET6):
            return None
        raw = found.get(IFA_LOCAL) or found.get(IFA_ADDRESS)
        if raw is None or len(raw) != (4 if family == socket.AF_INET else 16):
            raise ValueError('address payload')
        if len(found.get(IFA_FLAGS, b'')) >= 4:
            flags = struct.unpack_from('=I', found[IFA_FLAGS])[0]
        return (index, kind == RTM_DELADDR, family, ipaddress.ip_address(raw), prefixlen,
                bool(flags & (IFA_F_TENTATIVE | IFA_F_DADFAILED)), None)
    raise ValueError('unexpected netlink message')


class Basis:
    """One exact listener address and everything accepted through it."""
    def __init__(self, link, addr, physical):
        self.name, self.index = link['ifname'], link['ifindex']
        self.family = socket.AF_INET if addr['family'] == 'inet' else socket.AF_INET6
        self.local = addr['local']
        self.address = ipaddress.ip_address(self.local)
        self.prefixlen = addr['prefixlen']
        self.cidr = f"{self.local}/{self.prefixlen}"
        self.identity = identity(link)
        self.direct = eligible(link, physical) and self.family == socket.AF_INET
        self.key = (self.index, self.family, self.address, self.prefixlen, self.identity, physical)
        self.alive = True
        self.listeners = {}
        self.writers = set()
        self.tasks = set()

    def affected(self, event):
        index, deleted, family, address, prefixlen, unusable, current = event
        if index != self.index:
            return False
        if family is None:
            # Link removal, rename, down, enslavement, type/kind change, or a
            # non-generic (for example bridge port) message for this link.
            return deleted or current != self.identity
        if family != self.family or address != self.address:
            return False
        return deleted or unusable or prefixlen != self.prefixlen

    def retire(self):
        self.alive = False
        for listener in self.listeners.values():
            listener.close()
        for writer in self.writers:
            writer.close()
        for task in self.tasks:
            task.cancel()
        self.listeners.clear()
        self.writers.clear()
        self.tasks.clear()


class FrontDoor:
    def __init__(self, contexts):
        self.bases = {}
        self.epoch = 0
        self.contexts = contexts
        self.tasks = set()
        self.trusted_ready = False
        self.dirty = False
        self.backend_address = ('127.0.0.1', 18080)
        self.unix_path = UNIX
        self.monitor = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, socket.NETLINK_ROUTE)
        # Subscribe BEFORE the initial ip dump. Link + IPv4/IPv6 address events.
        self.monitor.bind((0, 1 | 0x10 | 0x100))
        self.monitor.setblocking(False)
        self.pending = None
        self.needs_subscription = False
        self.loop = None

    def resubscribe(self):
        monitor = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, socket.NETLINK_ROUTE)
        try:
            monitor.bind((0, 1 | 0x10 | 0x100))
            monitor.setblocking(False)
        except BaseException:
            monitor.close()
            raise
        if self.loop is not None:
            self.loop.remove_reader(self.monitor)
        self.monitor.close()
        self.monitor = monitor
        if self.loop is not None:
            self.loop.add_reader(self.monitor, self.event)
        self.needs_subscription = False

    def drain_events(self):
        changed = False
        while True:
            try:
                data, _, flags, _ = self.monitor.recvmsg(262144)
                changed = True
                # Any change withholds new trusted admission until a fresh,
                # synchronized snapshot; established sessions are judged below.
                self.trusted_ready = False
                self.dirty = True
                if not data or flags & socket.MSG_TRUNC:
                    raise OSError('netlink truncated')
                events = []
                offset = 0
                while offset < len(data):
                    if len(data) - offset < 16:
                        raise OSError('netlink incomplete header')
                    length, kind, message_flags = struct.unpack_from('=IHH', data, offset)
                    # NLMSG_ERROR/OVERRUN and NLM_F_DUMP_INTR lose continuity.
                    if length < 16 or offset + length > len(data) or kind in (2, 4) or message_flags & 0x10:
                        raise OSError('netlink event history unavailable')
                    events.append(parse_event(kind, data[offset + 16:offset + length]))
                    offset += (length + 3) & ~3
                # Retire exactly the bases an event touches, in the same
                # callback that observed it. Removal then readdition of the
                # same address retires on the removal and never revives.
                for event in events:
                    if event is not None:
                        for basis in tuple(self.bases.values()):
                            if basis.affected(event):
                                self.retire(basis)
            except BlockingIOError:
                return changed
            except (OSError, ValueError, struct.error):
                # ENOBUFS/overflow or an uncertain message: history is lost,
                # so no basis can be shown unchanged. Full invalidation.
                self.needs_subscription = True
                self.event_fence()
                return True

    def event(self):
        if self.drain_events():
            self.schedule()

    def schedule(self):
        if self.pending is None or self.pending.done():
            self.pending = asyncio.create_task(self.reconcile())

    def retire(self, basis):
        if self.bases.get(basis.key) is basis:
            del self.bases[basis.key]
        basis.retire()

    def snapshot(self, links):
        wanted = {}
        for link in links:
            physical = Path('/sys/class/net', link['ifname'], 'device').exists()
            for addr in link.get('addr_info', []):
                if addr.get('family') not in ('inet', 'inet6') or 'tentative' in addr.get('flags', []):
                    continue
                basis = Basis(link, addr, physical)
                wanted.setdefault(basis.key, basis)
        return wanted

    async def reconcile(self):
        self.trusted_ready = False
        self.dirty = False
        failed = False
        try:
            if self.needs_subscription:
                self.resubscribe()
            # Synchronous bounded dumps: no application handler runs between
            # snapshot and event drain. Queued events discard the snapshot;
            # the drain has already retired whatever they touched.
            links = json.loads(subprocess.check_output(['/usr/sbin/ip', '-j', '-d', 'address', 'show'], timeout=3))
            if self.drain_events():
                return
            wanted = self.snapshot(links)
            # Converge: a basis absent from the snapshot (address, mask, link
            # identity or eligibility differ) is retired; unchanged bases keep
            # their listeners and sessions.
            for key, basis in tuple(self.bases.items()):
                if key not in wanted:
                    self.retire(basis)
            for key, basis in wanted.items():
                self.bases.setdefault(key, basis)
            epoch = self.epoch
            for basis in tuple(self.bases.values()):
                for port, context in self.contexts:
                    if not basis.alive or port in basis.listeners:
                        continue
                    try:
                        sock = bound_socket(basis.family, basis.name, basis.local, port, index=basis.index)
                        server = await asyncio.start_server(
                            lambda r, w, b=basis: self.accept(r, w, b),
                            sock=sock, ssl=context, limit=HEADER_LIMIT,
                            **({'ssl_handshake_timeout': 5} if context else {}))
                        if epoch != self.epoch:
                            server.close()
                            return
                        if not basis.alive:
                            server.close()
                            continue
                        basis.listeners[port] = server
                    except OSError:
                        failed = True
                        logging.exception('listener unavailable for %s %s:%s', basis.name, basis.local, port)
            if not self.drain_events() and not self.dirty:
                self.trusted_ready = not failed
        except (OSError, ValueError, KeyError, subprocess.SubprocessError):
            # A failed dump is not lost event history: established sessions
            # stay judged by the continuous event stream, and trusted admission
            # stays withheld until a later snapshot succeeds.
            self.trusted_ready = False
            logging.exception('listener reconciliation unavailable')
        finally:
            loop = asyncio.get_running_loop()
            loop.call_later(2, self.retry)
            if self.dirty:
                loop.call_later(0.1, self.schedule)

    def event_fence(self):
        self.trusted_ready = False
        self.epoch += 1
        for basis in tuple(self.bases.values()):
            self.retire(basis)
        for task in tuple(self.tasks):
            task.cancel()

    def retry(self):
        # Retry partial bind/dump failures; unchanged snapshots need no churn.
        if not self.bases or not self.trusted_ready:
            self.schedule()

    async def accept(self, reader, writer, basis):
        task = asyncio.current_task()
        if len(self.tasks) >= MAX_CONNECTIONS or not basis.alive:
            writer.close()
            return
        self.tasks.add(task)
        basis.tasks.add(task)
        basis.writers.add(writer)
        backend = None
        pumps = []
        async def pump(source, sink):
            while True:
                data = await asyncio.wait_for(source.read(65536), 120)
                if not data:
                    return
                sink.write(data)
                await asyncio.wait_for(sink.drain(), 10)
        try:
            raw = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 5)
            head = parse_head(raw)
            peer = writer.get_extra_info('peername')[0]
            local = writer.get_extra_info('sockname')[0]
            if self.drain_events():
                self.schedule()
            trusted = privileged(head, basis.direct and self.trusted_ready, peer, basis.cidr)
            if not basis.alive:
                return
            if trusted:
                try:
                    upstream, backend = await asyncio.wait_for(asyncio.open_unix_connection(self.unix_path, limit=HEADER_LIMIT), 3)
                except (OSError, asyncio.TimeoutError):
                    trusted = False
            if trusted:
                evidence = json.dumps(dict(version=1, peer=peer, interface=basis.name, local=local), separators=(',', ':'))
                raw = raw[:-2] + b'X-Ceralive-Button-Path: ' + evidence.encode() + b'\r\n\r\n'
            else:
                upstream, backend = await asyncio.wait_for(asyncio.open_connection(*self.backend_address, limit=HEADER_LIMIT), 3)
                # Ordinary HTTP is one request per connection. An ordinary WS
                # remains ordinary for its entire lifetime, never reclassified.
                if head[2].get('upgrade', '').lower() != 'websocket':
                    lines = raw[:-4].split(b'\r\n')
                    raw = b'\r\n'.join([lines[0]] + [x for x in lines[1:] if not x.lower().startswith(b'connection:')]) + b'\r\nConnection: close\r\n\r\n'
            basis.writers.add(backend)
            if self.drain_events():
                self.schedule()
            if not basis.alive:
                return
            backend.write(raw)
            await asyncio.wait_for(backend.drain(), 5)
            if not trusted:
                # HTTP POST bodies must flow before the backend can respond.
                pumps.append(asyncio.create_task(pump(reader, backend)))
            # Inspect upstream response before tunnelling: no second HTTP request
            # may reach the private endpoint after a rejected upgrade.
            response = await asyncio.wait_for(upstream.readuntil(b'\r\n\r\n'), 5)
            writer.write(response)
            await asyncio.wait_for(writer.drain(), 5)
            if trusted and not response.startswith(b'HTTP/1.1 101 '):
                return
            if trusted:
                pumps.append(asyncio.create_task(pump(reader, backend)))
            pumps.append(asyncio.create_task(pump(upstream, writer)))
            await asyncio.wait(pumps, return_when=asyncio.FIRST_COMPLETED)
        except (OSError, ValueError, asyncio.TimeoutError, asyncio.IncompleteReadError, asyncio.LimitOverrunError):
            pass
        finally:
            for p in pumps:
                p.cancel()
            for w in (writer, backend):
                if w:
                    w.close()
                    basis.writers.discard(w)
            basis.tasks.discard(task)
            self.tasks.discard(task)
            await asyncio.gather(*pumps, return_exceptions=True)

    async def run(self):
        self.loop = asyncio.get_running_loop()
        self.loop.add_reader(self.monitor, self.event)
        self.schedule()
        try:
            await asyncio.Future()
        finally:
            self.event_fence()
            self.loop.remove_reader(self.monitor)
            self.monitor.close()


def main():
    logging.basicConfig(level=logging.INFO)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    directory = Path('/data/ceralive/tls')
    if not directory.is_dir():
        directory = Path('/etc/ceralive/tls')
    context.load_cert_chain(directory / 'ceralive.crt', directory / 'ceralive.key')
    asyncio.run(FrontDoor([(80, None), (443, context)]).run())


if __name__ == '__main__':
    main()

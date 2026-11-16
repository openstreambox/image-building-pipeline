#!/usr/bin/python3
"""Image-owned, per-cellular-link CLAT. NetworkManager remains link owner."""
import hashlib
import ipaddress as ip
import json
import os
import re
from pathlib import Path
import signal
import socket
import subprocess
import time
import sys
import uuid

RUN = Path('/run/ceralive/clat')
TAYGA = '/usr/sbin/tayga'
BOOT_ID = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
INVOCATION_ID = os.environ.get('INVOCATION_ID') or uuid.uuid4().hex
MAX_AGE = 30
# 32 IPv4 /24 blocks of 10.254.0.0/19, each without its .0 address.
MAX_INDEX = 32 * 255


def boot_time():
    # Includes suspend; the lease must expire while the machine is asleep too.
    return time.clock_gettime(time.CLOCK_BOOTTIME)


def atomic_json(path, data, durable=False):
    temp = path.with_suffix('.tmp')
    with temp.open('w') as stream:
        os.fchmod(stream.fileno(), 0o600 if durable else 0o644)
        stream.write(json.dumps(data) + '\n')
        if durable:
            stream.flush()
            os.fsync(stream.fileno())
    temp.replace(path)
    if durable:
        fd = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


def undo_absent(args):
    # Never infer absence from translated stderr or another failed command.
    if args[:4] == ['nft', 'delete', 'table', 'inet']:
        tables = json.loads(command('nft', '-j', 'list', 'tables'))['nftables']
        return not any(t.get('table', {}).get('family') == 'inet' and
                       t['table']['name'] == args[4] for t in tables)
    if args[:3] == ['ip', 'link', 'del']:
        return not any(d['ifname'] == args[3] for d in json.loads(command('ip', '-j', 'link', 'show')))
    if args[0] == 'ip' and args[1] in ('-4', '-6'):
        family = args[1]
        if args[2:4] == ['rule', 'del']:
            rules = json.loads(command('ip', '-j', family, 'rule', 'show'))
            priority, source, table = args[5], args[7], args[9]
            return not any(str(r.get('priority')) == priority and
                           r.get('src', '').split('/')[0] == source and
                           str(r.get('table')) == table for r in rules)
        if args[2:4] == ['route', 'flush']:
            routes = json.loads(command('ip', '-j', family, 'route', 'show', 'table', 'all'))
            return not any(str(r.get('table')) == args[5] for r in routes)
        if args[2:4] == ['route', 'del']:
            routes = json.loads(command('ip', '-j', family, 'route', 'show', 'table', 'all'))
            default = '0.0.0.0/0' if family == '-4' else '::/0'
            def network(value):
                return ip.ip_network(default if value == 'default' else value, strict=False)
            return not any(network(r.get('dst', 'default')) == network(args[4]) and
                           r.get('dev') == args[6] and
                           ('metric' not in args or str(r.get('metric')) == args[8]) for r in routes)
    return False


def replay(path):
    pending = []
    for args in reversed(json.loads(path.read_text())):
        try:
            try:
                command(*args)
            except subprocess.CalledProcessError:
                if not undo_absent(args):
                    raise
        except (OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
            pending.insert(0, args)
            print(f'CLAT cleanup failed: {error}', file=sys.stderr, flush=True)
    if pending:
        atomic_json(path, pending, durable=True)
    else:
        path.unlink()
    return pending


def command(*args, check=True, data=None):
    return subprocess.run(args, input=data, text=True, capture_output=True,
                          check=check, timeout=10).stdout


def service_ipv4(index):
    # Consumers reject a .0 last octet, so every block skips it; indexes 1-255
    # keep their original 10.254.0.<index> address.
    if not 1 <= index <= MAX_INDEX:
        raise ValueError('interface index exceeds CLAT allocation')
    block, host = divmod(index - 1, 255)
    return str(ip.IPv4Address(int(ip.IPv4Address('10.254.0.0')) + block * 256 + host + 1))


def service_ipv6(index, source):
    # The private mapping is unique per uplink source: after a renumber, old
    # conntrack entries (SNAT to the old source) cannot match the new tuples.
    digest = int.from_bytes(hashlib.sha256(ip.IPv6Address(source).packed).digest()[:6], 'big')
    return str(ip.IPv6Address((0xfd4600040004 << 80) | (digest << 32) | index))


def embed(prefix, address):
    network = ip.IPv6Network(prefix)
    bits = f'{int(ip.IPv4Address(address)):032b}'
    head = f'{int(network.network_address):0128b}'[:network.prefixlen]
    if network.prefixlen == 96:
        return str(ip.IPv6Address(int(head + bits, 2)))
    before = 64 - network.prefixlen
    return str(ip.IPv6Address(int((head + bits[:before] + '00000000' + bits[before:]).ljust(128, '0'), 2)))


def prefix_from_answers(answers):
    addresses = {ip.IPv6Address(a) for a in answers}
    candidates = set()
    for address in addresses:
        for length in (32, 40, 48, 56, 64, 96):
            network = ip.IPv6Network((address, length), strict=False)
            if network.is_multicast or network.is_link_local or network.network_address == ip.IPv6Address('::'):
                continue
            if {ip.IPv6Address(embed(network, a)) for a in ('192.0.0.170', '192.0.0.171')} <= addresses:
                candidates.add(str(network))
    if len(candidates) != 1:
        raise ValueError('DNS64 must confirm one prefix with both RFC 7050 literals')
    return candidates.pop()


def discover(interface, source, resolvers):
    import dns.exception
    import dns.flags
    import dns.message
    import dns.rcode
    import dns.rdatatype
    # Only IP6Config DNS servers, through a link/source-bound socket.
    question = dns.message.make_query('ipv4only.arpa.', dns.rdatatype.AAAA)
    for resolver in resolvers:
        try:
            with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as sock:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, interface.encode() + b'\0')
                sock.bind((source, 0))
                sock.settimeout(2)
                sock.connect((resolver, 53, 0, socket.if_nametoindex(interface)))
                sock.send(question.to_wire())
                answer = dns.message.from_wire(sock.recv(4096))
            if (not question.is_response(answer) or answer.rcode() != dns.rcode.NOERROR
                    or answer.flags & dns.flags.TC):
                continue
            addresses = [str(record.address) for rrset in answer.answer
                         if rrset.name == question.question[0].name
                         and rrset.rdtype == dns.rdatatype.AAAA for record in rrset]
            return prefix_from_answers(addresses)
        except (OSError, ValueError, dns.exception.DNSException):
            continue
    raise ValueError('No validated RFC 7050 prefix from uplink DNS')


def set_forwarding(value):
    # The global switch is required by the IPv6 forward path. Its sysctl setter
    # also changes every device: preserve those independent device settings.
    devices = {p: p.read_text().strip() for p in Path('/proc/sys/net/ipv6/conf').glob('*/forwarding')
               if p.parent.name not in ('all', 'default')}
    command('sysctl', '-qw', 'net.ipv6.conf.all.forwarding=' + value)
    for path, old in devices.items():
        if path.exists():
            path.write_text(old)


def eligible(addresses):
    if any(a['family'] == 'inet' and a['scope'] == 'global' for a in addresses):
        return []
    return sorted(a['local'] for a in addresses if a['family'] == 'inet6' and a['scope'] == 'global'
            and not any(a.get(flag) for flag in ('tentative', 'deprecated', 'dadfailed', 'temporary')))


def ip6_dns(config):
    # NM 1.52 and 1.58 IP6Config.Nameservers is aay, including link-local DNS.
    return tuple(socket.inet_ntop(socket.AF_INET6, bytes(address))
                 for address in config.get('Nameservers', []))


def retry(action):
    try:
        action()
    except Exception as error:
        print(f'CLAT reconciliation failed: {error}', file=sys.stderr, flush=True)
    return True


class Controller:
    def __init__(self):
        self.links = {}

    def sync(self, wanted, observed_at=None, sharing=None):
        """sharing: whether NetworkManager runs IPv6 sharing (None: unknown)."""
        observed_at = boot_time() if observed_at is None else observed_at
        # Retry orphaned inverses even if their NM grant never returns.
        cleanup(exclude={link.index for _, link in self.links.values()}, sharing=sharing)
        for interface, (signature, link) in list(self.links.items()):
            try:
                same_index = socket.if_nametoindex(interface) == link.index
            except OSError:
                same_index = False
            if link.stopping or not same_index or wanted.get(interface) != signature or (link.process and link.process.poll() is not None):
                if link.stop():
                    del self.links[interface]
        for interface, signature in wanted.items():
            if interface not in self.links:
                try:
                    link = Link(interface, *signature)
                except (OSError, ValueError):
                    continue
                if any(other.index == link.index for _, other in self.links.values()):
                    continue
                link.start(observed_at=observed_at)
                if link.undo:
                    self.links[interface] = (signature, link)
            else:
                link = self.links[interface][1]
                if link.stopping:
                    continue
                link.observed_at = observed_at
                try:
                    link.repair_routes()
                except subprocess.SubprocessError as error:
                    if link.stop('error', str(error)):
                        del self.links[interface]
                    continue
                if time.monotonic() - getattr(link, 'refreshed', time.monotonic()) >= 60:
                    try:
                        prefix = discover(link.interface, link.source, link.resolvers)
                        link.failures = 0
                        if prefix != link.prefix:
                            if link.stop():
                                del self.links[interface]
                            continue
                    except ValueError as error:
                        link.failures += 1
                        if link.failures >= 3:
                            if link.stop('error', str(error)):
                                del self.links[interface]
                            continue
                        link.status('up', str(error))
                        continue
                    finally:
                        link.refreshed = time.monotonic()
                link.status('up')
        if sharing:
            try:
                hand_over_forwarding()
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                print(f'CLAT forwarding handover failed: {error}', file=sys.stderr, flush=True)
        if not self.links:
            cleanup(sharing=sharing)


GUARD = 'clat_guard'
NM = 'org.freedesktop.NetworkManager'


def durable_text(path, text):
    temp = path.with_suffix('.tmp')
    with temp.open('w') as stream:
        os.fchmod(stream.fileno(), 0o600)
        stream.write(text)
        stream.flush()
        os.fsync(stream.fileno())
    temp.replace(path)
    fd = os.open(path.parent, os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def guard_present():
    tables = json.loads(command('nft', '-j', 'list', 'tables')).get('nftables', [])
    return any(t.get('table', {}).get('family') == 'inet' and t['table'].get('name') == GUARD
               for t in tables)


def install_guard():
    # Global IPv6 forwarding that CLAT enabled may carry only translator
    # traffic; per-link tables narrow that further.
    if guard_present():
        return
    command('nft', '-f', '-', data=f"""create table inet {GUARD}
add chain inet {GUARD} forward {{ type filter hook forward priority -1; }}
add rule inet {GUARD} forward meta nfproto ipv6 iifname != "clat*" oifname != "clat*" drop
""")


def remove_guard():
    try:
        command('nft', 'delete', 'table', 'inet', GUARD)
    except subprocess.CalledProcessError:
        if guard_present():
            raise


def ipv6_sharing(bus=None):
    """True while NetworkManager runs an IPv6 shared connection (it then owns
    global forwarding), False when it does not, None when unknown."""
    private = None
    try:
        import dbus
        if bus is None:
            # Never create the shared connection here: main() needs it
            # attached to its main loop.
            bus = private = dbus.SystemBus(private=True)
        if not bus.name_has_owner(NM):
            return False
        def get(path, interface, name):
            return dbus.Interface(bus.get_object(NM, path), 'org.freedesktop.DBus.Properties').Get(
                interface, name, timeout=5)
        for active in get('/org/freedesktop/NetworkManager', NM, 'ActiveConnections'):
            if int(get(active, NM + '.Connection.Active', 'State')) not in (1, 2):
                continue
            path = get(active, NM + '.Connection.Active', 'Connection')
            settings = dbus.Interface(bus.get_object(NM, path), NM + '.Settings.Connection').GetSettings(timeout=5)
            if str(settings.get('ipv6', {}).get('method', '')) == 'shared':
                return True
        return False
    except Exception as error:
        print(f'CLAT forwarding owner query failed: {error}', file=sys.stderr, flush=True)
        return None
    finally:
        if private is not None:
            private.close()


def acquire_forwarding():
    """Enable global IPv6 forwarding for translation, guarded from the start.

    The record (previous value) is written first and the guard is installed
    before forwarding changes; both stay until restore or handover."""
    record = RUN / 'forwarding'
    if not record.exists():
        current = command('sysctl', '-n', 'net.ipv6.conf.all.forwarding').strip()
        if current == '1':
            return  # Another owner already forwards; never record or guard it.
        if guard_present():
            raise ValueError('CLAT forwarding guard table already owned')
        durable_text(record, current)
    install_guard()
    if command('sysctl', '-n', 'net.ipv6.conf.all.forwarding').strip() != '1':
        set_forwarding('1')


def hand_over_forwarding():
    # NetworkManager shared mode now needs forwarding and never resets it:
    # forget the old value so CLAT never writes 0 over it, then unguard.
    record = RUN / 'forwarding'
    if record.exists():
        remove_guard()
        record.unlink()


def restore_forwarding(sharing=None):
    record = RUN / 'forwarding'
    if not record.exists():
        return
    if sharing is None:
        sharing = ipv6_sharing()
    if sharing is None:
        raise OSError('cannot tell whether another owner needs IPv6 forwarding')
    if sharing:
        hand_over_forwarding()
        return
    set_forwarding(record.read_text().strip())
    if ipv6_sharing() is True:
        # An owner appeared during the write: give its forwarding back.
        set_forwarding('1')
        hand_over_forwarding()
        return
    # Forwarding is off again before the guard goes.
    remove_guard()
    record.unlink()


class Link:
    def __init__(self, interface, source, gateway, resolvers, activation=None):
        if not re.fullmatch(r'[A-Za-z0-9_.:-]{1,15}', interface):
            raise ValueError('unsupported interface name')
        source = str(ip.IPv6Address(source))
        gateway = str(ip.IPv6Address(gateway)) if gateway else ''
        self.interface, self.source, self.gateway, self.resolvers = interface, source, gateway, resolvers
        self.index = socket.if_nametoindex(interface)
        self.v4 = service_ipv4(self.index)
        self.tun = f'clat{self.index}'
        self.table = str(46000 + self.index)
        self.priority = str(10000 + self.index)
        self.v6 = service_ipv6(self.index, source)
        self.nft = f'clat_{self.index}'
        self.process = None
        self.undo = []
        self.prefix = None
        self.failures = 0
        self.generation = uuid.uuid4().hex
        self.stopping = False
        self.final_state, self.final_error = 'down', None
        self.observed_at = boot_time()
        self.tun_index = None

    def status(self, state, error=None):
        try:
            RUN.mkdir(parents=True, exist_ok=True)
            path = RUN / f'{self.index}.json'
            now = boot_time()
            if state == 'up' and (now >= self.observed_at + MAX_AGE or
                                  self.observed_at > now or
                                  not self.process or self.process.poll() is not None):
                state, error = 'unavailable', 'liveness observation expired or translator exited'
            observed = self.observed_at if state == 'up' else now
            atomic_json(path, dict(schema_version=2, interface=self.interface,
                ifindex=self.index, tun=self.tun, tun_ifindex=self.tun_index,
                prefix=self.prefix, ipv4=self.v4, state=state, last_error=error,
                boot_id=BOOT_ID, invocation_id=INVOCATION_ID, generation=self.generation,
                updated_at=int(time.time()), observed_at=observed,
                expires_at=observed + MAX_AGE if state == 'up' else observed))
            return True
        except OSError as error:
            print(f'CLAT {self.interface} status write failed: {error}', file=sys.stderr, flush=True)
            return False

    def add(self, args, undo):
        self.undo.append(undo)
        self.save_cleanup()
        try:
            command(*args)
        except subprocess.CalledProcessError:
            self.undo.pop()
            self.save_cleanup()
            raise

    def save_cleanup(self):
        atomic_json(RUN / f'{self.index}.cleanup', self.undo, durable=True)

    def repair_routes(self):
        # Device down/up removes these routes without changing NM's grant.
        for family, route in [('-4', ['default', 'dev', self.tun, 'mtu', str(self.ipv4_mtu)]),
                              ('-6', ['default'] + (['via', self.gateway, 'onlink'] if self.gateway else []) + ['dev', self.interface])]:
            command('ip', family, 'route', 'replace', 'table', self.table, *route)
        command('ip', '-6', 'route', 'replace', self.v6 + '/128', 'dev', self.tun)
        command('ip', '-4', 'route', 'replace', 'default', 'dev', self.tun, 'metric', self.table, 'mtu', str(self.ipv4_mtu))

    def start(self, observed_at=None):
        self.observed_at = boot_time() if observed_at is None else observed_at
        # Never admit a new activation before the prior inverse has settled.
        journal = RUN / f'{self.index}.cleanup'
        try:
            if journal.exists():
                if not self.status('unavailable', 'cleanup replay in progress'):
                    return
                if replay(journal):
                    self.status('error', 'cleanup replay incomplete')
                    return
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            self.status('error', str(error))
            return
        self.generation = uuid.uuid4().hex
        self.stopping = False
        try:
            self.prefix = discover(self.interface, self.source, self.resolvers)
            self.refreshed = time.monotonic()
            # Refuse overlap with any existing local IPv4 subnet.
            for device in json.loads(command('ip', '-j', 'addr')):
                for address in device['addr_info']:
                    if address['family'] == 'inet' and ip.IPv4Address(self.v4) in ip.IPv4Network((address['local'], address['prefixlen']), strict=False):
                        raise ValueError('CLAT service IPv4 allocation overlaps a local subnet')
            if self.tun in dict(socket.if_nameindex()).values():
                raise ValueError('CLAT TUN already owned')
            for family in ('-4', '-6'):
                routes = command('ip', '-j', family, 'route', 'show', 'table', self.table, check=False)
                if json.loads(routes or '[]'):
                    raise ValueError('CLAT routing table already owned')
                rules = json.loads(command('ip', '-j', family, 'rule'))
                if any(str(rule.get('priority')) == self.priority for rule in rules):
                    raise ValueError('CLAT rule priority already owned')
            tables = json.loads(command('nft', '-j', 'list', 'tables')).get('nftables', [])
            if any(t.get('table', {}).get('family') == 'inet' and
                   t['table'].get('name') == self.nft for t in tables):
                raise ValueError('CLAT firewall table already owned')
            if not self.status('starting'):
                return
            acquire_forwarding()
            cfg = RUN / f'{self.index}.conf'
            cfg.write_text(f'tun-device {self.tun}\nipv4-addr 192.0.0.2\nipv6-addr fd46:4:ffff::{self.index:x}\nprefix {self.prefix}\nmap {self.v4} {self.v6}\n')
            self.add([TAYGA, '-c', str(cfg), '--mktun'], ['ip', 'link', 'del', self.tun])
            command('ip', 'link', 'set', self.tun, 'up')
            mtu = int(json.loads(command('ip', '-j', 'link', 'show', 'dev', self.interface))[0]['mtu'])
            # 1280 is the IPv6 minimum link MTU; the translated IPv4 side is
            # 20 bytes smaller (1260 at that minimum), which IPv4 permits.
            if mtu < 1280:
                raise ValueError('uplink MTU below the IPv6 minimum of 1280')
            self.ipv4_mtu = mtu - 20
            command('ip', 'link', 'set', self.tun, 'mtu', str(mtu))
            command('ip', 'addr', 'add', self.v4 + '/32', 'dev', self.tun)
            # Loose checks are needed only on our synthetic link; do not change WAN settings.
            command('sysctl', '-qw', f'net.ipv4.conf.{self.tun}.rp_filter=2')
            for family, route in [('-4', ['default', 'dev', self.tun, 'mtu', str(self.ipv4_mtu)]),
                                  ('-6', ['default'] + (['via', self.gateway, 'onlink'] if self.gateway else []) + ['dev', self.interface])]:
                self.add(['ip', family, 'route', 'add', 'table', self.table] + route,
                         ['ip', family, 'route', 'flush', 'table', self.table])
            for family, src in [('-4', self.v4), ('-6', self.v6)]:
                self.add(['ip', family, 'rule', 'add', 'priority', self.priority, 'from', src, 'lookup', self.table],
                         ['ip', family, 'rule', 'del', 'priority', self.priority, 'from', src, 'lookup', self.table])
            self.add(['ip', '-6', 'route', 'add', self.v6 + '/128', 'dev', self.tun],
                     ['ip', '-6', 'route', 'del', self.v6 + '/128', 'dev', self.tun])
            self.add(['ip', '-4', 'route', 'add', 'default', 'dev', self.tun, 'metric', self.table, 'mtu', str(self.ipv4_mtu)],
                     ['ip', '-4', 'route', 'del', 'default', 'dev', self.tun, 'metric', self.table])
            self.add(['nft', 'create', 'table', 'inet', self.nft],
                     ['nft', 'delete', 'table', 'inet', self.nft])
            # The reply route points to the LAN, so rt mtu alone would use its
            # larger MTU. Cap both directions at this translator's IPv4 ceiling.
            command('nft', '-f', '-', data=f'''add chain inet {self.nft} post {{ type nat hook postrouting priority 110; }}
add rule inet {self.nft} post oifname "{self.tun}" ip saddr != {self.v4} snat ip to {self.v4}
add rule inet {self.nft} post oifname "{self.interface}" ip6 saddr {self.v6} snat ip6 to {self.source}
add chain inet {self.nft} mss_forward {{ type filter hook forward priority mangle; }}
add rule inet {self.nft} mss_forward meta nfproto ipv4 oifname "{self.tun}" tcp flags & syn == syn tcp option maxseg size > {self.ipv4_mtu - 40} tcp option maxseg size set {self.ipv4_mtu - 40}
add rule inet {self.nft} mss_forward meta nfproto ipv4 iifname "{self.tun}" tcp flags & syn == syn tcp option maxseg size > {self.ipv4_mtu - 40} tcp option maxseg size set {self.ipv4_mtu - 40}
add chain inet {self.nft} mss_output {{ type route hook output priority mangle; }}
add rule inet {self.nft} mss_output meta nfproto ipv4 oifname "{self.tun}" tcp flags & syn == syn tcp option maxseg size > {self.ipv4_mtu - 40} tcp option maxseg size set {self.ipv4_mtu - 40}
add chain inet {self.nft} forward {{ type filter hook forward priority 0; }}
add rule inet {self.nft} forward iifname "{self.tun}" oifname "{self.interface}" ip6 saddr {self.v6} ip6 daddr {self.prefix} accept
add rule inet {self.nft} forward iifname "{self.interface}" oifname "{self.tun}" ip6 daddr {self.v6} ct state established,related accept
add rule inet {self.nft} forward meta nfproto ipv6 iifname "{self.tun}" drop
add rule inet {self.nft} forward meta nfproto ipv6 oifname "{self.tun}" drop
''')
            self.process = subprocess.Popen([TAYGA, '-c', str(cfg), '-n', '-u', 'nobody', '-g', 'nogroup'])
            time.sleep(.1)
            if self.process.poll() is not None:
                raise RuntimeError('tayga exited during startup')
            self.tun_index = socket.if_nametoindex(self.tun)
            self.status('up')
        except Exception as error:
            self.stop('error', str(error))

    def stop(self, state='down', error=None):
        if not self.stopping:
            self.final_state, self.final_error = state, error
        self.stopping = True
        # Invalidation is the commit point before any destructive action.
        if not self.status('unavailable', self.final_error or 'cleanup in progress'):
            return False
        try:
            if self.process and self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=3)
            journal = RUN / f'{self.index}.cleanup'
            if self.undo and not journal.exists():
                self.save_cleanup()
            if journal.exists():
                self.undo = replay(journal)
            if self.undo:
                self.status('error', 'cleanup incomplete')
                return False
        except (OSError, ValueError, subprocess.SubprocessError) as failure:
            self.status('error', f'cleanup incomplete: {failure}')
            return False
        return self.status(self.final_state, self.final_error)


def main():
    import dbus
    import dbus.mainloop.glib
    from gi.repository import GLib
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    name = 'org.freedesktop.NetworkManager'
    controller = Controller()
    loop = GLib.MainLoop()
    def props(path, interface):
        return dbus.Interface(bus.get_object(name, path), 'org.freedesktop.DBus.Properties').GetAll(interface)
    def reconcile():
        observed_at = boot_time()
        wanted = {}
        try:
            manager = dbus.Interface(bus.get_object(name, '/org/freedesktop/NetworkManager'), name)
            for path in manager.GetDevices():
                try:
                    dev = props(path, name + '.Device')
                    if int(dev['DeviceType']) != 8 or int(dev['State']) != 100:
                        continue
                    interface = str(dev['IpInterface'])
                    addr = json.loads(command('ip', '-j', 'addr', 'show', 'dev', interface))[0]['addr_info']
                    sources = eligible(addr)
                    if not sources:
                        continue
                    config = props(dev['Ip6Config'], name + '.IP6Config')
                    gateway = str(config['Gateway'])
                    dns = ip6_dns(config)
                    has_default = gateway or json.loads(command('ip', '-j', '-6', 'route', 'show', 'default', 'dev', interface))
                    if sources and has_default:
                        wanted[interface] = (sources[0], gateway, dns, (str(path), str(dev['ActiveConnection'])))
                except Exception:
                    # A disappearing/incomplete device must not withdraw its neighbours.
                    continue
        except Exception:
            # Manager loss invalidates every previous grant; no stale translation.
            wanted = {}
        sharing = ipv6_sharing(bus)
        return retry(lambda: controller.sync(wanted, observed_at=observed_at, sharing=sharing))
    # D-Bus changes trigger reconciliation; periodic retry also recovers DNS/startup failures.
    pending = [False]
    def changed(*args, **kwargs):
        if not pending[0]:
            pending[0] = True
            def once():
                pending[0] = False
                reconcile()
                return False
            GLib.idle_add(once)
    bus.add_signal_receiver(changed, bus_name=name)
    def shutdown(*args):
        loop.quit()
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    GLib.timeout_add_seconds(10, reconcile)
    reconcile()
    try:
        loop.run()
    finally:
        sharing = ipv6_sharing(bus)
        controller.sync({}, sharing=sharing)
        cleanup(exclude={link.index for _, link in controller.links.values()}, sharing=sharing)


def cleanup(exclude=(), sharing=None):
    failed = False
    # Invalidate *all* old snapshots before the first destructive command.
    snapshots = {}
    for path in RUN.glob('*.json'):
        if int(path.stem) in exclude:
            continue
        try:
            data = json.loads(path.read_text())
            now = boot_time()
            for key, value in dict(ifindex=int(path.stem), tun_ifindex=None, boot_id=BOOT_ID,
                                   invocation_id=INVOCATION_ID, generation=uuid.uuid4().hex).items():
                data.setdefault(key, value)
            data.update(schema_version=2, state='unavailable', last_error='cleanup in progress',
                        updated_at=int(time.time()), observed_at=now, expires_at=now)
            atomic_json(path, data)
            snapshots[path.stem] = data
        except (OSError, ValueError) as error:
            print(f'CLAT invalidation failed: {error}', file=sys.stderr, flush=True)
            return False
    pending = set()
    for path in RUN.glob('*.cleanup'):
        if int(path.stem) in exclude:
            continue
        try:
            if replay(path):
                pending.add(path.stem)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            print(f'CLAT recovery failed: {error}', file=sys.stderr, flush=True)
            pending.add(path.stem)
    if not list(RUN.glob('*.cleanup')) and not exclude:
        try:
            restore_forwarding(sharing)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            print(f'CLAT forwarding restore failed: {error}', file=sys.stderr, flush=True)
            failed = True
    for index, data in snapshots.items():
        now = boot_time()
        data.update(state='error' if index in pending or failed else 'down',
                    last_error='cleanup incomplete' if index in pending or failed else None,
                    updated_at=int(time.time()), observed_at=now, expires_at=now)
        atomic_json(RUN / f'{index}.json', data)
    return not pending and not failed


if __name__ == '__main__':
    settled = cleanup()
    if '--cleanup' in sys.argv:
        sys.exit(0 if settled else 1)
    main()

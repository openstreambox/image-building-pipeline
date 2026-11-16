#!/usr/bin/python3
"""Root-only synthetic network test; launch inside fresh PID/mount/network namespaces."""
import importlib.util
import json
import os
import shutil
from pathlib import Path
import socket
import struct
import sys
import subprocess as sp
import tempfile
import time

spec = importlib.util.spec_from_file_location('clat', Path(__file__).resolve().parents[1] / 'mkosi/runtime/ceralive-clat.py')
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
c.TAYGA = os.environ.get('CLAT_TEST_TAYGA', '/usr/sbin/tayga')
c.RUN = Path(tempfile.mkdtemp())
processes = []
links = []
def run(*a): return c.command(*a)
def spawn(a):
    p = sp.Popen(a); processes.append(p); return p
def ns(p, *a): return ['nsenter', '-t', str(p.pid), '-n', '--', *a]
def probe(source, port=9010, prefix=[]):
    code = "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind((%r,0)); s.settimeout(3); s.sendto(b'clat-test',('192.0.2.2',%d)); assert s.recv(100)==b'clat-test'" % (source, port)
    run(*(prefix+['python3','-c',code]))
# Exercise the callback boundary with the real GLib timer implementation.
from gi.repository import GLib
loop = GLib.MainLoop()
calls = []
def flaky_sync():
    calls.append(1)
    if len(calls) == 1:
        raise OSError('injected synchronization failure')
    loop.quit()
timer = GLib.timeout_add(1, lambda: c.retry(flaky_sync))
deadline = GLib.timeout_add(1000, lambda: (loop.quit(), False)[1])
loop.run()
GLib.source_remove(timer)
GLib.source_remove(deadline)
assert len(calls) == 2
print('PASS real GLib retry timer survives synchronization exception', flush=True)
original = c.command
bus_dir = Path(tempfile.mkdtemp(prefix='clat-contract-bus.', dir='/run'))
def ping_unrelated():
    return sp.run(ns(client,'ping','-6','-c','1','-W','1','fd51:1::2'),stdout=sp.DEVNULL,stderr=sp.DEVNULL).returncode == 0
def packet_too_big():
    fields = Path('/proc/net/snmp6').read_text().split()
    return int(fields[fields.index('Icmp6OutPktTooBigs') + 1])
def forwarding():
    return run('sysctl','-n','net.ipv6.conf.all.forwarding').strip()
def guard():
    return 'table inet clat_guard' in run('nft','list','ruleset')
try:
    run('ip','link','set','lo','up')
    # Private NetworkManager bus (outside /tmp: the real unit has PrivateTmp).
    address = 'unix:path=%s' % (bus_dir/'bus')
    bus = sp.Popen(['dbus-daemon','--session','--nofork','--address='+address,'--print-address=1'],stdout=sp.PIPE,text=True)
    processes.append(bus)
    bus.stdout.readline()
    os.environ['DBUS_SYSTEM_BUS_ADDRESS'] = address
    state = c.RUN/'nm-state';state.write_text(json.dumps({'1':30,'2':30}))
    def nm(**values):
        state.write_text(json.dumps(values))
    spawn(['/usr/bin/python3',str(Path(__file__).with_name('clat-nm-fixture.py')),address,str(state)])
    run('sysctl','-qw','net.ipv4.ip_forward=1')
    peer = spawn(['unshare','-n','sleep','300']); client = spawn(['unshare','-n','sleep','300']); time.sleep(.1)
    for p in [peer,client]: run(*ns(p,'ip','link','set','lo','up'))
    run(*ns(peer,'ip','addr','add','192.0.2.2/32','dev','lo'))
    run(*ns(peer,'sysctl','-qw','net.ipv4.ip_forward=1'))
    run(*ns(peer,'sysctl','-qw','net.ipv6.conf.all.forwarding=1'))
    cfg=c.RUN/'nat64.conf';cfg.write_text('tun-device nat64\nipv4-addr 192.0.2.254\nipv6-addr fd50::64\nprefix fd64:51::/96\ndynamic-pool 192.168.255.0/24\n')
    run(*ns(peer,c.TAYGA,'-c',str(cfg),'--mktun'))
    run(*ns(peer,'ip','link','set','nat64','up'))
    run(*ns(peer,'ip','-6','route','add','fd64:51::/96','dev','nat64'))
    run(*ns(peer,'ip','route','add','192.168.255.0/24','dev','nat64'))
    spawn(ns(peer,c.TAYGA,'-c',str(cfg),'-d'))
    sink="""import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(('192.0.2.2',9010))
while True:
 b,a=s.recvfrom(65535);s.sendto(b,a)
"""
    spawn(ns(peer,'python3','-c',sink))
    dns="""import socket,struct,pathlib
s=socket.socket(socket.AF_INET6,socket.SOCK_DGRAM);s.bind(('::',53))
while True:
 b,a=s.recvfrom(999);q=b[12:];ans=b''
 for v in (['fd64:51::1','fd64:51::2'] if pathlib.Path(%r).exists() else ['fd64:51::c000:aa','fd64:51::c000:ab']):
  ans+=bytes.fromhex('c00c001c00010000001e0010')+socket.inet_pton(socket.AF_INET6,v)
 s.sendto(b[:2]+bytes.fromhex('81800001000200000000')+q+ans,a)
"""
    dns = dns % str(c.RUN/'bad-dns')
    spawn(ns(peer,'python3','-c',dns))
    for i in [1,2]:
        wan=f'cell.{i}';srv=f'srv{i}'
        run('ip','link','add',wan,'type','veth','peer','name',srv)
        run('ip','link','set',srv,'netns',str(peer.pid))
        for a,dev,p in [(f'fd51:{i}::1/'+('128' if i==2 else '64'),wan,None),(f'fd51:{i}::2/64',srv,peer)]:
            cmd=['ip','addr','add',a,'dev',dev,'nodad']; run(*(ns(p,*cmd) if p else cmd))
            cmd=['ip','link','set',dev,'up'];run(*(ns(p,*cmd) if p else cmd))
        if i == 2:
            run('ip','-6','route','add','fd51:2::2/128','dev','cell.2')
        time.sleep(.5)
        run('sysctl','-qw',f'net/ipv6/conf/{wan}/accept_ra=0')
        run('sysctl','-qw',f'net/ipv6/conf/{wan}/forwarding=0')
        link=c.Link(wan,f'fd51:{i}::1',f'fd51:{i}::2',[f'fd51:{i}::2']);links.append(link)
        if i == 1:
            # A foreign table must survive a refused ownership claim.
            run('nft','create','table','inet',link.nft)
            link.start()
            assert not link.undo
            run('nft','list','table','inet',link.nft)
            run('nft','delete','table','inet',link.nft)
        link.start()
        assert json.loads((c.RUN/f'{link.index}.json').read_text())['state']=='up', (c.RUN/f'{link.index}.json').read_text()
        probe(link.v4)
    print('PASS two IPv6-only links: source-bound IPv4 echo over real tayga/NAT64',flush=True)
    run('ip','link','add','lan0','type','veth','peer','name','cli0');run('ip','link','set','cli0','netns',str(client.pid))
    run('ip','addr','add','10.42.0.1/24','dev','lan0');run('ip','link','set','lan0','up')
    run(*ns(client,'ip','addr','add','10.42.0.2/24','dev','cli0'));run(*ns(client,'ip','link','set','cli0','up'));run(*ns(client,'ip','route','add','default','via','10.42.0.1'))
    probe('10.42.0.2',prefix=ns(client))
    print('PASS hotspot NAT44 + CLAT + NAT64',flush=True)
    if '--service-only' not in sys.argv:
        sender=os.environ['CLAT_TEST_SENDER'];receiver=os.environ['CLAT_TEST_RECEIVER']
        received=c.RUN/'received'
        sink2="""import socket,pathlib
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(('192.0.2.2',9002))
while True:
 b,a=s.recvfrom(999)
 if b.endswith(b'CLAT'):open(%r,'ab').write(b)
""" % str(received)
        spawn(ns(peer,'python3','-c',sink2));spawn(ns(peer,receiver,'9000','192.0.2.2','9002'))
        for link in links:
            ips=c.RUN/'ips';ips.write_text(link.v4+'\n')
            snd=spawn([sender,'--verbose','9001','192.0.2.2','9000',str(ips)])
            time.sleep(3)
            before=received.stat().st_size if received.exists() else 0
            u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
            for i in range(30): u.sendto(struct.pack('!IIII',i,0,0,1)+b'CLAT',('127.0.0.1',9001));time.sleep(.02)
            time.sleep(.3);assert received.stat().st_size>before
            snd.terminate();snd.wait(timeout=3)
        print('PASS real srtla_send -> IPv4 srtla_rec through each CLAT',flush=True)
    controller=c.Controller()
    for link in links:controller.links[link.interface]=((link.source,link.gateway,link.resolvers),link)
    # A flap drops owned IPv6 routes even when NM restores the same grant.
    signature = {link.interface: (link.source,link.gateway,link.resolvers) for link in links}
    run('ip','link','set','cell.2','down')
    run('ip','link','set','cell.2','up')
    run('ip','addr','replace','fd51:2::1/128','dev','cell.2','nodad')
    run('ip','-6','route','replace','fd51:2::2/128','dev','cell.2')
    controller.sync(signature)
    assert json.loads(run('ip','-j','-6','route','show','table',links[1].table))
    probe(links[1].v4)
    print('PASS route repair after interface flap',flush=True)
    for link in links:
        assert run('sysctl','-n',f'net/ipv6/conf/{link.interface}/accept_ra').strip() == '0'
        assert run('sysctl','-n',f'net/ipv6/conf/{link.interface}/forwarding').strip() == '0'
    # Observe fragments before conntrack reassembly on the NAT64 peer. Default
    # sockets deliberately retain IP_PMTUDISC_WANT, as ordinary senders do.
    run(*ns(peer,'nft','add','table','inet','fragment_probe'))
    run(*ns(peer,'nft','add','chain','inet','fragment_probe','ingress',
            '{ type filter hook prerouting priority -450; }'))
    run(*ns(peer,'nft','add','rule','inet','fragment_probe','ingress',
            'ip6','nexthdr','44','counter'))
    def fragments():
        rules = json.loads(run(*ns(peer,'nft','-j','list','chain','inet','fragment_probe','ingress')))
        return sum(expr['counter']['packets'] for item in rules['nftables']
                   for expr in item.get('rule', {}).get('expr', []) if 'counter' in expr)
    bulk_server = """import socket
s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('192.0.2.2',9012));s.listen()
while True:
 c,a=s.accept();total=0
 while True:
  b=c.recv(65535)
  if not b:break
  total+=len(b)
 c.sendall(str(total).encode());c.close()
"""
    spawn(ns(peer,'python3','-c',bulk_server));time.sleep(.2)
    default_udp = """import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind((%r,0));s.settimeout(3)
for size in (1332,1372,1452):
 b=b'x'*size;s.sendto(b,('192.0.2.2',9010));assert s.recv(65535)==b
"""
    default_tcp = """import socket
s=socket.socket();s.bind((%r,0));s.settimeout(3);s.connect(('192.0.2.2',9012))
s.sendall(b'x'*200000);s.shutdown(socket.SHUT_WR)
assert s.recv(100)==b'200000'
"""
    for label, source, prefix in [('box '+link.interface,link.v4,[]) for link in links] + [('hotspot','10.42.0.2',ns(client))]:
        for protocol, code in [('UDP',default_udp),('TCP',default_tcp)]:
            before_fragments = fragments()
            run(*(prefix+['python3','-c',code % source]))
            count = fragments()-before_fragments
            assert count == 0, (label,protocol,count)
            print(f'PASS default-socket {label} {protocol}: zero IPv6 fragments',flush=True)
    run(*ns(peer,'nft','delete','table','inet','fragment_probe'))
    # A single transmission must fit in both directions without PTB/retry.
    before = packet_too_big()
    large = """import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.bind((%r,0));s.settimeout(3)
s.setsockopt(socket.IPPROTO_IP,10,2) # IP_MTU_DISCOVER = IP_PMTUDISC_DO
b=b'x'*1452 # IPv4 total 1480, translated IPv6 total 1500
s.sendto(b,('192.0.2.2',9010));assert s.recv(65535)==b
"""
    for link in links:
        run('python3','-c',large % link.v4)
        assert int(json.loads(run('ip','-j','link','show','dev',link.tun))[0]['mtu']) == 1500
        for args in [('table',link.table),('dev',link.tun)]:
            routes = json.loads(run('ip','-j','-4','route','show',*args))
            default = next(r for r in routes if r['dst']=='default')
            metrics = default['metrics']
            if isinstance(metrics, list):
                metrics = {key: value for item in metrics for key, value in item.items()}
            assert metrics['mtu'] == 1480, default
            assert 'mtu 1480' in run('ip','-4','route','show',*args), default
            assert 'lock' not in run('ip','-4','route','show',*args), default
    run(*ns(client,'python3','-c',large % '10.42.0.2'))
    assert packet_too_big() == before
    print('PASS DF-forced IPv4 1480 / IPv6 1500 datagram each way without PTB',flush=True)
    # Check negotiated MSS at both ends, including the hotspot's 1500-byte LAN.
    tcp_server="""import socket,pathlib
s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('192.0.2.2',9011));s.listen()
while True:
 c,a=s.accept();m=c.getsockopt(socket.IPPROTO_TCP,socket.TCP_MAXSEG)
 c.sendall(str(m).encode());c.close()
"""
    spawn(ns(peer,'python3','-c',tcp_server));time.sleep(.2)
    tcp_client="""import socket
s=socket.socket();s.bind((%r,0));s.settimeout(3);s.connect(('192.0.2.2',9011))
m=s.getsockopt(socket.IPPROTO_TCP,socket.TCP_MAXSEG)
r=int(s.recv(100));assert 1400 <= m <= 1440 and 1400 <= r <= 1440,(m,r)
"""
    for link in links:run('python3','-c',tcp_client % link.v4)
    run(*ns(client,'python3','-c',tcp_client % '10.42.0.2'))
    small = tcp_client.replace("s.bind(", "s.setsockopt(socket.IPPROTO_TCP,socket.TCP_MAXSEG,1200);s.bind(").replace('1400 <= m <= 1440 and 1400 <= r <= 1440', '1100 <= m <= 1200 and 1100 <= r <= 1200')
    run('python3','-c',small % links[0].v4)
    run(*ns(client,'python3','-c',small % '10.42.0.2'))
    print('PASS TCP MSS clamp for box and hotspot in both directions, smaller MSS preserved',flush=True)
    # Unrelated IPv6 traffic must not inherit forwarding enabled for CLAT.
    run('ip','addr','add','fd52::1/64','dev','lan0','nodad')
    run(*ns(client,'ip','addr','add','fd52::2/64','dev','cli0','nodad'))
    run(*ns(client,'ip','-6','route','add','fd51:1::/64','via','fd52::1'))
    run('ip','-6','route','add','fd51:1::/64','dev','cell.1')
    run(*ns(peer,'ip','-6','route','add','fd52::/64','via','fd51:1::1'))
    ping=ns(client,'ping','-6','-c','1','-W','1','fd51:1::2')
    assert sp.run(ping,stdout=sp.DEVNULL,stderr=sp.DEVNULL).returncode != 0
    # Stop all links, then emulate another owner's pre-existing forwarding.
    controller.sync({})
    assert run('sysctl','-n','net.ipv6.conf.all.forwarding').strip() == '0'
    run('sysctl','-qw','net.ipv6.conf.all.forwarding=1')
    for link in links:link.start()
    assert sp.run(ping,stdout=sp.DEVNULL,stderr=sp.DEVNULL).returncode == 0
    for link in links:link.stop()
    c.restore_forwarding()
    assert run('sysctl','-n','net.ipv6.conf.all.forwarding').strip() == '1'
    run('sysctl','-qw','net.ipv6.conf.all.forwarding=0')
    # The forwarding guard exists before forwarding does, whatever step a
    # startup crash interrupts; real unrelated IPv6 packets stay blocked.
    def crash_at(step):
        def command(*args, **kwargs):
            result = original(*args, **kwargs)
            if (step == 'guard' and args[:2] == ('nft','-f') and 'clat_guard' in (kwargs.get('data') or '')) or \
               (step == 'forwarding' and args[:2] == ('sysctl','-qw') and args[2] == 'net.ipv6.conf.all.forwarding=1'):
                raise SystemExit('simulated crash after '+step)
            return result
        return command
    for step in ('forwarding','guard'):
        crashing = c.Link('cell.1', *signature['cell.1'])
        c.command = crash_at(step)
        try:
            crashing.start()
        except SystemExit:
            pass
        finally:
            c.command = original
        assert not ping_unrelated(), step
        assert guard(), step
        assert forwarding() == ('1' if step == 'forwarding' else '0'), step
        assert c.cleanup(sharing=False)
        assert forwarding() == '0' and not guard(), step
    # A later inverse fails after the link's own nft table is gone.
    failing = c.Link('cell.1', *signature['cell.1']); failing.start()
    assert failing.undo and guard() and forwarding() == '1'
    stubs = c.RUN/'ip-stub'; stubs.mkdir()
    real_ip = run('which','ip').strip()
    (stubs/'ip').write_text('#!/bin/sh\ncase " $* " in *" route flush "*) exit 1;; esac\nexec '+real_ip+' "$@"\n')
    (stubs/'ip').chmod(0o755)
    old_path = os.environ['PATH']; os.environ['PATH'] = str(stubs)+':'+old_path
    try:
        assert not failing.stop()
        assert failing.nft not in run('nft','list','ruleset')
        assert any(undo[2:4] == ['route','flush'] for undo in json.loads((c.RUN/f'{failing.index}.cleanup').read_text()))
        assert not c.cleanup(sharing=False)
        assert forwarding() == '1'
        assert not ping_unrelated()
        assert guard()
    finally:
        os.environ['PATH'] = old_path
    assert c.cleanup(sharing=False)
    assert forwarding() == '0' and not guard()
    print('PASS forwarding guard precedes forwarding and outlives startup crashes and a failed later inverse',flush=True)
    # NetworkManager IPv6 sharing that starts after CLAT owns forwarding from then on.
    controller.sync(signature, sharing=c.ipv6_sharing())
    assert guard() and forwarding() == '1' and not ping_unrelated()
    nm(**{'1':30,'2':30,'shared6':True}); run('sysctl','-qw','net.ipv6.conf.all.forwarding=1')  # as NM does
    assert c.ipv6_sharing() is True
    controller.sync(signature, sharing=c.ipv6_sharing())
    assert not guard() and ping_unrelated()
    controller.sync({}, sharing=c.ipv6_sharing())
    assert not controller.links and forwarding() == '1' and ping_unrelated()
    # Reverse order: sharing first, then CLAT starts and stops (here through
    # the cleanup entrypoint, which asks NetworkManager itself).
    reverse = [c.Link(name, *grant) for name, grant in signature.items()]
    for link in reverse:
        link.start(); assert link.undo
    assert not guard() and ping_unrelated()
    for link in reverse:
        assert link.stop()
    assert c.cleanup()
    assert forwarding() == '1' and ping_unrelated()
    nm(**{'1':30,'2':30}); run('sysctl','-qw','net.ipv6.conf.all.forwarding=0')
    assert c.ipv6_sharing() is False
    print('PASS IPv6 forwarding handed to NetworkManager sharing that starts after CLAT, never reset under it',flush=True)
    # Renumber on the same ifindex: an unchanged IPv4 tuple (fixed ports,
    # sockets reopened) must not inherit the old SNAT binding.
    controller.sync(signature, sharing=False)
    tun = controller.links['cell.1'][1].tun
    assert f'dev {tun} ' in run('ip','route','get','192.0.2.2','from','10.42.0.2','iif','lan0')
    fixed = """import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind((%r,%d));s.settimeout(3)
s.sendto(b'renumber',('192.0.2.2',9010));assert s.recv(100)==b'renumber'
"""
    def fixed_probes():
        run('python3','-c',fixed % (controller.links['cell.1'][1].v4, 40000))
        run(*ns(client,'python3','-c',fixed % ('10.42.0.2', 40001)))
    fixed_probes()
    run('ip','addr','add','fd51:1::5/64','dev','cell.1','nodad')
    run('ip','addr','del','fd51:1::1/64','dev','cell.1')
    # The network no longer delivers to the old address.
    run(*ns(peer,'nft','add','table','inet','renumbered'))
    run(*ns(peer,'nft','add','chain','inet','renumbered','out','{ type filter hook output priority 0; }'))
    run(*ns(peer,'nft','add','rule','inet','renumbered','out','ip6','daddr','fd51:1::1','drop'))
    run(*ns(peer,'nft','add','chain','inet','renumbered','through','{ type filter hook forward priority 0; }'))
    run(*ns(peer,'nft','add','rule','inet','renumbered','through','ip6','daddr','fd51:1::1','drop'))
    renumbered = dict(signature, **{'cell.1': ('fd51:1::5',)+tuple(signature['cell.1'][1:])})
    old_v6 = controller.links['cell.1'][1].v6
    controller.sync(renumbered, sharing=False)
    assert json.loads((c.RUN/f"{controller.links['cell.1'][1].index}.json").read_text())['state'] == 'up'
    fixed_probes()
    assert controller.links['cell.1'][1].v6 != old_v6
    run(*ns(peer,'nft','delete','table','inet','renumbered'))
    run('ip','addr','add','fd51:1::1/64','dev','cell.1','nodad')
    controller.sync(signature, sharing=False)
    run('ip','addr','del','fd51:1::5/64','dev','cell.1')
    fixed_probes()
    controller.sync({}, sharing=False)
    assert forwarding() == '0' and not guard()
    print('PASS renumbered uplink: fixed-port UDP from box and hotspot gets a fresh SNAT binding',flush=True)
    # IPv6 minimum link MTU 1280 gives IPv4 1260 (MSS 1220).
    for dev, prefix in [('cell.1',[]),('srv1',ns(peer)),('nat64',ns(peer))]:
        run(*(prefix+['ip','link','set',dev,'mtu','1280']))
    controller.sync(signature, sharing=False)
    small = json.loads((c.RUN/f"{socket.if_nametoindex('cell.1')}.json").read_text())
    assert small['state'] == 'up', small
    small_link = controller.links['cell.1'][1]
    assert int(json.loads(run('ip','-j','link','show','dev',small_link.tun))[0]['mtu']) == 1280
    assert 'mtu 1260' in run('ip','-4','route','show','table',small_link.table)
    box = ('box', small_link.v4, [])
    hotspot = ('hotspot', '10.42.0.2', ns(client))
    # Hotspot traffic must leave through the 1280 link for this check.
    assert f'dev {small_link.tun} ' in run('ip','route','get','192.0.2.2','from','10.42.0.2','iif','lan0')
    run(*ns(peer,'nft','add','table','inet','fragment_probe'))
    run(*ns(peer,'nft','add','chain','inet','fragment_probe','ingress','{ type filter hook prerouting priority -450; }'))
    run(*ns(peer,'nft','add','rule','inet','fragment_probe','ingress','ip6','nexthdr','44','counter'))
    before = packet_too_big()
    fit = """import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind((%r,0));s.settimeout(3)
s.setsockopt(socket.IPPROTO_IP,10,2) # IP_PMTUDISC_DO
b=b'x'*1232 # IPv4 total 1260, translated IPv6 total 1280
s.sendto(b,('192.0.2.2',9010));assert s.recv(65535)==b
"""
    for label, source, prefix in (box, hotspot):
        start_fragments = fragments()
        run(*(prefix+['python3','-c',fit % source]))
        assert fragments() == start_fragments, label
        run(*(prefix+['python3','-c',default_tcp % source]))
        assert fragments() == start_fragments, (label, 'TCP')
        run(*(prefix+['python3','-c',tcp_client.replace('1400 <= m <= 1440 and 1400 <= r <= 1440','1180 <= m <= 1220 and 1180 <= r <= 1220') % source]))
    assert packet_too_big() == before
    # One byte more: the box refuses locally; a hotspot client learns 1260 by ICMP.
    oversized_box = """import errno,socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind((%r,0))
s.setsockopt(socket.IPPROTO_IP,10,2)
try:
 s.sendto(b'x'*1233,('192.0.2.2',9010));raise SystemExit('oversized DF datagram was sent')
except OSError as e:
 assert e.errno==errno.EMSGSIZE,e
"""
    run('python3','-c',oversized_box % small_link.v4)
    oversized_hotspot = """import socket,time,subprocess
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(('10.42.0.2',0));s.settimeout(1)
s.setsockopt(socket.IPPROTO_IP,10,2)
s.sendto(b'x'*1233,('192.0.2.2',9010));time.sleep(.5)
assert 'mtu 1260' in subprocess.run(['ip','route','get','192.0.2.2'],capture_output=True,text=True).stdout
"""
    run(*ns(client,'python3','-c',oversized_hotspot))
    # Without DF, a large datagram is fragmented and still delivered.
    unfragmented = """import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind((%r,0));s.settimeout(3)
s.setsockopt(socket.IPPROTO_IP,10,0) # IP_PMTUDISC_DONT
b=b'y'*3000
s.sendto(b,('192.0.2.2',9010));assert s.recv(65535)==b
"""
    for label, source, prefix in (box, hotspot):
        run(*(prefix+['python3','-c',unfragmented % source]))
    run(*ns(peer,'nft','delete','table','inet','fragment_probe'))
    controller.sync({}, sharing=False)
    for dev, prefix in [('cell.1',[]),('srv1',ns(peer)),('nat64',ns(peer))]:
        run(*(prefix+['ip','link','set',dev,'mtu','1500']))
    run(*ns(client,'ip','route','flush','cache'))
    print('PASS IPv6 minimum MTU 1280: IPv4 1260 UDP/TCP without fragments or PTB, DF refusal, ICMP to hotspot, fragmented delivery',flush=True)
    controller.sync(signature)
    links = [controller.links[name][1] for name in signature]
    print('PASS scoped IPv6 filter blocks unrelated traffic and preserves prior forwarding',flush=True)
    run('ip','link','set','cell.1','down')
    controller.sync({'cell.2': (links[1].source,links[1].gateway,links[1].resolvers)})
    probe(links[1].v4)
    assert not json.loads(run('ip','-j','link','show','type','tun')) == [] # second remains
    # Native IPv4 arrives: admission excludes the former IPv6-only grant.
    run('ip','addr','add','198.51.100.1/24','dev','cell.2')
    addresses=json.loads(run('ip','-j','addr','show','dev','cell.2'))[0]['addr_info']
    assert not c.eligible(addresses)
    controller.sync({})
    assert not any('clat' in a['ifname'] for a in json.loads(run('ip','-j','link')))
    assert 'clat_' not in run('nft','list','ruleset')
    run('ip','link','set','cell.1','up')
    run('ip','addr','replace','fd51:1::1/64','dev','cell.1','nodad')
    bad=c.Link('cell.1','fd51:1::1','fd51:1::2',[]);bad.start()
    assert json.loads((c.RUN/f'{bad.index}.json').read_text())['state']=='error' and not bad.undo
    assert not any('lookup 4600' in run('ip',family,'rule') for family in ['-4','-6'])
    print('PASS link teardown, survivor, absent prefix fails closed',flush=True)
    # Exercise the actual service entrypoint against NetworkManager D-Bus state.
    state.write_text(json.dumps({'1':100,'2':100,'ipv4_only':True}))
    run('ip','addr','add','198.51.100.2/24','dev','cell.1')
    # Both dual stack: the service must create no translator.
    module=c.RUN/'runtime.py';module.write_text(Path(c.__file__).read_text())
    code = "import importlib.util,os,pathlib; s=importlib.util.spec_from_file_location('clat',%r); c=importlib.util.module_from_spec(s);s.loader.exec_module(c);c.RUN=pathlib.Path(%r);c.TAYGA=%r;os.environ['DBUS_SYSTEM_BUS_ADDRESS']=%r;c.main()" % (str(module),str(c.RUN),c.TAYGA,address)
    time.sleep(.3)
    daemon=spawn(['setpriv','--bounding-set=-all,+net_admin,+net_raw,+kill,+setuid,+setgid','--no-new-privs','/usr/bin/python3','-c',code])
    time.sleep(.7)
    assert daemon.poll() is None
    assert not any('clat' in a['ifname'] for a in json.loads(run('ip','-j','link')))
    def wait_state(index, expected):
        for _ in range(200):
            path=c.RUN/f'{index}.json'
            if path.exists() and json.loads(path.read_text())['state']==expected:return
            time.sleep(.1)
        raise AssertionError(path.read_text() if path.exists() else 'no service status')
    run('ip','addr','del','198.51.100.1/24','dev','cell.2')
    wait_state(links[1].index,'up');probe(links[1].v4)
    assert links[0].tun not in [a['ifname'] for a in json.loads(run('ip','-j','link'))]
    run('ip','addr','del','198.51.100.2/24','dev','cell.1')
    state.write_text(json.dumps({'1':100,'2':100}))
    for link in links:wait_state(link.index,'up');probe(link.v4)
    state.write_text(json.dumps({'1':100,'2':100,'ipv4_only':True}))
    wait_state(links[0].index,'down')
    assert json.loads((c.RUN/f'{links[1].index}.json').read_text())['state']=='up'
    probe(links[1].v4)
    # A live controller is not proof that its translator child survived.
    old = json.loads((c.RUN/f'{links[1].index}.json').read_text())
    children = Path(f'/proc/{daemon.pid}/task/{daemon.pid}/children').read_text().split()
    assert children
    for child in children:
        os.kill(int(child), 9)
    for _ in range(200):
        current = json.loads((c.RUN/f'{links[1].index}.json').read_text())
        if current['state'] == 'up' and current['generation'] != old['generation']:
            break
        time.sleep(.1)
    else:
        raise AssertionError('dead child was not replaced with a new activation')
    assert daemon.poll() is None
    assert current['invocation_id'] == old['invocation_id']
    assert current['boot_id'] == old['boot_id']
    assert current['observed_at'] <= c.boot_time() < current['expires_at']
    probe(links[1].v4)
    print('PASS dead tayga child with live unit/controller rotates generation and recovers', flush=True)
    state.write_text(json.dumps({'1':30,'2':100}))
    wait_state(links[0].index,'down');probe(links[1].v4)
    state.write_text(json.dumps({'1':30,'2':30}))
    wait_state(links[1].index,'down')
    daemon.terminate();daemon.wait(timeout=5)
    assert not any('clat' in a['ifname'] for a in json.loads(run('ip','-j','link')))
    (c.RUN/'bad-dns').touch()
    bad=c.Link('cell.1','fd51:1::1','fd51:1::2',['fd51:1::2']);bad.start()
    assert not bad.undo and json.loads((c.RUN/f'{bad.index}.json').read_text())['state']=='error'
    (c.RUN/'bad-dns').unlink()
    # Simulate death after creation returns, before add() can do further work.
    early=c.Link('cell.1','fd51:1::1','fd51:1::2',['fd51:1::2'])
    def crash_after_create(*args, **kwargs):
        original(*args, **kwargs)
        raise SystemExit('simulated abrupt exit')
    c.command=crash_after_create
    try:
        early.add(['ip','link','add',early.tun,'type','dummy'], ['ip','link','del',early.tun])
    except SystemExit:
        pass
    finally:
        c.command=original
    c.cleanup()
    assert early.tun not in [a['ifname'] for a in json.loads(run('ip','-j','link'))]
    print('PASS crash immediately after resource creation',flush=True)
    orphan=c.Link('cell.1','fd51:1::1','fd51:1::2',['fd51:1::2']);orphan.start()
    assert orphan.undo
    orphan.process.kill();orphan.process.wait()
    # Real nonzero subprocess exit, with real owned nft state still present.
    stubs = c.RUN/'stubs'; stubs.mkdir()
    nft = run('which', 'nft').strip()
    stub = stubs/'nft'
    stub.write_text('#!/bin/sh\nif [ "$1" = delete ]; then exit 1; fi\nexec '+nft+' "$@"\n')
    stub.chmod(0o755)
    old_path = os.environ['PATH']
    os.environ['PATH'] = str(stubs)+':'+old_path
    try:
        assert not orphan.stop()
        assert json.loads((c.RUN/f'{orphan.index}.cleanup').read_text()) == [
            ['nft','delete','table','inet',orphan.nft]]
        assert json.loads((c.RUN/f'{orphan.index}.json').read_text())['state'] == 'error'
        assert not c.cleanup()
        run('nft','list','table','inet',orphan.nft)
        assert run('sysctl','-n','net.ipv6.conf.all.forwarding').strip() == '1'
    finally:
        os.environ['PATH'] = old_path
    assert c.cleanup()
    print('PASS failed nft delete retains inverse/error/forwarding until real recovery', flush=True)
    interrupted=c.Link('cell.1','fd51:1::1','fd51:1::2',['fd51:1::2']);interrupted.start()
    assert interrupted.undo
    def crash_during_undo(*args, **kwargs):
        snapshot = json.loads((c.RUN/f'{interrupted.index}.json').read_text())
        assert snapshot['state'] == 'unavailable'
        assert snapshot['expires_at'] == snapshot['observed_at']
        original(*args, **kwargs)
        raise SystemExit('crash after first successful undo')
    c.command=crash_during_undo
    try:
        interrupted.stop()
    except SystemExit:
        pass
    finally:
        c.command=original
    assert (c.RUN/f'{interrupted.index}.cleanup').exists()
    assert c.cleanup() # replay accepts the already-absent first deletion
    # Reuse both a kernel name and explicit ifindex; activation identity changes.
    run('ip','link','add','reuse0','index','7000','type','dummy')
    reused=c.Link('reuse0','fd51:1::1','',())
    reused.status('starting'); first=json.loads((c.RUN/'7000.json').read_text())
    run('ip','link','del','reuse0')
    run('ip','link','add','reuse0','index','7000','type','dummy')
    reused=c.Link('reuse0','fd51:1::1','',())
    reused.status('starting'); second=json.loads((c.RUN/'7000.json').read_text())
    assert first['ifindex'] == second['ifindex'] == 7000
    assert first['generation'] != second['generation']
    run('ip','link','del','reuse0')
    assert not any('clat' in a['ifname'] for a in json.loads(run('ip','-j','link')))
    assert 'clat_' not in run('nft','list','ruleset')
    assert run('sysctl','-n','net.ipv6.conf.all.forwarding').strip() == '0'
    print('PASS crash during teardown, idempotent restart replay and explicit ifindex reuse', flush=True)
    print('PASS crash journal cleanup and global forwarding restoration',flush=True)
    print('PASS malformed DNS64 prefix fails closed',flush=True)
    print('PASS actual D-Bus service: dual-stack exclusion, two grants, link loss and clean stop',flush=True)
    # The installed unit file under the host's systemd, in this network
    # namespace: stop/restart must withdraw before any translator stops.
    netns = os.environ.get('CLAT_TEST_NETNS')
    if not netns:
        raise SystemExit('CLAT_TEST_NETNS must name this network namespace for the unit contract')
    assert forwarding() == '0' and not guard()
    name = 'ceralive-clat.service'
    # systemctl cannot authenticate from a PID namespace; use the system bus.
    import dbus
    system = dbus.bus.BusConnection('unix:path=/run/dbus/system_bus_socket')
    manager = dbus.Interface(system.get_object('org.freedesktop.systemd1', '/org/freedesktop/systemd1'),
                             'org.freedesktop.systemd1.Manager')
    def prop(key):
        unit = system.get_object('org.freedesktop.systemd1', manager.LoadUnit(name))
        scope = 'Service' if key in ('MainPID', 'Result', 'KillMode') else 'Unit'
        value = dbus.Interface(unit, 'org.freedesktop.DBus.Properties').Get('org.freedesktop.systemd1.'+scope, key)
        return bytes(value).hex() if key == 'InvocationID' else str(value)
    def job(method, wait=True):
        path = getattr(manager, method)(name, 'replace')
        for _ in range(900 if wait else 0):
            if path not in [j[4] for j in manager.ListJobs()]:
                return
            time.sleep(.1)
        if wait:
            raise AssertionError(f'{method} job did not finish')
    unit_run = Path('/run/ceralive/clat')
    if prop('LoadState') != 'not-found' or unit_run.exists():
        raise SystemExit('refusing to replace an existing ceralive-clat unit or its runtime directory')
    root = Path(__file__).resolve().parents[1]
    ext = Path(tempfile.mkdtemp(prefix='clat-unit.', dir='/var/tmp'))
    unit_file = Path('/run/systemd/system')/name
    dropin = Path('/run/systemd/system')/(name+'.d')
    unit_indexes = [socket.if_nametoindex('cell.1'), socket.if_nametoindex('cell.2')]
    def unit_snapshot(index):
        try:
            return json.loads((unit_run/f'{index}.json').read_text())
        except (OSError, ValueError):
            return None
    def carrier(tun):
        try:
            return Path(f'/sys/class/net/{tun}/carrier').read_text().strip() == '1'
        except OSError:
            return False
    def wait_unit_up(invocation):
        for _ in range(300):
            snaps = [unit_snapshot(i) for i in unit_indexes]
            if all(s and s['state'] == 'up' and s['invocation_id'] == invocation for s in snaps):
                return snaps
            time.sleep(.1)
        raise AssertionError(f'unit links not up: {snaps}')
    def wait_inactive():
        for _ in range(600):
            if prop('ActiveState') in ('inactive', 'failed'):
                return
            time.sleep(.1)
        raise AssertionError('unit did not stop')
    def hold_reconcile():
        # The controller is busy (here: a slow NetworkManager call) when the
        # stop arrives, as with discovery or route work on a real box.
        entered = Path(str(state)+'.entered'); slow = Path(str(state)+'.slow')
        entered.unlink(missing_ok=True); slow.touch()
        nm(**dict(json.loads(state.read_text()), tick=time.time()))
        for _ in range(200):
            if entered.exists():
                break
            time.sleep(.05)
        else:
            raise AssertionError('controller never entered the held reconciliation')
        slow.unlink()
    def watch(tun, violation):
        import threading
        done = threading.Event()
        seen = {'lost': False, 'violation': None}
        def loop():
            while not done.is_set():
                if not carrier(tun):
                    seen['lost'] = True
                    seen['violation'] = seen['violation'] or violation()
                time.sleep(.002)
        thread = threading.Thread(target=loop, daemon=True); thread.start()
        def finish():
            done.set(); thread.join(); return seen
        return finish
    def published_up(index, invocation):
        def check():
            s = unit_snapshot(index)
            return s and s['state'] == 'up' and s['invocation_id'] == invocation and 'translator stopped while published up'
        return check
    try:
        ext.chmod(0o755)
        release = ext/'usr/lib/extension-release.d'/f'extension-release.{ext.name}'
        release.parent.mkdir(parents=True); release.write_text('ID=_any\n')
        (ext/'usr/lib/ceralive').mkdir(parents=True)
        shutil.copy(root/'mkosi/runtime/ceralive-clat.py', ext/'usr/lib/ceralive/ceralive-clat')
        (ext/'usr/lib/ceralive/ceralive-clat').chmod(0o755)
        if Path(c.TAYGA) != Path('/usr/sbin/tayga'):
            (ext/'usr/sbin').mkdir(parents=True); shutil.copy(c.TAYGA, ext/'usr/sbin/tayga')
        import dns
        if Path(dns.__file__).resolve().parents[1] != Path('/usr/lib/python3/dist-packages'):
            shutil.copytree(Path(dns.__file__).resolve().parent, ext/'usr/lib/python3/dist-packages/dns')
        shutil.copy(root/'mkosi/runtime/ceralive-clat.service', unit_file)
        dropin.mkdir()
        (dropin/'50-contract.conf').write_text(f'[Service]\nNetworkNamespacePath={netns}\nExtensionDirectories={ext}\n'
                                               f'Environment=DBUS_SYSTEM_BUS_ADDRESS={address}\n')
        manager.Reload()
        nm(**{'1':100,'2':100})
        job('StartUnit')
        invocation = prop('InvocationID')
        snaps = wait_unit_up(invocation)
        tuns = {i: s['tun'] for i, s in zip(unit_indexes, snaps)}
        for s in snaps:
            probe(s['ipv4'])
        # Stop: availability is withdrawn before any translator stops.
        hold_reconcile()
        finishers = [watch(tuns[i], published_up(i, invocation)) for i in unit_indexes]
        job('StopUnit', wait=False)
        wait_inactive()
        for seen in [f() for f in finishers]:
            assert seen['lost'] and not seen['violation'], seen
        assert prop('Result') == 'success', prop('Result')
        assert prop('KillMode') == 'mixed', prop('KillMode')
        assert all(unit_snapshot(i)['state'] == 'down' for i in unit_indexes)
        assert not any('clat' in a['ifname'] for a in json.loads(run('ip','-j','link')))
        assert forwarding() == '0' and not guard()
        print('PASS installed unit stop: controller withdraws before tayga stops (KillMode=mixed), clean result', flush=True)
        # Restart: the same ordering, then a new invocation serves again.
        job('StartUnit')
        invocation = prop('InvocationID'); wait_unit_up(invocation)
        hold_reconcile()
        finishers = [watch(tuns[i], published_up(i, invocation)) for i in unit_indexes]
        job('RestartUnit', wait=False)
        for _ in range(600):
            if prop('InvocationID') not in ('', invocation) and prop('ActiveState') == 'active':
                break
            time.sleep(.1)
        restarted = prop('InvocationID')
        for s in wait_unit_up(restarted):
            probe(s['ipv4'])
        for seen in [f() for f in finishers]:
            assert seen['lost'] and not seen['violation'], seen
        print('PASS installed unit restart: ordered withdrawal, new invocation serves both links', flush=True)
        # Invalidation cannot be written: the controller keeps its translator
        # and exits; systemd kills it only after the controller is gone.
        broken = unit_indexes[0]
        (unit_run/f'{broken}.json').unlink(); (unit_run/f'{broken}.json').mkdir()
        hold_reconcile()
        finish = watch(tuns[broken], lambda: prop('MainPID') not in ('', '0') and 'translator stopped while its controller ran')
        job('StopUnit', wait=False)
        wait_inactive()
        seen = finish()
        assert seen['lost'] and not seen['violation'], seen
        assert prop('Result') != 'success'
        assert guard() and forwarding() == '1'  # retained resources stay guarded
        (unit_run/f'{broken}.json').rmdir()
        manager.ResetFailedUnit(name)
        job('StartUnit')
        for s in wait_unit_up(prop('InvocationID')):
            probe(s['ipv4'])
        job('StopUnit')
        wait_inactive()
        assert prop('Result') == 'success'
        assert not any('clat' in a['ifname'] for a in json.loads(run('ip','-j','link')))
        assert forwarding() == '0' and not guard()
        print('PASS installed unit invalidation failure: translator kept until the controller exits, next start recovers', flush=True)
    except BaseException:
        print(sp.run(['journalctl','-u',name,'-n','60','--no-pager','-o','cat'],capture_output=True,text=True).stdout, file=sys.stderr)
        raise
    finally:
        for step in (lambda: job('StopUnit'), lambda: prop('ActiveState') == 'failed' and manager.ResetFailedUnit(name),
                     lambda: shutil.rmtree(dropin, ignore_errors=True),
                     lambda: unit_file.unlink(missing_ok=True), manager.Reload):
            try:
                step()
            except Exception as error:
                print(f'unit contract cleanup: {error}', file=sys.stderr)
        shutil.rmtree(unit_run, ignore_errors=True)
        try:
            unit_run.parent.rmdir()
        except OSError:
            pass
        shutil.rmtree(ext, ignore_errors=True)

finally:
    for link in links:link.stop()
    c.cleanup(sharing=False)
    for p in reversed(processes):
        if p.poll() is None:p.terminate()
    for p in processes:
        try:p.wait(timeout=3)
        except sp.TimeoutExpired:p.kill();p.wait()
    shutil.rmtree(bus_dir, ignore_errors=True)

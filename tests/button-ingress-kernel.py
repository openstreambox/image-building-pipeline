#!/usr/bin/python3
"""Run only inside a disposable root network namespace; no host networking."""
import asyncio
import importlib.util
import os
import pathlib
import socket
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ingress', root / 'mkosi/runtime/button-ingress/ingress.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL)

async def session_scope(pid, run):
    """Real kernel rtnetlink messages drive the front door's session scope."""
    front = m.FrontDoor([(18889, None)])
    async def echo(reader, writer):
        await reader.readuntil(b'\r\n\r\n')
        writer.write(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n')
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
        writer.close()
    backend = await asyncio.start_server(echo, '127.0.0.1', 0)
    front.backend_address = backend.sockets[0].getsockname()[:2]
    runner = asyncio.create_task(front.run())
    async def until(check, what):
        for _ in range(100):
            if check():
                return
            await asyncio.sleep(0.05)
        raise AssertionError('timed out waiting for ' + what)
    def bound(name, local):
        return any(b.name == name and b.local == local and 18889 in b.listeners for b in front.bases.values())
    async def connect():
        own = os.open('/proc/self/ns/net', os.O_RDONLY)
        theirs = os.open(f'/proc/{pid}/ns/net', os.O_RDONLY)
        try:
            os.setns(theirs, os.CLONE_NEWNET)
            sock = socket.socket()
        finally:
            os.setns(own, os.CLONE_NEWNET)
            os.close(own)
            os.close(theirs)
        sock.setblocking(False)
        await asyncio.wait_for(asyncio.get_running_loop().sock_connect(sock, ('192.0.2.1', 18889)), 2)
        before = set(front.tasks)
        reader, writer = await asyncio.open_connection(sock=sock)
        writer.write(b'GET /ws HTTP/1.1\r\nHost: box.local\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n')
        assert (await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 2)).startswith(b'HTTP/1.1 101 ')
        task, = set(front.tasks) - before
        return reader, writer, task
    async def alive(reader, writer, task):
        writer.write(b'ping')
        await writer.drain()
        return await asyncio.wait_for(reader.readexactly(4), 2) == b'ping' and not task.done()
    try:
        await until(lambda: front.trusted_ready and bound('lan0', '192.0.2.1'), 'initial listeners')
        session = await connect()
        assert await alive(*session)
        for command in (['ip', 'link', 'add', 'clap0', 'type', 'dummy'],
                        ['ip', 'addr', 'add', '198.51.100.1/24', 'dev', 'clap0'],
                        ['ip', 'link', 'set', 'clap0', 'up'],
                        ['ip', 'addr', 'add', '192.0.2.50/24', 'dev', 'lan0'],
                        ['ip', 'link', 'del', 'vpn0'],
                        # A link message for the session's own interface with
                        # unchanged name, state, type, master and kind.
                        ['ip', 'link', 'set', 'lan0', 'mtu', '1400']):
            run(*command)
        await until(lambda: front.trusted_ready and bound('clap0', '198.51.100.1') and not bound('vpn0', '192.0.2.1'),
                    'reconciled unrelated changes')
        assert await alive(*session), 'unrelated change closed the session'
        run('ip', 'addr', 'del', '192.0.2.1/24', 'dev', 'lan0')
        await until(lambda: session[2].done(), 'own address removal to close the session')
        assert not bound('lan0', '192.0.2.1')
        run('ip', 'addr', 'add', '192.0.2.1/24', 'dev', 'lan0')
        await until(lambda: front.trusted_ready and bound('lan0', '192.0.2.1'), 'readded listener')
        session[1].close()
        session = await connect()
        assert await alive(*session)
        run('ip', 'link', 'set', 'lan0', 'down')
        await until(lambda: session[2].done(), 'own link down to close the session')
        session[1].close()
    finally:
        runner.cancel()
        await asyncio.gather(runner, return_exceptions=True)
        backend.close()


child = subprocess.Popen(['unshare', '-n', 'sleep', '60'])
try:
    # Wait for unshare to complete without arbitrary timing delays.
    import os
    import time
    deadline = time.monotonic() + 3
    while os.readlink(f'/proc/{child.pid}/ns/net') == os.readlink('/proc/self/ns/net'):
        if child.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError('child namespace unavailable')
    def client(*args): run('nsenter', '-t', str(child.pid), '-n', *args)
    run('ip', 'link', 'set', 'lo', 'up')
    for iface, peer, address in [('lan0', 'client0', '192.0.2.2'), ('vpn0', 'client1', '192.0.2.3')]:
        run('ip', 'link', 'add', iface, 'type', 'veth', 'peer', 'name', peer)
        run('ip', 'link', 'set', peer, 'netns', str(child.pid))
        run('ip', 'addr', 'add', '192.0.2.1/24', 'dev', iface)
        run('ip', 'link', 'set', iface, 'up')
        client('ip', 'addr', 'add', address + '/24', 'dev', peer)
        client('ip', 'link', 'set', peer, 'up')
        run('sysctl', '-q', '-w', f'net.ipv4.conf.{iface}.rp_filter=0')
    run('sysctl', '-q', '-w', 'net.ipv4.conf.all.rp_filter=0')
    listener = m.bound_socket(socket.AF_INET, 'lan0', '192.0.2.1', 18888)
    listener.settimeout(2)
    probe = "import socket,sys;s=socket.socket();s.settimeout(.5);\ntry:s.connect(('192.0.2.1',18888));ok=True\nexcept OSError:ok=False\ns.close();sys.exit(0 if ok == (sys.argv[1]=='yes') else 1)"
    client('ip', 'route', 'replace', '192.0.2.1/32', 'dev', 'client0')
    client('python3', '-c', probe, 'yes')
    conn, _ = listener.accept()
    conn.close()
    client('ip', 'route', 'replace', '192.0.2.1/32', 'dev', 'client1')
    client('python3', '-c', probe, 'no')
    listener.settimeout(.1)
    try:
        conn, _ = listener.accept()
        conn.close()
        raise AssertionError('wrong-interface ingress accepted')
    except socket.timeout:
        pass
    listener.close()
    # The backend stays wildcard in the partner application. Verify the real
    # image fence, including local access, in this same disposable namespace.
    backend = socket.socket()
    backend.bind(('0.0.0.0', 18080))
    backend.listen()
    client('python3', '-c', probe.replace('18888', '18080'), 'yes')
    accepted, _ = backend.accept()
    accepted.close()
    run('nft', '-f', str(root / 'mkosi/runtime/button-ingress/backend.nft'))
    loopback = socket.create_connection(('127.0.0.1', 18080), timeout=1)
    loopback.close()
    client('python3', '-c', probe.replace('18888', '18080'), 'no')
    backend.close()
    print('actual SO_BINDTODEVICE: direct accepted, overlapping wrong-device ingress refused')
    client('ip', 'route', 'replace', '192.0.2.1/32', 'dev', 'client0')
    asyncio.run(session_scope(child.pid, run))
    print('real netlink: unrelated link/address changes and an own MTU change keep a session; own address removal and link down close it')
finally:
    child.terminate()
    child.wait()

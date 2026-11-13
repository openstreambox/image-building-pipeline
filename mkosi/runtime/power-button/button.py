#!/usr/bin/python3
"""Power-key gestures and a root-only, connection-scoped confirmation socket."""
import fcntl
import glob
import os
import selectors
import socket
import struct
import subprocess
import time

EVENT = struct.Struct('@llHHi')  # native Linux input_event (arm64 and amd64)


class Gestures:
    def __init__(self, light, poweroff):
        self.light, self.poweroff = light, poweroff
        self.down = self.tap = None
        self.fired = False
        self.request = None
        self.live = False

    def cancel(self):
        self.down = self.tap = None
        self.fired = False
        self.light('cancel', 0)

    def request_confirm(self, now, ttl, reply):
        if self.request:
            return False
        self.tap = None  # never carry a tap across request ownership
        self.request = (now + ttl, reply, now)
        return True

    def drop_request(self):
        self.request = None
        self.tap = None

    def tick(self, now):
        if self.request and now >= self.request[0]:
            reply = self.request[1]
            self.drop_request()
            reply('TIMEOUT')
        if self.down is not None and not self.fired:
            elapsed = now - self.down
            self.light('countdown', max(0, 3 - elapsed))
            if elapsed >= 3:
                self.fired = True
                self.tap = None
                self.light('shutdown', 0)
                self.poweroff()

    def key(self, value, now):
        if value == 1 and self.down is None:
            self.down, self.fired = now, False
            self.light('countdown', 3)
        elif value == 0 and self.down is not None:
            duration = now - self.down
            self.down = None
            if self.fired:
                return
            if duration >= 0.5:
                self.tap = None
                self.light('cancel', 0)
                return
            self.light('status', 0)
            if self.request and self.request[2] <= now < self.request[0]:
                if self.tap is not None and now - self.tap <= 0.4:
                    reply = self.request[1]
                    self.drop_request()  # consume before delivering
                    reply('CONFIRMED')
                    return
                self.tap = now
        # Autorepeat and unmatched releases never start a gesture.


class Input:
    def __init__(self, gestures, event_clock=False):
        self.g = gestures
        self.event_clock = event_clock
        self.buffer = b''
        self.dropped = False

    def feed(self, data, now):
        self.buffer += data
        while len(self.buffer) >= EVENT.size:
            sec, usec, kind, code, value = EVENT.unpack(self.buffer[:EVENT.size])
            self.buffer = self.buffer[EVENT.size:]
            if kind == 0 and code == 3:  # SYN_DROPPED: lose the whole gesture
                self.g.cancel()
                self.dropped = True
            elif self.dropped:
                # Require a release after resync; never infer a new press.
                if kind == 1 and code == 116 and value == 0:
                    self.dropped = False
            elif kind == 1 and code == 116:
                self.g.key(value, sec + usec / 1_000_000 if self.event_clock else now)


def discover():
    candidates = []
    for name in glob.glob('/sys/class/input/event*/device/name'):
        with open(name, encoding='utf-8') as source:
            if source.read().strip() in ('rk805 pwrkey', 'rk806 pwrkey'):
                candidates.append('/dev/input/' + name.split('/')[4])
    if len(candidates) != 1:
        raise RuntimeError('expected exactly one RK80x power key; configure --device')
    return candidates[0]


def monotonic_input(fd):
    # EVIOCSCLOCKID: use event time for physical gesture windows under load.
    fcntl.ioctl(fd, 0x400445A0, struct.pack("i", time.CLOCK_MONOTONIC))


def serve(device, path, light, poweroff, configure_input=monotonic_input):
    g = Gestures(light, poweroff)
    decoder = Input(g, event_clock=True)
    sel = selectors.DefaultSelector()
    # No EVIOCGRAB: logind must still receive events for its fallback policy.
    fd = os.open(device, os.O_RDONLY | os.O_NONBLOCK)
    configure_input(fd)
    sel.register(fd, selectors.EVENT_READ, 'input')
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)  # RuntimeDirectory is removed by systemd on stop.
    os.chmod(path, 0o600)
    server.listen(8)
    server.setblocking(False)
    sel.register(server, selectors.EVENT_READ, 'accept')
    clients = {}
    owner = None

    def close(client):
        nonlocal owner
        if client is owner:
            g.drop_request()
            owner = None
        sel.unregister(client)
        clients.pop(client)
        client.close()

    def reply(client, message):
        try:
            client.sendall((message + '\n').encode())
        except OSError:
            pass
        close(client)

    try:
        while True:
            for key, _ in sel.select(0.025):
                now = time.monotonic()
                if key.data == 'input':
                    data = os.read(fd, EVENT.size * 64)
                    if not data:
                        raise RuntimeError('power key disconnected')
                    decoder.feed(data, now)
                elif key.data == 'accept':
                    client, _ = server.accept()
                    client.setblocking(False)
                    if len(clients) >= 32:
                        client.close()
                        continue
                    clients[client] = [b'', now + 5, False]
                    sel.register(client, selectors.EVENT_READ, 'client')
                else:
                    client = key.fileobj
                    try:
                        data = client.recv(256)
                    except OSError:
                        data = b''
                    if not data:
                        close(client)
                        continue
                    state = clients[client]
                    state[0] += data
                    if state[2] or len(state[0]) > 80:
                        reply(client, 'ERROR')
                    elif b'\n' in state[0]:
                        line, rest = state[0].split(b'\n', 1)
                        parts = line.split()
                        if rest:
                            reply(client, 'ERROR')
                        elif len(parts) == 2 and parts[0] == b'CONFIRM' and parts[1].isdigit() and 1 <= int(parts[1]) <= 60:
                            if g.request_confirm(now, int(parts[1]), lambda msg, c=client: reply(c, msg)):
                                owner = client
                                state[2] = True
                                try:
                                    client.sendall(b'READY\n')
                                except OSError:
                                    close(client)
                            else:
                                reply(client, 'BUSY')
                        elif line in (b'LIVE 0', b'LIVE 1'):
                            g.live = line == b'LIVE 1'
                            reply(client, 'OK')
                        else:
                            reply(client, 'ERROR')
            now = time.monotonic()
            g.tick(now)
            for client, state in list(clients.items()):
                if not state[2] and now >= state[1]:
                    reply(client, 'TIMEOUT')
    finally:
        g.cancel()
        for client in list(clients):
            close(client)
        server.close()
        os.close(fd)
        sel.close()
        os.unlink(path)


def light_stub(event, remaining):
    # Deliberately no LED writes until the board-specific light owner is wired.
    if event != 'countdown':
        print('light:', event, flush=True)


def main():
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', help='explicit evdev path; otherwise discover RK80x')
    args = parser.parse_args()
    serve(args.device or discover(), '/run/ceralive-button/control.sock', light_stub,
          lambda: subprocess.run(['/usr/bin/systemctl', 'poweroff'], check=True, timeout=10))


if __name__ == '__main__':
    main()

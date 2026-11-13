"""Hardware-free production decoder, gesture and Unix socket contracts."""
import importlib.util
import multiprocessing
import os
from pathlib import Path
import socket
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('button', ROOT / 'mkosi/runtime/power-button/button.py')
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)


class Gestures(unittest.TestCase):
    def setUp(self):
        self.lights, self.off, self.replies = [], [], []
        self.g = b.Gestures(lambda *x: self.lights.append(x), lambda: self.off.append(True))

    def tap(self, now):
        self.g.key(1, now)
        self.g.key(0, now + .05)

    def test_taps(self):
        for live in (False, True):
            self.g.live = live
            self.tap(0)
            self.tap(.2)
            self.g.tick(20)
        self.assertFalse(self.off)
        self.assertEqual(len([x for x in self.lights if x[0] == 'status']), 4)

    def test_confirm(self):
        self.assertTrue(self.g.request_confirm(0, 10, self.replies.append))
        self.assertFalse(self.g.request_confirm(0, 10, self.replies.append))
        self.tap(1)
        self.tap(1.2)
        self.tap(1.3)
        self.tap(1.4)
        self.assertEqual(self.replies, ['CONFIRMED'])
        self.assertFalse(self.off)

    def test_windows(self):
        self.tap(0)  # tap before request cannot count
        self.g.request_confirm(.1, 1, self.replies.append)
        self.tap(.2)
        self.assertEqual(self.replies, [])
        self.tap(.7)  # too late to be a double press
        self.assertEqual(self.replies, [])
        self.g.tick(1.1)
        self.tap(1.2)
        self.assertEqual(self.replies, ['TIMEOUT'])
        self.g.request_confirm(2, 1, self.replies.append)
        self.g.drop_request()
        self.tap(2.1)
        self.tap(2.2)
        self.assertEqual(self.replies, ['TIMEOUT'])

    def test_holds(self):
        for live in (False, True):
            self.setUp()
            self.g.live = live
            for duration in (.5, 1, 2.999):
                self.g.key(1, 0)
                self.g.tick(duration)
                self.g.key(0, duration)
                self.g.tick(12)
                self.assertFalse(self.off)
            self.g.key(1, 20)
            self.g.tick(22.999)
            self.assertFalse(self.off)
            self.g.tick(23)
            self.g.tick(30)
            self.g.key(0, 31)
            self.assertEqual(self.off, [True])
            self.assertIn(('countdown', 3), self.lights)
            self.assertIn(('cancel', 0), self.lights)

    def test_decoder(self):
        decoder = b.Input(self.g)
        def ev(kind, code, value):
            return b.EVENT.pack(0, 0, kind, code, value)
        data = ev(1, 116, 1)
        decoder.feed(data[:7], 0)
        self.assertIsNone(self.g.down)
        decoder.feed(data[7:], 0)
        decoder.feed(ev(1, 116, 2) + ev(1, 30, 0), 1)
        self.assertEqual(self.g.down, 0)
        decoder.feed(ev(0, 3, 0), 2)  # dropped events cancel hold
        decoder.feed(ev(0, 0, 0) + ev(1, 116, 1), 3)
        self.g.tick(10)
        self.assertFalse(self.off)
        decoder.feed(ev(1, 116, 0), 11)
        decoder.feed(ev(1, 116, 2), 12)
        self.g.tick(20)
        self.assertFalse(self.off)
        decoder.feed(ev(1, 116, 1), 21)
        self.g.tick(24)
        self.assertEqual(self.off, [True])

    def test_queued_events(self):
        decoder = b.Input(self.g, event_clock=True)
        self.g.request_confirm(10, 10, self.replies.append)
        def tap(at):
            for value in (1, 0):
                decoder.feed(b.EVENT.pack(at, 0, 1, 116, value), 15)
        tap(8)
        tap(9)  # old physical events delivered after admission cannot confirm
        self.assertEqual(self.replies, [])
        tap(11)
        tap(12)  # same read time, physically too far apart
        self.assertEqual(self.replies, [])
        decoder.feed(b.EVENT.pack(12, 100000, 1, 116, 1), 15)
        decoder.feed(b.EVENT.pack(12, 150000, 1, 116, 0), 15)
        self.assertEqual(self.replies, ['CONFIRMED'])


class Socket(unittest.TestCase):
    def test_socket(self):
        with tempfile.TemporaryDirectory() as directory:
            fifo, path = directory + '/events', directory + '/control.sock'
            os.mkfifo(fifo)
            writer = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
            process = multiprocessing.get_context('fork').Process(target=b.serve, args=(fifo, path, lambda *x: None, lambda: None, lambda fd: None))
            process.start()
            clients = []
            def connect(command):
                c = socket.socket(socket.AF_UNIX)
                c.settimeout(2)
                c.connect(path)
                clients.append(c)
                c.sendall(command)
                return c
            def tap():
                for value in (1, 0):
                    now = time.monotonic()
                    sec = int(now)
                    os.write(writer, b.EVENT.pack(sec, int((now - sec) * 1_000_000), 1, 116, value))
            try:
                deadline = time.monotonic() + 3
                while not os.path.exists(path):
                    if time.monotonic() > deadline:
                        self.fail('socket did not start')
                    time.sleep(.01)
                self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
                self.assertEqual(connect(b'LIVE 1\n').recv(100), b'OK\n')
                for command in (b'CONFIRM 0\n', b'CONFIRM 61\n', b'CONFIRM nan\n', b'CONFIRM 1\nLIVE 0\n', b'x' * 81):
                    self.assertEqual(connect(command).recv(100), b'ERROR\n')
                c = connect(b'CONFIRM 10\n')
                self.assertEqual(c.recv(100), b'READY\n')
                self.assertEqual(connect(b'CONFIRM 1\n').recv(100), b'BUSY\n')
                tap()
                time.sleep(.06)
                tap()
                self.assertEqual(c.recv(100), b'CONFIRMED\n')
                self.assertEqual(c.recv(100), b'')
                c = connect(b'CONFIRM 1\n')
                self.assertEqual(c.recv(100), b'READY\n')
                self.assertEqual(c.recv(100), b'TIMEOUT\n')
                c = connect(b'CONFIRM 10\n')
                self.assertEqual(c.recv(100), b'READY\n')
                c.close()
                time.sleep(.06)
                c = connect(b'CONFIRM 1\n')
                self.assertEqual(c.recv(100), b'READY\n')
            finally:
                for c in clients:
                    c.close()
                process.terminate()
                process.join(3)
                os.close(writer)


if __name__ == '__main__':
    unittest.main()

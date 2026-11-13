"""Synthetic host contracts for the sole management configuration owner."""
import os
import select
import signal
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'mkosi/runtime'))
import management_confirm as journal
from management_owner import Owner, content_digest

BOOT = '11111111-1111-4111-8111-111111111111'
PATH = 'sha256:' + 'c' * 64


class OwnerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'owner'
        self.owner = Owner(self.root)
        self.owner.provision(b'old')
        self.clock = patch.object(journal, '_boottime', return_value=100)
        self.now = self.clock.start()
        self.addCleanup(self.clock.stop)
        self.events = []

    def arm(self, record):
        self.assertEqual(self.owner.controller.read(), record)
        self.assertEqual(self.owner.config.read_bytes(), b'old')
        self.assertEqual(self.owner.snapshot(record['previous']), b'old')
        self.events.append('armed')
        return dict(transaction=record['transaction'], boot=record['boot'],
                    deadline=record['deadline'])

    def change(self, arm=None, activate=None):
        return self.owner.change(BOOT, b'new', path=PATH, seconds=30,
                                 arm=arm or self.arm,
                                 activate=activate or self.events.append)

    def test_snapshot_and_arm_precede_persistent_and_active_change(self):
        self.change()
        self.assertEqual(self.events, ['armed', b'new'])
        self.assertEqual(self.owner.config.read_bytes(), b'new')
        self.assertEqual(self.owner.config.stat().st_mode & 0o777, 0o600)

    def test_no_arm_ack_never_applies(self):
        for ack in (None, True, {}, dict(transaction='wrong', boot=BOOT, deadline=130)):
            with self.subTest(ack=ack):
                # A failed arm leaves intent pending; explicit boot recovery is needed.
                self.owner.barrier(BOOT, activate=lambda raw: None)
                with self.assertRaises(RuntimeError):
                    self.change(arm=lambda record: ack)
                self.assertEqual(self.owner.config.read_bytes(), b'old')
        self.assertEqual(self.events, [])

    def test_arm_failure_and_slow_arm_do_not_apply(self):
        def failed(record):
            raise OSError('supervisor unavailable')
        with self.assertRaises(OSError):
            self.change(arm=failed)
        self.owner.barrier(BOOT, activate=lambda raw: None)
        def slow(record):
            ack = self.arm(record)
            self.now.return_value = 130
            return ack
        with self.assertRaises(RuntimeError):
            self.change(arm=slow)
        self.assertEqual(self.owner.config.read_bytes(), b'old')

    def test_same_boot_barrier_restores_before_network_start(self):
        self.change()
        self.owner.barrier(BOOT, activate=self.events.append)
        self.events.append('network-start')
        self.assertEqual(self.events, ['armed', b'new', b'old', 'network-start'])
        self.assertEqual(self.owner.controller.read()['state'], 'reverted')
        self.assertEqual(self.owner.config.read_bytes(), b'old')

    def test_timer_waits_then_restores_exact_bytes(self):
        self.change()
        self.assertEqual(self.owner.tick(BOOT, activate=self.events.append), 'pending')
        self.now.return_value = 130
        self.assertEqual(self.owner.tick(BOOT, activate=self.events.append), 'reverted')
        self.assertEqual(self.events, ['armed', b'new', b'old'])
        self.assertEqual(self.owner.config.read_bytes(), b'old')

    def test_restore_failure_keeps_barrier_closed_and_retries(self):
        self.change()
        def fail(raw):
            raise OSError('active restore failed')
        with self.assertRaises(OSError):
            self.owner.barrier(BOOT, activate=fail)
        self.assertEqual(self.owner.controller.read()['state'], 'pending')
        self.owner.barrier(BOOT, activate=self.events.append)
        self.assertEqual(self.owner.controller.read()['state'], 'reverted')

    def test_corrupt_or_missing_snapshot_blocks_barrier(self):
        self.change()
        snapshot = self.root / ('blob-' + content_digest(b'old')[7:])
        snapshot.write_bytes(b'damaged')
        with self.assertRaises(ValueError):
            self.owner.barrier(BOOT, activate=self.events.append)
        snapshot.unlink()
        with self.assertRaises(FileNotFoundError):
            self.owner.barrier(BOOT, activate=self.events.append)
        self.assertEqual(self.owner.controller.read()['state'], 'pending')

    def test_missing_or_corrupt_journal_never_opens_barrier(self):
        self.owner.controller.path.unlink()
        with self.assertRaises(FileNotFoundError):
            self.owner.barrier(BOOT, activate=self.events.append)
        self.owner.controller.path.write_text('{}')
        with self.assertRaises(ValueError):
            self.owner.barrier(BOOT, activate=self.events.append)

    def test_apply_failure_is_pending_and_boot_recovers(self):
        def fail(raw):
            raise OSError('apply interrupted')
        with self.assertRaises(OSError):
            self.change(activate=fail)
        self.assertEqual(self.owner.controller.read()['state'], 'pending')
        Owner(self.root).barrier(BOOT, activate=self.events.append)
        self.assertEqual(self.owner.config.read_bytes(), b'old')

    def test_request_death_mid_apply_independent_recovery(self):
        pid = os.fork()
        if pid == 0:
            self.change(activate=lambda raw: os._exit(73))
            os._exit(1)
        self.assertEqual(os.waitpid(pid, 0)[1], 73 << 8)
        self.assertEqual(self.owner.config.read_bytes(), b'new')
        self.now.return_value = 130
        Owner(self.root).tick(BOOT, activate=self.events.append)
        self.assertEqual(self.owner.config.read_bytes(), b'old')

    def test_independent_timer_is_armed_before_request_dies(self):
        def read(fd):
            if not select.select([fd], [], [], 3)[0]:
                raise RuntimeError('timer handshake failed')
            return os.read(fd, 1)
        intent_r, intent_w = os.pipe()
        ack_r, ack_w = os.pipe()
        fire_r, fire_w = os.pipe()
        timer = os.fork()
        if timer == 0:
            try:
                read(intent_r)
                record = self.owner.controller.read()
                assert record['state'] == 'pending'
                assert self.owner.config.read_bytes() == b'old'
                os.write(ack_w, b'a')
                read(fire_r)
                self.now.return_value = 130
                Owner(self.root).tick(BOOT, activate=lambda raw: None)
                os._exit(0)
            except Exception:
                os._exit(4)
        request = os.fork()
        if request == 0:
            def arm(record):
                os.write(intent_w, b'i')
                assert read(ack_r) == b'a'
                return {k: record[k] for k in ('transaction', 'boot', 'deadline')}
            self.change(arm=arm, activate=lambda raw: os._exit(73))
            os._exit(5)
        try:
            self.assertEqual(os.waitpid(request, 0)[1], 73 << 8)
            self.assertEqual(self.owner.config.read_bytes(), b'new')
            os.write(fire_w, b'f')
            self.assertEqual(os.waitpid(timer, 0)[1], 0)
            self.assertEqual(self.owner.config.read_bytes(), b'old')
        finally:
            for child in (request, timer):
                try:
                    if os.waitpid(child, os.WNOHANG) == (0, 0):
                        os.kill(child, signal.SIGKILL)
                        os.waitpid(child, 0)
                except ChildProcessError:
                    pass
            for fd in (intent_r, intent_w, ack_r, ack_w, fire_r, fire_w):
                os.close(fd)

    def test_pending_denies_every_new_writer_and_reprovision(self):
        self.change()
        with self.assertRaises(RuntimeError):
            self.change()
        with self.assertRaises(FileExistsError):
            self.owner.provision(b'replacement')
        self.assertEqual(self.owner.config.read_bytes(), b'new')

    def test_snapshot_and_intent_write_errors_never_arm_or_apply(self):
        atomic = self.owner.controller.io.atomic_file
        for target in ('blob-', 'management.json', 'config.bundle'):
            def fail(path, raw):
                if path.name.startswith(target):
                    raise OSError('disk full')
                atomic(path, raw)
            with self.subTest(target=target):
                with patch.object(self.owner.controller.io, 'atomic_file', side_effect=fail):
                    with self.assertRaises(OSError):
                        self.change()
                self.assertEqual(self.owner.config.read_bytes(), b'old')
                if target != 'config.bundle':
                    self.assertEqual(self.events, [])
                self.owner.barrier(BOOT, activate=lambda raw: None)

    def test_new_boot_restores_without_waiting_for_deadline(self):
        self.change()
        other = '22222222-2222-4222-8222-222222222222'
        self.assertEqual(self.owner.tick(other, activate=self.events.append), 'reverted')
        self.assertEqual(self.owner.config.read_bytes(), b'old')

    def test_existing_blob_cannot_be_silently_overwritten(self):
        (self.root / ('blob-' + content_digest(b'old')[7:])).write_bytes(b'bad')
        with self.assertRaises(ValueError):
            self.change()
        self.assertEqual(self.owner.config.read_bytes(), b'old')
        self.assertEqual(self.events, [])

    def test_concurrent_requests_have_one_winner(self):
        children = []
        for _ in range(2):
            pid = os.fork()
            if pid == 0:
                try:
                    self.change()
                    os._exit(0)
                except RuntimeError:
                    os._exit(2)
                except Exception:
                    os._exit(3)
            children.append(pid)
        self.assertEqual(sorted(os.waitpid(pid, 0)[1] >> 8 for pid in children), [0, 2])
        self.assertEqual(self.owner.snapshot(self.owner.controller.read()['previous']), b'old')

    def test_confirmed_survives_barrier_and_new_snapshot_is_current(self):
        tx = self.change()
        proof = dict(transaction=tx, boot_id=BOOT, candidate=content_digest(b'new'),
                     path=PATH, authenticated=True, new_session=True, observed_uptime=100)
        self.assertTrue(self.owner.confirm(BOOT, tx, probe=lambda: proof))
        self.owner.barrier(BOOT, activate=self.events.append)
        self.assertEqual(self.owner.config.read_bytes(), b'new')
        self.assertEqual(self.events, ['armed', b'new'])
        def arm_again(record):
            self.assertEqual(self.owner.snapshot(record['previous']), b'new')
            return {k: record[k] for k in ('transaction', 'boot', 'deadline')}
        self.owner.change(BOOT, b'third', path=PATH, seconds=30,
                          arm=arm_again, activate=self.events.append)
        self.owner.barrier(BOOT, activate=self.events.append)
        self.assertEqual(self.owner.config.read_bytes(), b'new')


if __name__ == '__main__':
    unittest.main()

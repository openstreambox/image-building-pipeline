"""Host management rollback contract; all path observations are synthetic."""
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "mkosi/runtime"))
import management_confirm as m

BOOT = "11111111-1111-4111-8111-111111111111"
OTHER = "22222222-2222-4222-8222-222222222222"
OLD = "sha256:" + "a" * 64
NEW = "sha256:" + "b" * 64
PATH = "sha256:" + "c" * 64


class ConfirmTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = m.Controller(self.tmp.name)
        self.clock = patch.object(m, "_boottime", return_value=100)
        self.now = self.clock.start()
        self.addCleanup(self.clock.stop)
        self.store.initialize()
        self.effects = []

    def start(self, apply=None):
        return self.store.start(BOOT, previous=OLD, candidate=NEW, path=PATH,
                                seconds=30, apply=apply or self.effects.append)

    def proof(self, tx, **changes):
        proof = dict(transaction=tx, boot_id=BOOT, candidate=NEW, path=PATH,
                     observed_uptime=100, authenticated=True, new_session=True)
        proof.update(changes)
        return lambda: proof

    def test_intent_precedes_apply_and_survives_restart(self):
        def apply(candidate):
            self.assertEqual(self.store.read()["state"], "pending")
            self.assertEqual(candidate, NEW)
        tx = self.start(apply)
        self.assertEqual(m.Controller(self.tmp.name).read()["transaction"], tx)

    def test_fresh_changed_path_confirms(self):
        tx = self.start()
        self.assertTrue(self.store.confirm(BOOT, tx, probe=self.proof(tx)))
        self.now.return_value = 200
        self.assertEqual(self.store.recover(BOOT, restore=self.effects.append), "confirmed")
        self.assertEqual(self.effects, [NEW])

    def test_bad_evidence_never_confirms(self):
        tx = self.start()
        for change in [dict(transaction="wrong"), dict(boot_id=OTHER),
                       dict(candidate=OLD), dict(path=OLD), dict(authenticated=False),
                       dict(authenticated=1), dict(new_session=False),
                       dict(observed_uptime=94), dict(observed_uptime=101),
                       dict(observed_uptime=float("nan"))]:
            with self.subTest(change=change):
                self.assertFalse(self.store.confirm(BOOT, tx, probe=self.proof(tx, **change)))
        self.assertFalse(self.store.confirm(OTHER, tx, probe=self.proof(tx)))
        self.assertFalse(self.store.confirm(BOOT, "wrong", probe=self.proof(tx)))
        self.assertEqual(self.store.read()["state"], "pending")

    def test_timeout_boundary_and_reboot_restore(self):
        for boot, now in [(BOOT, 130), (OTHER, 100), (BOOT, 99)]:
            with self.subTest(boot=boot, now=now):
                # Separate fixture per case.
                with tempfile.TemporaryDirectory() as root:
                    c = m.Controller(root)
                    c.initialize()
                    self.now.return_value = 100
                    c.start(BOOT, previous=OLD, candidate=NEW, path=PATH,
                            seconds=30, apply=lambda _: None)
                    self.now.return_value = now
                    restored = []
                    self.assertEqual(c.recover(boot, restore=restored.append), "reverted")
                    c.recover(boot, restore=restored.append)
                    self.assertEqual(restored, [OLD])

    def test_no_early_restore(self):
        self.start()
        self.now.return_value = 129.9
        self.assertEqual(self.store.recover(BOOT, restore=self.effects.append), "pending")
        self.assertEqual(self.effects, [NEW])

    def test_stale_proof_within_transaction_refuses(self):
        tx = self.start()
        self.now.return_value = 110
        self.assertFalse(self.store.confirm(BOOT, tx, probe=self.proof(tx, observed_uptime=104)))

    def test_late_and_slow_probe_refused(self):
        tx = self.start()
        self.now.return_value = 130
        self.assertFalse(self.store.confirm(BOOT, tx, probe=self.proof(tx, observed_uptime=130)))
        self.now.return_value = 100
        def slow():
            self.now.return_value = 131
            return self.proof(tx, observed_uptime=131)()
        self.assertFalse(self.store.confirm(BOOT, tx, probe=slow))

    def test_overlap_and_reinitialize_refused(self):
        self.start()
        with self.assertRaises(RuntimeError):
            self.start()
        with self.assertRaises(FileExistsError):
            self.store.initialize()

    def test_apply_failure_stays_pending(self):
        def fail(_):
            raise OSError("synthetic failure")
        with self.assertRaises(OSError):
            self.start(fail)
        self.assertEqual(self.store.read()["state"], "pending")
        self.now.return_value = 131
        self.store.recover(BOOT, restore=self.effects.append)
        self.assertEqual(self.effects, [OLD])

    def test_restore_failure_retries(self):
        self.start()
        self.now.return_value = 131
        def fail(_):
            raise OSError("synthetic failure")
        with self.assertRaises(OSError):
            self.store.recover(BOOT, restore=fail)
        self.assertEqual(self.store.read()["state"], "pending")
        self.store.recover(BOOT, restore=self.effects.append)
        self.assertEqual(self.effects, [NEW, OLD])

    def test_write_failure_never_applies(self):
        with patch.object(self.store, "_write", side_effect=OSError):
            with self.assertRaises(OSError):
                self.start()
        self.assertEqual(self.effects, [])

    def test_terminal_write_failure_retries_restore(self):
        self.start()
        self.now.return_value = 131
        with patch.object(self.store, "_write", side_effect=OSError):
            with self.assertRaises(OSError):
                self.store.recover(BOOT, restore=self.effects.append)
        self.store.recover(BOOT, restore=self.effects.append)
        self.assertEqual(self.effects, [NEW, OLD, OLD])

    def test_confirm_decision_precedes_durable_write(self):
        tx = self.start()
        write = self.store._write
        def slow(record):
            write(record)
            self.now.return_value = 131
        with patch.object(self.store, "_write", side_effect=slow):
            self.assertTrue(self.store.confirm(BOOT, tx, probe=self.proof(tx)))
        self.assertEqual(self.store.read()["state"], "confirmed")

    def test_missing_corrupt_unknown_refuse_effects(self):
        for raw in [None, b"{}", b"not json"]:
            with self.subTest(raw=raw):
                self.store.path.unlink(missing_ok=True)
                if raw is not None:
                    self.store.path.write_bytes(raw)
                with self.assertRaises((ValueError, OSError)):
                    self.start()
        self.assertEqual(self.effects, [])

    def test_validation(self):
        for changes in [dict(seconds=0), dict(seconds=True), dict(seconds=3601),
                        dict(candidate=OLD), dict(path="credential"), dict(previous=None)]:
            with self.subTest(changes=changes):
                args = dict(previous=OLD, candidate=NEW, path=PATH, seconds=30)
                args.update(changes)
                with self.assertRaises(ValueError):
                    self.store.start(BOOT, apply=self.effects.append, **args)
        self.assertEqual(self.effects, [])

    def test_process_death_before_and_after_effects(self):
        for phase in ("apply-before", "apply-after", "restore-before", "restore-after"):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as root:
                c = m.Controller(root)
                c.initialize()
                effect = Path(root) / "effective"
                effect.write_text(OLD)
                def apply(value):
                    if phase == "apply-before":
                        os._exit(73)
                    effect.write_text(value)
                    if phase == "apply-after":
                        os._exit(73)
                if phase.startswith("apply"):
                    pid = os.fork()
                    if pid == 0:
                        c.start(BOOT, previous=OLD, candidate=NEW, path=PATH,
                                seconds=30, apply=apply)
                        os._exit(74)
                else:
                    c.start(BOOT, previous=OLD, candidate=NEW, path=PATH,
                            seconds=30, apply=effect.write_text)
                    self.now.return_value = 131
                    def restore(value):
                        if phase == "restore-before":
                            os._exit(73)
                        effect.write_text(value)
                        os._exit(73)
                    pid = os.fork()
                    if pid == 0:
                        c.recover(BOOT, restore=restore)
                        os._exit(74)
                self.assertEqual(os.waitpid(pid, 0)[1], 73 << 8)
                self.now.return_value = 131
                self.assertEqual(c.recover(BOOT, restore=effect.write_text), "reverted")
                self.assertEqual(effect.read_text(), OLD)
                self.now.return_value = 100

    def test_concurrent_starts_admit_only_one(self):
        import concurrent.futures
        def attempt(_):
            try:
                return self.start()
            except RuntimeError:
                return None
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(attempt, range(8)))
        self.assertEqual(sum(v is not None for v in results), 1)
        self.assertEqual(self.effects, [NEW])

    def test_valid_checksum_unknown_schema_still_refuses(self):
        self.start()
        r = self.store.read()
        r["version"] = 99
        import hashlib
        self.store.path.write_bytes(m.encoded(
            {"record": r, "sha256": hashlib.sha256(m.encoded(r)).hexdigest()}))
        with self.assertRaises(ValueError):
            self.start()

    def test_old_transaction_cannot_confirm_new_change(self):
        old = self.start()
        self.now.return_value = 131
        self.store.recover(BOOT, restore=self.effects.append)
        self.now.return_value = 140
        new = self.start()
        self.assertNotEqual(new, old)
        self.assertFalse(self.store.confirm(BOOT, old, probe=self.proof(old, observed_uptime=140)))
        self.assertEqual(self.store.read()["state"], "pending")

    def test_probe_exception_refuses(self):
        tx = self.start()
        def fail():
            raise OSError("private error")
        self.assertFalse(self.store.confirm(BOOT, tx, probe=fail))


if __name__ == "__main__":
    unittest.main()

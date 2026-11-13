"""Host-only durability, budget and privacy contracts."""
from concurrent.futures import ProcessPoolExecutor
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "recovery", Path(__file__).resolve().parents[1] / "mkosi/runtime/recovery_witness.py")
r = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(r)
BOOT = "11111111-1111-4111-8111-111111111111"
OTHER = "22222222-2222-4222-8222-222222222222"
THIRD = "33333333-3333-4333-8333-333333333333"


def concurrent_begin(root):
    return r.Store(root, limit=2, healthy_seconds=60).begin(OTHER, 0)


class RecoveryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = r.Store(Path(self.tmp.name), limit=2, healthy_seconds=60)

    def boot(self, boot=BOOT, now=0):
        return self.store.begin(boot, now, slot="A")

    def rearm(self, boot=BOOT, now=0):
        self.store.health(boot, now, "healthy")
        return self.store.health(boot, now + 60, "healthy")

    def test_missing_is_spent_then_healthy_dwell_recovers(self):
        self.assertFalse(self.boot()["automatic_reset_allowed"])
        self.assertFalse(self.store.health(BOOT, 0, "healthy")["automatic_reset_allowed"])
        self.assertTrue(self.rearm()["automatic_reset_allowed"])
        witness = self.store.read()["boots"][BOOT]
        self.assertEqual(witness["state_source"], "missing")
        self.assertEqual(witness["budget_at_start"], 0)

    def test_boot_count_restart_and_exhaustion(self):
        self.boot()
        self.rearm()
        self.assertEqual(self.boot(OTHER)["remaining"], 1)
        self.assertEqual(self.boot(OTHER)["remaining"], 1)
        view = self.boot(THIRD)
        self.assertEqual(view["remaining"], 0)
        self.assertIn("Rescue", view["announcement"])
        self.assertFalse(view["automatic_reset_allowed"])
        records = self.store.read()["boots"]
        self.assertEqual(len(records), 3)
        self.assertIsNone(records[BOOT]["previous_boot"])
        self.assertEqual(records[OTHER]["previous_boot"], BOOT)
        self.assertEqual(records[THIRD]["previous_boot"], OTHER)

    def test_bad_records_never_refill_and_never_lock_forever(self):
        for value in (b'{', b'{}', b'{"version":0}', b'null', b'[]'):
            with self.subTest(value=value):
                self.store.path.write_bytes(value)
                self.assertFalse(self.boot()["automatic_reset_allowed"])
                self.assertTrue(self.rearm()["automatic_reset_allowed"])

    def test_checksum_detects_valid_json_damage(self):
        self.boot()
        self.rearm()
        envelope = json.loads(self.store.path.read_text())
        envelope["record"]["remaining"] = 2
        envelope["record"]["boots"][BOOT]["slot"] = "B"
        self.store.path.write_text(json.dumps(envelope))
        self.assertFalse(self.boot(OTHER)["automatic_reset_allowed"])

    def test_wall_clock_jumps_do_not_rearm(self):
        self.boot()
        with patch("time.time", return_value=10**12):
            self.store.health(BOOT, 5, "healthy")
        with patch("time.time", return_value=-10**12):
            self.assertFalse(self.store.health(BOOT, 64, "healthy")["automatic_reset_allowed"])
            self.assertTrue(self.store.health(BOOT, 65, "healthy")["automatic_reset_allowed"])

    def test_monotonic_regression_and_failed_health_restart_dwell(self):
        self.boot(now=100)
        self.store.health(BOOT, 100, "healthy")
        self.assertFalse(self.store.health(BOOT, 1, "healthy")["automatic_reset_allowed"])
        self.store.health(BOOT, 50, "failed")
        self.assertFalse(self.store.health(BOOT, 60, "healthy")["automatic_reset_allowed"])
        self.assertFalse(self.store.health(BOOT, 119, "healthy")["automatic_reset_allowed"])
        self.assertTrue(self.store.health(BOOT, 120, "healthy")["automatic_reset_allowed"])

    def test_wrong_boot_cannot_confirm_or_write_intent(self):
        self.boot()
        with self.assertRaises(ValueError):
            self.store.health(OTHER, 1000, "healthy")
        self.store.intent(BOOT, "activate-other-slot")
        self.assertEqual(self.store.read()["boots"][BOOT]["intent"], "activate-other-slot")
        with self.assertRaises(ValueError):
            self.store.intent(BOOT, "secret-token")
        with self.assertRaises(ValueError):
            self.boot("../../secret")

    def test_power_cut_before_replace_preserves_old_record(self):
        self.boot()
        before = self.store.path.read_bytes()
        with patch.object(r.os, "replace", side_effect=OSError("cut")):
            with self.assertRaises(OSError):
                self.store.intent(BOOT, "activate-other-slot")
        self.assertEqual(before, self.store.path.read_bytes())
        self.assertEqual(list(self.store.root.glob(".write-*")), [])

    def test_fsync_order_and_directory_failure_is_not_success(self):
        self.boot()
        events = []
        sync, replace = r.os.fsync, r.os.replace
        with patch.object(r.os, "fsync", side_effect=lambda fd: (events.append("sync"), sync(fd))[-1]), patch.object(r.os, "replace", side_effect=lambda a, b: (events.append("replace"), replace(a, b))[-1]):
            self.store.intent(BOOT, "activate-other-slot")
        self.assertEqual(events, ["sync", "sync", "replace", "sync"])
        with patch.object(r.os, "fsync", side_effect=OSError("full")):
            with self.assertRaises(OSError):
                self.store.intent(BOOT, "reset")

    def test_unknown_observations_and_private_values_refused(self):
        self.boot()
        record = self.store.read()["boots"][BOOT]
        self.assertEqual(record["health"], "unknown")
        self.assertEqual(record["detectors"], {"watchdog": "unknown", "rollback": "unknown"})
        with self.assertRaises(ValueError):
            self.store.begin(OTHER, 0, bootloader="serial-number")
        with self.assertRaises(ValueError):
            self.store.begin(OTHER, 0, console_tail=["password=abc"])

    def test_concurrent_producers_charge_once(self):
        self.boot()
        self.rearm()
        with ProcessPoolExecutor(max_workers=4) as pool:
            views = list(pool.map(concurrent_begin, [self.store.root] * 8))
        self.assertTrue(all(v["remaining"] == 1 for v in views))
        self.assertEqual(len(self.store.read()["boots"]), 2)

    def test_status_from_previous_boot_cannot_authorize_reset(self):
        self.boot()
        self.rearm()
        self.assertFalse(self.store.view(self.store.read(), OTHER)["automatic_reset_allowed"])

    def test_unreadable_storage_and_full_write_deny(self):
        self.boot()
        self.rearm()
        with patch.object(Path, "open", side_effect=PermissionError("denied")):
            self.assertEqual(self.store.read()["remaining"], 0)
        before = self.store.path.read_bytes()
        with patch.object(r, "MAX_BYTES", 1):
            with self.assertRaises(ValueError):
                self.boot(OTHER)
        self.assertEqual(before, self.store.path.read_bytes())

    def test_post_replace_sync_failure_is_reported_and_retry_is_idempotent(self):
        self.boot()
        self.rearm()
        sync = r.os.fsync
        calls = []
        def cut(fd):
            calls.append(fd)
            if len(calls) == 3:
                raise OSError("cut after rename")
            return sync(fd)
        with patch.object(r.os, "fsync", side_effect=cut):
            with self.assertRaises(OSError):
                self.boot(OTHER)
        self.assertEqual(self.boot(OTHER)["remaining"], 1)
        with patch.object(r.os, "replace", side_effect=OSError("retry cut")):
            with self.assertRaises(OSError):
                self.boot(OTHER)

    def test_old_version_and_nonfinite_uptime(self):
        self.boot()
        self.rearm()
        record = self.store.read()
        record["version"] = 0
        self.store.path.write_bytes(r.encoded({"record": record, "sha256": r.hashlib.sha256(r.encoded(record)).hexdigest()}))
        self.assertFalse(self.boot(OTHER)["automatic_reset_allowed"])
        for now in (-1, float("nan"), float("inf"), True):
            with self.assertRaises(ValueError):
                self.store.health(OTHER, now, "healthy")

    def test_cli_status_export_and_storage_failure(self):
        import subprocess
        import sys
        command = [sys.executable, SPEC.origin, "--state-dir", str(self.store.root),
                   "--limit", "2", "--healthy-seconds", "60"]
        before = list(self.store.root.iterdir())
        status = subprocess.run(command + ["status"], capture_output=True, text=True, check=True)
        self.assertFalse(json.loads(status.stdout)["automatic_reset_allowed"])
        subprocess.run(command + ["export"], capture_output=True, check=True)
        self.assertEqual(before, list(self.store.root.iterdir()))
        self.store.root.joinpath(".lock").mkdir()
        failed = subprocess.run(command + ["begin"], capture_output=True, text=True)
        self.assertNotEqual(failed.returncode, 0)
        self.assertFalse(json.loads(failed.stdout)["automatic_reset_allowed"])
        self.assertNotIn(str(self.store.root), failed.stdout)

    def test_killed_writer_leaves_temporary_file_but_old_commit_readable(self):
        import subprocess
        import sys
        self.boot()
        before = self.store.path.read_bytes()
        program = """
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location('recovery', sys.argv[1])
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
r.os.replace = lambda *args: os._exit(99)
r.Store(sys.argv[2], limit=2, healthy_seconds=60).intent(sys.argv[3], 'reset')
"""
        killed = subprocess.run([sys.executable, "-c", program, SPEC.origin, str(self.store.root), BOOT])
        self.assertEqual(killed.returncode, 99)
        self.assertTrue(list(self.store.root.glob(".write-*")))
        self.assertEqual(before, self.store.path.read_bytes())
        self.assertEqual(self.boot()["remaining"], 0)
        self.assertEqual(self.store.path.stat().st_mode & 0o777, 0o600)

    def test_wrong_collection_types_with_valid_checksum_are_uncertain(self):
        self.boot()
        self.rearm()
        baseline = self.store.path.read_bytes()
        for field, value in (("counters", ["A", "B"]),
                             ("detectors", ["watchdog", "rollback"]),
                             ("console_tail", {})):
            envelope = json.loads(baseline)
            envelope["record"]["boots"][BOOT][field] = value
            envelope["sha256"] = r.hashlib.sha256(r.encoded(envelope["record"])).hexdigest()
            self.store.path.write_bytes(r.encoded(envelope))
            self.assertEqual(self.store.read()["remaining"], 0)
            self.assertEqual(self.store.read()["source"], "invalid")

    def test_configuration_change_spends_budget(self):
        self.boot()
        self.rearm()
        other = r.Store(self.store.root, limit=3, healthy_seconds=60)
        self.assertFalse(other.begin(OTHER, 0)["automatic_reset_allowed"])


if __name__ == "__main__":
    unittest.main()

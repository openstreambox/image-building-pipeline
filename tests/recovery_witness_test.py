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
PIN = "sha256:" + "a" * 64


def good_proof(boot=BOOT, observed=61):
    return dict(boot_id=boot, observed_uptime=observed, counter_source="independent-readback",
                counter_before=3, counter_after=2, counter_readback=2,
                bootloader=PIN, watchdog="armed")


def concurrent_begin(root):
    return r.Store(root, limit=2, healthy_seconds=60).begin(OTHER, 0, reset_cause="watchdog")


def slow_health(root, ready):
    import time
    store = r.Store(root, limit=2, healthy_seconds=60)
    def change(record, witness):
        witness["health"] = "failed"
        ready.set()
        time.sleep(0.3)
    store.update(BOOT, change)


def racing_intent(root, ready):
    ready.wait(5)
    r.Store(root, limit=2, healthy_seconds=60).intent(BOOT, "unbind-adapter")


class RecoveryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = r.Store(Path(self.tmp.name), limit=2, healthy_seconds=60)

    def boot(self, boot=BOOT, now=0):
        return self.store.begin(boot, now, slot="A", reset_cause="watchdog")

    def rearm(self, boot=BOOT, now=0):
        self.store.health(boot, now, "healthy")
        self.store.health(boot, now + 30, "healthy")
        return self.store.health(boot, now + 60, "healthy")

    def test_missing_is_spent_then_healthy_dwell_recovers(self):
        self.assertFalse(self.boot()["reset_budget_available"])
        self.assertFalse(self.store.health(BOOT, 0, "healthy")["reset_budget_available"])
        self.assertTrue(self.rearm()["reset_budget_available"])
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
        self.assertFalse(view["reset_budget_available"])
        records = self.store.read()["boots"]
        self.assertEqual(len(records), 3)
        self.assertIsNone(records[BOOT]["previous_boot"])
        self.assertEqual(records[OTHER]["previous_boot"], BOOT)
        self.assertEqual(records[THIRD]["previous_boot"], OTHER)

    def test_bad_records_never_refill_and_never_lock_forever(self):
        for value in (b'{', b'{}', b'{"version":0}', b'null', b'[]'):
            with self.subTest(value=value):
                self.store.path.write_bytes(value)
                self.assertFalse(self.boot()["reset_budget_available"])
                self.assertTrue(self.rearm()["reset_budget_available"])

    def test_checksum_detects_valid_json_damage(self):
        self.boot()
        self.rearm()
        envelope = json.loads(self.store.path.read_text())
        envelope["record"]["remaining"] = 2
        envelope["record"]["boots"][BOOT]["slot"] = "B"
        self.store.path.write_text(json.dumps(envelope))
        self.assertFalse(self.boot(OTHER)["reset_budget_available"])

    def test_wall_clock_jumps_do_not_rearm(self):
        self.boot()
        with patch("time.time", return_value=10**12):
            self.store.health(BOOT, 5, "healthy")
        self.store.health(BOOT, 35, "healthy")
        with patch("time.time", return_value=-10**12):
            self.assertFalse(self.store.health(BOOT, 64, "healthy")["reset_budget_available"])
            self.assertTrue(self.store.health(BOOT, 65, "healthy")["reset_budget_available"])

    def test_monotonic_regression_and_failed_health_restart_dwell(self):
        self.boot(now=100)
        self.store.health(BOOT, 100, "healthy")
        self.assertFalse(self.store.health(BOOT, 1, "healthy")["reset_budget_available"])
        self.store.health(BOOT, 50, "failed")
        self.assertFalse(self.store.health(BOOT, 60, "healthy")["reset_budget_available"])
        self.store.health(BOOT, 90, "healthy")
        self.assertFalse(self.store.health(BOOT, 119, "healthy")["reset_budget_available"])
        self.assertTrue(self.store.health(BOOT, 120, "healthy")["reset_budget_available"])

    def test_wrong_boot_cannot_confirm_or_write_intent(self):
        self.boot()
        with self.assertRaises(ValueError):
            self.store.health(OTHER, 1000, "healthy")
        self.store.intent(BOOT, "unbind-adapter")
        self.assertEqual(self.store.read()["boots"][BOOT]["intent"], "unbind-adapter")
        with self.assertRaises(ValueError):
            self.store.intent(BOOT, "secret-token")
        with self.assertRaises(ValueError):
            self.boot("../../secret")

    def test_power_cut_before_replace_preserves_old_record(self):
        self.boot()
        before = self.store.path.read_bytes()
        with patch.object(r.os, "replace", side_effect=OSError("cut")):
            with self.assertRaises(OSError):
                self.store.intent(BOOT, "unbind-adapter")
        self.assertEqual(before, self.store.path.read_bytes())
        self.assertEqual(list(self.store.root.glob(".write-*")), [])

    def test_fsync_order_and_directory_failure_is_not_success(self):
        self.boot()
        events = []
        sync, replace = r.os.fsync, r.os.replace
        with patch.object(r.os, "fsync", side_effect=lambda fd: (events.append("sync"), sync(fd))[-1]), patch.object(r.os, "replace", side_effect=lambda a, b: (events.append("replace"), replace(a, b))[-1]):
            self.store.intent(BOOT, "unbind-adapter")
        self.assertEqual(events, ["sync", "sync", "replace", "sync", "sync", "replace", "sync"])
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
        self.assertFalse(self.store.view(self.store.read(), OTHER)["reset_budget_available"])

    def test_unreadable_storage_and_full_write_deny(self):
        self.boot()
        self.rearm()
        with patch.object(Path, "open", side_effect=PermissionError("denied")):
            self.assertEqual(self.store.read()["remaining"], 0)
        before = self.store.path.read_bytes()
        with patch.object(r, "MAX_BYTES", 1):
            with self.assertRaises(ValueError):
                self.boot(OTHER)
        self.assertEqual(before, (self.store.root / "recovery.rejected").read_bytes())

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
        self.assertFalse(self.boot(OTHER)["reset_budget_available"])
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
        self.assertFalse(json.loads(status.stdout)["reset_budget_available"])
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
r.Store(sys.argv[2], limit=2, healthy_seconds=60).intent(sys.argv[3], 'activate-other-slot')
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
        self.assertFalse(other.begin(OTHER, 0)["reset_budget_available"])


class ReviewTest(unittest.TestCase):
    setUp = RecoveryTest.setUp
    boot = RecoveryTest.boot
    rearm = RecoveryTest.rearm
    def test_lock_prevents_lost_health_and_intent_update(self):
        import multiprocessing
        self.boot()
        context = multiprocessing.get_context("fork")
        ready = context.Event()
        processes = [context.Process(target=slow_health, args=(self.store.root, ready)),
                     context.Process(target=racing_intent, args=(self.store.root, ready))]
        for process in processes:
            process.start()
        for process in processes:
            process.join(10)
            self.assertEqual(process.exitcode, 0)
        witness = self.store.read()["boots"][BOOT]
        self.assertEqual(witness["health"], "failed")
        self.assertEqual(witness["intent"], "unbind-adapter")

    def test_denied_reset_has_no_intent_and_cli_exit_3(self):
        import subprocess, sys
        self.boot()
        result = self.store.intent(BOOT, "reset")
        self.assertFalse(result["reset_budget_available"])
        self.assertEqual(self.store.read()["boots"][BOOT]["intent"], "none")
        # CLI boot identity is real, without issuing any reset.
        actual = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        self.store.begin(actual, 0)
        result = subprocess.run([sys.executable, SPEC.origin, "--state-dir", str(self.store.root),
            "--limit", "2", "--healthy-seconds", "60", "intent", "reset"], capture_output=True)
        self.assertEqual(result.returncode, 3)

    def test_bounded_history_rearms_after_many_boots(self):
        with patch.object(r, "MAX_WITNESSES", 4, create=True):
            for i in range(12):
                self.store.begin("%08x-1111-4111-8111-111111111111" % (i+1), 0)
            record = self.store.read()
            self.assertLessEqual(len(record["boots"]), 4)
            self.assertGreater(record["pruned_boots"], 0)
            last = record["current_boot"]
            self.store.health(last, 0, "healthy")
            self.store.health(last, 30, "healthy")
            self.assertTrue(self.store.health(last, 60, "healthy")["reset_budget_available"])

    def test_invalid_record_quarantined_and_orphans_cleaned(self):
        self.store.path.write_bytes(b"torn evidence")
        (self.store.root / ".write-orphan").write_bytes(b"old")
        self.boot()
        self.assertEqual((self.store.root / "recovery.rejected").read_bytes(), b"torn evidence")
        self.assertFalse((self.store.root / ".write-orphan").exists())

    def test_threshold_change_preserves_history(self):
        self.boot()
        self.rearm()
        self.store.intent(BOOT, "unbind-adapter")
        changed = r.Store(self.store.root, limit=2, healthy_seconds=90)
        result = changed.begin(OTHER, 0, reset_cause="power-on")
        self.assertFalse(result["reset_budget_available"])
        self.assertEqual(changed.read()["boots"][BOOT]["intent"], "unbind-adapter")

    def test_gap_resets_health_and_heartbeat_does_not_write(self):
        self.boot()
        self.store.health(BOOT, 0, "healthy")
        before = self.store.path.read_bytes()
        self.store.health(BOOT, 10, "healthy")
        self.assertEqual(before, self.store.path.read_bytes())
        self.assertFalse(self.store.health(BOOT, 70, "healthy")["reset_budget_available"])
        restarted = r.Store(self.store.root, limit=2, healthy_seconds=60)
        self.assertFalse(restarted.health(BOOT, 1000, "healthy")["reset_budget_available"])

    def test_repeated_failure_is_not_a_new_flash_write(self):
        self.boot()
        self.store.health(BOOT, 1, "failed")
        before = self.store.path.read_bytes()
        self.store.health(BOOT, 2, "failed")
        self.assertEqual(before, self.store.path.read_bytes())

    def test_another_reporter_failure_restarts_local_dwell(self):
        self.boot()
        self.store.health(BOOT, 0, "healthy")
        self.store.health(BOOT, 30, "healthy")
        other = r.Store(self.store.root, limit=2, healthy_seconds=60)
        other.health(BOOT, 40, "failed")
        self.assertFalse(self.store.health(BOOT, 60, "healthy")["reset_budget_available"])

    def test_clean_power_cycles_never_exhaust(self):
        self.boot()
        self.rearm()
        for boot in (OTHER, THIRD):
            result = self.store.begin(boot, 0, reset_cause="power-on")
            self.assertEqual(result["remaining"], 2)
            self.assertFalse(result["rescue_required"])
            self.assertFalse(result["rescue_active"])
        with self.assertRaises(ValueError):
            self.store.begin(BOOT, 0)
        with self.assertRaises(ValueError):
            self.store.health(BOOT, 100, "healthy")
        with self.assertRaises(ValueError):
            self.store.intent(BOOT, "activate-other-slot")

    def test_cli_uses_boottime_and_safe_bad_config(self):
        import sys
        with patch.object(sys, "argv", [SPEC.origin, "--state-dir", str(self.store.root),
                "--limit", "2", "--healthy-seconds", "60", "begin"]), \
                patch.object(r.time, "clock_gettime", return_value=123) as clock:
            r.main()
            clock.assert_called_once_with(r.time.CLOCK_BOOTTIME)
        with patch.object(sys, "argv", [SPEC.origin, "--state-dir", str(self.store.root),
                "--limit", "0", "--healthy-seconds", "60", "begin"]):
            self.assertEqual(r.main(), 1)


class ChargeTest(unittest.TestCase):
    """Second review: only real resets spend credit; only the last credit exhausts."""
    setUp = RecoveryTest.setUp
    rearm = RecoveryTest.rearm

    def armed(self):
        self.store.begin(BOOT, 0, reset_cause="power-on")
        self.rearm()

    def grant(self, boot=BOOT, action="reset"):
        with patch.object(r, "_boottime", return_value=62):
            return self.store.rollback(boot, pinned_bootloader=PIN, action=action,
                                       probe=lambda: good_proof(boot))

    def test_zero_credit_charge_is_not_exhaustion(self):
        # Fresh ledger, then one unclean reset: no credit, but no exhausted episode.
        self.store.begin(BOOT, 0, reset_cause="power-on")
        view = self.store.begin(OTHER, 0, reset_cause="watchdog")
        self.assertEqual(view["remaining"], 0)
        self.assertFalse(view["rescue_required"])
        self.assertNotIn("Rescue required", view["announcement"])
        self.assertFalse(self.store.read()["exhausted"])

    def test_corruption_then_watchdog_is_not_exhaustion(self):
        self.armed()
        self.store.path.write_bytes(b"torn")
        view = self.store.begin(OTHER, 0, reset_cause="watchdog")
        self.assertFalse(view["rescue_required"])
        self.assertFalse(self.store.read()["exhausted"])

    def test_threshold_change_activation_reboot_is_not_exhaustion(self):
        self.armed()
        changed = r.Store(self.store.root, limit=3, healthy_seconds=60)
        view = changed.begin(OTHER, 0, reset_cause="watchdog")
        self.assertFalse(view["rescue_required"])
        self.assertFalse(changed.read()["exhausted"])

    def test_last_credit_exhausts_and_stays_exhausted(self):
        self.armed()
        first = self.store.begin(OTHER, 0, reset_cause="watchdog")
        self.assertFalse(first["rescue_required"])
        self.assertEqual(first["state"], "rollback-not-armed")
        self.assertFalse(self.store.read()["exhausted"])
        view = self.store.begin(THIRD, 0, reset_cause="watchdog")
        self.assertEqual(view["remaining"], 0)
        # The boot after the last permitted reset may be healthy: spent, not rescue.
        self.assertTrue(self.store.read()["exhausted"])
        self.assertFalse(view["rescue_required"])
        self.assertEqual(view["state"], "reset-budget-spent")
        fourth = "44444444-4444-4444-8444-444444444444"
        self.assertFalse(self.store.begin(fourth, 0, reset_cause="power-on")["rescue_required"])
        self.assertTrue(self.store.read()["exhausted"])
        self.store.health(fourth, 0, "healthy")
        self.store.health(fourth, 30, "healthy")
        rearmed = self.store.health(fourth, 60, "healthy")
        self.assertFalse(rearmed["rescue_required"])
        self.assertEqual(rearmed["state"], "rollback-not-armed")
        self.assertFalse(self.store.read()["exhausted"])

    def test_view_rescue_flag_follows_exhaustion_not_missing_credit(self):
        self.store.begin(BOOT, 0, reset_cause="power-on")
        record = self.store.read()
        self.assertFalse(r.Store.view(record)["rescue_required"])
        record["exhausted"] = True
        self.assertFalse(r.Store.view(record)["rescue_required"])
        self.assertEqual(r.Store.view(record)["state"], "reset-budget-spent")
        record["rescue"]["required"] = True
        self.assertTrue(r.Store.view(record)["rescue_required"])

    def test_charge_by_cause(self):
        # Box-decided resets and unclean causes are charged; orderly reboots
        # (operator, update completion) and unclassified boots are not.
        for cause, charged in (("watchdog", True), ("panic", True), ("software", False),
                               ("unknown", False), ("power-on", False)):
            with self.subTest(cause=cause):
                self.store.path.unlink(missing_ok=True)
                self.armed()
                view = self.store.begin(OTHER, 0, reset_cause=cause)
                self.assertEqual(view["remaining"], 1 if charged else 2)

    def test_three_operator_reboots_do_not_exhaust(self):
        self.armed()
        for i in range(3):
            view = self.store.begin("%08x-5555-4555-8555-555555555555" % i, 0, reset_cause="software")
        self.assertEqual(view["remaining"], 2)
        self.assertFalse(view["rescue_required"])

    def test_granted_reset_is_charged_whatever_the_next_cause(self):
        for cause in ("power-on", "unknown", "software"):
            with self.subTest(cause=cause):
                self.store.path.unlink(missing_ok=True)
                self.armed()
                self.assertTrue(self.grant()["automatic_reset_allowed"])
                self.assertEqual(self.store.begin(OTHER, 0, reset_cause=cause)["remaining"], 1)

    def test_granted_reset_is_sticky_for_the_boot(self):
        self.armed()
        self.assertEqual(self.grant()["decision"], "ALLOW")
        for later in ("none", "unbind-adapter"):
            self.store.intent(BOOT, later)
            witness = self.store.read()["boots"][BOOT]
            self.assertEqual(witness["granted"], "reset")
            self.assertEqual(witness["intent"], later)
        # A refused rollback (stale evidence) and a granted trial cannot erase it.
        with patch.object(r, "_boottime", return_value=3600):
            self.assertEqual(self.store.rollback(BOOT, pinned_bootloader=PIN,
                                                 probe=good_proof)["decision"], "REFUSE")
        self.assertEqual(self.grant(action="activate-other-slot")["decision"], "ALLOW")
        self.assertEqual(self.store.read()["boots"][BOOT]["granted"], "reset")
        self.assertEqual(self.store.begin(OTHER, 0, reset_cause="power-on")["remaining"], 1)

    def test_repeated_grants_with_erasure_spend_the_budget(self):
        # Review probe: grant, erase with intent none, reset — must not loop for free.
        self.armed()
        boots = [BOOT] + ["%08x-6666-4666-8666-666666666666" % i for i in range(20)]
        admissions = 0
        for current, following in zip(boots, boots[1:]):
            if self.grant(current)["automatic_reset_allowed"]:
                admissions += 1
            self.store.intent(current, "none")
            self.store.begin(following, 0, reset_cause="unknown")
        self.assertEqual(admissions, 2)
        self.assertEqual(self.store.read()["remaining"], 0)

    def test_denied_reset_is_not_granted(self):
        self.store.begin(BOOT, 0, reset_cause="power-on")
        self.assertFalse(self.store.intent(BOOT, "reset")["automatic_reset_allowed"])
        self.assertEqual(self.store.read()["boots"][BOOT]["granted"], "none")

    def test_oversize_record_is_uncertain_and_quarantined(self):
        self.armed()
        size = self.store.path.stat().st_size
        with patch.object(r, "MAX_BYTES", size - 1):
            self.assertEqual(self.store.read()["source"], "invalid")
            self.assertEqual(self.store.read()["remaining"], 0)
        self.assertEqual(self.store.read()["remaining"], 2)

class AdmissionTest(unittest.TestCase):
    setUp = RecoveryTest.setUp
    boot = RecoveryTest.boot
    rearm = RecoveryTest.rearm
    def proof(self):
        return good_proof()

    def admit(self, proof=None, now=61, action="reset", pinned=PIN):
        with patch.object(r, "_boottime", return_value=now):
            return self.store.rollback(BOOT, pinned_bootloader=pinned, action=action,
                                       probe=lambda: self.proof() if proof is None else proof)

    def test_rollback_requires_fresh_independent_proof(self):
        self.boot()
        self.rearm()
        self.assertFalse(self.store.intent(BOOT, "reset")["automatic_reset_allowed"])
        self.assertTrue(self.admit()["automatic_reset_allowed"])
        for key, value in (("counter_source", "ledger"), ("counter_readback", 3),
                           ("counter_after", 3), ("bootloader", "unknown"),
                           ("watchdog", "unknown"), ("boot_id", OTHER),
                           ("observed_uptime", 0), ("counter_before", True)):
            proof = self.proof()
            proof[key] = value
            with self.subTest(key=key):
                result = self.admit(proof)
                self.assertFalse(result["rollback_armed"])
                self.assertEqual(result["decision"], "REFUSE")
                self.assertTrue(result["refusal_reasons"])
        self.assertFalse(self.admit(now=100)["rollback_armed"])
        self.assertFalse(self.store.view(self.store.read(), BOOT)["rollback_armed"])

    def test_unreadable_probe_refuses_and_status_file_is_not_permission(self):
        self.boot()
        self.rearm()
        def unreadable():
            raise OSError("private path")
        with patch.object(r, "_boottime", return_value=61):
            result = self.store.rollback(BOOT, pinned_bootloader="unknown", probe=unreadable)
        self.assertFalse(result["rollback_armed"])
        self.assertNotIn("private path", json.dumps(result))
        self.admit()
        status = json.loads((self.store.root / "recovery-status.json").read_text())
        self.assertFalse(status["rollback_armed"])
        self.assertFalse(status["automatic_reset_allowed"])

    def test_rescue_entry_is_once_until_explicit_healthy_rearm(self):
        boots = ["%08x-7777-4777-8777-777777777777" % i for i in range(9)]
        self.store.begin(boots[0], 0, reset_cause="power-on")
        self.rearm(boots[0])
        self.boot(boots[1])
        self.boot(boots[2])                      # last credit: spent, not rescue
        self.assertEqual(self.store.read()["rescue"]["entries"], 0)
        self.boot(boots[3])                      # a further unclean reset with no credit
        first = self.store.read()["rescue"].copy()
        self.assertEqual(first, {"required": True, "entries": 1, "entered_boot": boots[3]})
        self.boot(boots[3])
        self.boot(boots[4])
        self.store.begin(boots[5], 0, reset_cause="power-on")
        self.assertEqual(first, self.store.read()["rescue"])
        self.assertFalse(self.store.view(self.store.read())["rescue_active"])
        self.rearm(boots[5])
        self.assertFalse(self.store.read()["rescue"]["required"])
        self.boot(boots[6])
        self.boot(boots[7])
        self.boot(boots[8])
        self.assertEqual(self.store.read()["rescue"]["entries"], 2)

    def test_positive_proof_cannot_bypass_rescue_or_failed_commit(self):
        self.boot()
        record = self.store.read()
        # Credit shown alongside a latch must not reopen admission.
        record.update(exhausted=True, remaining=2)
        record["rescue"].update(required=True, entries=1, entered_boot=BOOT)
        self.store.write(record)
        result = self.admit()
        self.assertFalse(result["automatic_reset_allowed"])
        self.assertFalse(result["update_trial_allowed"])
        self.assertEqual(result["state"], "rescue-required")
        self.rearm()
        with patch.object(r.os, "replace", side_effect=OSError("cut")):
            with self.assertRaises(OSError):
                self.admit()
        self.assertEqual(self.store.read()["boots"][BOOT]["intent"], "none")
        result = self.admit(action="activate-other-slot")
        self.assertTrue(result["update_trial_allowed"])
        self.assertFalse(result["automatic_reset_allowed"])
        self.assertEqual(self.store.read()["boots"][BOOT]["intent"], "activate-other-slot")

    def test_status_projection_failure_neither_fails_nor_half_applies(self):
        self.boot()
        self.rearm()
        self.assertTrue((self.store.root / "recovery-status.json").exists())
        replace = r.os.replace
        def fail_status(source, target):
            if Path(target).name == "recovery-status.json":
                raise OSError("status unavailable")
            return replace(source, target)
        with patch.object(r.os, "replace", side_effect=fail_status):
            result = self.admit()
        # The ledger commit is the transaction; a stale projection is removed.
        self.assertEqual(result["decision"], "ALLOW")
        self.assertEqual(self.store.read()["boots"][BOOT]["granted"], "reset")
        self.assertFalse((self.store.root / "recovery-status.json").exists())
        self.assertEqual(list(self.store.root.glob(".write-*")), [])
        self.assertFalse(self.store.view(self.store.read())["automatic_reset_allowed"])

    def test_malformed_latch_or_release_refuses_even_with_valid_checksum(self):
        self.boot()
        self.rearm()
        baseline = self.store.path.read_bytes()
        for field in ("rescue", "release"):
            envelope = json.loads(baseline)
            envelope["record"][field] = {}
            envelope["sha256"] = r.hashlib.sha256(r.encoded(envelope["record"])).hexdigest()
            self.store.path.write_bytes(r.encoded(envelope))
            result = self.store.view(self.store.read())
            self.assertFalse(result["rescue_required"])
            self.assertFalse(result["automatic_reset_allowed"])

    def test_live_clock_checked_after_probe_and_after_persistence(self):
        self.boot()
        self.rearm()
        with patch.object(r, "_boottime", side_effect=[62, 67]):
            result = self.store.rollback(BOOT, pinned_bootloader=PIN, probe=self.proof)
        self.assertFalse(result["automatic_reset_allowed"])
        self.assertIn("expired", result["refusal_reasons"][-1])
        with patch.object(r, "_boottime", side_effect=[62, 63]):
            result = self.store.rollback(BOOT, pinned_bootloader=PIN, probe=self.proof)
        self.assertTrue(result["automatic_reset_allowed"])

    def test_release_observations_are_unknown_until_supplied(self):
        self.boot()
        release = self.store.read()["release"]
        self.assertIsNone(release["new_release"])
        self.assertIsNone(release["full_healthy_stream"])
        self.assertEqual(release["minimum_retention_seconds"], 604800)
        self.store.release(BOOT, new_release="sha256:" + "b" * 64,
                           previous_release="sha256:" + "c" * 64,
                           activated_at=1000, full_healthy_stream=True, trusted_now=605800)
        self.assertTrue(self.store.read()["release"]["full_healthy_stream"])
        self.assertFalse(self.store.view(self.store.read())["release_retirement_allowed"])


class SecondReviewAdmissionTest(unittest.TestCase):
    """Second review of the rollback layer: B6, B7, B8 and the follow-up gaps."""
    setUp = RecoveryTest.setUp
    rearm = RecoveryTest.rearm
    admit = AdmissionTest.admit
    proof = AdmissionTest.proof

    def armed(self):
        self.store.begin(BOOT, 0, reset_cause="power-on")
        self.rearm()

    def test_second_boot_after_flashing_does_not_latch(self):
        for cause in ("software", "watchdog", "panic"):
            with self.subTest(cause=cause):
                self.store.path.unlink(missing_ok=True)
                self.store.begin(BOOT, 0, reset_cause="power-on")
                view = self.store.begin(OTHER, 0, reset_cause=cause)
                self.assertFalse(view["rescue_required"])
                self.assertNotEqual(view["state"], "rescue-required")
                self.assertEqual(self.store.read()["rescue"]["entries"], 0)

    def test_corruption_or_threshold_change_then_watchdog_does_not_latch(self):
        self.armed()
        self.store.path.write_bytes(b"torn")
        self.assertNotEqual(self.store.begin(OTHER, 0, reset_cause="watchdog")["state"], "rescue-required")
        self.store.path.unlink()
        self.armed()
        changed = r.Store(self.store.root, limit=3, healthy_seconds=60)
        self.assertNotEqual(changed.begin(OTHER, 0, reset_cause="watchdog")["state"], "rescue-required")
        self.assertFalse(changed.read()["rescue"]["required"])

    def test_late_refusal_commits_no_grant(self):
        self.armed()
        boots = [BOOT] + ["%08x-8888-4888-8888-888888888888" % i for i in range(3)]
        for current, following in zip(boots, boots[1:]):
            with patch.object(r, "_boottime", side_effect=[62, 67]):
                result = self.store.rollback(current, pinned_bootloader=PIN,
                                             probe=lambda: good_proof(current))
            self.assertEqual(result["decision"], "REFUSE")
            witness = self.store.read()["boots"][current]
            self.assertEqual(witness["granted"], "none")
            self.assertEqual(witness["intent"], "none")
            self.assertEqual(witness["detectors"]["rollback"], "not-armed")
            status = json.loads((self.store.root / "recovery-status.json").read_text())
            self.assertFalse(status["automatic_reset_allowed"])
            self.store.begin(following, 0, reset_cause="power-on")
        self.assertEqual(self.store.read()["remaining"], 2)
        self.assertFalse(self.store.read()["rescue"]["required"])

    def test_late_refusal_keeps_an_earlier_grant(self):
        self.armed()
        self.assertEqual(self.admit(now=62)["decision"], "ALLOW")
        with patch.object(r, "_boottime", side_effect=[62, 67]):
            self.store.rollback(BOOT, pinned_bootloader=PIN, probe=self.proof)
        self.assertEqual(self.store.read()["boots"][BOOT]["granted"], "reset")

    def test_grant_survives_intent_and_refused_rollback(self):
        self.armed()
        self.assertEqual(self.admit()["decision"], "ALLOW")
        self.store.intent(BOOT, "none")
        self.store.intent(BOOT, "unbind-adapter")
        bad = self.proof()
        bad["watchdog"] = "unknown"
        self.assertEqual(self.admit(bad)["decision"], "REFUSE")
        self.assertEqual(self.store.read()["boots"][BOOT]["granted"], "reset")
        self.assertEqual(self.store.begin(OTHER, 0, reset_cause="unknown")["remaining"], 1)

    def test_review_probe_twenty_grants_spend_the_budget(self):
        self.armed()
        boots = [BOOT] + ["%08x-9999-4999-8999-999999999999" % i for i in range(20)]
        admissions = 0
        for current, following in zip(boots, boots[1:]):
            with patch.object(r, "_boottime", return_value=62):
                result = self.store.rollback(current, pinned_bootloader=PIN,
                                             probe=lambda: good_proof(current))
            admissions += result["decision"] == "ALLOW"
            self.store.intent(current, "none")
            self.store.begin(following, 0, reset_cause="unknown")
        self.assertEqual(admissions, 2)
        self.assertEqual(self.store.read()["remaining"], 0)

    def test_granted_trial_is_charged(self):
        self.armed()
        self.assertTrue(self.admit(action="activate-other-slot")["update_trial_allowed"])
        self.assertEqual(self.store.read()["boots"][BOOT]["granted"], "activate-other-slot")
        self.assertEqual(self.store.begin(OTHER, 0, reset_cause="unknown")["remaining"], 1)

    def test_clock_is_not_a_caller_parameter(self):
        import inspect
        self.assertNotIn("now", inspect.signature(r.Store.rollback).parameters)
        self.assertNotIn("now", inspect.signature(r.Store.rollback_status).parameters)
        self.armed()
        with self.assertRaises(TypeError):
            self.store.rollback(BOOT, 61, pinned_bootloader=PIN, probe=self.proof)
        # Hour-old evidence is refused by the live clock.
        self.assertEqual(self.admit(now=3661)["decision"], "REFUSE")

    def test_future_dated_evidence_refused(self):
        self.armed()
        with patch.object(r, "_boottime", return_value=61):
            self.assertFalse(self.store.rollback_status(
                BOOT, pinned_bootloader=PIN, probe=lambda: good_proof(observed=70))["rollback_armed"])
        self.assertEqual(self.admit(good_proof(observed=70), now=61)["decision"], "REFUSE")
        self.assertEqual(self.admit(good_proof(observed=61), now=66)["decision"], "ALLOW")

    def test_counter_evidence_must_be_exact_and_typed(self):
        self.armed()
        cases = [dict(counter_after=1, counter_readback=1), dict(counter_readback=1),
                 dict(counter_before=0), dict(counter_after="2"), dict(counter_before=2.0),
                 dict(counter_before=2 ** 31), dict(counter_readback=None),
                 dict(counter_before=3.0, counter_after=2.0, counter_readback=2.0),
                 dict(counter_before=True, counter_after=0, counter_readback=0)]
        for change in cases:
            key, value = next(iter(change.items()))
            proof = self.proof()
            proof.update(change)
            with self.subTest(key=key, value=value):
                result = self.admit(proof)
                self.assertEqual(result["decision"], "REFUSE")
                self.assertTrue(any("counter" in reason for reason in result["refusal_reasons"]))

    def test_pin_format_is_checked_not_just_equality(self):
        self.armed()
        for pin in ("unknown", "sha256:" + "A" * 64, "sha256:" + "a" * 63, None):
            proof = self.proof()
            proof["bootloader"] = pin
            with self.subTest(pin=pin):
                self.assertEqual(self.admit(proof, pinned=pin)["decision"], "REFUSE")

    def test_refusal_records_detectors_but_never_the_bootloader(self):
        self.armed()
        bad = self.proof()
        bad["watchdog"] = "unknown"
        self.admit(bad)
        witness = self.store.read()["boots"][BOOT]
        self.assertEqual(witness["bootloader"], "unknown")
        self.assertEqual(witness["detectors"], {"rollback": "not-armed", "watchdog": "unknown"})
        stale = self.proof()
        self.admit(stale, now=100)
        witness = self.store.read()["boots"][BOOT]
        self.assertEqual(witness["detectors"], {"rollback": "not-armed", "watchdog": "unknown"})
        self.assertEqual(witness["bootloader"], "unknown")
        self.admit()
        witness = self.store.read()["boots"][BOOT]
        self.assertEqual(witness["detectors"], {"rollback": "armed", "watchdog": "armed"})
        self.assertEqual(witness["bootloader"], PIN)

    def test_rollback_status_is_read_only_and_never_grants(self):
        self.armed()
        before = sorted((path.name, path.read_bytes()) for path in self.store.root.iterdir())
        with patch.object(r, "_boottime", return_value=62):
            status = self.store.rollback_status(BOOT, pinned_bootloader=PIN, probe=self.proof)
        self.assertTrue(status["rollback_armed"])
        self.assertEqual(status["decision"], "REFUSE")
        self.assertFalse(status["automatic_reset_allowed"])
        self.assertFalse(status["update_trial_allowed"])
        self.assertEqual(before, sorted((path.name, path.read_bytes()) for path in self.store.root.iterdir()))
        for i in range(3):
            following = "%08x-aaaa-4aaa-8aaa-aaaaaaaaaaaa" % i
            self.store.begin(following, 0, reset_cause="power-on")
        self.assertEqual(self.store.read()["remaining"], 2)

    def test_rollback_status_creates_nothing_on_a_fresh_directory(self):
        root = Path(self.tmp.name) / "absent"
        store = r.Store(root, limit=2, healthy_seconds=60)
        with patch.object(r, "_boottime", return_value=62):
            status = store.rollback_status(BOOT, pinned_bootloader=PIN, probe=good_proof)
        self.assertEqual(status["decision"], "REFUSE")
        self.assertFalse(root.exists())

    def test_probe_errors_of_any_kind_refuse(self):
        self.armed()
        def broken():
            raise RuntimeError("collector bug")
        with patch.object(r, "_boottime", return_value=62):
            result = self.store.rollback(BOOT, pinned_bootloader=PIN, probe=broken)
            status = self.store.rollback_status(BOOT, pinned_bootloader=PIN, probe=broken)
        self.assertEqual(result["decision"], "REFUSE")
        self.assertFalse(status["rollback_armed"])

    def test_rescue_entered_only_when_a_reset_is_needed_after_the_last_credit(self):
        boots = ["%08x-bbbb-4bbb-8bbb-bbbbbbbbbbbb" % i for i in range(6)]
        for need in ("watchdog", "failed-health", "reset-request"):
            with self.subTest(need=need):
                self.store.path.unlink(missing_ok=True)
                self.store.begin(boots[0], 0, reset_cause="power-on")
                self.rearm(boots[0])
                self.store.begin(boots[1], 0, reset_cause="watchdog")
                view = self.store.begin(boots[2], 0, reset_cause="watchdog")
                self.assertEqual(view["state"], "reset-budget-spent")
                self.assertFalse(view["rescue_required"])
                self.assertIn("spent", view["announcement"])
                self.assertNotIn("Stop media", view["announcement"])
                self.assertEqual(self.store.health(boots[2], 1, "healthy")["state"], "reset-budget-spent")
                if need == "watchdog":
                    view = self.store.begin(boots[3], 0, reset_cause="watchdog")
                    entered = boots[3]
                elif need == "failed-health":
                    view = self.store.health(boots[2], 2, "failed")
                    entered = boots[2]
                else:
                    with patch.object(r, "_boottime", return_value=62):
                        view = self.store.rollback(boots[2], pinned_bootloader=PIN,
                                                   probe=lambda: good_proof(boots[2]))
                    self.assertEqual(view["decision"], "REFUSE")
                    entered = boots[2]
                self.assertTrue(view["rescue_required"])
                self.assertEqual(view["state"], "rescue-required")
                self.assertEqual(self.store.read()["rescue"],
                                 {"required": True, "entries": 1, "entered_boot": entered})

    def test_missing_credit_reset_request_is_not_rescue(self):
        self.store.begin(BOOT, 0, reset_cause="power-on")
        result = self.admit()
        self.assertEqual(result["decision"], "REFUSE")
        self.assertFalse(result["rescue_required"])
        self.assertFalse(self.store.read()["rescue"]["required"])

    def test_damaged_ledger_reports_unknown_rescue_state(self):
        self.armed()
        self.store.path.write_bytes(b"torn")
        view = self.store.view(self.store.read())
        self.assertIsNone(view["rescue_required"])
        self.assertEqual(view["state"], "recovery-uncertain")
        view = self.store.begin(OTHER, 0, reset_cause="power-on")
        self.assertIsNone(view["rescue_required"])
        status = json.loads((self.store.root / "recovery-status.json").read_text())
        self.assertIsNone(status["rescue_required"])


if __name__ == "__main__":
    unittest.main()

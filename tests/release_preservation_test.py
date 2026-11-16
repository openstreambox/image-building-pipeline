"""Host-only preservation contracts; all releases and observations are synthetic."""
import json
import os
import select
import signal
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'mkosi/runtime'))
import recovery_witness as witness
import release_preservation as retention

BOOT = '11111111-1111-4111-8111-111111111111'
OTHER = '22222222-2222-4222-8222-222222222222'
OLD, NEW, NEXT, PIN = ['sha256:' + c * 64 for c in 'abcd']
WEEK = 604800


class PreservationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.store = witness.Store(self.root, limit=3, healthy_seconds=1)
        self.owner = retention.Owners(self.store)
        self.now, self.wall, self.boot = 10, 1000000, BOOT
        self.clock = patch.object(witness, '_boottime', side_effect=lambda: self.now)
        self.clock.start()
        self.addCleanup(self.clock.stop)
        self.wallclock = patch.object(retention, '_walltime', side_effect=lambda: self.wall)
        self.wallclock.start()
        self.addCleanup(self.wallclock.stop)
        self.store.begin(BOOT, slot='A')
        self.healthy()
        self.running, self.slot, self.target, self.target_slot = OLD, 'A', NEXT, 'B'
        self.calls = []

    def wait_child(self, pid):
        fd = os.pidfd_open(pid)
        try:
            if not select.select([fd], [], [], 10)[0]:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
                self.fail('owned child exceeded deadline')
            return os.waitpid(pid, 0)[1]
        finally:
            os.close(fd)

    def healthy(self):
        self.store.health(self.boot, 'healthy')
        self.now += 1
        self.store.health(self.boot, 'healthy')

    def proof(self, **changes):
        result = dict(boot_id=self.boot, observed_uptime=self.now,
                      running_release=self.running, running_slot=self.slot,
                      target_release=self.target, target_slot=self.target_slot,
                      bootable=True, counter_source='independent-readback',
                      counter_before=3, counter_after=2, counter_readback=2,
                      bootloader=PIN, watchdog='armed')
        result.update(changes)
        return result

    def provision(self):
        self.owner.provision(self.boot, probe=self.proof)

    def update(self, candidate=NEW, probe=None, apply=None):
        return self.owner.update(self.boot, candidate=candidate, pinned_bootloader=PIN,
                                 probe=probe or self.proof, apply=apply or self.calls.append)

    def activate(self):
        self.provision()
        self.assertTrue(self.update()['allowed'])
        self.running, self.slot, self.target, self.target_slot = NEW, 'B', OLD, 'A'
        self.store.begin(OTHER, slot='B')
        self.boot = OTHER
        self.healthy()
        self.assertTrue(self.owner.observe(self.boot, probe=self.proof)['allowed'])

    def stream(self, **changes):
        token = self.store.read()['retention']['activation']
        return self.owner.stream(self.boot, probe=lambda: self.proof(
            activation=token, full_healthy_stream=True, **changes))

    def advance(self, seconds=WEEK, wall=None):
        self.now += seconds
        self.wall += seconds if wall is None else wall
        return self.owner.observe(self.boot, probe=self.proof)

    def qualify(self):
        self.activate()
        self.assertTrue(self.stream()['allowed'])
        self.advance()

    def retire(self, owner='mirror', **kwargs):
        return self.owner.retire(self.boot, owner=owner, pinned_bootloader=PIN,
                                 probe=kwargs.pop('probe', self.proof),
                                 apply=kwargs.pop('apply', self.calls.append), **kwargs)

    def assert_visible(self, fragment):
        status = self.store.rollback_status(self.boot, pinned_bootloader=PIN, probe=self.proof)
        self.assertIn(fragment, ' '.join(status['release_retention_reasons']))
        projection = self.store.current_projection()
        self.assertIsNotNone(projection)
        self.assertIn(fragment, ' '.join(projection['release_retention_reasons']))

    def test_unknown_missing_and_damaged_state_never_runs_effects(self):
        for raw in (None, b'{}', b'{torn'):
            with self.subTest(raw=raw):
                if raw is None:
                    self.store.path.unlink()
                else:
                    self.store.path.write_bytes(raw)
                self.assertFalse(self.update()['allowed'])
                self.assertFalse(self.retire()['allowed'])
                self.assertEqual(self.calls, [])

    def test_explicit_setup_requires_health_fresh_identity_and_no_overwrite(self):
        for changes in ({'bootable': None}, {'observed_uptime': 0}, {'running_release': None},
                        {'running_slot': 'B'}, {'boot_id': OTHER}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.owner.provision(self.boot, probe=lambda: self.proof(**changes))
        self.store.health(self.boot, 'failed')
        with self.assertRaises(ValueError):
            self.provision()
        self.healthy()
        self.provision()
        with self.assertRaises(FileExistsError):
            self.provision()

    def test_update_records_prior_before_effect_and_unknown_target_refuses(self):
        self.provision()
        self.assertFalse(self.update(probe=lambda: self.proof(target_release=None))['allowed'])
        def apply(plan):
            saved = self.store.read()['retention']
            self.assertEqual(saved['phase'], 'pending')
            self.assertEqual(saved['previous_release'], OLD)
            self.assertEqual(saved['previous_slot'], 'A')
            self.assertEqual(plan['slot'], 'B')
            self.assertIsNone(saved['activated_wall'])
        self.assertTrue(self.update(apply=apply)['allowed'])
        self.assert_visible('activation')

    def test_update_never_writes_running_or_unknown_slot_or_bad_pin(self):
        self.provision()
        for changes in ({'target_slot': 'A'}, {'bootloader': NEXT}, {'watchdog': 'unknown'},
                        {'counter_readback': 1}, {'observed_uptime': self.now + 1},
                        {'running_release': NEXT}):
            with self.subTest(changes=changes):
                self.assertFalse(self.update(probe=lambda: self.proof(**changes))['allowed'])
        self.assertEqual(self.calls, [])
        self.assert_visible('running')

    def test_pending_update_cannot_be_replaced_or_retired_even_after_week(self):
        self.provision()
        def failed(_):
            raise OSError('interrupted install')
        with self.assertRaises(OSError):
            self.update(apply=failed)
        self.advance()
        self.assertFalse(self.update(NEXT)['allowed'])
        self.assertFalse(self.retire()['allowed'])
        self.assertEqual(self.store.read()['retention']['previous_release'], OLD)

    def test_health_snapshots_and_legacy_release_boolean_do_not_prove_stream(self):
        self.activate()
        self.store.release(self.boot, new_release=NEW, previous_release=OLD,
                           activated_at=0, full_healthy_stream=True, trusted_now=9999999)
        self.advance()
        self.assertFalse(self.retire()['allowed'])
        self.assert_visible('stream')

    def test_stream_proof_is_activation_boot_release_health_and_freshness_bound(self):
        self.activate()
        token = self.store.read()['retention']['activation']
        for changes in ({'activation': '0' * 32}, {'boot_id': BOOT}, {'running_release': OLD},
                        {'observed_uptime': self.now - 6}, {'full_healthy_stream': 1},
                        {'full_healthy_stream': None}):
            with self.subTest(changes=changes):
                proof = self.proof(activation=token, full_healthy_stream=True)
                proof.update(changes)
                self.assertFalse(self.owner.stream(self.boot, probe=lambda: proof)['allowed'])
        self.store.health(self.boot, 'failed')
        self.assertFalse(self.stream()['allowed'])
        self.healthy()
        self.assertTrue(self.stream()['allowed'])

    def test_both_stream_and_full_week_required_at_exact_boundary_for_all_owners(self):
        self.activate()
        self.assertTrue(self.stream()['allowed'])
        self.advance(WEEK - 1)
        for owner in ('update', 'selector', 'mirror'):
            self.assertFalse(self.retire(owner)['allowed'])
        self.advance(1)
        self.assertTrue(self.store.rollback_status(self.boot, pinned_bootloader=PIN,
                        probe=self.proof)['release_retention_eligible'])
        for owner in ('update', 'selector', 'mirror'):
            # Each owner is checked against the same intact unretired generation.
            saved = self.store.path.read_bytes()
            self.assertTrue(self.retire(owner)['allowed'])
            self.store.path.write_bytes(saved)
        self.assertEqual(len(self.calls), 4)

    def test_clock_forward_and_backward_jumps_cannot_shorten_retention(self):
        self.activate()
        self.stream()
        self.advance(1, wall=WEEK * 10)
        self.assertFalse(self.retire()['allowed'])
        self.advance(1, wall=-WEEK * 10)
        self.assertFalse(self.retire()['allowed'])
        self.advance(WEEK - 2)
        self.assertFalse(self.retire()['allowed'])
        self.advance(2)
        self.assertTrue(self.retire()['allowed'])

    def test_backwards_monotonic_clock_earns_no_time(self):
        self.activate()
        self.stream()
        self.advance(-5, wall=WEEK)
        self.assertFalse(self.retire()['allowed'])
        self.advance(WEEK - 1)
        self.assertFalse(self.retire()['allowed'])
        self.advance(1)
        self.assertTrue(self.retire()['allowed'])

    def test_reboots_count_only_observed_same_boot_intervals(self):
        self.activate()
        self.stream()
        self.advance(WEEK // 2)
        self.boot = '33333333-3333-4333-8333-333333333333'
        self.now = 1
        self.wall += WEEK * 2
        self.store.begin(self.boot, slot='B')
        self.owner.observe(self.boot, probe=self.proof)
        self.assertFalse(self.retire()['allowed'])
        self.advance(WEEK // 2)
        self.assertTrue(self.retire()['allowed'])

    def test_process_restart_does_not_duplicate_elapsed_time(self):
        self.activate()
        self.stream()
        self.advance(WEEK // 2)
        self.owner = retention.Owners(witness.Store(self.root, limit=3, healthy_seconds=1))
        self.owner.observe(self.boot, probe=self.proof)
        self.assertEqual(self.store.read()['retention']['elapsed'], WEEK // 2)
        self.advance(WEEK // 2)
        self.assertTrue(self.retire()['allowed'])

    def test_unknown_observation_breaks_clock_chain_and_keeps_previous(self):
        self.activate()
        self.stream()
        self.advance(WEEK // 2)
        self.now += WEEK
        self.wall += WEEK
        self.owner.observe(self.boot, probe=lambda: {})
        self.owner.observe(self.boot, probe=self.proof)
        self.assertFalse(self.retire()['allowed'])
        self.advance(WEEK // 2)
        self.assertTrue(self.retire()['allowed'])

    def test_next_update_retains_current_release_and_resets_evidence(self):
        self.qualify()
        self.assertTrue(self.update(NEXT)['allowed'])
        r = self.store.read()['retention']
        self.assertEqual((r['new_release'], r['previous_release']), (NEXT, NEW))
        self.assertFalse(r['full_stream'])
        self.assertEqual(r['elapsed'], 0)
        self.assertIsNone(r['activated_wall'])
        self.assertFalse(self.retire()['allowed'])

    def test_second_update_refuses_before_qualification(self):
        self.activate()
        self.assertFalse(self.update(NEXT)['allowed'])
        self.assertEqual(len(self.calls), 1)
        self.assert_visible('stream')

    def test_retirement_requires_exact_current_and_target_identities(self):
        self.qualify()
        for changes in ({'target_release': NEXT}, {'target_slot': 'B'}, {'running_release': OLD},
                        {'bootable': False}, {'boot_id': BOOT}):
            with self.subTest(changes=changes):
                self.assertFalse(self.retire(probe=lambda: self.proof(**changes))['allowed'])
        self.assertEqual(len(self.calls), 1)

    def test_failed_effect_leaves_intent_and_retry_is_bound_to_same_owner(self):
        self.qualify()
        def failed(_):
            raise OSError('interrupted mirror')
        with self.assertRaises(OSError):
            self.retire(apply=failed)
        self.assertFalse(self.retire('selector')['allowed'])
        self.assertFalse(self.update(NEXT)['allowed'])
        self.assertTrue(self.retire()['allowed'])
        self.assertTrue(self.store.read()['retention']['retired'])

    def test_late_collector_refuses_before_effect(self):
        self.qualify()
        def slow():
            proof = self.proof()
            self.now += 6
            return proof
        self.assertFalse(self.retire(probe=slow)['allowed'])
        self.assertEqual(len(self.calls), 1)

    def test_persistence_failure_never_calls_effect(self):
        self.provision()
        with patch.object(self.store, 'atomic_file', side_effect=OSError('disk full')):
            with self.assertRaises(OSError):
                self.update()
        self.assertEqual(self.calls, [])

    def test_late_persistence_refuses_before_effect(self):
        self.qualify()
        original = self.store.write
        def slow(record):
            original(record)
            self.now += 6
        with patch.object(self.store, 'write', side_effect=slow):
            self.assertFalse(self.retire()['allowed'])
        self.assertEqual(len(self.calls), 1)
        self.assert_visible('expired')

    def test_projection_failure_is_unavailable_and_never_authorizes(self):
        self.activate()
        original = self.store.atomic_file
        def fail_status(path, raw):
            if path.name == 'recovery-status.json':
                raise OSError('status full')
            original(path, raw)
        with patch.object(self.store, 'atomic_file', side_effect=fail_status):
            self.assertFalse(self.retire()['allowed'])
        self.assertIsNone(self.store.current_projection())
        self.assertFalse(self.store.rollback_status(self.boot, pinned_bootloader=PIN,
                         probe=self.proof)['release_retirement_allowed'])

    def test_rescue_latch_is_not_cleared_by_preservation(self):
        self.activate()
        with self.store.locked():
            r = self.store.read()
            r['exhausted'] = True
            r['rescue'].update(required=True, entries=1, entered_boot=self.boot)
            self.store.write(r)
        self.assertFalse(self.update(NEXT)['allowed'])
        self.assertTrue(self.store.read()['rescue']['required'])

    def test_concurrent_producers_do_not_lose_health_or_duplicate_time(self):
        self.activate()
        self.stream()
        self.now += WEEK // 2
        self.wall += WEEK // 2
        children = []
        for operation in ('observe', 'observe', 'health'):
            pid = os.fork()
            if pid == 0:
                try:
                    try:
                        if operation == 'health':
                            self.store.health(self.boot, 'failed')
                        else:
                            self.owner.observe(self.boot, probe=self.proof)
                        os._exit(0)
                    except BaseException:
                        os._exit(1)
                except BaseException:
                    os._exit(98)
            children.append(pid)
        for pid in children:
            self.assertEqual(self.wait_child(pid), 0)
        r = self.store.read()
        self.assertEqual(r['retention']['elapsed'], WEEK // 2)
        self.assertEqual(r['boots'][self.boot]['health'], 'failed')
        self.assertFalse(self.retire()['allowed'])

    def test_effect_holds_shared_lock_against_health_writer(self):
        self.provision()
        ready_r, ready_w = os.pipe()
        go_r, go_w = os.pipe()
        done_r, done_w = os.pipe()
        children = []
        try:
            pid = os.fork()
            if pid == 0:
                try:
                    def apply(_):
                        os.write(ready_w, b'x')
                        if not select.select([go_r], [], [], 5)[0]:
                            os._exit(97)
                        os.read(go_r, 1)
                    self.update(apply=apply)
                    os._exit(0)
                except BaseException:
                    os._exit(98)
            children.append(pid)
            self.assertTrue(select.select([ready_r], [], [], 5)[0])
            os.read(ready_r, 1)
            pid = os.fork()
            if pid == 0:
                try:
                    os.write(done_w, b's')
                    self.store.health(self.boot, 'failed')
                    os.write(done_w, b'd')
                    os._exit(0)
                except BaseException:
                    os._exit(98)
            children.append(pid)
            self.assertTrue(select.select([done_r], [], [], 5)[0])
            self.assertEqual(os.read(done_r, 1), b's')
            self.assertFalse(select.select([done_r], [], [], 0.1)[0])
        finally:
            os.write(go_w, b'x')
            for pid in children:
                self.assertEqual(self.wait_child(pid), 0)
            for fd in (ready_r, ready_w, go_r, go_w, done_r, done_w):
                os.close(fd)
        r = self.store.read()
        self.assertEqual(r['boots'][self.boot]['health'], 'failed')
        self.assertEqual(r['retention']['previous_release'], OLD)

    def test_concurrent_updates_have_one_effect(self):
        self.provision()
        marker = self.root / 'effects'
        children = []
        for _ in range(2):
            pid = os.fork()
            if pid == 0:
                try:
                    try:
                        def apply(_):
                            with marker.open('ab') as stream:
                                stream.write(b'x')
                        self.update(apply=apply)
                        os._exit(0)
                    except BaseException:
                        os._exit(1)
                except BaseException:
                    os._exit(98)
            children.append(pid)
        for pid in children:
            self.assertEqual(self.wait_child(pid), 0)
        self.assertEqual(marker.read_bytes(), b'x')

    def test_crash_at_every_durable_update_boundary_keeps_prior(self):
        self.provision()
        baseline = self.store.path.read_bytes()
        # atomic ledger and advisory status: file fsync, replace, directory fsync.
        for boundary in range(1, 7):
            for after in (False, True):
                with self.subTest(boundary=boundary, after=after):
                    self.store.path.write_bytes(baseline)
                    pid = os.fork()
                    if pid == 0:
                        try:
                            count = [0]
                            original_fsync, original_replace = os.fsync, os.replace
                            def call(fn, *args):
                                # Skip lock-directory setup; hook only once write starts.
                                count[0] += 1
                                if count[0] == boundary and not after:
                                    os._exit(71)
                                value = fn(*args)
                                if count[0] == boundary and after:
                                    os._exit(71)
                                return value
                            original_write = self.store.write
                            def write(record):
                                with patch.object(os, 'fsync', side_effect=lambda *a: call(original_fsync, *a)), \
                                     patch.object(os, 'replace', side_effect=lambda *a: call(original_replace, *a)):
                                    original_write(record)
                            self.store.write = write
                            self.update()
                            os._exit(72)
                        except BaseException:
                            os._exit(98)
                    self.assertEqual(self.wait_child(pid), 71 << 8)
                    r = self.store.read()
                    self.assertIn(r['retention']['phase'], ('idle', 'pending'))
                    self.assertFalse(self.retire()['allowed'])
                    self.assertEqual(self.calls, [])

    def test_process_death_during_effect_retains_prior_and_blocks_next_update(self):
        self.provision()
        pid = os.fork()
        if pid == 0:
            try:
                self.update(apply=lambda _: os._exit(73))
                os._exit(74)
            except BaseException:
                os._exit(98)
        self.assertEqual(self.wait_child(pid), 73 << 8)
        self.assertEqual(self.store.read()['retention']['previous_release'], OLD)
        self.assertFalse(self.update(NEXT)['allowed'])
        self.assertFalse(self.retire()['allowed'])

    def test_crash_at_retirement_commit_boundaries_keeps_running_release(self):
        self.qualify()
        baseline = self.store.path.read_bytes()
        for boundary in range(1, 13):
            for after in (False, True):
                with self.subTest(boundary=boundary, after=after):
                    self.store.path.write_bytes(baseline)
                    marker = self.root / 'retired-effect'
                    marker.unlink(missing_ok=True)
                    pid = os.fork()
                    if pid == 0:
                        try:
                            count = [0]
                            fsync, replace = os.fsync, os.replace
                            def call(fn, *args):
                                count[0] += 1
                                if count[0] == boundary and not after:
                                    os._exit(75)
                                value = fn(*args)
                                if count[0] == boundary and after:
                                    os._exit(75)
                                return value
                            write = self.store.write
                            def interrupted(record):
                                with patch.object(os, 'fsync', side_effect=lambda *a: call(fsync, *a)), \
                                     patch.object(os, 'replace', side_effect=lambda *a: call(replace, *a)):
                                    write(record)
                            self.store.write = interrupted
                            def effect(plan):
                                assert plan['release'] == OLD and plan['slot'] == 'A'
                                marker.write_bytes(b'previous only')
                            self.retire(apply=effect)
                            os._exit(76)
                        except BaseException:
                            os._exit(98)
                    self.assertEqual(self.wait_child(pid), 75 << 8)
                    r = self.store.read()['retention']
                    self.assertEqual((r['new_release'], r['new_slot']), (NEW, 'B'))
                    self.assertEqual(r['previous_release'], OLD)
                    if r['retired']:
                        self.assertTrue(marker.exists())
                    elif r['effect']:
                        self.assertFalse(self.update(NEXT)['allowed'])
                        self.assertTrue(self.retire()['allowed'])

    def test_stream_collector_exception_and_unknown_are_visible(self):
        self.activate()
        for probe in (lambda: None, lambda: 1,
                      lambda: (_ for _ in ()).throw(OSError('unavailable'))):
            self.assertFalse(self.owner.stream(self.boot, probe=probe)['allowed'])
            self.assert_visible('stream')

    def test_wall_jump_after_qualification_does_not_authorize_retirement(self):
        self.qualify()
        self.wall -= WEEK + 1
        self.assertFalse(self.retire()['allowed'])
        self.assertEqual(len(self.calls), 1)

    def test_missing_or_invalid_clock_preserves_and_is_visible(self):
        self.activate()
        for value in (None, float('nan'), -1, True):
            with self.subTest(value=value), patch.object(retention, '_walltime', return_value=value):
                self.assertFalse(self.owner.observe(self.boot, probe=self.proof)['allowed'])
                self.assertFalse(self.retire()['allowed'])
            self.assert_visible('clock')

    def test_elapsed_is_bounded_by_slow_wall_time(self):
        self.activate()
        self.stream()
        self.advance(WEEK, wall=10)
        self.assertEqual(self.store.read()['retention']['elapsed'], 10)
        self.assertFalse(self.retire()['allowed'])

    def test_unknown_schema_or_corrupt_retention_never_authorizes(self):
        self.qualify()
        for mutate in (lambda r: r.update(version=999),
                       lambda r: r['retention'].update(elapsed=True),
                       lambda r: r['retention'].update(phase='future')):
            saved = self.store.path.read_bytes()
            envelope = json.loads(saved)
            mutate(envelope['record'])
            import hashlib
            envelope['sha256'] = hashlib.sha256(witness.encoded(envelope['record'])).hexdigest()
            self.store.path.write_bytes(witness.encoded(envelope))
            self.assertFalse(self.retire()['allowed'])
            self.store.path.write_bytes(saved)


if __name__ == '__main__':
    unittest.main()

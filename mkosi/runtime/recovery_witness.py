#!/usr/bin/env python3
"""Durable boot evidence and reset admission, with no hardware or reset effects."""
import argparse
import contextlib
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import tempfile
import time

VERSION = 4
MAX_WITNESSES = 64
MAX_BYTES = 4 * 1024 * 1024
INTENTS = {"none", "reset", "activate-other-slot", "unbind-adapter"}
CONSOLE_MARKERS = {"kernel-start", "root-wait", "userspace-start", "panic", "watchdog-reset"}
STATES = {"unknown", "armed", "not-armed"}
HEALTH = {"unknown", "healthy", "failed"}
CAUSES = {"unknown", "watchdog", "panic", "software", "power-on"}
# Unclean resets spend credit; orderly reboots (operator, update completion) and
# unclassified boots do not, unless this box itself granted the reset.
CHARGED_CAUSES = {"watchdog", "panic"}
GRANTS = {"none", "reset"}


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def boot_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}", value):
        raise ValueError("invalid boot id")
    return value


def uptime(value):
    if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
        raise ValueError("invalid boot uptime")
    return value


def observations(slot, counters, bootloader, reset_cause, detectors, console_tail):
    if slot not in {"A", "B", "unknown"} or reset_cause not in CAUSES:
        raise ValueError("invalid slot or reset cause")
    if not isinstance(counters, dict) or set(counters) != {"A", "B"} or any(
        v is not None and (type(v) is not int or not 0 <= v <= 2147483647)
        for v in counters.values()
    ):
        raise ValueError("invalid counters")
    # A software digest identifies a bootloader build, never a particular box.
    if bootloader != "unknown" and not re.fullmatch(r"sha256:[0-9a-f]{64}", bootloader):
        raise ValueError("invalid bootloader digest")
    if not isinstance(detectors, dict) or set(detectors) != {"watchdog", "rollback"} or any(v not in STATES for v in detectors.values()):
        raise ValueError("invalid detector state")
    # Never store raw console text: even its last line can contain credentials.
    if not isinstance(console_tail, list) or len(console_tail) > 32 or any(v not in CONSOLE_MARKERS for v in console_tail):
        raise ValueError("invalid console markers")


class Store:
    """One locked atomic commit contains both budget and boot-keyed witnesses.

    The directory must be private, local durable storage owned by the caller.
    All producers must use this API; no edits or parallel alternate writers.
    """

    def __init__(self, root, *, limit, healthy_seconds):
        if type(limit) is not int or not 1 <= limit <= 1000:
            raise ValueError("invalid budget limit")
        if type(healthy_seconds) is not int or not 1 <= healthy_seconds <= 604800:
            raise ValueError("invalid health interval")
        self.root = Path(root)
        self.path = self.root / "recovery.json"
        self.limit = limit
        self.healthy_seconds = healthy_seconds
        self.max_health_gap = min(30, healthy_seconds)
        self._health = {}

    def empty(self, source):
        return {"version": VERSION, "limit": self.limit, "healthy_seconds": self.healthy_seconds,
                "remaining": 0, "current_boot": None, "boots": {}, "source": source, "exhausted": False,
                "pruned_boots": 0, "max_health_gap": self.max_health_gap,
                "rescue": {"required": False, "entries": 0, "entered_boot": None},
                "release": {"new_release": None, "previous_release": None,
                            "activated_at": None, "full_healthy_stream": None,
                            "trusted_now": None, "minimum_retention_seconds": 604800}}

    def validate(self, record):
        if set(record) != set(self.empty("missing")):
            raise ValueError("unknown record shape")
        if (type(record["version"]) is not int or record["version"] != VERSION
                or type(record["limit"]) is not int or not 1 <= record["limit"] <= 1000
                or type(record["healthy_seconds"]) is not int or not 1 <= record["healthy_seconds"] <= 604800
                or type(record["remaining"]) is not int or not 0 <= record["remaining"] <= record["limit"]
                or record["source"] not in {"missing", "invalid", "valid"}
                or not isinstance(record["boots"], dict)):
            raise ValueError("invalid budget")
        if record["current_boot"] is not None and record["current_boot"] not in record["boots"]:
            raise ValueError("missing current boot")
        if (type(record["exhausted"]) is not bool or type(record["pruned_boots"]) is not int
                or record["pruned_boots"] < 0 or type(record["max_health_gap"]) is not int
                or not 1 <= record["max_health_gap"] <= 30):
            raise ValueError("invalid recovery policy")
        rescue = record["rescue"]
        if (not isinstance(rescue, dict) or set(rescue) != {"required", "entries", "entered_boot"}
                or type(rescue["required"]) is not bool or type(rescue["entries"]) is not int
                or rescue["entries"] < 0 or rescue["required"] != record["exhausted"]):
            raise ValueError("invalid rescue state")
        if rescue["entered_boot"] is not None:
            boot_id(rescue["entered_boot"])
        self.validate_release(record["release"])
        for key, witness in record["boots"].items():
            boot_id(key)
            if set(witness) != {"state_source", "budget_at_start", "previous_boot", "slot", "counters", "bootloader", "reset_cause", "detectors", "console_tail", "health", "intent", "granted", "last_uptime", "healthy_since", "budget_remaining"}:
                raise ValueError("unknown witness shape")
            if witness["state_source"] not in {"missing", "invalid", "valid"}:
                raise ValueError("invalid initial state source")
            if type(witness["budget_at_start"]) is not int or not 0 <= witness["budget_at_start"] <= 1000:
                raise ValueError("invalid initial budget")
            if witness["previous_boot"] is not None:
                boot_id(witness["previous_boot"])
                if witness["previous_boot"] == key or witness["previous_boot"] not in record["boots"]:
                    raise ValueError("invalid previous boot")
            observations(*(witness[k] for k in ("slot", "counters", "bootloader", "reset_cause", "detectors", "console_tail")))
            uptime(witness["last_uptime"])
            if witness["healthy_since"] is not None:
                uptime(witness["healthy_since"])
                if witness["healthy_since"] > witness["last_uptime"]:
                    raise ValueError("invalid health anchor")
            if witness["health"] not in HEALTH or witness["intent"] not in INTENTS or witness["granted"] not in GRANTS:
                raise ValueError("invalid witness verdict")
            if type(witness["budget_remaining"]) is not int or not 0 <= witness["budget_remaining"] <= 1000:
                raise ValueError("invalid witness budget")
        return record

    def read(self):
        """Missing/old/torn/unreadable state denies resets, never invents health."""
        try:
            with self.path.open("rb") as stream:
                raw = stream.read(MAX_BYTES + 1)
            if len(raw) > MAX_BYTES:
                raise ValueError("record too large")
            envelope = json.loads(raw)
            if set(envelope) != {"record", "sha256"} or envelope["sha256"] != hashlib.sha256(encoded(envelope["record"])).hexdigest():
                raise ValueError("integrity mismatch")
            record = self.validate(envelope["record"])
            if (record["healthy_seconds"] != self.healthy_seconds or record["limit"] != self.limit
                    or record["max_health_gap"] != self.max_health_gap):
                record.update(remaining=0, source="invalid", limit=self.limit,
                              healthy_seconds=self.healthy_seconds, max_health_gap=self.max_health_gap)
            return record
        except FileNotFoundError:
            return self.empty("missing")
        except (OSError, ValueError, TypeError, KeyError, OverflowError, RecursionError):
            return self.empty("invalid")

    @contextlib.contextmanager
    def locked(self):
        # fsync the parent even after restart after an interrupted mkdir.
        self.root.mkdir(mode=0o700, exist_ok=True)
        self.root.chmod(0o700)
        parent = os.open(self.root.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
        with open(self.root / ".lock", "a", opener=lambda p, flags: os.open(p, flags, 0o600)) as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield

    def write(self, record):
        self.validate(record)
        raw = encoded({"record": record, "sha256": hashlib.sha256(encoded(record)).hexdigest()})
        if len(raw) > MAX_BYTES:
            raise ValueError("witness storage full; export and service required")
        self.atomic_file(self.path, raw)
        # A durable status projection for UI/LED consumers. Cached evidence never grants.
        self.atomic_file(self.root / "recovery-status.json", encoded(self.view(record)))

    def atomic_file(self, path, raw):
        fd, name = tempfile.mkstemp(prefix=".write-", dir=self.root)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(raw)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(name, path)
            directory = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            Path(name).unlink(missing_ok=True)

    @staticmethod
    def validate_release(value):
        if not isinstance(value, dict) or set(value) != {"new_release", "previous_release",
                "activated_at", "full_healthy_stream", "trusted_now", "minimum_retention_seconds"}:
            raise ValueError("invalid release record")
        for key in ("new_release", "previous_release"):
            if value[key] is not None and (not isinstance(value[key], str) or
                    not re.fullmatch(r"sha256:[0-9a-f]{64}", value[key])):
                raise ValueError("invalid release digest")
        for key in ("activated_at", "trusted_now"):
            if value[key] is not None:
                uptime(value[key])
        if (value["full_healthy_stream"] is not None and type(value["full_healthy_stream"]) is not bool
                or type(value["minimum_retention_seconds"]) is not int
                or value["minimum_retention_seconds"] != 604800):
            raise ValueError("invalid release evidence")

    @staticmethod
    def view(record, current_boot=None):
        remaining = record["remaining"]
        if current_boot is not None and record["current_boot"] != current_boot:
            remaining = 0
        rescue = record["rescue"]["required"]
        return {"version": VERSION, "boot_id": record["current_boot"], "remaining": remaining,
                "reset_budget_available": remaining > 0 and not rescue,
                "automatic_reset_allowed": False, "rollback_armed": False, "decision": "REFUSE",
                "update_trial_allowed": False,
                "refusal_reasons": ["Recheck independent counter persistence, pinned bootloader and live watchdog before relying on rollback."],
                "rescue_required": rescue, "rescue_active": False,
                "state": "rescue-required" if rescue else "rollback-not-armed",
                "console_marker": "RESCUE_REQUIRED" if rescue else "ROLLBACK_NOT_ARMED",
                "announcement": ("Rescue required: automatic resets denied. Stop media; retain management and log export. Rescue is not active. Ask a helper to recover using known-good boot media."
                                 if rescue else "Rollback not armed: verify counter persistence, pinned bootloader and live watchdog; updates and trials refused."),
                "release_retirement_allowed": False,
                "state_source": record["source"]}

    @staticmethod
    def latch(record):
        rescue = record["rescue"]
        if record["exhausted"] and not rescue["required"]:
            rescue.update(required=True, entries=rescue["entries"] + 1,
                          entered_boot=record["current_boot"])
        elif rescue["required"] and rescue["entered_boot"] is None:
            rescue["entered_boot"] = record["current_boot"]

    def rollback(self, boot, now=None, *, pinned_bootloader, probe, action="reset"):
        """Fresh trusted read-only collector; never use ledger/cached evidence.

        The collector must independently reread the bootloader's persisted counter,
        identify the running bootloader and check the currently running watchdog.
        No hardware collector or production pin is supplied by this host layer.
        """
        if now is not None:
            uptime(now)
        if action not in {"reset", "activate-other-slot"}:
            raise ValueError("invalid rollback action")
        reasons = []
        observed_times = []
        def change(record, witness):
            try:
                proof = probe()
            except (OSError, ValueError):
                proof = {}
            if not isinstance(proof, dict):
                proof = {}
            try:
                observed = uptime(proof.get("observed_uptime"))
                checked_now = time.clock_gettime(time.CLOCK_BOOTTIME) if now is None else now
                observed_times.append(observed)
                fresh = proof.get("boot_id") == boot and 0 <= checked_now - observed <= 5
            except ValueError:
                fresh = False
            if not fresh:
                reasons.append("Read fresh evidence from this boot (maximum age 5 seconds).")
            values = [proof.get(k) for k in ("counter_before", "counter_after", "counter_readback")]
            if (proof.get("counter_source") != "independent-readback"
                    or any(type(v) is not int or not 0 <= v <= 2147483647 for v in values)
                    or values[0] < 1 or values[1] != values[0] - 1 or values[2] != values[1]):
                reasons.append("Verify the bootloader decremented its counter and independently reread the persisted value.")
            if (not isinstance(pinned_bootloader, str)
                    or not re.fullmatch(r"sha256:[0-9a-f]{64}", pinned_bootloader)
                    or proof.get("bootloader") != pinned_bootloader):
                reasons.append("Check the running bootloader against the known pinned build; arrange manual service if different. Never write it automatically.")
            if proof.get("watchdog") != "armed":
                reasons.append("Verify the watchdog is running; an installed device or configuration alone is insufficient.")
            witness["detectors"] = {"rollback": "not-armed" if reasons else "armed",
                                    "watchdog": "armed" if fresh and proof.get("watchdog") == "armed" else "unknown"}
            if not reasons:
                witness["bootloader"] = pinned_bootloader
            witness["intent"] = action if not reasons and record["remaining"] > 0 else "none"
        result = self.update(boot, change)
        if now is None and observed_times and not 0 <= time.clock_gettime(time.CLOCK_BOOTTIME) - observed_times[0] <= 5:
            reasons.append("Evidence expired during persistence; collect fresh evidence before the action.")
        result["rollback_armed"] = not reasons
        result["refusal_reasons"] = reasons + (["Reset budget exhausted or uncertain; recover and explicitly requalify health."]
                                                if not result["reset_budget_available"] else [])
        allowed = not reasons and result["reset_budget_available"]
        result["decision"] = "ALLOW" if allowed else "REFUSE"
        result["automatic_reset_allowed"] = allowed and action == "reset"
        result["update_trial_allowed"] = allowed and action == "activate-other-slot"
        if allowed:
            result.update(state="rollback-armed", console_marker="ROLLBACK_ARMED",
                          announcement="Rollback evidence verified for this immediate admission only.")
        return result

    def release(self, boot, *, new_release, previous_release, activated_at,
                full_healthy_stream, trusted_now):
        """Record trusted update-path observations, never prune or authorize pruning."""
        value = dict(new_release=new_release, previous_release=previous_release,
                     activated_at=activated_at, full_healthy_stream=full_healthy_stream,
                     trusted_now=trusted_now, minimum_retention_seconds=604800)
        self.validate_release(value)
        return self.update(boot, lambda record, witness: record.update(release=value))

    def begin(self, boot, now, *, slot="unknown", counters=None, bootloader="unknown",
              reset_cause="unknown", detectors=None, console_tail=None):
        boot_id(boot)
        uptime(now)
        counters = {"A": None, "B": None} if counters is None else counters
        detectors = {"watchdog": "unknown", "rollback": "unknown"} if detectors is None else detectors
        console_tail = [] if console_tail is None else console_tail
        observations(slot, counters, bootloader, reset_cause, detectors, console_tail)
        with self.locked():
            record = self.read()
            for orphan in self.root.glob(".write-*"):
                orphan.unlink()
            if record["source"] == "invalid" and not record["boots"] and self.path.exists():
                # Preserve one rejected generation, even when its contents cannot be read.
                os.replace(self.path, self.root / "recovery.rejected")
                directory = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
            if boot in record["boots"]:
                if record["current_boot"] != boot:
                    raise ValueError("stale boot")
                # A prior writer may have died after rename but before directory fsync.
                # Recommit before returning a successful idempotent admission.
                self.latch(record)
                self.write(record)
                return self.view(record)
            previous_boot = record["current_boot"]
            prior = record["boots"].get(previous_boot, {})
            # A granted reset is charged whatever cause the next boot reports.
            charge = prior.get("granted", "none") != "none" or reset_cause in CHARGED_CAUSES
            if charge and record["remaining"] > 0:
                record["remaining"] -= 1
                # Only spending the last credit is an exhausted episode; a charge
                # against missing, corrupt or reset-by-threshold credit is not.
                if record["remaining"] == 0:
                    record["exhausted"] = True
            record["current_boot"] = boot
            record["boots"][boot] = dict(state_source=record["source"],
                budget_at_start=record["remaining"], previous_boot=previous_boot, slot=slot, counters=counters, bootloader=bootloader,
                reset_cause=reset_cause, detectors=detectors, console_tail=console_tail,
                health="unknown", intent="none", granted="none", last_uptime=now, healthy_since=None,
                budget_remaining=record["remaining"])
            # Keep insertion order via the explicit previous_boot chain (JSON keys sort).
            keep, current = [], boot
            while current is not None and len(keep) < MAX_WITNESSES:
                keep.append(current)
                current = record["boots"][current]["previous_boot"]
            removed = set(record["boots"]) - set(keep)
            record["pruned_boots"] += len(removed)
            for key in removed:
                del record["boots"][key]
            record["boots"][keep[-1]]["previous_boot"] = None
            self.latch(record)
            self.write(record)
            return self.view(record)

    def update(self, boot, change):
        boot_id(boot)
        with self.locked():
            record = self.read()
            if record["current_boot"] != boot:
                raise ValueError("current boot witness unavailable")
            change(record, record["boots"][boot])
            self.latch(record)
            self.write(record)
            return self.view(record)

    def intent(self, boot, action):
        """Call and await success BEFORE submitting the disruptive operation."""
        if action not in INTENTS:
            raise ValueError("invalid intent")
        def change(record, witness):
            if action in {"reset", "activate-other-slot"}:
                return
            witness["intent"] = action
        return self.update(boot, change)

    def health(self, boot, now, verdict):
        uptime(now)
        if verdict not in HEALTH:
            raise ValueError("invalid health")

        # Heartbeats are process-local. A restarted reporter must start a new dwell;
        # persisted healthy snapshots cannot prove that the reporter stayed alive.
        boot_id(boot)
        with self.locked():
            record = self.read()
            if record["current_boot"] != boot:
                raise ValueError("current boot witness unavailable")
            witness = record["boots"][boot]
            prior = self._health.get(boot)
            continuous = (prior is not None and prior[2] == "healthy" and verdict == "healthy"
                          and witness["health"] == "healthy"
                          and 0 <= now - prior[0] <= self.max_health_gap)
            anchor = prior[1] if continuous else (now if verdict == "healthy" else None)
            self._health[boot] = (now, anchor, verdict)
            rearm = verdict == "healthy" and now - anchor >= self.healthy_seconds
            transition = (verdict != witness["health"] or rearm
                          or verdict == "healthy" and not continuous)
            if not transition:
                return self.view(record)
            witness.update(last_uptime=now, health=verdict, healthy_since=anchor)
            if rearm:
                record.update(remaining=self.limit, source="valid", exhausted=False)
                record["rescue"]["required"] = False
                self._health[boot] = (now, now, verdict)
            witness["budget_remaining"] = record["remaining"]
            self.latch(record)
            self.write(record)
            return self.view(record)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--limit", type=int, required=True)
    parser.add_argument("--healthy-seconds", type=int, required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("begin")
    sub.add_parser("status")
    sub.add_parser("export")
    sub.add_parser("intent").add_argument("action", choices=sorted(INTENTS))
    sub.add_parser("health").add_argument("verdict", choices=sorted(HEALTH))
    args = parser.parse_args()
    try:
        store = Store(args.state_dir, limit=args.limit, healthy_seconds=args.healthy_seconds)
        if args.command == "export":
            result = store.read()
        elif args.command == "status":
            result = store.view(store.read(), Path("/proc/sys/kernel/random/boot_id").read_text().strip())
        else:
            boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
            now = time.clock_gettime(time.CLOCK_BOOTTIME)
            if args.command == "begin":
                result = store.begin(boot, now)
            elif args.command == "intent":
                result = store.intent(boot, args.action)
            else:
                result = store.health(boot, now, args.verdict)
        print(json.dumps(result, sort_keys=True))
        if args.command == "intent" and args.action in {"reset", "activate-other-slot"}:
            return 3
    except (OSError, ValueError):
        # Do not echo paths, raw input or exception text into a support report.
        print(json.dumps({"automatic_reset_allowed": False, "rescue_required": None,
                          "rescue_active": False, "state": "recovery-unavailable",
                          "console_marker": "RECOVERY_UNAVAILABLE", "rollback_armed": False, "decision": "REFUSE",
                          "update_trial_allowed": False,
                          "announcement": "Recovery state unavailable; automatic resets denied. Ask a helper to recover using known-good boot media."}))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

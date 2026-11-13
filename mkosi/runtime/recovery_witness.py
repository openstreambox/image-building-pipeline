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

VERSION = 3
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
                "pruned_boots": 0, "max_health_gap": self.max_health_gap}

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
        fd, name = tempfile.mkstemp(prefix=".write-", dir=self.root)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(raw)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(name, self.path)
            directory = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            Path(name).unlink(missing_ok=True)

    @staticmethod
    def view(record, current_boot=None):
        remaining = record["remaining"]
        if current_boot is not None and record["current_boot"] != current_boot:
            remaining = 0
        return {"version": VERSION, "boot_id": record["current_boot"], "remaining": remaining,
                "automatic_reset_allowed": remaining > 0,
                "rescue_required": record["exhausted"],
                "rescue_active": False,
                "announcement": ("Rescue required: reset budget exhausted. Automatic resets denied; management and log export must remain available."
                                 if record["exhausted"] else ("Recovery reset budget unavailable; confirm continuous health." if remaining == 0 else "Recovery reset budget available.")),
                "state_source": record["source"]}

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
            self.write(record)
            return self.view(record)

    def update(self, boot, change):
        boot_id(boot)
        with self.locked():
            record = self.read()
            if record["current_boot"] != boot:
                raise ValueError("current boot witness unavailable")
            change(record, record["boots"][boot])
            self.write(record)
            return self.view(record)

    def intent(self, boot, action):
        """Call and await success BEFORE submitting the disruptive operation."""
        if action not in INTENTS:
            raise ValueError("invalid intent")
        def change(record, witness):
            if action == "reset":
                if record["remaining"] == 0:
                    return
                # Sticky for this boot: later intents cannot erase the grant.
                witness["granted"] = "reset"
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
                self._health[boot] = (now, now, verdict)
            witness["budget_remaining"] = record["remaining"]
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
        if args.command == "intent" and args.action == "reset" and not result["automatic_reset_allowed"]:
            return 3
    except (OSError, ValueError):
        # Do not echo paths, raw input or exception text into a support report.
        print(json.dumps({"automatic_reset_allowed": False, "rescue_required": True,
                          "rescue_active": False, "announcement": "Recovery state unavailable; automatic resets denied."}))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

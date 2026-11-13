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

VERSION = 6
MAX_WITNESSES = 64
MAX_REJECTED = 4
MAX_BYTES = 4 * 1024 * 1024
INTENTS = {"none", "reset", "activate-other-slot", "unbind-adapter"}
CONSOLE_MARKERS = {"kernel-start", "root-wait", "userspace-start", "panic", "watchdog-reset"}
STATES = {"unknown", "armed", "not-armed"}
HEALTH = {"unknown", "healthy", "failed"}
CAUSES = {"unknown", "watchdog", "panic", "software", "power-on"}
# Unclean resets spend credit; orderly reboots (operator, update completion) and
# unclassified boots do not, unless this box itself granted the reset.
CHARGED_CAUSES = {"watchdog", "panic"}
# Admitted disruptive actions. Granted only by rollback(); sticky for the boot.
GRANTS = {"none", "reset", "activate-other-slot"}
ACTIONS = GRANTS - {"none"}
FRESH_SECONDS = 5
# What a reset request refused for want of credit means on a box that never
# confirmed health: count it like a charged reset, once per boot (default), or
# leave it uncounted so only charged boots can reach rescue.
REFUSED_RESET_REQUESTS = {"count-per-boot", "ignore"}
PIN_FORMAT = r"sha256:[0-9a-f]{64}"


def _boottime():
    # Private clock seam: evidence age, health dwell and witness uptime are never
    # judged by a caller-supplied time.
    return time.clock_gettime(time.CLOCK_BOOTTIME)


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

    def __init__(self, root, *, limit, healthy_seconds, refused_reset_requests="count-per-boot"):
        if type(limit) is not int or not 1 <= limit <= 1000:
            raise ValueError("invalid budget limit")
        if type(healthy_seconds) is not int or not 1 <= healthy_seconds <= 604800:
            raise ValueError("invalid health interval")
        if refused_reset_requests not in REFUSED_RESET_REQUESTS:
            raise ValueError("invalid refused reset request policy")
        self.refused_reset_requests = refused_reset_requests
        self.root = Path(root)
        self.path = self.root / "recovery.json"
        self.limit = limit
        self.healthy_seconds = healthy_seconds
        self.max_health_gap = min(30, healthy_seconds)
        self._health = {}

    def empty(self, source):
        return {"version": VERSION, "limit": self.limit, "healthy_seconds": self.healthy_seconds,
                "remaining": 0, "current_boot": None, "boots": {}, "source": source, "exhausted": False,
                "charges_without_credit": 0,
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
        if (type(record["charges_without_credit"]) is not int
                or not 0 <= record["charges_without_credit"] <= 1000):
            raise ValueError("invalid uncredited charge count")
        if (type(record["exhausted"]) is not bool or type(record["pruned_boots"]) is not int
                or record["pruned_boots"] < 0 or type(record["max_health_gap"]) is not int
                or not 1 <= record["max_health_gap"] <= 30):
            raise ValueError("invalid recovery policy")
        rescue = record["rescue"]
        if (not isinstance(rescue, dict) or set(rescue) != {"required", "entries", "entered_boot"}
                or type(rescue["required"]) is not bool or type(rescue["entries"]) is not int
                or rescue["entries"] < 0 or rescue["required"] and not record["exhausted"]):
            raise ValueError("invalid rescue state")
        if rescue["entered_boot"] is not None:
            boot_id(rescue["entered_boot"])
        self.validate_release(record["release"])
        for key, witness in record["boots"].items():
            boot_id(key)
            if set(witness) != {"state_source", "budget_at_start", "previous_boot", "slot", "counters", "bootloader", "reset_cause", "detectors", "console_tail", "health", "intent", "granted", "granted_at", "counted_without_credit", "last_uptime", "healthy_since", "budget_remaining"}:
                raise ValueError("unknown witness shape")
            if type(witness["counted_without_credit"]) is not bool:
                raise ValueError("invalid uncredited charge flag")
            if (witness["granted"] == "none") != (witness["granted_at"] is None):
                raise ValueError("invalid grant time")
            if witness["granted_at"] is not None:
                uptime(witness["granted_at"])
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
            try:
                record = self.validate(envelope["record"])
            except (ValueError, TypeError, KeyError, AttributeError):
                # An intact record of another schema version (a newer release, or
                # an older one after slot fallback) keeps a known latch.
                return self.carry_latch(envelope["record"])
            if (record["healthy_seconds"] != self.healthy_seconds or record["limit"] != self.limit
                    or record["max_health_gap"] != self.max_health_gap):
                record.update(remaining=0, source="invalid", limit=self.limit,
                              healthy_seconds=self.healthy_seconds, max_health_gap=self.max_health_gap)
            return record
        except FileNotFoundError:
            return self.empty("missing")
        except (OSError, ValueError, TypeError, KeyError, OverflowError, RecursionError):
            return self.empty("invalid")

    def carry_latch(self, old):
        """Quarantine an intact record of any other shape, keeping a known latch.

        Only the top-level `exhausted` and `rescue.required` fields are read; every
        schema keeps them. Only True carries over, so damage cannot clear a latch
        and nothing here invents credit.
        """
        record = self.empty("invalid")
        if not isinstance(old, dict):
            return record
        rescue = old.get("rescue") if isinstance(old.get("rescue"), dict) else {}
        if rescue.get("required") is True:
            entries = rescue.get("entries")
            entered = rescue.get("entered_boot")
            try:
                entered = boot_id(entered)
            except ValueError:
                entered = None
            record["rescue"] = {"required": True, "entered_boot": entered,
                                "entries": entries if type(entries) is int and 1 <= entries <= 1000000 else 1}
            record["exhausted"] = True
        elif old.get("exhausted") is True:
            record["exhausted"] = True
        return record

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
        digest = hashlib.sha256(encoded(record)).hexdigest()
        raw = encoded({"record": record, "sha256": digest})
        if len(raw) > MAX_BYTES:
            raise ValueError("witness storage full; export and service required")
        self.atomic_file(self.path, raw)
        self.project(record, digest)

    def project(self, record, digest):
        """Durable advisory projection for UI/LED consumers; never grants.

        The ledger commit above is the transaction. A failed projection must not
        fail it or leave a stale projection behind, so it is removed instead.
        `ledger_sha256` names the ledger generation it describes; see
        current_projection().
        """
        status = self.root / "recovery-status.json"
        try:
            self.atomic_file(status, encoded(dict(self.view(record), ledger_sha256=digest)))
        except OSError:
            with contextlib.suppress(OSError):
                status.unlink(missing_ok=True)

    def current_projection(self):
        """The published status only while it describes the intact current ledger.

        A ledger damaged, replaced or reconfigured after the last write makes the
        projection stale (it may still say rescue while the ledger says unknown);
        that returns None, which consumers treat as unavailable and refuse.
        """
        try:
            with (self.root / "recovery-status.json").open("rb") as stream:
                status = json.loads(stream.read(MAX_BYTES))
        except (OSError, ValueError):
            return None
        record = self.read()
        if (not isinstance(status, dict) or record["source"] == "missing"
                or status.get("ledger_sha256") != hashlib.sha256(encoded(record)).hexdigest()):
            return None
        return status

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
        spent = record["exhausted"] and not rescue
        # A quarantined ledger loses any earlier latch: say unknown, never "not required".
        uncertain = not rescue and not spent and record["source"] == "invalid"
        if rescue:
            state, marker = "rescue-required", "RESCUE_REQUIRED"
            announcement = ("Rescue required: automatic resets denied. Stop media; retain management and log export. "
                            "Rescue is not active. Ask a helper to recover using known-good boot media.")
        elif spent:
            state, marker = "reset-budget-spent", "RESET_BUDGET_SPENT"
            announcement = ("Reset budget spent: no automatic resets until continuous health is confirmed. "
                            "Rescue is required only if the box needs another reset.")
        elif uncertain:
            state, marker = "recovery-uncertain", "RECOVERY_UNCERTAIN"
            announcement = ("Recovery history unreadable or reset by a configuration change; earlier rescue state unknown. "
                            "Automatic resets denied until continuous health is confirmed.")
        else:
            state, marker = "rollback-not-armed", "ROLLBACK_NOT_ARMED"
            announcement = "Rollback not armed: verify counter persistence, pinned bootloader and live watchdog; updates and trials refused."
        return {"version": VERSION, "boot_id": record["current_boot"], "remaining": remaining,
                "reset_budget_available": remaining > 0 and not rescue,
                # Media stops only on a known latch; an unknown one (null) keeps
                # streaming with resets and trials denied.
                "stop_media": rescue,
                "automatic_reset_allowed": False, "rollback_armed": False, "decision": "REFUSE",
                "update_trial_allowed": False,
                "refusal_reasons": ["Recheck independent counter persistence, pinned bootloader and live watchdog before relying on rollback."],
                "rescue_required": None if uncertain else rescue, "rescue_active": False,
                "state": state, "console_marker": marker, "announcement": announcement,
                "release_retirement_allowed": False,
                "state_source": record["source"]}

    @staticmethod
    def count_without_credit(record, witness):
        """One uncredited charge per boot; reaching the limit is a spent budget."""
        if witness["counted_without_credit"] or record["exhausted"]:
            return
        witness["counted_without_credit"] = True
        record["charges_without_credit"] = min(record["limit"], record["charges_without_credit"] + 1)
        if record["charges_without_credit"] >= record["limit"]:
            record["exhausted"] = True

    @staticmethod
    def enter_rescue(record):
        """Latch once per episode, when a reset is needed after the last credit."""
        rescue = record["rescue"]
        if record["exhausted"] and not rescue["required"]:
            rescue.update(required=True, entries=rescue["entries"] + 1,
                          entered_boot=record["current_boot"])

    @staticmethod
    def evidence(boot, pinned_bootloader, probe):
        """Judge fresh collector evidence; returns (reasons, observed uptime, watchdog)."""
        reasons = []
        try:
            proof = probe()
        except Exception:  # any collector failure refuses; it never propagates
            # SystemExit, KeyboardInterrupt and GeneratorExit are process control,
            # not collector failures: they propagate before anything is written,
            # so they cannot grant either.
            proof = {}
        if not isinstance(proof, dict):
            proof = {}
        try:
            observed = uptime(proof.get("observed_uptime"))
            fresh = proof.get("boot_id") == boot and 0 <= _boottime() - observed <= FRESH_SECONDS
        except ValueError:
            observed, fresh = None, False
        if not fresh:
            reasons.append("Read fresh evidence from this boot (maximum age 5 seconds).")
        values = [proof.get(k) for k in ("counter_before", "counter_after", "counter_readback")]
        if (proof.get("counter_source") != "independent-readback"
                or any(type(v) is not int or not 0 <= v <= 2147483647 for v in values)
                or values[0] < 1 or values[1] != values[0] - 1 or values[2] != values[1]):
            reasons.append("Verify the bootloader decremented its counter and independently reread the persisted value.")
        if (not isinstance(pinned_bootloader, str)
                or not re.fullmatch(PIN_FORMAT, pinned_bootloader)
                or proof.get("bootloader") != pinned_bootloader):
            reasons.append("Check the running bootloader against the known pinned build; arrange manual service if different. Never write it automatically.")
        if proof.get("watchdog") != "armed":
            reasons.append("Verify the watchdog is running; an installed device or configuration alone is insufficient.")
        watchdog = "armed" if fresh and proof.get("watchdog") == "armed" else "unknown"
        return reasons, observed, watchdog

    @staticmethod
    def budget_reason(record):
        if record["rescue"]["required"]:
            return "Rescue required; recover and explicitly requalify health."
        if record["exhausted"]:
            return "Reset budget spent; confirm continuous health before another automatic reset."
        return "Reset budget unavailable or uncertain; confirm continuous health."

    @staticmethod
    def decide(result, reasons, available_reason, allowed, action):
        result["rollback_armed"] = not reasons
        result["refusal_reasons"] = reasons + ([available_reason] if available_reason else [])
        result["decision"] = "ALLOW" if allowed else "REFUSE"
        result["automatic_reset_allowed"] = allowed and action == "reset"
        result["update_trial_allowed"] = allowed and action == "activate-other-slot"
        if allowed:
            result.update(state="rollback-armed", console_marker="ROLLBACK_ARMED",
                          announcement="Rollback evidence verified for this immediate admission only.")
        return result

    def rollback_status(self, boot, *, pinned_bootloader, probe, action="reset"):
        """Read-only evidence check for display. Never writes, grants or latches."""
        if action not in ACTIONS:
            raise ValueError("invalid rollback action")
        boot_id(boot)
        record = self.read()  # rename-atomic snapshot; no lock, no directory creation
        reasons, _, _ = self.evidence(boot, pinned_bootloader, probe)
        if record["current_boot"] != boot:
            reasons.append("This boot is not admitted; run begin first.")
        result = self.view(record, boot)
        available = result["reset_budget_available"]
        return self.decide(result, reasons, None if available else self.budget_reason(record),
                           False, action)

    def rollback(self, boot, *, pinned_bootloader, probe, action="reset"):
        """Admit one disruptive action on fresh trusted read-only evidence.

        The collector must independently reread the bootloader's persisted counter,
        identify the running bootloader and check the currently running watchdog.
        No hardware collector or production pin is supplied by this host layer.
        An ALLOW records a grant that is sticky for this boot and charged at the
        next boot; perform the action only after this call returns ALLOW.
        """
        if action not in ACTIONS:
            raise ValueError("invalid rollback action")
        boot_id(boot)
        with self.locked():
            record = self.read()
            if record["current_boot"] != boot:
                raise ValueError("current boot witness unavailable")
            witness = record["boots"][boot]
            reasons, observed, watchdog = self.evidence(boot, pinned_bootloader, probe)
            available = record["remaining"] > 0 and not record["rescue"]["required"]
            allowed = not reasons and available
            before = (witness["intent"], witness["granted"], witness["granted_at"])
            witness["detectors"] = {"rollback": "not-armed" if reasons else "armed", "watchdog": watchdog}
            if not reasons:
                witness["bootloader"] = pinned_bootloader
            if allowed:
                witness["intent"] = action
                # Every successful admission renews ownership, independently of the
                # proof's observation time. Failed admissions restore this tuple.
                if witness["granted"] == "none":
                    witness["granted"] = action
                witness["granted_at"] = uptime(_boottime())
            elif not available and action == "reset":
                if record["exhausted"]:
                    # A reset is needed and the last credit is gone: the rescue episode.
                    # An update trial is not a needed reset: it only refuses.
                    self.enter_rescue(record)
                elif self.refused_reset_requests == "count-per-boot":
                    # No credit was ever earned (fresh or quarantined ledger): this
                    # boot needed a reset it cannot get; count it once, like a charge.
                    self.count_without_credit(record, witness)
            available_reason = None if available else self.budget_reason(record)
            self.write(record)
            if allowed and not 0 <= _boottime() - observed <= FRESH_SECONDS:
                # Persistence outlasted the evidence: withdraw this call's grant in the
                # same locked transaction, so a REFUSE never leaves a charged grant.
                reasons.append("Evidence expired during persistence; collect fresh evidence before the action.")
                allowed = False
                witness["intent"], witness["granted"], witness["granted_at"] = before
                witness["detectors"] = {"rollback": "not-armed", "watchdog": "unknown"}
                self.write(record)
            result = self.view(record)
        return self.decide(result, reasons, available_reason, allowed, action)

    def release(self, boot, *, new_release, previous_release, activated_at,
                full_healthy_stream, trusted_now):
        """Record trusted update-path observations, never prune or authorize pruning."""
        value = dict(new_release=new_release, previous_release=previous_release,
                     activated_at=activated_at, full_healthy_stream=full_healthy_stream,
                     trusted_now=trusted_now, minimum_retention_seconds=604800)
        self.validate_release(value)
        return self.update(boot, lambda record, witness: record.update(release=value))

    def begin(self, boot, *, slot="unknown", counters=None, bootloader="unknown",
              reset_cause="unknown", detectors=None, console_tail=None):
        boot_id(boot)
        counters = {"A": None, "B": None} if counters is None else counters
        detectors = {"watchdog": "unknown", "rollback": "unknown"} if detectors is None else detectors
        console_tail = [] if console_tail is None else console_tail
        observations(slot, counters, bootloader, reset_cause, detectors, console_tail)
        with self.locked():
            now = uptime(_boottime())
            record = self.read()
            for orphan in self.root.glob(".write-*"):
                orphan.unlink()
            if record["source"] == "invalid" and not record["boots"] and self.path.exists():
                self.quarantine()
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
            # Another charged reset after the last credit was spent needs rescue.
            needs_rescue = charge and record["remaining"] == 0 and record["exhausted"]
            if charge and record["remaining"] > 0:
                record["remaining"] -= 1
                # Only spending the last credit is an exhausted episode; a single
                # charge against missing, corrupt or reset-by-threshold credit is not.
                if record["remaining"] == 0:
                    record["exhausted"] = True
            witness = dict(state_source=record["source"],
                budget_at_start=record["remaining"], previous_boot=previous_boot, slot=slot, counters=counters, bootloader=bootloader,
                reset_cause=reset_cause, detectors=detectors, console_tail=console_tail,
                health="unknown", intent="none", granted="none", granted_at=None,
                counted_without_credit=False, last_uptime=now, healthy_since=None,
                budget_remaining=record["remaining"])
            if charge and record["remaining"] == 0 and not needs_rescue:
                # A box that never confirmed health and keeps dying: as many charged
                # resets as a full budget allows are a spent budget too, so the next
                # one needs rescue instead of looping as rollback-not-armed.
                self.count_without_credit(record, witness)
            witness["budget_at_start"] = witness["budget_remaining"] = record["remaining"]
            record["current_boot"] = boot
            record["boots"][boot] = witness
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
            if needs_rescue:
                self.enter_rescue(record)
            self.write(record)
            return self.view(record)

    def quarantine(self):
        """Keep rejected generations, even unreadable ones, under content names.

        A name never collides with another generation, nor with the single
        `recovery.rejected` an older release writes; the oldest beyond
        MAX_REJECTED is removed.
        """
        raw = self.path.read_bytes()
        digest = hashlib.sha256(raw).hexdigest()[:16]
        rejected = list(self.root.glob("recovery.rejected-*"))

        def order(path):
            # Pre-sequence content names are older than every new rejection.
            match = re.fullmatch(r"recovery.rejected-([0-9]+)-[0-9a-f]{16}", path.name)
            return int(match[1]) if match else 0

        sequence = max((order(path) for path in rejected), default=0) + 1
        target = self.root / f"recovery.rejected-{sequence:020d}-{digest}"
        # Keep recovery.json intact until write() durably replaces it. Copying
        # through atomic_file also persists bytes from a restored source file.
        self.atomic_file(target, raw)
        duplicates = [path for path in rejected if path.name.endswith(digest)]
        for path in duplicates:
            path.unlink()
        kept = sorted([path for path in rejected if path not in duplicates] + [target], key=order)
        for path in kept[:-MAX_REJECTED]:
            path.unlink()
        directory = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)

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
            # Disruptive actions are admitted only by rollback(); the grant is separate
            # from the declared intent, so no intent can erase it.
            if action in ACTIONS:
                return
            witness["intent"] = action
        return self.update(boot, change)

    def health(self, boot, verdict):
        """Report a verdict at this boot's CLOCK_BOOTTIME, sampled here under the lock."""
        if verdict not in HEALTH:
            raise ValueError("invalid health")

        # Heartbeats are process-local. A restarted reporter must start a new dwell;
        # persisted healthy snapshots cannot prove that the reporter stayed alive.
        boot_id(boot)
        with self.locked():
            now = uptime(_boottime())
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
                record.update(remaining=self.limit, source="valid", exhausted=False,
                              charges_without_credit=0)
                record["rescue"]["required"] = False
                if witness["granted_at"] is not None and anchor > witness["granted_at"]:
                    # A full healthy interval that began after the grant: the grant
                    # was never used, so a later boot must not be charged for it.
                    witness.update(granted="none", granted_at=None)
                self._health[boot] = (now, now, verdict)
            witness["budget_remaining"] = record["remaining"]
            # A failed verdict alone never enters rescue: a transient failure must
            # not stop a live stream. Rescue starts when a reset is actually needed
            # with the budget spent: the reset policy asks rollback(), or the box
            # comes back from another charged reset (begin()).
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
            if args.command == "begin":
                result = store.begin(boot)
            elif args.command == "intent":
                result = store.intent(boot, args.action)
            else:
                result = store.health(boot, args.verdict)
        print(json.dumps(result, sort_keys=True))
        if args.command == "intent" and args.action in ACTIONS:
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

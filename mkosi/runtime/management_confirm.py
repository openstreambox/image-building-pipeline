"""Host-only commit-confirm journal. No timer, network or service is enabled."""
import hashlib
import json
from pathlib import Path
import re
import secrets

from recovery_witness import Store, encoded, boot_id, uptime, PIN_FORMAT, _boottime


def digest(value):
    if not isinstance(value, str) or not re.fullmatch(PIN_FORMAT, value):
        raise ValueError("invalid content digest")
    return value


class Controller:
    """Single serialized management transaction, with integration-owned effects.

    Use a private, durable directory separate from the recovery ledger. Callbacks
    run under the writer lock, must be bounded, and must never reenter this API.
    Configuration bytes/secrets stay with the owner; only digests enter this file.
    """

    def __init__(self, root):
        self.io = Store(root, limit=1, healthy_seconds=1)
        self.path = Path(root) / "management.json"

    @staticmethod
    def _validate(r):
        if not isinstance(r, dict) or r.get("version") != 1:
            raise ValueError("unknown management state")
        if r == {"version": 1, "state": "idle"}:
            return
        if set(r) != {"version", "state", "transaction", "boot", "previous",
                      "candidate", "path", "started", "deadline"}:
            raise ValueError("invalid management state")
        if r["state"] not in {"pending", "confirmed", "reverted"}:
            raise ValueError("invalid management phase")
        if not isinstance(r["transaction"], str) or not re.fullmatch("[0-9a-f]{64}", r["transaction"]):
            raise ValueError("invalid transaction")
        boot_id(r["boot"])
        for key in ("previous", "candidate", "path"):
            digest(r[key])
        if r["previous"] == r["candidate"]:
            raise ValueError("unchanged candidate")
        if not 1 <= uptime(r["deadline"]) - uptime(r["started"]) <= 3600:
            raise ValueError("invalid deadline")

    def read(self):
        """Diagnostic snapshot only; never authorizes effects."""
        raw = self.path.read_bytes()
        if len(raw) > 4096:
            raise ValueError("management state too large")
        try:
            envelope = json.loads(raw)
            r = envelope["record"]
            if set(envelope) != {"record", "sha256"} or envelope["sha256"] != hashlib.sha256(encoded(r)).hexdigest():
                raise ValueError("invalid management checksum")
            self._validate(r)
            return r
        except (KeyError, TypeError) as exc:
            raise ValueError("invalid management envelope") from exc

    def _write(self, r):
        self._validate(r)
        self.io.atomic_file(self.path, encoded(
            {"record": r, "sha256": hashlib.sha256(encoded(r)).hexdigest()}))

    def initialize(self):
        """Explicit local provisioning only; never repair or clear a journal."""
        with self.io.locked():
            if self.path.exists():
                raise FileExistsError("management state already exists")
            self._write({"version": 1, "state": "idle"})

    @staticmethod
    def _expired(r, boot, now):
        return boot != r["boot"] or now < r["started"] or now >= r["deadline"]

    def start(self, boot, *, previous, candidate, path, seconds, apply):
        boot_id(boot)
        for value in (previous, candidate, path):
            digest(value)
        if type(seconds) is not int or not 1 <= seconds <= 3600 or previous == candidate:
            raise ValueError("invalid management change")
        with self.io.locked():
            old = self.read()
            if old["state"] == "pending":
                raise RuntimeError("management change already pending")
            now = uptime(_boottime())
            r = dict(version=1, state="pending", transaction=secrets.token_hex(32),
                     boot=boot, previous=previous, candidate=candidate, path=path,
                     started=now, deadline=now + seconds)
            self._write(r)  # Durable revert intent MUST precede any path change.
            apply(candidate)
            return r["transaction"]

    def confirm(self, boot, transaction, *, probe):
        """Trusted path-owner probe, never request-body/client asserted evidence."""
        boot_id(boot)
        with self.io.locked():
            r = self.read()
            if r["state"] != "pending" or transaction != r["transaction"]:
                return False
            if self._expired(r, boot, uptime(_boottime())):
                return False
            try:
                proof = probe()
                now = uptime(_boottime())
                valid = (isinstance(proof, dict)
                         and proof.get("transaction") == transaction
                         and proof.get("boot_id") == boot == r["boot"]
                         and proof.get("candidate") == r["candidate"]
                         and proof.get("path") == r["path"]
                         and proof.get("authenticated") is True
                         and proof.get("new_session") is True
                         and r["started"] <= uptime(proof.get("observed_uptime")) <= now
                         and now - proof["observed_uptime"] <= 5)
            except Exception:
                return False
            if not valid or self._expired(r, boot, now):
                return False
            # Confirmation linearizes here under the same lock as recovery.
            # A slow fsync can delay the reply; it cannot move this decision time.
            r["state"] = "confirmed"
            self._write(r)
            return True

    def recover(self, boot, *, restore, startup=False):
        """Timer/startup owner calls this; restore is durable and idempotent."""
        boot_id(boot)
        with self.io.locked():
            r = self.read()
            if r["state"] == "pending" and (startup or self._expired(r, boot, uptime(_boottime()))):
                restore(r["previous"])
                r["state"] = "reverted"
                self._write(r)
            return r["state"]

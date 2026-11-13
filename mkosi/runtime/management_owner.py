"""Inert host configuration owner; scheduler and network adapters are not installed."""
import hashlib
from pathlib import Path

from management_confirm import Controller, digest
from recovery_witness import Store, uptime
import management_confirm

MAX_CONFIG = 1024 * 1024


def content_digest(raw):
    if type(raw) is not bytes or not 0 < len(raw) <= MAX_CONFIG:
        raise ValueError('invalid configuration bundle')
    return 'sha256:' + hashlib.sha256(raw).hexdigest()


class Owner:
    """Sole writer of a private config bundle and retained content-addressed blobs.

    All integration writers must enter here. File modes are not a boundary against
    another trusted same-UID writer. Callbacks are bounded, synchronous, durable,
    non-reentrant adapters. An arm acknowledgement promises an independent timer
    already owns this exact transaction, boot and deadline, not merely a queued job.
    """

    def __init__(self, root):
        self.root = Path(root)
        self.controller = Controller(self.root)
        self.config = self.root / 'config.bundle'
        self.writer = Store(self.root / 'writer', limit=1, healthy_seconds=1)

    def _blob(self, raw):
        key = content_digest(raw)
        path = self.root / ('blob-' + key[7:])
        if path.exists():
            self.snapshot(key)
        else:
            self.controller.io.atomic_file(path, raw)
        return key

    def snapshot(self, key):
        digest(key)
        with (self.root / ('blob-' + key[7:])).open('rb') as stream:
            raw = stream.read(MAX_CONFIG + 1)
        if content_digest(raw) != key:
            raise ValueError('snapshot digest mismatch')
        return raw

    def provision(self, raw):
        """Explicit local setup; interrupted setup requires repair, never overwrite."""
        content_digest(raw)
        # Establish the private root before creating the subordinate writer lock.
        with self.controller.io.locked():
            if self.config.exists() or self.controller.path.exists():
                raise FileExistsError('management owner already provisioned')
            self._blob(raw)
            self.controller.io.atomic_file(self.config, raw)
            self.controller._write(dict(version=1, state='idle'))

    def change(self, boot, raw, *, path, seconds, arm, activate):
        content_digest(raw)
        with self.writer.locked():
            if self.controller.read()['state'] == 'pending':
                raise RuntimeError('management change already pending')
            previous = self._blob(self.config.read_bytes())
            candidate = self._blob(raw)

            def apply(key):
                record = self.controller.read()
                ack = arm(dict(record))
                expected = {k: record[k] for k in ('transaction', 'boot', 'deadline')}
                if (type(ack) is not dict or ack != expected
                        or self.controller._expired(record, boot, uptime(management_confirm._boottime()))):
                    raise RuntimeError('timer not armed before apply deadline')
                self.controller.io.atomic_file(self.config, self.snapshot(key))
                activate(raw)

            return self.controller.start(boot, previous=previous, candidate=candidate,
                                         path=path, seconds=seconds, apply=apply)

    def confirm(self, boot, transaction, *, probe):
        with self.writer.locked():
            return self.controller.confirm(boot, transaction, probe=probe)

    def _recover(self, boot, activate, startup):
        with self.writer.locked():
            def restore(key):
                raw = self.snapshot(key)
                self.controller.io.atomic_file(self.config, raw)
                activate(raw)
            return self.controller.recover(boot, restore=restore, startup=startup)

    def tick(self, boot, *, activate):
        """Independent supervisor retries expired intent; errors must remain visible."""
        return self._recover(boot, activate, False)

    def barrier(self, boot, *, activate):
        """Return only after pending state is restored, including same-boot restart.

        The service manager must REQUIRE success before any network service starts.
        Exceptions keep that barrier closed; there is no fail-open timeout here.
        """
        return self._recover(boot, activate, True)

# Management commit-confirm (host contract, not enabled)

A management change can remove the connection carrying its own confirmation.
`mkosi/runtime/management_confirm.py` supplies a serialized durable transaction,
with no network commands, scheduler, service installation or production timeout.
It shares the witness module's locked, atomic file/directory-fsync primitives,
but uses a **separate private directory** and schema-1 checksummed journal.

## API and trust boundary

Provision `Controller(root).initialize()` locally once before allowing changes.
Never initialize automatically after loss, corruption or an unknown schema.
Those conditions raise and deny new changes, confirmation and automatic restore:
the owner must retain independent known-good configuration and expose local repair.
The checksum detects damage, not hostile writers. All state/configuration
directories must be private, local, durable and owned by the trusted producer.
Do not reuse the witness state directory or edit the journal outside this API.

The configuration owner durably preserves an exact known-good snapshot and the
candidate, indexed by SHA-256, before `start(boot, previous=..., candidate=...,
path=..., seconds=..., apply=...)`. Digests identify bytes, not devices or
credentials; neither network names nor configuration secrets enter this journal.
`path` is the digest of the intended management-path specification. Distinct
transaction IDs prevent stale replies confirming a later change. The boot ID is
the current kernel boot ID, obtained by the trusted owner, never from a client.

`start` refuses overlap, persists the pending intent and deadline, then calls
`apply(candidate_digest)`. Failure leaves a pending transaction. All exceptions
deny authorization: callers must not apply outside this callback, retry an apply
after an uncertain result, or erase state to make a retry work.

A separate, already-running supervisor calls `recover(current_boot, restore=...)`
on a bounded cadence, at startup **before networking applies candidate state**,
and after an apply failure. Before expiry it leaves the change pending. At the
deadline (inclusive), a changed boot, or a backwards boot clock, it restores the
previous snapshot, then durably records reverted. A crash or error before that
record means restore is repeated. The restore callback must therefore be
idempotent, synchronous and durable, and must restore both persistent config and
active state before returning. Failure remains pending and visible; no reset or
budget refill is requested.

`confirm(boot, transaction, probe=...)` consumes a trusted server-side path-owner
probe. It must authenticate a **new session through the changed path**, bind the
observed active candidate and path specification to this transaction and boot,
and supply `observed_uptime` from CLOCK_BOOTTIME. Its dictionary contains
`transaction`, `boot_id`, `candidate`, `path`, `observed_uptime`,
`authenticated=True` and `new_session=True`. Client JSON, an old keepalive
session, reachability through a different uplink, and values copied from the
journal are not evidence. No generic trusted collector is implemented here.
Probe exceptions, missing facts, future/stale observations (>5 seconds), wrong
bindings and expiry refuse without clearing the pending intent.

Confirmation linearizes at the final deadline check under the same lock used
by recovery, immediately before the confirmed commit. A slow fsync may delay
the acknowledgement past the deadline; the decision was made before it.
A failed commit raises, never acknowledges success; after a crash either complete
pending (restore) or complete confirmed (retain) may survive. Wall clock is never
used. Callbacks run under the lock, must be bounded well within the selected
timeout, and must not reenter the API. A hung callback or storage stack cannot
be repaired by this host primitive; the supervisor must report that fault.
No claim of guaranteed physical restoration follows from a journal write.

## Must not land alone / enabling dependencies

This topic is stacked on the guest-CI topic (#13), including the witness/budget
and rollback-refusal stack (#11/#12). Keep those fixes and CI coverage together.
This module is inert; it must not be presented or enabled as management-path
protection without all of these in the same enabling release:

- A configuration owner that captures/verifies/retains the prior snapshot,
  binds digests to real bytes, serializes **every** management-path writer
  (including UI, provisioning, update, boot and external network managers), and
  blocks updates that could bypass or erase a pending journal.
- A timer supervisor armed **before apply**, independent of the request process,
  and an early-boot recovery barrier; bounded callbacks, restart/retry handling,
  persistent candidate/previous snapshot retention and fail-closed local repair.
- A trusted authenticated changed-path collector and UI showing the countdown,
  pending/refused/confirmed/reverted/repair-needed state, with reconnect instructions.
- Image-owned Python and module installation, witness intent integration, and
  measured storage/network acceptance. This topic changes no package list,
  boot service, network owner, reset policy, watchdog or bootloader.

## D7 bench drill (pending, sacrificial media)

First prove the recovery floor and retain a verified spare card and console.
Record board/image identity, journal/config digests, boot IDs and monotonic
timestamps; keep credentials and raw network config out of exported receipts.
Select a measured timeout and supervisor cadence, not this test's example values.

1. Positive control: stage a harmless path change; reconnect/authenticate via that
   path in a new session; confirm before expiry. Observe unchanged candidate
   across the deadline and a subsequent boot.
2. Cut the path mid-change. Do not confirm. Observe restoration of the exact
   previous persistent and active config by timeout plus the measured cadence
   and restore bound; reconnect over it and export the reverted receipt.
3. Try confirmation over the old session, alternate uplink, stale transaction,
   wrong candidate/path and at/after expiry. Each must leave restoration armed.
4. Kill request and supervisor separately before/after intent, apply, restore
   and terminal commits. Restart; pending intent must survive and restore must
   retry safely. Reboot while pending: early recovery must restore before
   candidate networking starts.
5. Inject missing/full/corrupt journal storage, unavailable snapshot and restore
   failure. Verify visible repair-needed denial, no new disruptive change and
   no automatic initialization. Repeat controlled power cuts on sacrificial
   media; host fsync tests do not qualify device durability.

Host validation: `tests/management-confirm.test.sh` (registered in the default
gate), plus `tests/recovery-witness.test.sh`. Hardware D7, supervisor/network
integration and physical power-loss qualification remain unrun.

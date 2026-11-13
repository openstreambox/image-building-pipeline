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

## Configuration owner and startup barrier (host contracts only)

`management_owner.Owner(root)` is the sole write API for an opaque, nonempty
configuration bundle (maximum 1 MiB). Choose a dedicated private directory on
persistent local storage, separate from the witness ledger; it holds
`config.bundle`, `management.json`, `blob-<sha256>` snapshots and `writer/.lock`.
No production directory, service or timeout is selected or installed here.
`provision(bytes)` is explicit local setup. Never call it to repair missing or
damaged state. Interrupted provisioning needs local inspection. Retain blobs;
there is deliberately no garbage collection that could delete a pending snapshot.

Every management writer calls `change(boot, bytes, path=..., seconds=...,
arm=..., activate=...)`. The owner lock serializes snapshot capture, changes,
confirmation, timer recovery and boot recovery across processes. The prior bytes
are copied from the current bundle, not accepted as a caller's claimed digest.
Both bundles are durably retained under content digests, checked on every reuse
and restore. Secrets remain in mode-0600 files under the private root. Each file
uses same-directory temporary write, file fsync, atomic rename and directory
fsync. This is a single-bundle contract: it does not promise multi-file atomic
replacement or atomicity between persistent bytes and the active network.

Ordering is snapshot/candidate durability → durable pending journal → independent
timer acknowledgement → deadline recheck → atomic config replacement → active
apply. `arm(record)` must synchronously acknowledge exactly `{transaction, boot,
deadline}` only after an independent supervisor has accepted that deadline. It
must not merely schedule an async request or spawn a request-owned child. Failed,
wrong or late acknowledgements deny apply and leave intent pending. A supervisor
that loses its arm must restart, recover pending state and report failure, never
claim protection is active. No cancellation is needed for safety: a stale timer
calls `tick`, which rereads the locked canonical journal instead of replaying an
old callback or overwriting a later confirmed transaction.

The supervisor calls `tick(current_boot, activate=...)` at its bounded cadence;
request death releases file locks, so the already independent supervisor can
restore. The host process test demonstrates an arm handshake with a separate
process before the request dies mid-apply, followed by exact-byte recovery.
A wedged callback or storage operation holding the lock still blocks recovery;
bounded adapter execution and fault handling remain release dependencies.

The early startup entry point is `barrier(current_boot, activate=...)`. It restores
**every pending change**, even before its deadline on a same-boot service-manager
restart. Persistent restore and successful active restore precede the durable
reverted record and barrier success. Failed restore, missing snapshot or invalid
journal raises; retry is idempotent and must keep networking stopped. Confirmed,
reverted and idle journals can pass. `confirm` routes the existing trusted probe
through the same owner lock; authentication semantics are unchanged.

### Required service-manager wiring before enabling

Install an image-owned early oneshot that runs the barrier after persistent data
is mounted but before *every* network configuration consumer. Each consumer needs
both `Requires=management-recovery.service` and
`After=management-recovery.service` (ordering alone does not block on failure).
Include NetworkManager/networkd, AP/provisioning, app and update writers, and
socket, D-Bus and hotplug activation paths; inventory the actual image instead
of assuming `network-pre.target` alone covers them. No consumer may read/apply
the candidate before this barrier. Keep the barrier's restore adapter free of
network-service dependencies to avoid an ordering cycle. On failure expose local
repair over the independent recovery floor, without starting candidate networking.
Do not add a fail-open timeout or `ConditionPathExists` that skips missing state.

The installed long-lived supervisor must own its timer independently of requests,
restart with bounded retries, reread journals after restart and use boot time.
Adapters must restore durable bundle bytes **and** active state before returning.
The bundle must be the authoritative input for all writers; NetworkManager profile
files and provisioning scripts cannot continue as independent sources of truth.
Image packaging, privileged IPC/authorization, exclusive real configuration
ownership, the actual supervisor and unit dependency closure are still unbuilt.
Thus this additive topic must not land alone or enable protection: retain #18
and #11–#13, plus those adapters/wiring, the trusted changed-path collector,
Python/module packaging, witness/UI consumers and measured D7 acceptance together.
No existing network file, timer, service or boot ordering is changed by this topic.

### D7 additions for the owner/timer/barrier (pending board work)

On the sacrificial card with console and verified spare media already available:

1. Inventory every management writer and activation path. Record the installed
   bundle/snapshot/journal locations, their ownership/modes and digests, supervisor
   identity, timeout/cadence/restore bounds and complete unit dependency graph.
   Verify a direct legacy writer is denied or routed through the owner.
2. Capture monotonic events proving snapshot fsync and pending fsync precede timer
   acknowledgement, and that acknowledgement precedes persistent and active apply.
   Stop/refuse the timer before arming and inject a late/wrong acknowledgement:
   no config or active-path change is allowed. A local pending repair is expected.
3. Kill the request after acknowledgement and during active apply. Leave the
   supervisor alive; observe exact prior bytes and usable prior path restored by
   the declared deadline plus cadence/restore bound, without a request restart.
4. Reboot pending before expiry. Capture early console/unit events proving both
   persistent and active restoration finish before any network consumer starts.
   Repeat a same-boot barrier restart; pending must revert immediately too.
5. Remove/corrupt the snapshot, fail active restore and make durable storage full.
   The barrier must fail and every consumer remain stopped, including activation
   by socket/D-Bus/hotplug. Repair locally, retry and prove restoration completes.
6. Confirm through the changed path as in the positive control above, then reboot:
   candidate stays selected. Start a second change and prove its prior snapshot
   is that confirmed candidate. Repeat controlled power cuts around each durable
   boundary, recording actual recovery times and storage outcomes.

These steps are a protocol, not a board receipt. Host process death and fsync
checks cannot qualify power-loss durability or real network restoration.

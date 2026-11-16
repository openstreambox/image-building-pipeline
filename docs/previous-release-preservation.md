# Previous-release preservation: host contracts

An update must leave the previous known-good release bootable until the new
release has completed one full healthy stream **and** seven days have passed.
A successful boot or two healthy snapshots do not satisfy the stream rule.
Update installation/cleanup, selector-entry removal and slot mirroring must all
obey the same rule, including the previous release's boot files and entries.

This is an inert source contract on the closed recovery reference stack. It
installs no service, device adapter, boot policy or image package. It is not a
replacement for the stock RAUC/systemd recovery integration, and must not be
merged as a way to bring that reference stack back into production.

## Ownership and sequence

`release_preservation.Owners(Store(...))` shares the witness store's private
persistent directory, cross-process lock and atomic, checksummed generation.
Schema 7 adds `retention`; every write still includes the recovery witness,
reset budget and rescue latch. Health and retention producers cannot overwrite
one another's fields. The prior `Store.release()` API remains observation-only;
its nullable healthy-stream boolean and wall timestamps never grant retirement.

- `provision(boot, probe=...)` is explicit local setup, not automatic recovery
  after missing or damaged state. It requires a healthy witness and a fresh,
  verified bootable running release/slot. It cannot overwrite existing retention.
- `update(boot, candidate=..., pinned_bootloader=..., probe=..., apply=...)`
  resolves the exact running and target release/slot through a trusted collector.
  It never writes the running slot. It durably records that running release as
  the retained previous release before invoking the target installer. A second
  update cannot reuse that previous slot before qualification. After retirement,
  a new update preserves the then-current release and starts fresh evidence.
- `observe(boot, probe=...)` records activation only after the candidate is
  actually observed booted, bound to its witnessed slot. Installation intent
  alone starts no retention clock. It also records elapsed-time observations.
- `stream(boot, probe=...)` records a trusted media-owner attestation that an
  entire real stream completed healthy on this exact activation, release and
  boot. The witness must also say healthy. The collector must check the whole
  session; a single health snapshot, preview or test-pattern stream is not proof.
  The existing release-observation vocabulary is updated in the same transaction.
- `retire(boot, owner="update"|"selector"|"mirror", ..., apply=...)` admits an
  immediate effect against only the exact previous release and slot. These are
  the update/GC, selector-entry and mirror owner contracts. Every such writer
  must enter here; direct RAUC, rsync, unlink or selector edits would bypass it.
  The callback owns all retained copies and artifacts as one idempotent operation;
  it is not permission for another owner to run later against a saved status.

Collector dictionaries contain `boot_id`, `observed_uptime`, `running_release`,
`running_slot`, `target_release`, `target_slot`, and strict `bootable: true`.
Identities are authenticated software digests, not caller claims. Slots are A/B.
Update and retirement also require the existing independent counter readback,
known pinned bootloader and live-watchdog evidence. A mismatch warns and refuses;
nothing writes a bootloader. Update admission additionally refuses rescue or an
unavailable reset budget. Actual trial selection still needs the existing
immediate `rollback(action="activate-other-slot")` admission; this module never
switches slots or reboots.

Stream attestation adds the exact `activation` token from the pending record and
strict `full_healthy_stream: true`. Collection occurs under the same lock;
exceptions, stale/future observations, missing values and wrong bindings refuse.
Adapters are trusted, synchronous, bounded and non-reentrant. The exact effect
plan contains owner, release, slot and activation. The adapter must enforce that
plan, verify physical identity again before effects, and cover root contents,
boot artifacts and selector entries. Same-UID writers are inside this trust
boundary; filesystem permissions are not a sandbox against them.

## Time rule

The clock is sampled privately, never supplied by an API caller. Activation
starts with this boot's `CLOCK_BOOTTIME` and the wall clock. Each later valid
same-boot observation earns `min(boot-clock delta, wall-clock delta)`, only when
both deltas are nonnegative. Credited time saturates at 604800 seconds. A wall
jump forward cannot earn more time than the boot clock; a wall jump backward
earns no time for that interval. A backwards boot clock discards accumulated
credit. Missing/invalid observations break the anchor; the next valid observation
starts a new interval. Repeated/concurrent observations cannot double-count.

A new boot earns nothing for the unobserved gap, including powered-off time.
Valid intervals already earned on earlier boots remain. Process restart on the
same boot uses the persisted anchor. This conservative rule can retain a release
longer than seven calendar days. Retirement needs both 604800 credited seconds
and a current wall clock at least 604800 seconds beyond observed activation.
Unknown clocks refuse. No NTP adjustment alone can shorten the elapsed-time floor.

## Persistence and visible refusals

Intent commits by file fsync, same-directory rename and directory fsync before
any install/retirement callback. Evidence freshness is checked again after that
commit. Storage errors propagate and prohibit the effect; callers must display
the failure and retain the previous release. Slow persistence that expires proof
records a refusal. No cached status can authorize an operation.

Death during install leaves a pending activation holding the previous release;
new updates and retirement refuse. If the exact candidate subsequently boots,
`observe` can admit that activation; otherwise local reconciliation is needed.
Retirement intent is durable before the effect, and `retired` only after it
returns success. Death/failure leaves an intent bound to the same owner. That
owner may retry its exact idempotent operation on fresh evidence while the
target identity is still verifiable; an unknown or partially changed target needs
local reconciliation. Another owner or new update cannot pass the intent. A filesystem/callback hang can hold the lock and
is outside this host primitive's ability to repair.

`rollback_status()` and the digest-bound `recovery-status.json` include:

- `release_retention_reasons`: unmet requirements plus the latest named refusal;
- `release_retention_eligible`: advisory qualification, never effect admission;
- `previous_release_retired`: successful owner completion;
- `release_retirement_allowed: false`: a saved projection never grants a write.

Missing, corrupt or unknown-schema evidence keeps the previous release. A status
file that is missing, stale or cannot be verified likewise means retain. A failed
projection does not undo a committed ledger, and is removed rather than left
looking current. Consumers must use `Store.current_projection()` or verify the
ledger digest themselves. The schema-6 reference release cannot read schema-7
retention: it must never run as an enabled preservation owner. Schema changes
require an explicit preservation-compatible rollout or local repair; health
requalification never invents lost retention evidence.

## Enabling work and qualification

Actual privileged update, selector and mirror writers are not wired here. Before
any enablement, inventory every writer and prove none can bypass the owner,
provide authenticated release/artifact inventory and a real complete-stream
collector, package the modules, integrate the status consumers, and supply a
bounded idempotent adapter with crash recovery for each owner. Use the supported
RAUC/systemd integration as the production basis, rather than reviving this
closed reference stack. Rescue stays latched; preserve the SD/rescue-card floor;
never auto-write a bootloader.

Host process-death tests cover before/after fsync and rename, concurrent producers,
interrupted install/retirement, clock jumps and stale/missing evidence. They are
not SD power-loss qualification. Still required on sacrificial media: power cuts
around each durable boundary; successful fallback with the exact previous root,
boot files and selector entry; blocked mirror/second update before qualification;
a real full-stream positive control; repeated reboots and clock corrections;
failed/full/missing storage and visible refusals; retry of each interrupted owner.
No hardware, image build or deployment is implied by these tests.

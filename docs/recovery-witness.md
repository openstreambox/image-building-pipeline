# Boot witness and reset budget (host contract, not enabled)

Repeated resets need evidence and a ceiling independent of A/B slot attempts.
`mkosi/runtime/recovery_witness.py` supplies both below the application, so a
broken application need not erase the explanation. It has no reset, watchdog,
slot-selection, network, media or service-control effects. No unit enables it
and no production thresholds are selected by this change. The implementation
uses the Python 3.8+ standard library for strict JSON and direct fsync/rename/lock
operations. Enabling it requires an image-owned Python runtime dependency; a
diagnostic add-on must not be its boot dependency. No package list changes here.

## Durable record and safe reads

`Store` takes an explicit private, caller-owned local state directory, budget
limit and healthy interval. Its schema-6 `recovery.json` ledger holds one witness
per boot ID and the separate reset budget in the **same commit**. Writers share
an exclusive flock; a same-directory mode-0600 temporary file is flushed and
fsynced, renamed atomically, then the directory is fsynced. New-directory
creation also fsyncs its parent. A failed write/flush/rename/directory fsync raises:
no disruptive operation may follow that failure. A cut before rename preserves
the old record; after rename the old or new complete record may survive. The
SHA-256 envelope detects accidental valid-JSON damage; it is not authentication.
Storage and filesystem durability still require power-cut drills.

Every witness links its previous boot ID (null if unknown), preserving boot order
without a wall clock. It contains slot, A/B counters, bootloader **software digest**, reset
cause, health verdict, detector states, intent, reset grant, boot uptime and budget snapshot.
The source and budget at boot admission remain recorded even after healthy
requalification, so recovery does not erase the earlier uncertainty.
Unobserved values are explicitly unknown (counters null); armed is never inferred
from absence. The boot ID is ephemeral kernel identity, never machine-id, serial,
MAC, IMEI, hostname or another device identifier. Intent is a fixed enum and its
write must return successfully **before** a caller performs that action.

Console tails are ordered, bounded **classified markers**, not raw text. A caller
may project the previous console tail into the fixed marker vocabulary; arbitrary
console text is refused because it can contain secrets. Empty means no admitted
evidence, never no crash. Raw console acquisition/redaction and extraction on a
nonbooting board remain separate work. The most recent 64 witnesses are retained, linked from the current boot. The
oldest retained link is null and `pruned_boots` counts removed witnesses. Pruning
runs under the writer lock before write; the 4 MiB bound remains a final safety
ceiling. Witness retention is independent of software-release retention.

Missing, truncated, unknown-version, schema-invalid, checksum-invalid, oversized,
unreadable or configuration-mismatched records mean **zero automatic resets
available**, with unknown witnesses. They never mean a healthy first boot or a
fresh allowance. At `begin`, rejected bytes are durably copied to
`recovery.rejected-<sequence>-<first 16 hex of its SHA-256>` before replacement.
The active ledger stays intact until its atomic replacement carries any known
latch, including after an interrupted quarantine or a duplicate rejection.
Generations never overwrite the single `recovery.rejected` an older release
writes. The newest four distinct contents are kept by rejection sequence,
independent of source mtime; rejecting identical content refreshes its order.
Pre-sequence generations sort before new rejections. Copy/rename/directory-fsync
failure aborts admission; interruption may leave extra diagnostic copies, which
the next quarantine prunes.

**Schema changes keep a known latch.** An intact record (checksum valid) of any
other shape or version, newer or older, is quarantined like damage, but its
top-level `exhausted` and `rescue.required` are read first: a `true` carries
over (rescue with its entry count), so a slot fallback or an update never clears
a latch, and nothing here creates credit. Every future schema must keep those
two fields with this meaning. Code that predates this rule cannot follow it: a
release older than schema 6 reads a newer ledger as rescue false. None has
shipped, and the update owner must never fall back to such a release with a
ledger written by a newer one. A checksum-invalid record has no trustworthy
fields and carries nothing (`rescue_required: null`, below).
Threshold changes spend the budget while preserving the witness history. Orphan
`.write-*` files are removed under the same lock before admission.
`export` is read-only and exports the admitted ledger, not raw malformed bytes.

## Budget semantics and visibility

A new boot spends an attempt only when its predecessor was **granted** a reset
or the observed cause is unclean (`watchdog`, or `panic` for a reboot after a
kernel panic). A grant is recorded by the first `Store.rollback` of a boot that
returns ALLOW (reset or trial; see below) and is sticky: later intents (`none`,
`unbind-adapter`), refused rollback calls and later grants update the declared
`intent` and detectors but never erase `granted`, so a granted reset or trial is
charged whatever cause the next boot reports (`power-on`, `unknown` or
`software`). Trials are therefore bounded by this budget too. A grant the box
never acted on expires at a healthy re-arm whose continuous dwell began after
the latest successful admission (the box stayed healthy a full interval without
that reset), so a later power cycle is not charged for it. A re-arm whose dwell began before the
grant keeps it. Every ALLOW refreshes `granted_at` from the private boot clock,
not the proof's observation time; REFUSE preserves the previous grant time.
The action owner MUST submit the action immediately after ALLOW and obtain a
new admission if delayed; it MUST NOT act on an expired authorization.
Clean power-on, `unknown` and an orderly `software` reboot that the
box did not grant itself (an operator reboot, an update's completion reboot) do
not spend. Whether operator reboots should count is an owner decision; until it
is made they do not.

`exhausted` is set when a charge spends the **last** credit (1 to 0). A single
charge against zero credit — a missing ledger, a quarantined corrupt one, or the
zero credit left by a threshold change — leaves the credit at zero without
claiming an exhausted episode, so one hang after flashing is not called rescue.
Such charges are counted in `charges_without_credit`; once a box that never
confirmed health has taken as many charged resets as the configured limit, that
is a spent budget too (`exhausted`), and the next charged reset enters rescue as
below. Otherwise a crash loop on a fresh or quarantined ledger would stay
rollback-not-armed forever. Clean and orderly boots neither add to nor clear the
count, and a boot counts at most once. An episode already exhausted stays
exhausted. Only health re-arm clears it, and the uncredited count with it.

A reset **request** refused for want of credit on such a box counts the same way
by default (`Store(..., refused_reset_requests="count-per-boot")`): the box needed
a reset it cannot get. Without it, a box that is up but failing, on a fresh or
quarantined ledger, is refused for ever and never reaches a designed state.
Trials never count. `refused_reset_requests="ignore"` leaves such requests
uncounted, so only charged boots can reach rescue; that choice belongs to the
owner and is the only behaviour the setting changes. Counts saturate at zero; restarting a
producer in the same boot does not spend again, but does recommit/fsync before
returning admission (a prior writer may have died after rename). Stale boot IDs cannot modify a
new boot. This is a box reset budget, not the bootloader slot counter, and does
not depend on an update being pending. Boot integration must admit each actual kernel boot and supply its observed
reset cause; this module does not arm an unattended policy.

Corruption falls toward **denying automatic reset** to stop loops. It does not
permanently lock recovery: in that same boot the trusted health producer can
report healthy, then confirm continuous health after the configured interval.
That refills the allowance durably. Reports must arrive within the stored
maximum gap (at most 30 seconds). The reporting Store process keeps the heartbeat
continuity in memory; a new Store process starts a new dwell. Only transitions
(first healthy, interrupted dwell, failed/unknown, re-arm) write the ledger;
ordinary heartbeats do not rewrite it. The CLI is diagnostic and cannot prove
a continuous interval across separate invocations. An unhealthy/unknown verdict or decreasing
uptime restarts the interval. The producer must continuously own health and
report failures; two unrelated healthy snapshots are not a health guarantee.
Process restart must resume that ownership or report unknown before confirmation.
No time-of-day is stored or used: Linux `CLOCK_BOOTTIME` includes suspend and
survives wall-clock/NTP jumps, but its anchors are scoped to the current boot.
A new boot always starts with unknown health and no anchor. A threshold change
also spends the budget until healthy requalification.

`begin` and `intent` return after persistence; health transitions persist before
returning, while ordinary heartbeats return the unchanged safe projection.
`status` and `export` need no write. Status from a previous boot denies resets
until the current boot is admitted. Spending the last credit reports
`reset-budget-spent` (`RESET_BUDGET_SPENT`): no automatic reset, but the boot
produced by the last permitted reset may be healthy and is not told to stop
media. **“Rescue required”** (`rescue_required: true`) is entered only when the
box needs another reset with the budget spent: a further charged boot, or a
`rollback(action="reset")` request (with any evidence). An update trial
(`activate-other-slot`) is not a reset the box needs: with the budget spent it
refuses with the budget reason and never enters rescue, so an update during the
healthy interval after the last reset cannot stop a live stream. A `failed`
health verdict alone does not enter rescue, even
with the budget spent: one transient failure must not stop a live stream, and a
later healthy verdict could not clear the latch before a full healthy interval.
The reset policy acts on a failed verdict by asking `rollback` for a reset; with
no credit left that request refuses and enters rescue. Missing credit alone is
rollback-not-armed with `rescue_required: false`; a fresh clean boot is not
called rescue. After a checksum-invalid ledger (or a threshold change) any
earlier latch is unknown, so the state is `recovery-uncertain` with
`rescue_required: null` until health is requalified.

`stop_media` is the field media owners act on: `true` only for a known latch
(`rescue_required: true`). `null` means **keep streaming**, with automatic resets
and update trials denied and the uncertain announcement shown. Reasons: null
arises only from storage damage or a configuration change, not from a box that
keeps dying; intact latches survive schema changes (above), so null means no
latch information survived; stopping a live stream on storage damage is the false
trip this contract avoids elsewhere; and a box that really keeps dying reaches
rescue again through the uncredited count.
`rescue_active: false` deliberately does not
claim that a rescue mode exists. Any storage/identity error exits nonzero and
prints a safe denial without paths or exception text. `intent reset` returns
exit 3 on a denied reset and never records that refused reset intent (storage or
argument errors return 1). Consumers must check exit
status and deny reset on failure. Status, `intent` and healthy re-arm never grant rollback-dependent admission.
`reset_budget_available` reports only the budget vote. The fresh `Store.rollback`
transaction below durably records an admitted action. Standalone reset/trial
intent commands return exit 3 and do not record a refused action.

The lowest working local console can run:

```sh
python3 /path/to/recovery_witness.py --state-dir /path/to/private-state \
  --limit 3 --healthy-seconds 600 status
```

Those numbers are examples, not production defaults. API callers supply measured
slot/counters, bootloader digest, watchdog bootstatus classification and detector
evidence to `begin`; the CLI's `begin` leaves those observations unknown. Use
`export` for the boot-keyed evidence; use `Store.rollback` before a reset or trial.
Wire this projection to the management UI/log export and independent console in
the enabling change. Rescue must retain management/update/export while suppressing
media, but this module neither stops a stream nor falsely announces active rescue.

## Rollback refusal and terminal state (host contract)

`Store.rollback(boot, pinned_bootloader=..., probe=..., action="reset")`
checks a trusted, read-only collector under the writer lock and durably writes the
intent before returning an immediate admission. `action="activate-other-slot"`
is the other supported action. No default pin or hardware collector is provided:
without these integration-owned inputs, admission remains REFUSE. Collectors
must raise on failed reads (any `Exception` refuses), never substitute a configured value
for an observation. `SystemExit`, `KeyboardInterrupt` and `GeneratorExit` are
process control, not collector failures: they propagate before anything is
written, so the ledger is unchanged and nothing is granted. The returned reasons contain fixed actionable messages, never
exception text or paths. No bootloader write is implemented or permitted here.

There is no caller-supplied time anywhere in the store: `begin` and `health`
sample CLOCK_BOOTTIME themselves under the writer lock (`Store.begin(boot, ...)`,
`Store.health(boot, verdict)`), so a caller cannot step a clock to complete a
healthy interval, and `rollback` samples it after collection and again after
persistence. Tests replace one private clock function.
If the write outlasts freshness, the same locked transaction restores the
boot's previous grant and intent, records the rollback detector as not armed and
recommits before returning REFUSE, so a refusal never leaves a charged grant. If
that second commit fails the call raises; the grant may then remain and the next
boot is charged (fails toward fewer resets).

`Store.rollback_status(...)` takes the same arguments for display: it judges the
evidence and reports `rollback_armed` and reasons, but never writes, grants,
latches or creates files, and always returns REFUSE, also with the budget spent.
Use it, not `rollback`, to show whether rollback is armed. Collector failures
refuse as above.

The collector returns this exact evidence contract (extra fields confer no trust):

- `boot_id`, `observed_uptime`: the current kernel boot ID and CLOCK_BOOTTIME at
  collection, at most 5 seconds old at admission; future or cross-boot evidence refuses.
- `counter_source="independent-readback"`, integer `counter_before`,
  `counter_after`, `counter_readback`: positive pre-decrement count, exactly one
  decrement, and a separate reread of the persisted bootloader counter matching
  that decrement. Neither the witness counter nor this module's successful fsync
  is independent evidence. The collector must verify storage provenance and
  bootloader write/read ordering; setting the source string is not that proof.
- `bootloader`: measured running bootloader software SHA-256, equal to the
  caller's immutable known-build SHA-256 pin. Package presence/version alone is
  insufficient. Unknown/mismatch warns and refuses; service must be manual.
- `watchdog="armed"`: a fresh observation of an actually live watchdog, including
  its ownership/handoff, not a device node, config file or prior boot's flag.

The collector is a trusted integration boundary, not arbitrary UI input. A false
collector can lie; no host-only code qualifies these hardware facts. Collect
immediately before the action and bind execution to this boot. Recheck if the
consumer delays or the evidence changes. CLI commands intentionally have no way
to claim these proofs and always refuse rollback-dependent admission.

Clean power-on does not spend a reset credit. A previous admitted grant or an
observed watchdog/panic reset does (see budget semantics). The durable `rescue`
latch has `required`, `entries` and `entered_boot`. It is entered once per
episode, repeated producers/reboots do not add entries, and only explicit
continuous-health requalification clears it.

Leaving the latch needs one long-lived health producer: a single `Store`
process reporting `healthy` at gaps of at most the stored maximum for the whole
healthy interval. The CLI's `health` starts a fresh dwell per invocation and
cannot clear it, and no such producer exists yet. Because the latch asks the
consumer to stop media, the health verdict used during rescue must not depend
on media running (for example: management path reachable, storage writable, no
watchdog pressure); otherwise there is no exit. The wiring task must define it. Missing/invalid/old-schema storage
starts with no automatic reset credit, separately from an exhausted rescue episode; it never migrates into a fresh allowance.
A person can recover using known-good boot media and then explicitly requalify
health. There is no unauthenticated clear command. No further automatic reset or
update/trial is admitted while latched, even with good rollback evidence.

Every successful mutation publishes `recovery-status.json` using mode 0600,
atomic replacement and file/directory fsync, after committing `recovery.json`.
The ledger commit is the transaction: a failed projection write neither fails
it nor leaves an old projection behind (the stale file is removed).
It is a versioned projection for a privileged UI/LED reader, with `state`,
`console_marker`, `announcement`, `rescue_required` and `rescue_active`. Console
JSON exposes the same fields. `RESCUE_REQUIRED` means stop media and preserve
management/export; it explicitly says rescue is **not active**. This layer does
not implement a rescue service, stop media, drive LEDs or reset the machine.
Consumers must implement suppression and retain the announcement across restarts.
No generic promise that inserting a card will boot is made.

The status file is advisory and never carries a rollback/reset grant. It names
the ledger generation it describes in `ledger_sha256`. It can go stale: a crash
between ledger and projection replacement, or a ledger damaged after the last
write (the projection may still say rescue while the ledger now says unknown).
`Store.current_projection()` returns the projection only while that digest
matches the intact current ledger, otherwise None; a consumer outside Python
must verify the ledger envelope the same way, or use `status`. Consumers must
check boot ID, treat unavailable/stale status as refusal, and republish via a
successful transaction before displaying a cleared latch.
A failed ledger write/fsync denies the operation; a failed projection only
removes the projection. Never authorize from status.

## Previous-release observations and update-path obligations

`release` persists across boots and healthy re-arm. Its fields are software digests
`new_release`/`previous_release`, trusted activation timestamp `activated_at`,
nullable `full_healthy_stream`, latest trusted timestamp `trusted_now`, and
`minimum_retention_seconds=604800`. Unknown fields remain null. The trusted update
owner records these through `Store.release`; this is evidence storage only.
`release_retirement_allowed` is always false: this layer implements no release
retention, slot copying, deletion, selection, or wall-clock eligibility logic.

The update path must provide authenticated exact release identities, preserve the
previous release and its boot artifacts/selector entry, record activation once,
and supply a complete real healthy stream verdict bound to that new release.
Two health snapshots or budget re-arm are not a full healthy stream. It must
supply trusted elapsed calendar time across boots (NTP jumps alone cannot prove
seven days), retain the prior release until **both** one full healthy stream and
seven days since activation are proven, and prevent slot-sync/mirror from erasing
it sooner. Replacing an activation resets its release-specific evidence. Unknown
or failed evidence must retain the previous release. The update owner must
serialize and bind these observations to the matching activation; this generic
recording API does not enforce release lifecycle or authorize retirement.

## Enabling work still required

- Verify the SD boot/storage and known-good recovery-media floor with missing,
  full/corrupt storage, medium-priority and power-cut drills.
- Supply independently measured counter, running bootloader pin and live watchdog
  collectors, plus image-owned Python and boot-time callers. Never auto-write SPI.
- Implement the wiring contract below (reset policy, watchdog, panic and systemd
  reboot suppression in rescue, `stop_media`).
- Wire rescue-required to media suppression and persistent UI/LED announcements,
  keeping management/update repair/log export available without claiming rescue
  activation until that mechanism is implemented and measured.
- Implement previous-release retention in selector/update/mirror owners.
- Management-path commit-confirm, reset triggers, missing-root timeouts and remote
  companion/export authentication remain separate work. Hardware acceptance still
  requires boot, storage and power-cut drills; this module enables no services.

### Wiring contract (MUST)

This module only admits or refuses resets it is asked about. Rescue means no
further resets, so the enabling change MUST also stop the resets that never ask:

- **Reset policy.** On a failed health verdict the policy MUST call
  `Store.rollback(action="reset")` and act only on ALLOW. It MUST NOT pre-check
  `reset_budget_available` (or any status field) and skip the call: the refused
  request is what records the need, counts it on a box without credit and enters
  rescue when the budget is spent. Display code uses `rollback_status`.
- **Hardware watchdog.** With `rescue_required: true`, and before handing the
  watchdog to PID 1 on such a boot, the consumer MUST NOT arm, or MUST disarm,
  the hardware watchdog (`RuntimeWatchdogSec=0`/`RebootWatchdogSec=0`, no handover
  from the bootloader), so a hang in rescue waits for a person instead of looping.
- **Kernel panic reboot.** In rescue the kernel MUST NOT reboot on panic
  (`panic=0`, `kernel.panic=0`, and `panic_on_oops`/`softlockup_panic` must not turn
  hangs into resets).
- **systemd reboot actions.** In rescue, unit `FailureAction=`/`SuccessAction=`,
  `StartLimitAction=`, `JobTimeoutAction=` and `WatchdogSec` service restarts that
  escalate to `reboot*` or `poweroff` MUST be off or downgraded to `none`.
- **Media.** Act on `stop_media`: stop media only when it is `true`; on `null`
  keep streaming with resets and trials denied.
- **Trials.** An update trial MUST call `rollback(action="activate-other-slot")`
  and act only on ALLOW; with the budget spent it refuses and does not latch.

Whether the same reset suppression should apply once the budget is merely spent
(`reset-budget-spent`) is the wiring task's decision; this layer already refuses
every admitted reset in that state.

Run `tests/recovery-witness.test.sh`; it is also registered in `./run-tests`.

## Privileged harness boundary

`tests/lib/require-disposable-guest.sh` admits only a marked disposable guest:
it requires both KVM/QEMU virtualization and the firmware marker
`/sys/firmware/qemu_fw_cfg/by_name/opt/ceralive`, otherwise exit 2. Test the
helper itself on a workstation, never a destructive harness.

The real RAUC pair (`real-rauc-contract.sh`, `real-rauc-cleanup-contract.test.sh`)
changes host state outside its own fixtures: it may unmount any `/mnt/rauc/*`
mount, binds over `/proc/cmdline` and briefly exposes `rootfs_a`/`rootfs_b`
partition labels to host udev. It sources `tests/lib/require-ephemeral-host.sh`
before privileged operations, also on direct invocation. That guard admits a
marked guest (`CERALIVE_RUN_REAL_RAUC_CONTRACT=disposable-marked-guest-only`), or
a GitHub-hosted ephemeral runner VM on the explicit spelling
`github-hosted-ephemeral`: the runner's own `GITHUB_ACTIONS=true` and
`RUNNER_ENVIRONMENT=github-hosted`, on a machine `systemd-detect-virt --vm`
reports as a VM. The runner is discarded after the job, which is why the pair
ran there as required before the guard existed. A workstation is bare metal and
refuses even with those variables; `required` is no longer accepted.

The other privileged rows are **confined**: confined except transient host
loop devices, netns mounts and host-namespace binds under their own directory.
Real Avahi creates per-run network namespaces (nsfs mounts under the host's
`/run/netns`) and veth pairs created in the host namespace with fixed peer
names, so two concurrent runs collide and a killed run can leak interfaces; its
daemon runs with a private mount namespace and D-Bus. Real kernel stage attaches
host loop devices to its own images and binds the host's `/proc`, `/sys`,
`/dev` and `/dev/pts` non-recursively into its own chroot tree under its
`mktemp` directory, where dpkg runs as root; it refuses to delete that tree
while a mount remains and keeps mounts and loops on a failed cleanup. Neither
mounts over a host path, labels a host partition or starts a host service. They
run as before the guard: opt-in locally, `required` in the hosted job. Each
carries a `# guest-guard: confined.` header with these limits, and
`tests/test-registry.test.sh` fixes the confined set, so moving a row out from
under a guard is a reviewed change.

A guest is **marked** when the host starts it under QEMU/KVM with at least one
firmware configuration item named below `opt/ceralive/` and the guest kernel
exposes fw_cfg (`qemu_fw_cfg`), for example
`-fw_cfg name=opt/ceralive/job,string=1`. `ci/kernel-runner/vm.py` already
passes its job items that way, so its disposable guest is marked and
`ci/kernel-runner/ci-tests.sh` runs every guarded row. Nothing inside a guest
can create the marker after boot, and an ordinary hosted runner has none.

The hosted `bats` job requires the real Avahi, real kernel-stage and
privilege-drop contracts directly, and selects the real RAUC rows with
`ci/privileged-contracts.sh`: on a marked guest they run as
`disposable-marked-guest-only`, on a GitHub-hosted runner VM as
`github-hosted-ephemeral`, so the pair stays required on every pull request as it
was before the guard. Anywhere else (a workstation, a self-hosted runner) they
are skipped with a visible `skipped: needs marked guest` notice and step-summary
line, instead of exiting 2 at the guard. A skip there is not a pass of the RAUC
contract. There is no override variable for a bare-metal host.

### Running the privileged rows in a marked guest

`ci/kernel-runner/privileged-guest.sh` runs exactly the registry's `privileged`
rows inside a fresh guest and prints one result line per row:

```bash
ci/kernel-runner/privileged-guest.sh                 # KVM if /dev/kvm is usable, else TCG
ci/kernel-runner/privileged-guest.sh --accel kvm --smp 4 --memory 12288
```

The host side runs QEMU as the invoking user and refuses to run as root; it
needs `qemu-system-x86_64`, `qemu-img`, `xorriso`, `flock`, `git` and Python
with PyYAML. It reuses `ci/kernel-runner/vm.py`: a pristine Ubuntu base
(cloud image pinned by digest, packages from `provision.sh`) is built once per
set of base inputs under `mkosi/cache/kernel-runner/` (or
`CERALIVE_GUEST_CACHE`), and every run boots a new overlay of it that is deleted
afterwards. The host passes only this checkout's tracked files as a read-only tar
capsule and `ci/kernel-runner/privileged-check.sh` as the `opt/ceralive/check`
firmware item, which is the marker. No host directory is shared, no credential
enters the guest and nothing privileged touches the host.

Inside the guest, `privileged-check.sh` unpacks the capsule for the unprivileged
`ubuntu` user, reports the guard verdict, and runs `ci/kernel-runner/ci-tests.sh
--privileged-only` as that user. That builds the pinned RAUC, creates the
`ceralive-ota` account, exports the native Debian rootfs, and runs each
`privileged` row to the end so one failure does not hide the others. Each row
ends with `CERALIVE_PRIVILEGED_ROW rc=<exit> seconds=<n> <path>` on the console.
The launcher's log stays in the cache directory.

`--accel kvm` is the normal path. `--accel tcg` emulates the CPU in software for
a host without `/dev/kvm` access. It is the same guest, only several times
slower, and two rows carry budgets sized for hardware virtualization. Under
TCG the real RAUC contract exceeds its 60-second `rauc install` timeout (exit
124). The real Avahi contract never sees the late-merge name conflict, probably
because the slow guest joins the two networks after Avahi has finished
announcing (not yet proven). Both pass
under KVM. A TCG run decides only the kernel-stage and RAUC cleanup rows; use
KVM for a verdict on the other two. The workflow `.github/workflows/privileged-guest.yml` runs the launcher
with KVM on an ordinary GitHub-hosted runner, which exposes `/dev/kvm`. It uses no
secrets, no self-hosted runner and a read-only token, and is not a required
check. It is the only CI that runs the guest-only RAUC pair; the confined real
Avahi and kernel-stage rows it runs as well stay required, unguarded, in the
hosted `bats` job. `tests/test-registry.test.sh` checks that the workflow
header names exactly the guarded rows.

Remaining policy limits: healthy requalification still restores the configured
allowance, so very slow periodic failures can recur; boot-time includes suspend
(but a report gap exceeding the maximum restarts dwell), and lock acquisition
fails closed while waiting for an existing writer. No hardware durability or
rescue activation is established by host tests.

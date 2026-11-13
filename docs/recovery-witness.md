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
limit and healthy interval. Its schema-2 `recovery.json` ledger holds one witness
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
cause, health verdict, detector states, intent, boot uptime and budget snapshot.
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
fresh allowance. At `begin`, a rejected file is renamed to `recovery.rejected` (one retained
generation) before replacement; rename/directory-fsync failure aborts admission.
Threshold changes spend the budget while preserving the witness history. Orphan
`.write-*` files are removed under the same lock before admission.
`export` is read-only and exports the admitted ledger, not raw malformed bytes.

## Budget semantics and visibility

A new boot spends an attempt only when its predecessor recorded a reset intent
or the observed cause is watchdog/software reset; clean power-on does not spend.
A missing ledger has no automatic reset credit but is not itself an exhausted
reset episode. `exhausted` distinguishes actual exhaustion from unavailable
credit. Counts saturate at zero; restarting a
producer in the same boot does not spend again, but does recommit/fsync before
returning admission (a prior writer may have died after rename). Stale boot IDs cannot modify a
new boot. This is a box reset budget, not the bootloader slot counter, and does
not depend on an update being pending. The future boot integration must decide
which actual boots to admit; this module does not arm an unattended policy.

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

`begin`, `health` and `intent` return the versioned status projection only after
persistence. `status` and `export` need no write. Status from a previous boot denies resets
until the current boot is admitted. A spent/uncertain budget announces
**“Rescue required: reset budget exhausted or uncertain”**, denies automatic resets
and exposes `rescue_required: true`. `rescue_active: false` deliberately does not
claim that a rescue mode exists. Any storage/identity error exits nonzero and
prints a safe denial without paths or exception text. `intent reset` returns
exit 3 on a denied reset and never records that refused reset intent (storage or
argument errors return 1). Consumers must check exit
status and deny reset on failure. Status is advisory: a disruptive reset must
follow a successful current-boot `intent reset` transaction returning permission,
not a cached/read-only grant. This is only the budget’s vote: consumers must
separately prove action, stream and rollback admission. A positive budget never
proves that a watchdog or rollback is armed. No cached permission is authority
for a later boot.

The lowest working local console can run:

```sh
python3 /path/to/recovery_witness.py --state-dir /path/to/private-state \
  --limit 3 --healthy-seconds 600 status
```

Those numbers are examples, not production defaults. API callers supply measured
slot/counters, bootloader digest, watchdog bootstatus classification and detector
evidence to `begin`; the CLI's `begin` leaves those observations unknown. Use
`export` for the boot-keyed evidence and `intent reset` before a reset submission.
Wire this projection to the management UI/log export and independent console in
the enabling change. Rescue must retain management/update/export while suppressing
media, but this module neither stops a stream nor falsely announces active rescue.

## Enabling work still required

- Select/verify the durable medium and extraction floor, with missing/full/corrupt
  storage drills. Bootloader, early-kernel and PID-1 callers are not yet wired.
- Choose exhausted-budget behaviour during a stream before wiring media suppression
  or a terminal-mode transition. This status is useful under either answer.
- Previous-release retention affects the selector/mirror, not this ledger.
- Pinning/writing bootloader or SPI affects evidence collection and refusal policy;
  a digest here is observation, not a pinned-bootloader proof.
- Remote export transport and authentication belong to the consumer.
- Boot-time update/trial admission, management-path confirmation, reset triggers
  and missing-root handling are outside this module. Hardware acceptance requires
  separate boot, storage and power-cut drills.

Run `tests/recovery-witness.test.sh`; it is also registered in `./run-tests`.

## Privileged harness boundary

Every privileged registry entry sources `tests/lib/require-disposable-guest.sh`
before privileged operations. It requires both KVM/QEMU virtualization and the
firmware marker `/sys/firmware/qemu_fw_cfg/by_name/opt/ceralive`, otherwise exit 2.
The real RAUC gate spelling is `disposable-marked-guest-only`; `required` is no
longer accepted. Direct invocation has the same guard. Test the helper itself
on a workstation, never a destructive harness. The hosted workflow must run
these privileged legs in a marked disposable guest; an ordinary hosted VM with
no marker is deliberately refused. Existing CI environments need that guest
provisioning rather than an override.

Remaining policy limits: healthy requalification still restores the configured
allowance, so very slow periodic failures can recur; boot-time includes suspend
(but a report gap exceeding the maximum restarts dwell), and lock acquisition
fails closed while waiting for an existing writer. No hardware durability or
rescue activation is established by host tests.

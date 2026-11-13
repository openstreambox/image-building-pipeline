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
limit and healthy interval. Its schema-1 `recovery.json` ledger holds one witness
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
nonbooting board remain separate work. No file is automatically pruned: retention
is not inferred from software-release retention. The 4 MiB bound fails writes
closed and requires export/service before growth continues.

Missing, truncated, unknown-version, schema-invalid, checksum-invalid, oversized,
unreadable or configuration-mismatched records mean **zero automatic resets
available**, with unknown witnesses. They never mean a healthy first boot or a
fresh allowance. Existing malformed bytes are replaced only by an explicit
successful `begin` transaction, preserving their uncertainty in `state_source`.
`export` is read-only and exports the admitted ledger, not raw malformed bytes.

## Budget semantics and visibility

Each admitted new boot spends one attempt, saturating at zero; restarting a
producer in the same boot does not spend again, but does recommit/fsync before
returning admission (a prior writer may have died after rename). Stale boot IDs cannot modify a
new boot. This is a box reset budget, not the bootloader slot counter, and does
not depend on an update being pending. The future boot integration must decide
which actual boots to admit; this module does not arm an unattended policy.

Corruption falls toward **denying automatic reset** to stop loops. It does not
permanently lock recovery: in that same boot the trusted health producer can
report healthy, then confirm continuous health after the configured interval.
That refills the allowance durably. An unhealthy/unknown verdict or decreasing
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
prints a safe denial without paths or exception text. Consumers must check exit
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

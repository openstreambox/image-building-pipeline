# Reset evidence (source implementation; bench qualification pending)

The RK3588 boot script reserves **0x1f000000–0x1f0fffff**, 1 MiB,
for ROCK 5B and ROCK 5B+ (`rk3588-rock-5b{,-plus}.dtb`). The
`/reserved-memory` child is `ramoops@1f000000`: 128 KiB dmesg records,
512 KiB continuous console, `max-reason=2` (oops and panic). The remaining
512 KiB holds four dmesg records. Existing required kernel symbols include
PSTORE, PSTORE_RAM and PSTORE_CONSOLE built in. No watchdog policy changes.

The reservation is made in the **loaded DT before booti**, so replacing a
slot's kernel/DT does not silently drop it. `rk3588-ramoops.dts` is the
compile-checked equivalent overlay for inspection/alternative boot chains;
**do not also apply it** with the production boot-script reservation. The
base DT must supply `/reserved-memory` with two address and size cells.
The script refuses a failed reservation rather than silently claiming capture.

This address is below 512 MiB on supported RAM sizes, above the usual
kernel/FDT/initrd load area and away from low-memory firmware reservations.
It is a **proposed board reservation, not measured firmware preservation**.
Before shipping, verify the actual DT memory map, firmware reservations,
U-Boot relocation/load ranges (including the largest initrd), and `/proc/iomem`
for each supported RAM SKU and kernel/bootloader pair. A loader which clears
DRAM on warm reset defeats ramoops. Cold power loss also destroys it. A hang
need not produce an oops; continuous console is the evidence in that case.

Other families remain TODO:

- Other RK3588 boards, including Orange Pi 5 Plus: verify firmware RAM ownership
  and reset preservation before enabling this reservation on them.
- Other ARM families: select an address from their own memory and firmware map;
  copying the RK3588 address can corrupt memory.
- x86: no DT reservation; choose and qualify an appropriate persistent backend
  (for example EFI pstore) before advertising reset capture.

## Boot collection and reader

The runtime uses Bash, coreutils, util-linux and explicitly installed `jq`;
it does not require the development image or a Python interpreter.

`ceralive-reset-evidence.service` runs after `/data`, local filesystems,
pstore mount and udev coldplug. It checks that `/data` really is mounted,
including when its fstab entry is `nofail`. The image masks
`systemd-pstore.service` so it cannot race or erase sources after a failed
collection. This collector replaces the stock archiver on these images.

`/usr/local/sbin/ceralive-reset-evidence collect` writes to
`/data/log/reset-evidence/<UTC-timestamp>_<boot-id>/`, beside the persistent
system/console log tree (`/var/log` is bound from `/data/log`). External serial
captures remain independent; correlate by boot ID and timestamp. RTC time can
be wrong before network sync: `sequence` establishes collection order within
this store. No serial capture service is introduced.

Each directory holds `evidence.json` (schema 1) and byte-exact `pstore/*`:

- current boot ID and UTC collection time (records describe the previous boot);
- every exposed `/sys/class/watchdog/watchdog*/bootstatus`, as raw text;
- exposed text `reset_reason` at `/sys/kernel/reset_reason` and platform-device
  `reset_reason`/`reset_cause` attributes, keyed by source path;
- the list of copied pstore filenames. Missing sources yield empty maps/list,
  which means unavailable, **not** a clean reset or a zero bootstatus.

There is no generic SoC reset-cause ABI, and the current RK3588 kernel may expose
none. No register offsets, MMIO reads or debugfs writes are guessed. Additional
kernel-specific text ABIs need explicit adapters and tests. `bootstatus` is
read-only in the Linux ABI. **Only pstore files are cleared**, by unlink, after
all copied bytes and the containing directories have been fsync'd. Watchdog and
reset-cause attributes are never written or cleared; do not open `/dev/watchdog`.
See the [watchdog ABI](https://github.com/torvalds/linux/blob/master/Documentation/ABI/testing/sysfs-class-watchdog)
and [ramoops guide](https://docs.kernel.org/admin-guide/ramoops.html).

Collections are private (0700 directories, 0600 files), atomic and serialized.
Keep the latest **eight collections**, with at most **16 MiB / 128 pstore files**
per collection (approximately 128 MiB plus small metadata, and one transient
collection). Oversized/unreadable inputs or storage/fsync errors fail without
acknowledging pstore. Pre-publication partial directories are removed on retry.
A crash after durable publication can leave duplicate source records; a same-boot
retry keeps the original archive and does not clear newly arriving records.
A storage failure can prevent retention cleanup; the unit reports failure.

The read-only interface for a future privileged support-bundle/CeraUI integration:

```sh
/usr/local/sbin/ceralive-reset-evidence latest
```

It prints the latest schema-1 JSON, exits 0 on success, 1 when absent/unreadable,
2 for bad arguments. It never collects or clears. Support bundles can include
that collection's JSON and pstore directory with their existing privacy policy;
no data is exposed through an HTTP endpoint. CeraUI is unchanged. Tests set
`CERALIVE_EVIDENCE_ROOT` to an entirely fake filesystem; production units never
set this override.

## Remaining qualification

On recoverable media, with independent serial logging and recorded kernel,
firmware, RAM size and bootloader identities: verify reservation/probe; induce
a controlled oops/panic and warm reboot; confirm old console+dmesg saved once,
source pstore cleared after durable copy, watchdog status and any exposed cause
captured, and reader results aligned with serial output. Test a reset without
panic, cold power loss limitations, `/data` mount/write failure and retention.
Repeat after kernel/bootloader changes. No flash, board access or reset was
performed to implement this change.

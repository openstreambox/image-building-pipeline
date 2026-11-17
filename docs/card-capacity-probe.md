# Card size and fake-capacity probe (core only)

**Status: not installed, not invoked.** `mkosi/runtime/ceralive-card-probe.sh`
is a host-tested core. No unit, postinst module, build step or image layer
calls it, and `tests/card-capacity-probe.test.sh` fails if one starts to. It
accepts only an owned regular file and refuses block devices. Wiring it into
first boot waits for qualification on real cards (see the end of this page).
A pass is not evidence of genuine capacity (see [Limits](#limits)).

## Why

A card that claims more space than it has usually maps writes past its real
size back onto lower addresses, or drops them. On a box, such a card looks fine
until the data partition fills past the real size, and then recordings and
settings are lost, or the system itself is overwritten. The data partition grows
on first boot, before anything of the user's is on the card, so that is the
moment to find out cheaply.

Existing tools do not fit there: `f3probe` needs a USB-attached device and
refuses `/dev/mmcblk*`, and `f3write`/`f3read` fill the free space of a mounted
file system, which on a wrapping card overwrites the running system.

## What it does

`ceralive-card-probe.sh reference IMAGE [--min-media-bytes N]` runs at build
time on the pristine image and prints a small reference record:

```text
format=ceralive-card-probe-reference/1
image_bytes=<image length>
min_media_bytes=<N, when given>
region=loader 0 <first partition start> <sha256>
region=backup-gpt <offset> <length> <sha256>
```

The loader region is everything before the first partition: the protective
MBR, the primary GPT and, on RK3588, the raw loader blobs. The backup GPT region
is its entry array plus header, and must sit after the last usable LBA. Nothing
inside a partition is hashed: setup tools may add configuration files to the
boot partition after writing, and some hosts add folders there.

Both sides read the GPT the same way (see [GPT checks](#gpt-checks)); the build
side refuses an image whose GPT fails them, or whose backup header is not its
last sector.

`ceralive-card-probe.sh probe TARGET REFERENCE [--marks N]` then:

1. checks the target path and opens it once (see [Target handling](#target-handling));
   the reference must have exactly the shape above, or it stops as
   **refused** (`invalid-reference`);
2. reads the target's size; below `min_media_bytes`, or with no room for two
   marks after the image, it stops as **too-small** without writing;
3. checks both regions against the reference; if they already differ it stops
   as **fake-or-faulty** without writing;
4. reads the target's GPT and checks it as below; an invalid GPT stops as
   **refused** (`invalid-gpt`). The reference must then name exactly the image
   end (the backup header's end), the loader region `[0, first partition)` and
   the backup region the GPT implies; any difference stops as **refused**
   (`reference-mismatch`). Nothing is written in either case;
5. writes a 1 MiB mark at N evenly spread offsets (default and maximum 64,
   minimum 2) from the first MiB boundary after the image to the last full MiB
   of the card, plus at every power-of-two offset in that range. Each 512-byte
   sector of a mark names the run (a random nonce), the mark's offset and the
   sector index, so marks from other offsets or earlier runs never match;
6. writes all marks before reading any, then flushes the target and drops its
   cached pages;
7. reads every mark back, then checks both regions again.

Power-of-two offsets catch the common fake that wraps at a power-of-two real
size: those marks land on each other and on offset zero, so an earlier mark is
overwritten and the loader region changes. Evenly spread marks alone can each
land in a different place and all read back fine.

Every write is checked to be one aligned MiB inside `[first MiB after the image,
reported size)` before the first write happens. The total written is at most
`64 + number of power-of-two offsets` MiB: 66 MiB for a 7 GiB image on a
32 GB card.

Output is `key=value` lines on stdout (`result`, `reason`, `size_bytes`,
`image_bytes`, `probe_start`, `marks_written`, `mismatches`, up to 16
`mismatch_offset`, `region_changed`, `io_error_offset`). Exit status:

| Status | Result | Meaning |
| --- | --- | --- |
| 0 | `pass` | every mark and both regions match |
| 1 | `fake-or-faulty` | a mark read back wrong or the image area changed |
| 2 | `refused` | bad arguments, invalid reference or GPT, reference that does not match the GPT, unsupported or replaced target |
| 3 | `io-error` | a read, write or flush failed; no verdict |
| 4 | `too-small` | below the minimum, or no room after the image |

A failing genuine card fails the same way as a fake one, which is why the
result is "fake or faulty". An I/O error is kept separate so that the caller
does not have to call it fraud. A refusal (2) before the first write leaves the
target unchanged; the reason line says which check refused.

## GPT checks

The helper reads the GPT with Bash and coreutils only (`dd`, `od`, Bash
arithmetic for CRC-32), through the same storage functions as everything else.
It requires, for 512-byte sectors:

- primary header at LBA 1 and backup header at the alternate LBA, both with the
  `EFI PART` signature, revision 1.0, a header size of 92 to 512 bytes, a
  matching header CRC-32, a zero reserved field and their own LBA in the
  "my LBA" field; LBA fields below 2^48, so no offset overflows;
- the backup header inside the target and mirroring the primary one (alternate
  LBA 1, same usable range, disk GUID, entry count, entry size and entry-array
  CRC), with its entry array directly before it;
- the order MBR, primary header, primary entries, first usable LBA, last usable
  LBA, backup entries, backup header;
- 1 to 256 entries of 128 to 1024 bytes (a power of two); the primary entry
  array matching its CRC-32 and the backup array byte-identical to it;
- every used entry inside `[first usable, last usable]` with start <= end, at
  least one partition, and no two partitions overlapping.

So a partition can no longer reach over the backup GPT, and the first mark
offset (the first MiB at or after the backup header's end) is after every
partition the GPT declares.

## Target handling

Before anything opens the target, `stat` checks that it is an owned,
single-link regular file (block devices are refused with "not qualified on real
cards yet"), that the path contains no symlink, and that every directory above
it belongs to root or the caller and cannot be changed by others (or has the
sticky bit). The helper then opens the target once, read-write, and checks
through that descriptor that the opened file is an owned, single-link regular
file and that the path still names exactly it. Every later size query, read,
write and flush goes through `/proc/self/fd/N` for that descriptor, so the
target path is never resolved again. If the path names something else at the
end, the result is `refused target-changed`, even though every write went to the
file that was checked.

Each `dd` uses `iflag=fullblock` and must report exactly the requested whole
records in and out. A short read (for example a target that shrank) or a short
write is an **io-error**, never a mark mismatch.

## Limits

- **A destructive false pass is possible.** Most non-power-of-two wrap sizes
  can evade these samples for full-size images. Modelling the actual offsets
  with a 7 GiB image found 93–97% of non-power-of-two wrap sizes passed for
  32/64/128 GiB claims, and over 99% for 1–2 TiB claims. These are model results,
  not rates measured across physical cards. A host reproduction with a 7 GiB
  image, 32 GiB claim and 8000 MiB wrap returned `pass` while 57 MiB of marks
  landed inside boot/rootfs partitions. The 32 MiB fixture hides this geometry
  dependence. Power-of-two wraps were detected in the checked cases.
  A pass means only that sampled marks and hashed regions match; it proves
  neither genuine capacity nor preservation of partition contents. A full
  offline check (f3, H2testw) remains a separate step.
- **The reference still decides what "pristine" means.** Its geometry is now
  checked against the target's GPT, but its hashes are taken as given. A
  reference built from another valid image that happens to match the card's
  loader area and backup GPT is accepted. Ship it read-only with the image.
- **Remaining target-handling boundaries.** Bash cannot open with `O_NOFOLLOW`
  or `O_NONBLOCK`. Between the `stat` checks and the open, only root or the
  caller can change the path (the directory checks above); if they swap in
  another kind of file, the open itself may have side effects (for example on a
  character device) before the descriptor check refuses it. A replacement owned
  regular file may instead be accepted: the pre-validation inode is not pinned,
  and the post-open check compares the descriptor with the path as it is then.
  The descriptor
  approach needs Linux `/proc`; without it every I/O call fails and the probe
  stops without writing. A process of the same user can still change the file's
  contents while the probe runs.
- **No speed test.** Card speed is a separate check.
- **Regular files only.** Block devices are refused. Full-block reads and the
  record count check are tested only with regular files and pipes. On a real
  card the flush and cache-dropping step, and reading with direct I/O, still
  need to be qualified.
- The GPT reader assumes 512-byte logical sectors, as SD cards and the image
  builder use.

## Storage seam for tests

All target I/O goes through four functions: `card_io_size`, `card_io_read`,
`card_io_write` and `card_io_flush`. Sourcing the script defines the
regular-file versions and does not run anything. The contract test redefines
them to model fake cards over a smaller backing file: wrapping at 64 MiB and at
512 MiB on a card claiming 1 GiB, dropping writes, returning marks from an
earlier run, one corrupted byte, and a failing write. There is no environment
variable or option that selects another implementation.

The test also builds hostile references (understated, overstated or
incomplete geometry with matching hashes) and hostile GPTs with valid CRCs
(overlap, a partition over the backup GPT, out-of-range LBAs, broken mirror),
using CRCs computed independently from the gzip trailer. It swaps the target
path during a run and between the checks and the open, and checks short reads
and writes.

One backup-only corruption case deliberately preserves the primary and backup
headers' matching entry-CRC fields and repairs only the backup header CRC.
The current array comparison rejects it without writes; removing that comparison
accepts the image. No CRC collision is needed, so the comparison is not redundant.

## Before anything calls it

- Decide whether the sampling blind spot above is acceptable at all for the
  real image size, or whether the probe needs a different design first. Host
  fixes to the reference, GPT and target handling do not change it.
- Qualify block-device handling (opening, full-block reads, flushing, cache
  behaviour and direct reads) on `mmcblk`; until then block devices stay refused.
- Plan destructive tests offline: wrapping writes can overwrite LBA 0 and the
  running rootfs even when the requested offsets are after the image.
- Measure the probe on real genuine cards and on a known fake, on the box,
  including how long it takes and what flushing and cache dropping do on
  `mmcblk`.
- Decide where it runs in the first-boot order (before growth) and what the box
  shows for each result.
- Generate the reference during the image build and ship it read-only.

Until then, nothing in the image runs it.

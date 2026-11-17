# Card size and fake-capacity probe (core only)

**Status: not installed, not invoked.** `mkosi/runtime/ceralive-card-probe.sh`
is a host-tested core. No unit, postinst module, build step or image layer
calls it, and `tests/card-capacity-probe.test.sh` fails if one starts to. It
accepts only an owned regular file and refuses block devices. Wiring it into
first boot waits for qualification on real cards (see the end of this page).

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

`ceralive-card-probe.sh probe TARGET REFERENCE [--marks N]` then:

1. reads the target's size; below `min_media_bytes`, or with no room for two
   marks after the image, it stops as **too-small** without writing;
2. checks both regions against the reference; if they already differ it stops
   as **fake-or-faulty** without writing;
3. writes a 1 MiB mark at N evenly spread offsets (default and maximum 64,
   minimum 2) from the first MiB boundary after the image to the last full MiB
   of the card, plus at every power-of-two offset in that range. Each 512-byte
   sector of a mark names the run (a random nonce), the mark's offset and the
   sector index, so marks from other offsets or earlier runs never match;
4. writes all marks before reading any, then flushes the target and drops its
   cached pages;
5. reads every mark back, then checks both regions again.

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
| 2 | `refused` | bad arguments, invalid reference or unsupported target |
| 3 | `io-error` | a read, write or flush failed; no verdict |
| 4 | `too-small` | below the minimum, or no room after the image |

A failing genuine card fails the same way as a fake one, which is why the
result is "fake or faulty". An I/O error is kept separate so that the caller
does not have to call it fraud.

## Limits

- **Sampling, not certification.** A card that wraps at a size that is not a
  power of two can place a mark inside the image area outside the hashed
  regions; that mark reads back fine and the probe can pass. A pass is not proof
  that a card is genuine; a full offline check (f3, H2testw) remains the way to
  certify one.
- **No speed test.** Card speed is a separate check.
- **Regular files only.** Block devices are refused. On a real card the flush
  and cache-dropping step, and reading with direct I/O, still need to be
  qualified.
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

## Before anything calls it

- Measure the probe on real genuine cards and on a known fake, on the box,
  including how long it takes and what flushing and cache dropping do on
  `mmcblk`.
- Decide where it runs in the first-boot order (before growth) and what the box
  shows for each result.
- Generate the reference during the image build and ship it read-only.

Until then, nothing in the image runs it.

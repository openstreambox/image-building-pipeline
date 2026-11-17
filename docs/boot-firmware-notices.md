# Firmware and boot loader notices

Two pinned Armbian packages ship without a copyright file: `armbian-firmware-full`
26.8.3 (all of `/usr/lib/firmware` except Debian's `regulatory.db`) and
`linux-u-boot-rock-5b-plus-edge` 26.8.3 (the ROCK 5B+ loader the image writes at
32 KiB). The firmware package also leaves out linux-firmware's `WHENCE` and every
licence file it names. The image build now adds
`/usr/share/doc/<package>/copyright` for both, the only doc file name every doc
prune keeps.

These files record origins and notices. They are not legal advice, do not grant
any licence, and do not settle whether every firmware file may be redistributed.
They do not claim that the loader was rebuilt from source.

## What the files contain

**Firmware.** The archive and its two sources at their exact commits:
linux-firmware `eeed587f`, installed first, and armbian/firmware `f50a2a21`,
extracted over it. Then, verbatim: `WHENCE`, the 129 licence files it names for
the package's files, and the armbian/firmware `README.md` as published (its note
that redistribution "is limited to non-commercial or usage-only contexts" is
reproduced and not interpreted). Last, every one of the package's 5305 firmware
files, marked shipped or removed by this image, with one of four classes:

| Class | Meaning | Licence statement |
| --- | --- | --- |
| `upstream` | same bytes as linux-firmware at the same path | that path's WHENCE entry |
| `upstream-other-path` | same bytes as a linux-firmware file at another path | that path's WHENCE entry |
| `armbian-changed` | armbian/firmware replaced the file with other bytes | none established |
| `armbian-only` | no file with these bytes in linux-firmware | none established |

A WHENCE entry that describes other bytes at the same path is never used for an
`armbian-changed` file. Measured on a ROCK 5B+ image built from these pins, 4687 files ship:
4167, 25, 46 and 449 per class. 82 shipped `upstream` files have a WHENCE entry
that names no licence file.

**U-Boot.** The archive, the loader's sha256, and its parts:

- DDR init (TPL): the bytes are `rk35/rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.20_20250926.bin`
  of armbian/rkbin `ce50c0d1` (git blob `c6288879`). Rockchip's rkbin has a file
  of the same version with different bytes. **No licence text that applies to
  these bytes has been established.** armbian/rkbin's `LICENSE.TXT` is reproduced
  only as that repository's licence file, labelled as not established for this
  blob; Rockchip's licence text is not reproduced.
- SPL, U-Boot proper and FIT device trees: U-Boot v2026.04 (`88dc2788`) with
  Armbian's patches. Every file of U-Boot's `Licenses/` at that commit.
- BL31: Trusted Firmware-A v2.13.0 (`c1735145`), built by Armbian. Its licence
  files at that tag. The in-file notices of third-party code that `docs/license.rst`
  mentions are not reproduced, because which of it this build contains is not
  established.

## How it is built

`mkosi/runtime/licence-notices/boot-firmware/inputs.json` holds the reviewed pins:
each archive by URL, sha256 and size, each source by full commit.
`tools/generate-boot-firmware-notices.py` derives everything else and checks
each claim first (archive hashes and control fields, every firmware file's git
blob against the pinned trees, the loader's RKNS hashes, the DDR blob identity,
version strings, the U-Boot licence summary). It writes the two static payloads,
`firmware-files.tsv`, `identity.tsv`, `texts.tsv` (byte range, sha256 and git blob
of every verbatim text) and `SHA256SUMS`.

```bash
tools/fetch-boot-firmware-notice-sources.sh /tmp/bfn     # network: blobless clones, archives
tools/generate-boot-firmware-notices.py --sources /tmp/bfn/sources --debs /tmp/bfn/debs --check
```

The fetch keeps only the pinned commits' trees and the text blobs the generator
reads, a few MB; it never downloads source firmware. `--check` regenerates in
memory and compares byte for byte. Regenerate when either package pin moves; the
host test fails until then.

## Image install

The app layer runs `install-boot-firmware-notices.sh` after the package and
other notice installs and before the doc prune. It reads the dpkg status, `.list`
and `.md5sums` files as text and hashes installed files; it runs nothing from the
image and needs no network. Before writing anything it refuses: payloads that
differ from `SHA256SUMS`, a changed verbatim text, another version or
architecture, an md5sums file other than the pinned archive's, a changed or
missing required file, a package file the tables do not list, a pinned file the
package database does not list, a symlinked file or directory, an unmerged
`/lib`, a firmware tree with no package file, and an existing copyright file.
Packages that are not installed are skipped. Other installed `linux-u-boot-*`
and `armbian-firmware*` packages are logged as uncovered and get no file.

Contract: `tests/boot-firmware-notices.test.sh`. It also runs the app layer's
`prune_package_docs`, the device's `ceralive-reprune`, and `doc-notice-policy.sh`
when present, and checks that both files survive byte for byte.

## Not covered

- The applicable terms for the DDR blob, and its build origin.
- A licence statement for the shipped `armbian-changed` and `armbian-only`
  firmware files.
- Byte reproduction of the TPL, SPL, U-Boot and BL31, and the exact Armbian
  build commit.
- The other U-Boot packages in `manifests/armbian-bsp-deb-versions.txt`
  (Orange Pi 5 Plus, and the vendor packages used by `edge-test`).
- Which firmware the hardware loads, and the contents of a board's SPI flash.

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
They identify the source of each loader part from the loader itself and do not
rely on a rebuild.

## What the files contain

**Firmware.** The archive and its two sources at their exact commits:
linux-firmware `eeed587f`, installed first, and armbian/firmware `f50a2a21`,
extracted over it. Then, verbatim: `WHENCE`, the 131 licence files it names for
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
4167, 25, 46 and 449 per class. 39 shipped `upstream` files have a WHENCE entry
that names no licence file; their Licence fields are free text ("Allegedly GPLv2+",
"Dual GPLv2/MPL", "GPLv2 or OpenIB.org BSD license").

A WHENCE `Licence:` field is free text. The generator resolves each of its words
against the pinned `LICENSES/` listing (and licence-shaped names against the
repository root), so `Licence: MIT` names `LICENSES/MIT` and `License: Apache-2.0`
names `LICENSES/Apache-2.0`. A word shaped like a licence file name or an SPDX
identifier that is no file stops generation, except for the reviewed names in
`licence_names_without_file` in `inputs.json`, each of which must appear beside a
named licence file in the same field and must still be used.

**Historical origins.** Two shipped `armbian-changed` files are older
linux-firmware bytes at the same path: `rtw89/rtw8852b_fw-1.bin` (git blob
`ab2f8081`) is at linux-firmware `2afd1423` ("rtw89: 8852b: update fw to
v0.29.29.5"), and `rtl_bt/rtl8852bu_fw.bin` (`2636ae5a`) is at `0061a2dd`
("rtl_bt: Update RTL8852B BT USB firmware to 0xDBC6_B20F"). Upstream later
replaced both, so the pinned `eeed587f` WHENCE describes other bytes. For these
two, `historical_origins` in `inputs.json` names the earlier commit, and the
payload gets a section "Historical linux-firmware origins" with, for each file:
the commit, the WHENCE section that lists the path at that commit (verbatim,
with its byte range in that WHENCE), the byte range of the group that lists the
path, and the licence file that group names. In both cases that is
`LICENCE.rtlwifi_firmware.txt`, git blob `d70921f4`, the same bytes as the
`LICENSES/LICENCE.rtlwifi_firmware.txt` already reproduced, so the payload cites
that copy instead of repeating it. A historical licence file with other bytes
would be reproduced from its own commit. The `rtl_bt` group sits in the btusb
section after an Intel group; the Intel group's `LICENCE.ibt_firmware` line does
not apply to it.

Both files stay in the `armbian-changed` class. Their rows in the file table
cite the earlier commit; every other `armbian-changed` and `armbian-only` row is
unchanged. armbian/firmware does not record where it took these bytes from,
and nothing here establishes that copy step, interprets the licence text, or
says that its conditions are met. A file of the same name with other bytes, at
any commit, establishes nothing.

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
of every verbatim text), `excerpts.tsv` (byte range and sha256 of every verbatim
excerpt, with its place in the source file) and `SHA256SUMS`.

For each historical origin the generator checks, before it writes anything: the
reviewed sha256, size and git blob against the package and the pinned
armbian/firmware tree; that the pinned linux-firmware has other bytes at that
path; that the earlier commit comes from the same linux-firmware repository, has
the reviewed subject and these exact bytes at that path; that its WHENCE is the
reviewed blob and lists the path on exactly one File line, in exactly one group,
under the reviewed Driver line, closed by the reviewed Licence field; and that
the field names exactly the reviewed licence files, as the reviewed blobs. It
does not check that a commit is on linux-firmware's main branch or in a release
tag; that was checked when the pins were reviewed (both files' bytes are in the
signed release tag `20231211`).

```bash
tools/fetch-boot-firmware-notice-sources.sh /tmp/bfn     # network: blobless clones, archives
tools/generate-boot-firmware-notices.py --sources /tmp/bfn/sources --debs /tmp/bfn/debs --check
```

The fetch keeps only the pinned commits' trees and the text blobs the generator
reads, a few MB; it never downloads source firmware. The two earlier
linux-firmware commits are fetched the same way. `--check` regenerates in
memory and compares byte for byte. Regenerate when either package pin moves; the
host test fails until then.

## Image install

The app layer runs `install-boot-firmware-notices.sh` after the package and
other notice installs and before the doc prune. It reads the dpkg status, `.list`
and `.md5sums` files as text and hashes installed files; it runs nothing from the
image and needs no network. Before writing anything it refuses: payloads that
differ from `SHA256SUMS`, a changed verbatim text or excerpt, another version or
architecture, an md5sums file other than the pinned archive's, a changed or
missing required file, a package file the tables do not list, a pinned file the
package database does not list, a symlinked file or directory, an unmerged
`/lib`, a firmware tree with no package file, an existing copyright file, and a
destination path with a symlink or a non-directory in it. Every destination is
checked for both packages before the first file is written, so a refusal leaves
neither file behind.
Packages that are not installed are skipped. Other installed `linux-u-boot-*`
and `armbian-firmware*` packages are logged as uncovered and get no file.

Contract: `tests/boot-firmware-notices.test.sh`. It also runs the app layer's
`prune_package_docs`, the device's `ceralive-reprune`, and `doc-notice-policy.sh`
when present, and checks that both files survive byte for byte.

## Not covered

- The applicable terms for the DDR blob, and its build origin.
- A licence statement for the shipped `armbian-changed` and `armbian-only`
  firmware files at the pinned commits. Two `armbian-changed` files have a
  historical linux-firmware origin (above); for the others no statement has
  been found. How armbian/firmware obtained the two files' bytes is not
  recorded.
- A build of the DDR init blob from source, and the exact Armbian build commit.
  A separate rebuild from the pinned U-Boot and TF-A commits, with Armbian's
  configuration and patches and the matching Debian cross compiler, reproduced
  SPL, U-Boot proper, BL31 and both complete loaders byte for byte. It used the
  unchanged DDR blob as a binary input, so it says nothing about that blob's
  origin or terms. That rebuild is not part of this change.
- The other U-Boot packages in `manifests/armbian-bsp-deb-versions.txt`
  (Orange Pi 5 Plus, and the vendor packages used by `edge-test`).
- Which firmware the hardware loads, and the contents of a board's SPI flash.

# Licence notices in the image

The image keeps only files named `copyright` under `/usr/share/doc`: the app
layer prunes everything else, and `ceralive-reprune` repeats that after every apt
run. Licence texts therefore have to arrive as `/usr/share/doc/<name>/copyright`.

## What adds them

- **First-party packages without a copyright file.** `mkosi/runtime/licence-notices/notices.tsv`
  lists, per package version, the component sources and the licence file at a
  pinned commit. `texts/` holds verbatim copies pinned by sha256.
  `install-licence-notices.sh` runs in the app layer after the first-party
  `.deb` files are installed and writes `/usr/share/doc/<package>/copyright`.
- **MediaMTX.** `setup_rtmp_gateway` copies the `LICENSE` member of the verified
  release tarball to `/usr/share/doc/mediamtx/copyright`.

## When it fails

The build stops when an installed package's version differs from its rows, a
pinned text is missing or changed, a row is malformed, the package now ships its
own copyright file (drop its rows), or the MediaMTX tarball has no `LICENSE`.
Bumping a pin in `manifests/first-party-deb-versions.txt` therefore means
refreshing that package's rows; `tests/licence-notices.test.sh` checks that the
two agree. `tools/verify-licence-notices.sh` (network) re-fetches every pinned
text from its source and compares it with the vendored copy.

## Covered today

| Package | Component | Licence file |
| --- | --- | --- |
| `srtla` 4.2.0 | srtla_send | `LICENSE` of CERALIVE/srtla-send-rs at `1b5febb7` |
| `libsrt1.5-ceralive` 1.5.7+ceralive.2 | libsrt | `LICENSE` of CERALIVE/srt at `d487b133` |
| `gstreamer1.0-libuvcsrc` 2026.9.0 | bundled libuvc | `LICENSE.txt` of CeraLive/libuvc at `f3eda761` |
| `gstreamer1.0-libuvcsrc` 2026.9.0 | the GStreamer plugin | none: CERALIVE/gstlibuvcsrc at `8fe5ba50` has no licence file |
| MediaMTX v1.19.2 | `/usr/local/bin/mediamtx` | `LICENSE` from the release tarball |

## Not covered

- The GStreamer plugin in `gstreamer1.0-libuvcsrc`: its source has no licence
  file, so the copyright file says so and reproduces no text for it. The libuvc
  text in the same file covers libuvc only.
- Complete shipped Rust dependency membership and compiler/runtime notices remain
  unverified; source dependency inputs below do not close these gaps.
- Packages without public source or licence text (`cerastream`,
  `ceralive-apt-credentials`) have no row.
- Sysext and appfs bundles built from the same `.deb` files do not carry these
  files.

The libsrt notice includes the pinned leading notice blocks from `srtcore/udt.h`, `md5.h`
and `md5.cpp` to preserve their inherited University of Illinois BSD
and Aladdin notices with their source line ranges. The verifier extracts these ranges and compares
them byte for byte with the pinned copies.

The installer queries the installed package database once and fails on query
errors. `copyright-required.txt` names the first-party application packages
that must have a nonempty copyright after installation. `cerastream` and
`ceralive-apt-credentials` remain explicit gaps, excluded from that check until
public texts are supplied. This does not establish full licence closure.

## Device package dependency order

The current amd64 `2026.11.2-20261110T235721.31b06d5` and arm64
`2026.11.2-20261110T235725.31b06d5` device pins predate package copyright
notices. Measured on 17 November 2026, these are explicit logged gaps only for
those exact versions. No licence text is invented for them; this is not release
licence closure. All other required packages and later device versions still
fail if their copyright file is missing or empty.

Land CeraUI #125, build and review its integration package, then advance the
image's device pin to that actual package and remove the two legacy exceptions.
Do not advance the pin to an unbuilt topic head. The coverage list continues to
require `ceralive-device`, including after this dependency is satisfied.

## Pinned source dependency notices

The app layer runs `install-dependency-notices.sh` after the parent notice
installer. It appends verified static payloads to the existing `srtla` 4.2.0 and
MediaMTX v1.19.2 copyright files. Parent bytes remain intact. Both image doc
pruning and apt repruning retain these files. Unsupported installed versions,
changed payloads, missing parent copyright files and duplicate installation
fail closed. The existing legacy device exceptions are unchanged.

`mkosi/runtime/licence-notices/dependencies/plan.json` records official immutable
archive URLs, SHA256 pins, upstream crate checksums and Go module h1 checksums,
package versions, original file hashes, and half-open byte ranges for each
verbatim text. `plan.sha256` pins the inventory; `SHA256SUMS` pins the installed
payloads. No archive, binary or build-host path is needed in the repository.

Regenerate on the build host with Python 3.11+ (stdlib only):

```sh
python3 tools/generate-dependency-notices.py --cache /path/to/source-cache --output /path/to/new-output
# Add --fetch to download missing archives from the pinned official origins.
diff -u mkosi/runtime/licence-notices/dependencies/SHA256SUMS /path/to/new-output/SHA256SUMS
bash tests/dependency-notices.test.sh
bash tests/licence-notices.test.sh
```

Cache filenames are SHA256(URL). Every archive is checked before use; Go zip
SHA256 and Go sorted-file-content h1 are separate checks. The generator checks
original file bytes and extracted notice bytes before creating any output.
There is no enrol or automatic drift acceptance mode. Updating sources requires
reviewing and updating the inventory and static payloads together. An unlisted
missing-text exception fails, including a new version of a known exception.

The installed texts retain named licence, notice and authorship files, licence
directories, and verbatim copyright-bearing comment blocks from the pinned
source inventory. They omit executable source surrounding those blocks. This is
source notice coverage, not a claim that every possible embedded notice has
been found or a legal/compliance clearance.

The Rust inventory has 122 registry crates and four workspace packages. The
Cargo.lock closure includes optional, development and non-Linux packages; it
is not a measured shipped feature graph. MediaMTX has 131 fetched go.sum module
zips: 85 match the measured arm64 Go 1.26.4 release buildinfo and 46 are
source-only. Buildinfo measures module metadata, not included files/functions.
The same source release is used on amd64, but no amd64 membership measurement is
claimed. Runtime/compiler notices remain separate pending exact verified source
and version evidence. No rebuild or source-to-binary reproducibility is claimed.

Known exceptions are pinned to versions and official archive origins:

- `r-efi` 5.3.0 and 6.0.0 retain their crate `AUTHORS` files, which contain the
  MIT permission/warranty text, other notices and authorship. A file named
  LICENSE is not invented. Supplemental exact commits remain recorded.
- `valuable` 0.1.1 retains its MIT LICENSE from the exact recorded crate VCS
  commit `9efc29b6e58cef28f6566a47aa7e142a55fead77`.
- `github.com/benburkert/openpgp` at
  `v0.0.0-20160410205803-c2471f86866c` is measured in the Go binary metadata.
  Its headers reference a BSD LICENSE absent from both the module zip and exact
  commit `c2471f86866ca6ab0679b9d216cb6a84cfe90db1`. Headers are retained and
  the missing grant is stated in the payload. No substitute grant is supplied.

The private-source `cerastream` gap remains separate. This topic neither changes
package pins nor establishes release licence closure.

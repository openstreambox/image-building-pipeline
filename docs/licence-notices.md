# Licence notices in the image

Under `/usr/share/doc` the image keeps each package's licence, notice and
authorship files (`copyright`, `copyright.*`, `COPYING*`, `LICENSE*`, `NOTICE*`,
`AUTHORS*`, `CREDITS*` and similar names) and prunes the rest; `ceralive-reprune`
applies the same rule (`mkosi/runtime/doc-notice-policy.sh`) after every apt run.
Notices this build adds for a package go into `/usr/share/doc/<name>/copyright`.

## What adds them

- **First-party packages without a copyright file.** `mkosi/runtime/licence-notices/notices.tsv`
  lists, per package version, the component sources and the licence file at a
  pinned commit. `texts/` holds verbatim copies pinned by sha256.
  `install-licence-notices.sh` runs in the app layer after the first-party
  `.deb` files are installed and writes `/usr/share/doc/<package>/copyright`.
- **MediaMTX.** `setup_rtmp_gateway` copies the `LICENSE` member of the verified
  release tarball to `/usr/share/doc/mediamtx/copyright`.
- **This repository's own runtime files and the portal brand mark.** No package
  owns them. `image-notices.tsv` pins verbatim copies of this repository's
  `LICENSE`, `LICENSE-MIT` and `LICENSE-APACHE` (installed under
  `/usr/share/licenses/image-building-pipeline/` with a README naming source and
  commit) and of `BRAND-ASSETS-NOTICE.md` and `brand-assets.lock.json` (installed
  next to the brand mark in `/usr/share/ceralive/brand/`).
  `install-image-notices.sh` fails when a text changed or when the installed
  brand mark is not the one the lock records. `tests/image-notices.test.sh`
  checks the copies still equal the files at the repository root.
- **The generated `libv4l-0` compatibility package.** Its only content is a
  symlink into `libv4l-0t64`, so its copyright file points at
  `/usr/share/doc/libv4l-0t64/copyright` and adds no terms of its own.

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
- Statically linked dependencies: the Rust crates in `srtla_send` and the Go
  modules in `mediamtx` are not listed.
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

### Notice destination and doc-root checks

Before pruning, every component of the absolute doc root is checked. Symlinks,
`.` and `..` components are refused before enumeration or deletion. The build
fails on refusal; the on-device hook logs the skipped reduction and exits zero.
Links encountered below a valid doc root are still left alone.

The image notice installer checks the destination prefix, every output path and
the generated README for symlink components. The README is checked before the
first notice is installed and again before its write. Unsafe prefixes and dot
components are refused. These checks assume a stable build tree; they do not
make path-based shell I/O safe against concurrent path replacement.

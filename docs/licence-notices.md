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
installer and before doc pruning. It appends static payloads to the existing
`srtla` and MediaMTX copyright files, keeping the parent bytes intact, so image
and apt doc pruning both retain them. It reads only checksummed files in
`mkosi/runtime/licence-notices/dependencies/`, makes no network access and runs
no installed binary.

`identity.tsv` names what the payloads cover: the `srtla` dpkg version and
architectures, and the MediaMTX binary path, version, per-architecture release
tarball SHA256 (as recorded in the parent copyright file) and the SHA256 of the
binary inside that tarball. The installer hashes the installed MediaMTX binary
instead of running it. Every check runs before any file changes, and each
refusal prints its reason. It refuses:

- another `srtla` version or architecture, a dpkg state other than installed
  or absent, several `srtla` records, or a parent copyright file that is
  missing or was not written for that version;
- a MediaMTX binary whose hash, release tarball, version line or path differs,
  the binary without its parent copyright file or the reverse, a `mediamtx`
  dpkg package, or a MediaMTX binary in another common location;
- payloads that differ from `SHA256SUMS`, symlinked destinations, and notices
  that were already appended.

Host tests also tie `identity.tsv` to the MediaMTX recipe pins, the binary path
installed by the runtime layer and the `srtla` pins in
`manifests/first-party-releases.json`. Bumping either pin fails the tests until
the notices are regenerated.

### Inventory and regeneration

`sources.json` is the reviewed input. It pins the two root source archives,
both official MediaMTX release archives, four supplemental exact-commit
archives and the version-pinned licence-text gaps. The generator derives
everything else from those pins:

- every Cargo.lock registry crate, checked against the lock checksum;
- every go.sum module zip, checked against its Go `h1:` checksum, with the zip
  SHA256 recorded separately;
- the measured Go modules, read from the module list the Go linker embeds in
  the arm64 release binary (the binary is parsed, never executed);
- the notice selection described below.

`plan.json` is that derivation, written byte for byte. Regeneration derives it
again from the archives and fails unless it matches exactly, so an omitted,
truncated, reordered or misrouted text, a missing exclusion record or a changed
archive fails before any output exists. Offline checks on the committed plan
also require whole-file ranges for notice files, the payload routing, recorded
exclusion reasons and the gap list.

Regenerate on the build host with Python 3.11+ (stdlib only):

```sh
python3 tools/generate-dependency-notices.py --cache /path/to/source-cache --check
# Add --fetch to download missing archives from their official origins first.
CERALIVE_DEPENDENCY_NOTICE_CACHE=/path/to/source-cache bash tests/dependency-notices.test.sh
bash tests/licence-notices.test.sh
```

Cache filenames are SHA256(URL), about 280 MB in total. Without the cache
variable, the tests use synthetic archives and the committed inventory only. To
refresh after a pin change, update `sources.json`, run the generator with
`--write-plan` and `--output` into new paths, review the inventory diff, then
copy `plan.json`, `plan.sha256`, the payloads, `identity.tsv` and `SHA256SUMS`
into the dependencies directory. There is no mode that accepts drift.

### What is retained

- **Notice files, whole:** any file whose name contains licence, copying,
  copyright, notice, authors, contributors, patent, attribution, credits,
  unlicense, third party, legal or dep5 in any case and with any or no
  extension, or that sits below a `LICENSES` or `.reuse` directory. Examples:
  `THIRD-PARTY-NOTICES`, `ATTRIBUTIONS.md`, `APACHE-LICENSE-2.0`,
  `MIT.LICENSE`, `CONTRIBUTORS`, `UNLICENSE`, `*.png.license`.
- **Comment blocks** that mention copyright or hold licence grant, condition or
  pointer wording, in any file type. Shebang, `#include`, `#pragma` and Rust
  attribute lines are not part of a comment block.
- **Whole files** with licence grant or condition wording outside comments,
  such as a README that embeds an MIT text, so the conditions and warranty are
  not cut off.
- **Paragraphs** holding a copyright statement outside comments.

Every remaining file that mentions copyright is listed in `plan.json` with a
reason: binary content (not reproducible as text), mentions outside comments
that are not a statement (identifiers, tables, strings), empty notice files,
and links or special archive members.

A crate or Go module without a licence-named file fails the derivation unless
`sources.json` lists it as a gap for that exact version, and a listed gap that
is no longer missing also fails. File names that only look like licences, such
as `check_license.sh` or `.licenserc.yaml`, do not satisfy this check.

### Scope and known gaps

This is mechanical source notice coverage, not a claim that every possible
notice has been found or a legal or compliance clearance.

The Rust inventory has 122 registry crates and four workspace packages. The
Cargo.lock closure includes optional, development and non-Linux packages; it
is not a measured shipped feature graph. MediaMTX has 131 fetched go.sum module
zips: 85 match the module list in the arm64 Go 1.26.4 release binary and 46
are source-only. The module list records modules, not included files or
functions. The amd64 release is identified by hash only; its module membership
is not measured. Compiler and runtime notices are not covered. No rebuild or
source-to-binary reproducibility is claimed.

Licence-text gaps, pinned to versions and origins:

- `r-efi` 5.3.0 and 6.0.0 ship no licence-named file. Their `AUTHORS` files
  hold the MIT permission and warranty text, other notices and the authorship,
  and are retained whole, also from the exact commits in the crates' VCS
  metadata.
- `valuable` 0.1.1 declares MIT without a licence file. The MIT `LICENSE` is
  retained from the exact recorded commit
  `9efc29b6e58cef28f6566a47aa7e142a55fead77`.
- `github.com/benburkert/openpgp` at
  `v0.0.0-20160410205803-c2471f86866c` is in the measured module list. Its
  headers refer to a BSD `LICENSE` absent from both the module zip and the
  exact commit `c2471f86866ca6ab0679b9d216cb6a84cfe90db1`. The headers are
  retained, the MediaMTX payload states the missing text, and no substitute
  grant is supplied.

The private-source `cerastream` gap remains separate. This topic neither changes
package pins nor establishes release licence closure.

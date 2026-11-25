# First-party pin currency [EXISTS]

An internally consistent image can still downgrade a board. On 2026-09-15,
the image selected cerastream `2026.9.2` while `2026.9.3` was released and had
been installed through APT. Reflashing restored the stale-format capture
preflight bug. The Rockchip plugin had the same release-versus-pin gap.

## Run the guard

```sh
python3 ci/check-first-party-pins.py
tests/first-party-pin-currency.test.sh -v
```

Requirements: Python 3.12+, Bash and `dpkg` (comparison only; nothing is
installed). The offline tests also use the existing CI dependency PyYAML.
Exit codes: **0** current or explicitly overridden; **1** stale pins;
**2** unverifiable evidence, malformed input, or inconsistent manifests.
Forward versions pass this currency check; existing authenticated package-fetch
and checksum gates still determine whether those exact artifacts exist.

The `v2 Pipeline CI` shellcheck job runs the guard before downstream jobs.
The registered unit suite executes the real CLI and each workflow's actual
guard command against both current and deliberately downgraded fixture trees.
The release candidate and scheduled real-build workflows also check currency
before building, using a tighter evidence-age bound.

## What is authoritative

| Input | What the guard measures |
|---|---|
| `lib/fetch-debs.sh` `FIRST_PARTY_APT_PKGS` | Exact app-package coverage; an added/unmapped or removed package fails closed |
| `manifests/first-party-deb-versions.txt` | Effective exact pin on **each** architecture; arch-specific rows override generic rows as in the fetcher |
| `versions.yaml` | Component provenance, read through `get_pin`; it must agree with selected component package versions |
| `manifests/rk3588-userspace-deb-versions.txt` | Active first-party platform filename version and decoded GitHub URL tag; commented predecessors do not count |
| `manifests/first-party-releases.json` | Independently observed published stable release and package versions, not copied from image pins |

Covered components: `srt`, `cerastream`, `CeraUI`, `srtla`,
`gstlibuvcsrc`, `modem-stack`, `gstreamer-rockchip`, `librga`, and
`apt-credentials` (from the `apt-worker` repository, not its Worker release train).
Component `srtla` is the Rust sender, renamed from `srtla-send-rs` at the 4.1.0
cutover; its GitHub repository was not renamed, so `ci/pin_versions.py`
`COMPONENT_REPOS` — not the component name — resolves the repository for release
lookups, and `CERALIVE/srtla` (the retired C receiver) is never queried.
The modem companion follows its release tag; its nine upstream-versioned
packages are compared individually against the release's package manifest.
Their per-source rebuild counters are **not** inferred from the component tag.
GitHub sanitizes `~` in their asset names, so the release manifest—not the
asset filename—supplies those Debian versions.

Cloud/receiver-only entries in `versions.yaml`, third-party MPP and multimedia
config, and source-commit kernel inputs are not first-party device package
release pins. They keep their existing gates. Neither platform library moves
into `REPOS` or the app layer. `librga-ceralive-dev` is not an image package.

Version comparison uses Debian's numeric comparator after removing an optional
`v`/`srt-v`/`apt-credentials-v` prefix and recognized hash/timestamp build suffixes. In particular,
`+ceralive.10` is **newer** than `+ceralive.9`; that suffix is never discarded
as SemVer build metadata. Unknown version schemes fail closed.

## Release evidence and network policy

PR CI deliberately uses a **committed catalog**, not a live GitHub request (release
builds and the weekly audit refresh it in the job; see below).
The ordinary PR token cannot read private sibling repositories such as
cerastream, and an anonymous 404 is not proof that a newer release is absent.
This keeps PR checks deterministic within an explicitly bounded observation
window and avoids exposing a cross-repository credential to PR code.

Refresh using a local `gh` login with read access to all component repositories:

```sh
python3 ci/check-first-party-pins.py --refresh
```

The refresh enumerates all release pages, excludes drafts/prereleases and
binding-only release trains, and picks the greatest component version, not
GitHub's manually selected `latest` flag or a lexicographic tag maximum.
It requires the selected newest release to carry all image packages. It
never falls back to an older complete release if the newest is incomplete.
Only `apt-credentials-v*` tags in `apt-worker` are considered for the credentials
component; Worker tags cannot substitute for it. The first release,
`apt-credentials-v1.0.0`, is published and served on beta (stable promotion is a
separate step). A previous catalog predating a component may omit it during
refresh's regression comparison, but the newly written catalog must cover every
current component. Previously recorded components still fail on a lower discovered
version. Ordinary catalog checks remain strict. Offline CLI tests pin a synthetic
historical credentials row in their private fixture independently of live releases.
It updates only the catalog, **never the three pin inputs or overrides**.
If pins are stale, a successful catalog refresh still exits **1** after
writing the new evidence; this is the expected signal to review the pins.

Each GitHub command has a 60-second timeout and at most three attempts. Missing
credentials, API/rate-limit errors, malformed responses and incomplete releases
fail closed; a failed discovery leaves the previous catalog untouched. Review
and commit the refreshed catalog in a normal PR. Do not hand-edit release
versions or restamp `checked_at` without re-querying the release sources.

**Freshness bounds:** ordinary CI allows at most **168 hours (seven days)**;
release candidates and scheduled real builds allow **24 hours**. Future-dated
or expired evidence fails, including with a rollback override. Maintain the
catalog with every first-party release and at least weekly; refresh within a
day before a real CI image build. PR CI keeps using the committed snapshot. Release
builds (`release.yml`) and the weekly `real-build-audit.yml` refresh the evidence
themselves in the job (`--refresh --max-age-hours 24`), so they no longer depend on a
manual refresh commit: they use the optional read-only secret
`FIRST_PARTY_RELEASE_READ_TOKEN`, and without it `gh` falls back to the runner user's
login. The refresh never edits pins, so a pin behind a newer first-party release still
fails the build, and there is no bot and no warning-only bypass. The committed
snapshot used by PR CI still needs a reviewed refresh at least weekly.

**Limit:** a release published after `checked_at` is invisible until refresh,
up to the bounds above. The printed timestamp is the scope of the verdict;
the output never calls a snapshot check a live lookup. This is the deliberate
availability/currency trade-off of the committed-manifest option, not a claim
to catch APT changes or new releases instantaneously. For the freshest manual
pre-build check, run `--refresh --max-age-hours 24` immediately before `./build`.
Direct local `./build` is unchanged; CI is the enforced surface in this change.

## Media pin serving receipt — 2026-09-16

> Scope: this receipt covers the plugin pin, which is still current, and the
> engine pin as it stood on 2026-09-16. The engine row in
> `manifests/first-party-deb-versions.txt` advanced to `cerastream=2026.9.5` on
> 2026-09-17 (PR #173); the hashes below do not describe that package.

The plugin `1.14.4+ceralive.6` and engine `2026.9.4` were fetched from the
stable APT indexes **before** their image pins changed. Both architecture
`InRelease` signatures verified with the existing archive key
`3BD975960D38C74A5F06A8044F6501E14003A6B3`; each `Packages.gz` hash matched
its signed Release record. Index URLs:

- `https://apt.ceralive.tv/dists/stable/binary-arm64/Packages.gz`
- `https://apt.ceralive.tv/dists/stable/binary-amd64/Packages.gz`

Each index's `Filename: ./<filename>` resolved against its architecture-qualified
stable directory. Every APT archive was fetched with mTLS and normal TLS
verification, independently hashed with `sha256sum`, and byte-compared with a
separate authenticated GitHub release download using `cmp`.

| Package / architecture | Version | APT SHA-256 = GitHub asset SHA-256 = index SHA-256 |
|---|---|---|
| `gstreamer1.0-rockchip-ceralive` / arm64 | `1.14.4+ceralive.6` | `d131e443dcd88fb7988773b10c9b0125a65536ceb11128f41b3644a0fb41a3b5` |
| `cerastream` / arm64 | `2026.9.4` | `c0c1ab87a07c50c4f3b04da84390273988dff007f1ac628e3cb521a8a1ab5819` |
| `cerastream` / amd64 | `2026.9.4` | `f4ce664356c7a37f6433547590d5bf92f0bd1b922d5c32707740e8b63842f433` |

GitHub sources are `CERALIVE/gstreamer-rockchip` release `1.14.4+ceralive.6`
and private `CERALIVE/cerastream` release `v2026.9.4`, with filenames
`<package>_<version>_<architecture>.deb`. Debian control fields independently
confirmed all three identities. The engine declares the canonical
`gstreamer1.0-libuvcsrc` dependency already pinned by this pipeline.

The plugin's platform manifest uses the checksum **computed from the downloaded
archive**, not a copied sidecar or workflow verdict. Its commented Radxa rollback
row survives unchanged; it remains outside `REPOS` and `FIRST_PARTY_APT_PKGS`.
The engine stays app-layer, with unprefixed Debian version and `v`-prefixed
repo-local provenance tag. The catalog was refreshed through `--refresh`, which
correctly reported the old pins stale before they changed; no guard, test or
rollback override was weakened. No image build, flash or new hardware
qualification is implied by this receipt.

Refreshing the catalog exposed unit fixtures that copied live release values
while hardcoding historical `.3`/`.5` scenarios. The fixture setup now fixes
both sides of those historical inputs explicitly; every existing assertion
remains, including `.2` → `.3` engine and `.2` → `.5` plugin downgrade
rejections. The production CLI and workflow step still check real current pins
against the refreshed catalog, independently of these historical fixtures.

## Engine pin serving receipt — 2026-09-17

The engine `2026.9.5` was fetched from the stable APT indexes **before** its image
pin changed, on both architectures:

- `https://apt.ceralive.tv/dists/stable/binary-arm64/Packages.gz`
- `https://apt.ceralive.tv/dists/stable/binary-amd64/Packages.gz`

Each index's `Filename: ./<filename>` resolved against its architecture-qualified
stable directory. Every APT archive was independently hashed with `sha256sum` and
byte-compared with a separate authenticated GitHub release download using `cmp`;
both comparisons reported the files identical.

| Package / architecture | Version | APT SHA-256 = GitHub asset SHA-256 = index SHA-256 |
|---|---|---|
| `cerastream` / arm64 | `2026.9.5` | `367376cd87912880d4af1ebc4d6b2df50314a072b974ce82803ceb94de42e64d` |
| `cerastream` / amd64 | `2026.9.5` | `495fd58d397b6e5833b0ad84f1d4ff640a7bb27488fb2b58f31c89a2c9d40eab` |

GitHub source is private `CERALIVE/cerastream` release `v2026.9.5`, with filenames
`<package>_<version>_<architecture>.deb`. Debian control fields independently
confirmed both identities; the engine still declares `libc6 (>= 2.41)` and the
canonical `gstreamer1.0-libuvcsrc` dependency already pinned by this pipeline.

The stable index was not immediately current at release time. The `apt-reindex`
`repository_dispatch` fired 9 s after the last asset upload and the reindex run
rewrote `Packages.gz` roughly 100 s later, so a read taken inside that window — or
against an edge cache entry, which the object serves with `cache-control:
public, max-age=3600` — still reported `2026.9.4`. That is publication latency plus
caching, not the historical publisher-provisioning gap: the dispatch was delivered,
the run completed successfully, and no manual re-trigger was performed.

The engine stays app-layer, with unprefixed Debian version and `v`-prefixed
repo-local provenance tag. The catalog was refreshed through `--refresh`; no guard,
test or rollback override was weakened. No image build, flash or new hardware
qualification is implied by this receipt.

## Engine pin receipt — 2026-09-21

At the time of this receipt the pipeline selected `cerastream=2026.9.6` on both
architectures and recorded `v2026.9.6` in its repo-local provenance registry;
the current pin is in `manifests/first-party-deb-versions.txt`. Authenticated `gh release view`
and the tag-ref API independently identify the published release and commit
`b3eb2a0767687415401998353337c3413c09fda9`. Both downloaded Debian assets match
their published sidecars and GitHub asset digests; their control fields confirm
`Package: cerastream`, `Version: 2026.9.6` and the respective architecture.
The pipeline's real first-party curl transport also fetched both exact versions
through the stable GPG-verified architecture indexes. `cmp` proved both APT
archives byte-identical to the separate GitHub downloads.

| Architecture | Release asset | Verified SHA-256 |
|---|---|---|
| arm64 | `cerastream_2026.9.6_arm64.deb` | `75cf2ecbd37957b9bf3d5d2091d670cb0a14a035b0aac7d7d12757b3a2518f3a` |
| amd64 | `cerastream_2026.9.6_amd64.deb` | `22fbcd010ab95d767ef4535701888c25d552321f32e2b1e49b130a0e391cf175` |

This release includes the audio-meter, idle-preview and program-session
teardown-ownership fixes (engine PRs #199–#201). A teardown timeout no longer
permits replacement capture to race unresolved native cleanup. The release keeps
the existing published bindings; this is a binary package bump, not an npm bump.

The image does not build cerastream from a sibling checkout. Its exact Debian
version selects a record in the freshly GPG-verified architecture index, and the
fetcher verifies the archive's SHA-256 and Debian control identity. The producer
tag is therefore checked in the producer repository, not with a cross-repository
Git ancestry test. Image-source ancestry separately proves inclusion of required
pipeline changes. The package-contract test pins both architecture selectors and
the provenance tag independently to this release.

All other component pins, the MPP userspace pin and the HDMI-RX profile policy
remain unchanged. This receipt is not a board soak, flash or OTA authorization.

## CeraUI pin receipt — 2026-10-24

This historical receipt selected stable [CeraUI v2026.10.0](https://github.com/CERALIVE/CeraUI/releases/tag/v2026.10.0),
published 2026-10-24T03:42:10Z, tag commit `7c076c1`. Downloaded release assets
independently passed `sha256sum -c`; `dpkg-deb -f` confirmed `Package:
ceralive-device`, the exact version and the respective architecture.

| Architecture | Debian control version | Release asset SHA-256 = authenticated served-release SHA-256 |
|---|---|---|
| arm64 | `2026.10.0-20261024T034043.7c076c1` | `f69f506e85a28ddc7259732faecb33d2d9a3607c5ba195b7733e71176ee3c398` |
| amd64 | `2026.10.0-20261024T034041.7c076c1` | `0a67dc4d0c812c8b6d0a0941875c8353826f364e01c11ed65efe87d8d4aef9bd` |

The live APT index was **not read directly** during this pin update because it
requires mTLS. The existing authenticated publisher and device receipts were
used instead: [apt-worker reindex run 40059391307](https://github.com/CERALIVE/apt-worker/actions/runs/40059391307)
recorded exactly one `KEEP` and one `Verified served release` for each architecture,
with the versions and hashes above, and completed successfully. Its saved
single-build check passed for both architectures. The Rock 5B+ authenticated
`apt-cache policy` receipt showed the arm64 candidate at priority 990 from the
stable CeraLive index. Subsequent Rock and Orange Pi product-upgrade receipts
recorded that exact arm64 version installed, clean dpkg audits and an active
service. Their verification receipts retain the expected pruned package-doc
notices; they do not supply an archive SHA-256. No amd64 device was tested: its
proof is the publisher receipt plus release asset control and digest checks.

Only the guard's authenticated `--refresh --max-age-hours 24` updated the release
catalog. It first reported the two old device pins and provenance stale (exit 1);
the updated pins must pass the 24-hour and ordinary 168-hour checks. No timestamp
was hand-edited, no rollback exception was added, and no size budget changed.
This is not image build, boot, flash or hardware qualification, or OS publication
authorization. OS 2026.10.97 stays private-drill only; stable/beta pointers remain
untouched.

## CeraUI pin receipt — 2026-10-29

This historical receipt selected stable [CeraUI v2026.10.1](https://github.com/CERALIVE/CeraUI/releases/tag/v2026.10.1),
published 2026-10-29T06:43:44Z, tag commit
`81c16be0a0ff842ab73c6ef8d175c411b746a964`. Both Debian assets and their sidecars
were downloaded with `gh release download v2026.10.1 -R CERALIVE/CeraUI` into
a new empty directory outside the repository. Independent `sha256sum` hashes
matched both sidecars (`sha256sum -c`); `dpkg-deb -f` confirmed package
`ceralive-device`, each exact version and its architecture.

| Architecture | Debian control version | Release asset SHA-256 = authenticated served-release SHA-256 |
|---|---|---|
| arm64 | `2026.10.1-20261029T064207.81c16be` | `b90d912e2bff4ff97358e5a3f4364f3d25ca64ebb28ae3cd441aa5515ffc0f5b` |
| amd64 | `2026.10.1-20261029T064208.81c16be` | `30443d551e80b3d75c30f77684a5b3309b6767b5427f765c95534c5f91251657` |

Direct requests to both stable architecture `InRelease` URLs returned HTTP 403;
no mTLS credentials were read and no local index signature was verified.
As in the previous receipt, serving proof comes from the authenticated
[APT Reindex run 40830981528](https://github.com/CERALIVE/apt-worker/actions/runs/40830981528):
`gh run view 40830981528 -R CERALIVE/apt-worker --log` records both exact versions
as `KEEP` and both hashes as `Verified served release`. The successful run signed
both indexes with archive key `3BD975960D38C74A5F06A8044F6501E14003A6B3` and
its post-publish health check reports `Signature OK`, `by-hash OK` for both
architectures, and `Publication metadata checks passed for channel=stable`.

The catalog was generated by authenticated
`python3 ci/check-first-party-pins.py --refresh --max-age-hours 24 --catalog <temporary-file>`
and copied byte-for-byte into the committed catalog. It initially exited 1 for
the two old device pins and registry provenance. Other component evidence and
all other pins remain unchanged; no timestamp was invented, rollback exception
added or size budget changed. Neither architecture was installed or tested on
hardware. This pin change publishes no image or kernel and changes no channel pointer.

## CeraUI pin receipt — 2026-11-06

The previous image pin selected stable [CeraUI v2026.11.1](https://github.com/CERALIVE/CeraUI/releases/tag/v2026.11.1),
published 2026-11-06T23:58:19Z, tag commit
`77fae5eb21d3e6b7125325dcbc4d1fcbe09638a4`. Authenticated release metadata
confirms a published, non-draft, non-prerelease release. Both Debian assets and
their SHA-256 sidecars were downloaded into an empty directory outside the
repository. Independent `sha256sum -c` checks and GitHub asset digests agree;
`dpkg-deb -f` confirms package `ceralive-device`, the exact versions and their
architectures.

| Architecture | Debian control version | Release asset SHA-256 = sidecar SHA-256 = GitHub asset digest |
|---|---|---|
| arm64 | `2026.11.1-20261106T235641.77fae5e` | `7d61d045de202c082373b7d85c8e481e4b58e02425c8a2880b0239087bcf378b` |
| amd64 | `2026.11.1-20261106T235637.77fae5e` | `8d86a82e3ea511b419fe44816bfc84bd4db1faf3f6300f9bfb057f5a67b82fc3` |

The manifest's architecture selectors and repo-local provenance registry name
these exact release assets. The existing package-contract test independently
checks the registry tag and both fetcher-selected package versions.

The committed release catalog remains unchanged. Its authenticated refresh must
be the final commit after the owner decides which prerequisite PRs land before
this branch; its 168-hour lifetime must cover the subsequent release steps.
APT indexes, serving, installation and hardware were not checked for this pin.
No mTLS credentials were read. This receipt is release-asset identity proof,
not image qualification, kernel publication or a channel-pointer change.

## srtla and CeraUI pin receipt — 2026-11-12

The image selects `srtla=4.2.0` with registry provenance `srtla.pin: v4.2.0`.
The owner also selected stable CeraUI `v2026.11.2`, which changes the UI version
baked into future images. Its tag points to
`31b06d54ff2e338805d84602a292e9dc95d8de2e`; the release was published
2026-11-10T23:58:58Z.

| Architecture | CeraUI Debian version |
|---|---|
| amd64 | `2026.11.2-20261110T235721.31b06d5` |
| arm64 | `2026.11.2-20261110T235725.31b06d5` |

These versions match the actual release asset names and the authenticated
catalog refresh at `2026-11-12T17:50:18.331926+00:00`. The catalog remains exactly
as generated by `python3 ci/check-first-party-pins.py --refresh`. Before either
pin changed, the offline check exited 1 with `STALE` for CeraUI and srtla on
both architectures and in registry provenance. No other component was stale.
The existing package-contract test retains exact equality for the CeraUI tag
and both architecture versions.

Sender [release notes](https://github.com/CERALIVE/srtla-send-rs/releases/tag/v4.2.0)
retain the approximately one-second slower stall-latch readmission limitation;
the physical-device reconnect path is not qualified. The CeraUI PR pinning this
sender in its own CI is separate. No image was built or flashed, and APT serving,
installation and hardware were not checked for this combined pin change.

## Downstream srtla sender rebuild +osb1 (2026-11-25)

On arm64 the image now selects `srtla` `4.2.0+osb1`: CeraLive's v4.2.0 sender plus
two fork changes,
[openstreambox/srtla-send-rs#12](https://github.com/openstreambox/srtla-send-rs/pull/12)
(register a replacement uplink socket as soon as a reload opens it) and
[openstreambox/srtla-send-rs#15](https://github.com/openstreambox/srtla-send-rs/pull/15)
(fresh-link probation). A link that registers while another link is delivering
carries only paced duplicate copies until its own SRTLA ACK proves the path, and
a link that registers but never delivers backs off its retries. Without it, a
newly added modem that registers but drops media takes original packets from the
first moment, and the receiver late-drops them. It needs nothing from the
receiver; the bench below used a stock BELABOX `srtla_rec` and a variant with
early per-link ACKs. amd64 keeps the released build.

- **Source:** openstreambox/srtla-send-rs `osb/release/v4.2.0-osb1` at
  `0ae0dcebbb019192370104383af6de388320a866`: tag v4.2.0 (`1b5febb7`), one
  docs-only commit from CeraLive's main, #12 (`ddfbe963`), #15 (`9ea1ee54`), and
  one commit that sets the crate version to `4.2.0+osb1` in `Cargo.toml` and
  `Cargo.lock`. The dependency closure is 4.2.0's.
- **Build:** the toolchain, Debian packages, crates, environment and
  `SOURCE_DATE_EPOCH` values that rebuild CeraLive's `srtla_4.2.0_arm64.deb`
  byte for byte. The build lock changes the source pin, the release tag name the
  packaging script checks (`v4.2.0+osb1`) and the output file name, and the
  build tool takes that file name. In the same build session, a control rebuild
  of v4.2.0 matched the release deb exactly and a second build of `+osb1`
  matched the first. The package is produced by the source's own
  `ci/build-deb.sh`.
- **Against 4.2.0's deb:** paths, modes, ownership and timestamps are
  identical (sizes and archive header checksums follow the content). `DEBIAN/control` differs in `Version` and `Installed-Size` (5000 to
  5064), and `/usr/bin/srtla_send` differs. `srtla_send -v` prints
  `4.2.0+osb1 [srtla_send]`.
- **CeraUI contract:** the command line, the capability document, the stats
  file, the control socket and receiver address handling are unchanged. The
  reload interface (`SIGHUP` with the ips file and bind map) is unchanged; the
  handling behind it changed in #12. On a ROCK 5B+ with CeraUI 2026.11.5
  (`1dbec5e62`, the train build that this line's development builds take through
  the local override; the manifest's released pin is 2026.11.2),
  CeraUI's capability probe accepted the sender and spawned it with
  `--conn-timeout-ms 15000 --stats-file … --control-socket … --bind-map …`, its
  per-link telemetry read the stats file, and it reloaded the sender as a second
  uplink came and went, with the same sender process throughout a 20-minute stream.
- **Ordering:** `4.2.0 < 4.2.0+osb1 < 4.2.1` in `ci/pin_versions.py` and
  `dpkg --compare-versions`, so CeraLive's next release reads `STALE`. The
  pin-currency check compares a `X.Y.Z+osbN` pin with the `versions.yaml`
  release it was rebuilt from (`4.2.0`).
- **Not on apt.ceralive.tv.** Supply this deb with `--first-party-local-debs`
  under the same rules as the ModemManager rebuild below. Production mode and
  GitHub Actions refuse local overrides, so this pin works in development-mode
  builds only. A fetch never asks apt or curl for a `+osbN` pin: without the
  local file it stops before any download, so a signed index carrying the same
  version under other bytes can't stand in for the reviewed deb. The installed
  version is pinned in the image like every local override.

| Package (arm64) | sha256 |
|---|---|
| `srtla_4.2.0+osb1_arm64.deb` | `fc09abd4103c3e52f33dd9da6428ef6d9910b6fea95b07bb0fd12f0a62b995d7` |

Executable `usr/bin/srtla_send`:
`6d76ad554c5ceccdb9c26359d24ab267c848becd2b87d794f7baada5ba268574`.

**Bench (the installed package on a ROCK 5B+, 9 V, two sockets on one Ethernet
cable, a stock BELABOX `srtla_rec` and a copy with early per-link ACKs on the
receiving host).** Join time is from the receiver's REG3 to the first original
DATA on the new socket.

| Input | Stock receiver | Early-ACK receiver |
|---|---:|---:|
| 6 Mbit/s replay, LAN (5 runs) | 318–335 ms | 33–54 ms |
| same, +50 ms RTT on the new socket (2 runs) | 405–406 ms | 101–118 ms |
| same, +100 ms RTT (2 runs) | 477 ms | 205–206 ms |
| 0.3 Mbit/s replay | 765 ms | 105 ms |
| CeraUI test pattern, hardware encoder (3 joins) | 370 ms | not run |

Probe copies left at a median spacing of 30 ms, not the 20 ms pacing floor,
because a 30 fps source delivers packets in per-frame bursts. A ten-sequence ACK
batch therefore costs about 0.27 s plus the path's round trip.
With all SRTLA ACKs on the new socket withheld for 4 s, it carried no original
before the ACKs returned, with either receiver. Streaming through CeraUI with
the hardware encoder, the new socket's media was dropped at the receiving host
for 60 s after each of five joins (control and keepalives passed). It carried no
originals in any of them; all of its 1,157 to 1,686 copies per cycle matched
sequences already sent on the delivering socket, and its first ACK came 290 to
317 ms after the drop ended. A 20-minute stream with joins and leaves kept one
sender process and ended with 38,622 packets received, 10 losses (all
retransmitted in time) and no late drops at the receiver.

## Downstream ModemManager rebuild +osb2 — 2026-11-25

On arm64 the image now selects `modemmanager` and `libmm-glib0`
`1.24.2-2~ceralive.3+osb2`. That is the `+osb1` rebuild below plus one quilt
patch from
[openstreambox/modem-stack#12](https://github.com/openstreambox/modem-stack/pull/12):
the generic `+CREG`/`+CGREG`/`+CEREG` parsers in `mm-modem-helpers.c` accept a
two-digit AcT (10 to 13), and on NR the `<lac>` field of `+CREG`/`+CGREG` is
read as a TAC. Without it, an FM350-GL that registers on 5G SA after
ModemManager's first registration check (for example after a replug) reports
an AcT of 11 that the one-digit patterns don't match, so the modem stays at
`searching` and doesn't connect until someone runs
`mmcli -m <n> --3gpp-register-home`. amd64 keeps the released build.

- **Source:** openstreambox/modem-stack `osb/release/v1.4.0-osb1` at
  `e12cc0712ad1411daa7988602b194c8a76c235e0`, the merge of #12 onto `+osb1`'s
  `c9aa6778`. In `packaging/ModemManager/debian` it adds only
  `patches/0004-modem-helpers-accept-two-digit-act-in-creg.patch` and its
  `patches/series` line. Built the same way as `+osb1`: `libqrtr-glib`,
  `libmbim` and `libqmi` carried from the v1.4.0 release assets (the same 20
  arm64 debs, byte for byte), ModemManager rebuilt with
  `BUILD_SOURCES=modemmanager EXACT_SUFFIX='~ceralive.3+osb2' build-stack.sh arm64` in
  `debian:trixie@sha256:3cda3ca4…dafba2`. The `.buildinfo` build dependencies
  equal `+osb1`'s.
- **Ordering:** `~ceralive.3+osb1` < `~ceralive.3+osb2` < `~ceralive.3+osb10`
  < `~ceralive.4` in `ci/pin_versions.py` and `dpkg --compare-versions`, so an
  installed `+osb1` upgrades to `+osb2` and a newer upstream counter still reads
  `STALE`.
- **Not on apt.ceralive.tv.** Supply exactly these two debs with
  `--first-party-local-debs`. That flag works in development builds only;
  production mode and GitHub Actions refuse it. Their sha256 values are in
  `manifests/first-party-local-sha256.txt`. For a package pinned to a `+osbN`
  version, the fetch accepts only an override with that version and the one
  sha256 listed for it. A missing manifest, a missing or duplicate row, or a
  malformed digest refuses it. A different version (for example the released
  `ceralive.3` or the earlier `+osb1`) or different bytes is refused. Without
  the override the fetch fails before any download: a `+osbN` pin is never
  requested from apt or curl.
  The build's `first-party-local-override.json` and lock record the sha256:

| Package (arm64) | sha256 |
|---|---|
| `modemmanager_1.24.2-2~ceralive.3+osb2_arm64.deb` | `a464c1b34464160447b19a49fe83c05d4510f3616b139406e35e1a05239148d3` |
| `libmm-glib0_1.24.2-2~ceralive.3+osb2_arm64.deb` | `452984c27e35ced36034e00eabc9af543b47eb158a7ea05845b1c22cf232086c` |

- **Content check against `+osb1`** (per-file sha256, `.gnu_debugaltlink` and
  `.gnu_debuglink` masked as before):
  - File lists, maintainer scripts, conffiles, triggers, shlibs and symbols are
    identical. Control (version, libmm-glib0's `Recommends`), md5sums and the
    changelog differ.
  - `libmm-glib.so.0.11.0` is identical.
  - `/usr/sbin/ModemManager` carries the patch: a new `mm_3gpp_creg_lac_is_tac`,
    and `registration_state_changed` and `registration_status_check_ready`
    grow. `.rodata` grows by the six rewritten `creg_regex[]` patterns. `.text`
    is smaller only because one fewer Cortex-A53 erratum-843419 stub page is
    needed.
  - 18 plugin and shared `.so` files differ only in `.note.gnu.build-id`, since
    the patched header shifts DWARF line numbers. Apart from that build-ID note,
    which sits in a loadable segment, every loaded section is byte-identical.
- **Tests:** the ModemManager meson suite with the patch passes (30/30, helper
  tests 214/214).
- **Hardware:** not yet proven on an FM350-GL on 5G SA.

## Downstream ModemManager rebuild — 2026-11-24

Superseded by `+osb2` above. Until then, on arm64 the image selected
`modemmanager` and `libmm-glib0` `1.24.2-2~ceralive.3+osb1`. That is
modem-stack v1.4.0's ModemManager source (released as `1.24.2-2~ceralive.3`)
with one change: the fm350gl `+CGCONTRDP` parser fix, proposed upstream as
[CERALIVE/modem-stack#36](https://github.com/CERALIVE/modem-stack/pull/36).
Without it, an FM350-GL on a network that leaves the bearer id empty in that
answer (seen on T-Mobile US) never connects: the first attempt fails to parse,
and every retry gets `+CME ERROR: 5847`. amd64 keeps the released build.

- **Source:** openstreambox/modem-stack `osb/release/v1.4.0-osb1` at
  `c9aa6778fe95d9ff0e2f18e4934162edb4d4adf5`. This is tag `v1.4.0`, then a
  cherry-pick of the fix (`3e932ea6`), then one build-tooling commit that lets
  `inject-deb-version.sh` take an exact `~ceralive.N+osbM` suffix. Only
  `libqrtr-glib`, `libmbim` and `libqmi` were carried from the v1.4.0 release
  assets, sha256-checked against its release manifest. ModemManager was rebuilt
  with `build-stack.sh arm64` in `debian:trixie@sha256:3cda3ca4…dafba2`.
- **Ordering:** `~ceralive.3+osb1` sorts above `~ceralive.3` and below the
  next upstream counter `~ceralive.4`, and upstream never uses `+`, so it can't
  collide with a published version. `ci/pin_versions.py` accepts the `+osbN`
  form and orders it. A newer upstream release still reads `STALE`, which is
  the point to drop the rebuild or carry it forward.
- **Not on apt.ceralive.tv.** These two debs were supplied with
  `--first-party-local-debs` under the rules in the `+osb2` receipt above, and
  their sha256 rows were in `manifests/first-party-local-sha256.txt` until
  `+osb2` replaced them. This change also made the fetch accept a `+osbN` pin
  only with its one listed sha256; other overrides kept their existing
  behaviour. The `+osb1` hashes were:

| Package (arm64) | sha256 |
|---|---|
| `modemmanager_1.24.2-2~ceralive.3+osb1_arm64.deb` | `bdb31a65decfe1e36dcc4a09890757c83705ba2be5862732c3c284ca525b92e4` |
| `libmm-glib0_1.24.2-2~ceralive.3+osb1_arm64.deb` | `dbcb28fdd1a6332b64c829c01a0c708e4e2e70c0bc46180568c4e6fddc2060b8` |

- **Production builds:** an arm64 build in production mode can't select a
  `+osbN` pin, because the override is refused there and the signed index
  doesn't carry it. That needs the pair in a signed first-party index. This
  line builds development-mode release candidates, like its other local
  packages.
- **Content check:** a control rebuild of plain v1.4.0 in the same container,
  under the development version string, matched the published `ceralive.3`
  packages file for file, leaving aside version metadata, the changelog and the
  masked debug-link bytes below. The rebuild compared with `ceralive.3`:
  - Installed paths, modes, ownership and maintainer scripts are identical.
  - The changelog entry and version metadata differ, including libmm-glib0's
    `Recommends` version.
  - 56 of the 57 ELF files are byte-identical once only `.gnu_debugaltlink` and
    `.gnu_debuglink` are masked. Those hold the dwz multifile build-id and the
    debug CRC, and change because the shared dwz file includes the plugin's
    debug info. Every debug CRC and dwz reference resolves within its own build.
  - The only changed runtime binary is
    `usr/lib/aarch64-linux-gnu/ModemManager/libmm-plugin-fm350gl.so`.
  - The debug packages differ in DWARF, as expected.
- **Hardware:** the same plugin code connected an FM350-GL on T-Mobile US on
  4 of 4 activations (boot, after a USB re-enumeration, and two
  disconnect/reconnect cycles), with no 5847.

## Intentional rollback

Edit `manifests/first-party-pin-overrides.json` in the **same reviewed PR** as
the rollback. It is an empty list normally. Each exception binds an exact
subject, exact raw pin, exact observed released version, a non-empty reason,
and an inclusive UTC expiry date:

```json
[
  {
    "subject": "gstreamer1.0-rockchip-ceralive[arm64]",
    "pinned": "1.14.4+ceralive.4",
    "released": "1.14.4+ceralive.5",
    "reason": "Bisect the encoder regression; tracking issue #NNN",
    "expires": "2026-09-22"
  }
]
```

The output becomes `ROLLBACK` and prints the reason and expiry. There is no
environment-variable bypass, wildcard, or waiver for missing evidence.
A different pin or newer release invalidates the exception. Blank reasons,
expired/duplicate/unknown entries and unused exceptions fail. Remove the entry
when restoring currency. Existing artifact identity and qualification rules
remain in force; this exception authorizes only the currency comparison.

An app rollback usually needs three entries: `package[amd64]`,
`package[arm64]`, and `versions.yaml:component`. Copy the exact `pinned=` and
`released=` values from each diagnostic; provenance tags retain their prefix.
This prevents accidentally approving only one architecture or a stale banner.

The commented Radxa predecessor rows remain usable too. Restoring `librga2`
or `gstreamer1.0-rockchip1` is reported as stale **regardless of numeric
ordering**: Radxa's `2.2.0-1` is a packaging label, not a newer CeraLive API.
Use an exception naming the predecessor subject and version, with `released`
set to the CeraLive component tag. Restore the corresponding family/package
wiring as required by the existing gates; this guard does not rewrite it.

## Pinned versus installed: a separate advisory signal

The guard can read an **already captured** inventory without any board access:

```sh
python3 ci/check-first-party-pins.py --installed test-results/installed.tsv
```

The TSV has three columns: Debian package name, architecture, installed
version. An operator can later collect it with
`dpkg-query -W -f='${Package}\t${Architecture}\t${Version}\n'` on the device;
no collection, SSH, service, capture, or hardware command is run by the guard.

It reports `INSTALLED-NEWER`, `INSTALLED-OLDER`, `INSTALLED-MATCH`,
`INSTALLED-BUILD-DRIFT`, `INSTALLED-UNCOMPARABLE`, or `NOT-OBSERVED` per image
package/architecture. Partial inventories are labelled, never assumed matched.
Installed drift is advisory because operator-driven APT updates are legitimate;
it does not waive or strengthen the independent release-pin verdict.
Automated inventory collection or surfacing this in CeraUI belongs in a
separate diagnostics change. No new board observations are claimed here.

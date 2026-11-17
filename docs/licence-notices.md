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
- Statically linked dependencies: the Rust crates in `srtla_send` and the Go
  modules in `mediamtx` are not listed.
- Packages without public source or licence text (`cerastream`,
  `ceralive-apt-credentials`) have no row.
- Sysext and appfs bundles built from the same `.deb` files do not carry these
  files.

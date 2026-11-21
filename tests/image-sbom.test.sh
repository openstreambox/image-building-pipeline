#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
snapshot=20260925T000000Z

for timestamp in latest 20260231T000000Z 20990101T000000Z '20260925T000000Z/../'; do
  if CERALIVE_DEBIAN_SNAPSHOT="$timestamp" DRY_RUN=1 "$repo/build" rock-5b-plus >"$work/build.log" 2>&1; then
    echo "accepted bad snapshot: $timestamp" >&2
    exit 1
  fi
  grep -F 'CERALIVE_DEBIAN_SNAPSHOT must be a past UTC timestamp' "$work/build.log"
done

(
  # shellcheck source=mkosi/runtime/build-apt-cache.sh
  source "$repo/mkosi/runtime/build-apt-cache.sh"
  export CERALIVE_DEBIAN_SNAPSHOT="$snapshot" CERALIVE_BUILD_APT_PROXY=http://cache.invalid:3142
  export APT_SUITE=fixture APT_SUITE_SECURITY=fixture-security
  runtime_snapshot_apt_scope
  apt-config dump >"$work/apt-config"
  grep -Fx 'APT::Update::Error-Mode "any";' "$work/apt-config"
  grep -Fx "Dir::Etc::sourceparts \"${CERALIVE_BUILD_APT_DIR}/sources\";" "$work/apt-config"
  sources="$CERALIVE_BUILD_APT_DIR/sources/debian.sources"
  grep -Fx "URIs: https://snapshot.debian.org/archive/debian/$snapshot/" "$sources"
  grep -Fx "URIs: https://snapshot.debian.org/archive/debian-security/$snapshot/" "$sources"
  [[ "$(grep -Fxc 'Check-Valid-Until: no' "$sources")" == 2 ]]
  [[ "$(grep -Fxc 'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' "$sources")" == 2 ]]
  [[ "$(stat -c %a "$CERALIVE_BUILD_APT_DIR")" == 755 ]]
)

root="$work/root"
receipts="$root/usr/lib/ceralive/build-lock"
mkdir -p "$receipts" "$root/var/lib/dpkg" "$root/usr/bin" "$root/usr/local/bin" "$root/boot"
printf '%s\n' "$snapshot" >"$receipts/debian-snapshot"
printf 'fixture\tSat, 26 Sep 2026 00:00:00 UTC\n' >"$receipts/base.dates"
sha="$(printf 'fixture\n' | sha256sum | cut -d' ' -f1)"
for package in ceralive-device srtla; do
  printf 'Package: %s\nVersion: 1:2.3\nArchitecture: arm64\nStatus: install ok installed\n\n' "$package" >>"$root/var/lib/dpkg/status"
  printf '{"name":"%s","version":"1:2.3","arch":"arm64","origin":"first-party","sha256":"%s"}\n' "$package" "$sha" >>"$receipts/app.jsonl"
done
printf 'Package: removed\nVersion: 1\nArchitecture: all\nStatus: deinstall ok config-files\n' >>"$root/var/lib/dpkg/status"
for payload in usr/bin/srtla_send usr/local/bin/ceralive usr/local/bin/mediamtx boot/vmlinuz-fixture boot/Image; do
  printf 'fixture\n' >"$root/$payload"
done
python3 "$repo/lib/packages-lock.py" merge "$root" "$work/staging" "$work/packages.lock.json" 0 '1970-01-01T00:00:00Z' '' ''
printf '%s  fixture.raw\n' "$sha" >"$work/fixture.raw.sha256"
printf -v boot_blob 'u-boot.itb\t16384\t512\t%s\tfixture-uboot\t1' "$sha"
output="$work/fixture.sbom.cdx.json"
emit=(python3 "$repo/lib/image-sbom.py" emit --root "$root" --lock "$work/packages.lock.json"
      --output "$output" --board fixture --snapshot "$snapshot" --image-version 1
      --mediamtx-version v1 --boot-blobs "$boot_blob" --artifact "$work/fixture.raw.sha256")
"${emit[@]}"
(cd "$work" && sha256sum --strict -c fixture.sbom.cdx.json.sha256)
python3 - "$output" "$sha" "$snapshot" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    bom = json.load(stream)
assert bom["bomFormat"] == "CycloneDX" and bom["specVersion"] == "1.6"
parts = {part["name"]: part for part in bom["components"]}
assert set(parts) == {"ceralive-device", "srtla", "usr/bin/srtla_send",
                     "usr/local/bin/ceralive", "usr/local/bin/mediamtx",
                     "boot/vmlinuz-fixture", "boot/Image", "u-boot.itb"}
assert parts["srtla"]["purl"] == "pkg:deb/srtla@1%3A2.3?arch=arm64"
assert parts["u-boot.itb"]["type"] == "firmware"
assert all(part["hashes"] == [{"alg": "SHA-256", "content": sys.argv[2]}]
           for part in parts.values())
props = {prop["name"]: prop["value"] for prop in bom["metadata"]["properties"]}
assert props["ceralive:debian:snapshot"] == sys.argv[3]
assert props["ceralive:artifact:sha256:fixture.raw"] == sys.argv[2]
PY
cp "$output" "$work/reference"
"${emit[@]}"
cmp "$output" "$work/reference"
printf 'wrong snapshot\n' >"$receipts/debian-snapshot"
if "${emit[@]}"; then
  echo "accepted a rootfs from a different snapshot" >&2
  exit 1
fi
cmp "$output" "$work/reference"
(
  # shellcheck source=lib/stages/packages-lock.sh
  source "$repo/lib/stages/packages-lock.sh"
  CERALIVE_DEBIAN_SNAPSHOT='' stage_image_sbom
)
echo 'Snapshot and SBOM checks passed'

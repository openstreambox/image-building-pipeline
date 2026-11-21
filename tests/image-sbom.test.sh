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

(
  # shellcheck source=mkosi/runtime/build-apt-cache.sh
  source "$repo/mkosi/runtime/build-apt-cache.sh"
  mkdir -p "$work/cold" "$work/partial"
  base="snapshot.debian.org_archive_debian_${snapshot}_dists_fixture"
  security="snapshot.debian.org_archive_debian-security_${snapshot}_dists_fixture-security"
  # Simulate a fresh APT cache after the base pocket succeeded and security failed.
  printf 'Date: fixture\n' >"$work/cold/${base}_InRelease"
  printf 'Package: fixture\n' >"$work/cold/${base}_main_binary-arm64_Packages"
  if snapshot_require_pockets "$snapshot" fixture fixture-security "$work/cold" 2>"$work/error"; then
    echo "accepted a failed cold-cache security pocket" >&2
    exit 1
  fi
  grep -F 'missing authenticated snapshot Release or Packages for fixture-security' "$work/error"
  # A partially populated warm cache and a Release from the wrong day cannot fill the gap.
  printf 'Date: fixture\n' >"$work/cold/${security}_InRelease"
  printf 'Package: fixture\n' >"$work/partial/${security}_main_binary-arm64_Packages"
  printf 'Date: fixture\n' >"$work/partial/${security/${snapshot}/20260825T000000Z}_InRelease"
  if snapshot_require_pockets "$snapshot" fixture fixture-security "$work/cold" "$work/partial"; then
    echo "accepted an incomplete warm-cache pocket" >&2
    exit 1
  fi
  mv "$work/partial/${security}_main_binary-arm64_Packages" "$work/cold/"
  snapshot_require_pockets "$snapshot" fixture fixture-security "$work/cold" "$work/partial"
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
printf 'Package: libstdc++6\nVersion: 2:3.4-1+b2\nArchitecture: arm64\nStatus: install ok installed\nSource: gcc-fixture (2:3.4-1)\n\n' >>"$root/var/lib/dpkg/status"
printf '{"name":"libstdc++6","version":"2:3.4-1+b2","arch":"arm64","origin":"debian","sha256":"%s"}\n' "$sha" >>"$receipts/app.jsonl"
printf 'Package: bsp+fixture\nVersion: 7.0+b1\nArchitecture: all\nStatus: install ok installed\nSource: bsp-source\n\n' >>"$root/var/lib/dpkg/status"
printf '{"name":"bsp+fixture","version":"7.0+b1","arch":"all","origin":"bsp","sha256":"%s"}\n' "$sha" >>"$receipts/app.jsonl"
printf 'Package: userspace-fixture\nVersion: 1\nArchitecture: arm64\nStatus: install ok installed\n\n' >>"$root/var/lib/dpkg/status"
printf '{"name":"userspace-fixture","version":"1","arch":"arm64","origin":"userspace-pin","sha256":"%s"}\n' "$sha" >>"$receipts/app.jsonl"
printf 'userspace-fixture fixture.deb %s https://github.com/Example-Vendor/repo/releases/download/v1/fixture.deb\n' "$sha" >"$work/userspace-pins"
printf 'Package: removed\nVersion: 1\nArchitecture: all\nStatus: deinstall ok config-files\n' >>"$root/var/lib/dpkg/status"
for payload in usr/bin/srtla_send usr/local/bin/ceralive usr/local/bin/mediamtx boot/vmlinuz-fixture boot/Image; do
  printf 'fixture\n' >"$root/$payload"
done
python3 "$repo/lib/packages-lock.py" merge "$root" "$work/staging" "$work/packages.lock.json" 0 '1970-01-01T00:00:00Z' '' ''
mkdir -p "$work/candidate" "$work/boot"
printf 'fixture\n' >"$work/fixture.raw"
xz -c "$work/fixture.raw" >"$work/candidate/fixture.raw.xz"
printf 'bundle\n' >"$work/fixture.raucb"
cp "$work/fixture.raucb" "$work/candidate/good.raucb"
(cd "$work" && sha256sum fixture.raw >fixture.raw.sha256
                sha256sum fixture.raucb >fixture.raucb.sha256)
(cd "$work/candidate" && sha256sum fixture.raw.xz >../fixture.raw.xz.sha256)
printf 'fixture\n' >"$work/boot/boot.scr"
printf -v boot_blob 'u-boot.itb\t16384\t512\t%s\tfixture-uboot\t1' "$sha"
output="$work/fixture.sbom.cdx.json"
emit=(python3 "$repo/lib/image-sbom.py" emit --root "$root" --lock "$work/packages.lock.json"
      --output "$output" --board fixture --snapshot "$snapshot" --image-version 1
      --mediamtx-version v1 --debian-suite fixture --armbian-suite vendor-fixture
      --userspace-pins "$work/userspace-pins" --boot-blobs "$boot_blob" --boot-payload "$work/boot" --artifact "$work/fixture.raw.sha256"
      --artifact "$work/fixture.raw.xz.sha256" --artifact "$work/fixture.raucb.sha256")
"${emit[@]}"
(cd "$work" && sha256sum --strict -c fixture.sbom.cdx.json.sha256)
python3 - "$output" "$sha" "$snapshot" "$work/packages.lock.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    bom = json.load(stream)
assert bom["bomFormat"] == "CycloneDX" and bom["specVersion"] == "1.6"
parts = {part["name"]: part for part in bom["components"]}
assert set(parts) == {"ceralive-device", "srtla", "usr/bin/srtla_send",
                     "usr/local/bin/ceralive", "usr/local/bin/mediamtx",
                     "boot/vmlinuz-fixture", "boot/Image", "u-boot.itb", "libstdc++6",
                     "bsp+fixture", "usr/lib/ceralive/boot/boot.scr", "userspace-fixture"}
assert parts["srtla"]["purl"] == "pkg:deb/ceralive/srtla@1:2.3?arch=arm64&distro=fixture"
assert parts["libstdc++6"]["purl"] == "pkg:deb/debian/libstdc%2B%2B6@2:3.4-1%2Bb2?arch=arm64&distro=fixture"
assert parts["bsp+fixture"]["purl"] == "pkg:deb/armbian/bsp%2Bfixture@7.0%2Bb1?arch=all&distro=vendor-fixture"
assert parts["userspace-fixture"]["purl"] == "pkg:deb/example-vendor/userspace-fixture@1?arch=arm64&distro=fixture"
assert parts["boot/Image"]["version"] == "fixture"
with open(sys.argv[4]) as stream:
    lock = json.load(stream)
packages = {item["name"]: item for item in lock["packages"]}
assert packages["libstdc++6"]["debian_source"] == {"name": "gcc-fixture", "version": "2:3.4-1"}
assert packages["bsp+fixture"]["debian_source"] == {"name": "bsp-source", "version": "7.0+b1"}
assert packages["srtla"]["debian_source"] == {"name": "srtla", "version": "1:2.3"}
source = {prop["name"]: prop["value"] for prop in parts["libstdc++6"]["properties"]}
assert source["ceralive:deb:source:name"] == "gcc-fixture"
assert source["ceralive:deb:source:version"] == "2:3.4-1"
exclusions = [prop["value"] for prop in bom["metadata"]["properties"]
              if prop["name"] == "ceralive:debian:snapshot-exclusion"]
assert exclusions == lock["debian_snapshot"]["exclusions"]
assert len(exclusions) == 5
assert parts["u-boot.itb"]["type"] == "firmware"
assert all(part["hashes"] == [{"alg": "SHA-256", "content": sys.argv[2]}]
           for part in parts.values())
props = {prop["name"]: prop["value"] for prop in bom["metadata"]["properties"]}
assert props["ceralive:debian:snapshot"] == sys.argv[3]
assert props["ceralive:artifact:sha256:fixture.raw"] == sys.argv[2]
PY
verify=(python3 "$repo/lib/image-sbom.py" verify-candidate --sbom "$output"
        --compressed "$work/candidate/fixture.raw.xz" --bundle "$work/candidate/good.raucb")
"${verify[@]}" --snapshot "$snapshot"
cmp "$work/fixture.raw.sha256" "$work/candidate/raw.sha256"
(cd "$work/candidate" && sha256sum --strict -c fixture.raw.xz.sha256 good.raucb.sha256)
expect_rejected() {
  local expected="$1"; shift
  if "$@" >"$work/error" 2>&1; then
    echo "accepted candidate with $expected" >&2
    exit 1
  fi
  grep -F "$expected" "$work/error"
}
expect_rejected 'snapshot does not match SBOM' "${verify[@]}" --snapshot 20260825T000000Z
printf 'tampering' >>"$work/candidate/good.raucb"
expect_rejected 'candidate digest differs from SBOM: good.raucb' "${verify[@]}" --snapshot "$snapshot"
cp "$work/fixture.raucb" "$work/candidate/good.raucb"
printf 'tampering' >>"$work/candidate/fixture.raw.xz"
expect_rejected 'candidate digest differs from SBOM: fixture.raw.xz' "${verify[@]}" --snapshot "$snapshot"
xz -c "$work/fixture.raucb" >"$work/candidate/fixture.raw.xz"
(cd "$work/candidate" && sha256sum fixture.raw.xz >../fixture.raw.xz.sha256)
"${emit[@]}"
expect_rejected 'uncompressed candidate raw digest differs from SBOM' "${verify[@]}" --snapshot "$snapshot"
xz -c "$work/fixture.raw" >"$work/candidate/fixture.raw.xz"
(cd "$work/candidate" && sha256sum fixture.raw.xz >../fixture.raw.xz.sha256)
"${emit[@]}"
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

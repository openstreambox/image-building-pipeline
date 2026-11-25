#!/usr/bin/env bash
# lib/export-debs.py: every .deb of a lock (staged non-Debian files, Debian rows from the build's
# own dated snapshot pockets, verified and matched by digest) as one reproducible tar.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"
check() { if "$@"; then ok "$*"; else bad "$*"; fi; }
refused() { local what="$1"; shift; if "$@" >"$WORK/refused.log" 2>&1; then bad "accepted: $what"; else ok "refused: $what"; fi; }
WORK=''
finish() {
  local status=$?
  [[ "$status" -eq 0 || "$FAIL" -gt 0 ]] || bad "unexpected exit: $status"
  [[ -z "$WORK" ]] || { gpgconf --homedir "$WORK/gnupg" --kill all 2>/dev/null; rm -rf "$WORK"; }
  printf ' RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]]
}
trap 'finish; exit $?' EXIT
WORK="$(mktemp -d)" || { bad 'fixture: mktemp'; exit 1; }
umask 022
mkdeb() { # dir name version arch
  local r="$WORK/src-$2"; mkdir -p "$r/DEBIAN" "$1"
  printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: T <t@example.invalid>\nDescription: t\n' "$2" "$3" "$4" >"$r/DEBIAN/control"
  dpkg-deb --root-owner-group --build "$r" "$1/$2_${3#*:}_$4.deb" >/dev/null; rm -rf "$r"
  sha256sum "$1/$2_${3#*:}_$4.deb" | cut -d' ' -f1
}
S="$WORK/staging"
fp="$(mkdeb "$S/firstparty" ceralive-device 2026.12.1-1 arm64)"
bsp="$(mkdeb "$S/bsp" armbian-firmware-full 26.8.3 all)"
krn="$(mkdeb "$S/kernel-build" linux-image-test 7.2.0-1 arm64)"
rau="$(mkdeb "$S/rauc-build" rauc 1.15.2-1 arm64)"
# --- a dated snapshot with two signed pockets (a throwaway key stands in for Debian's) ---
mkdir -m 700 "$WORK/gnupg"
gpg --homedir "$WORK/gnupg" --batch --quiet --pinentry-mode loopback --passphrase '' \
  --quick-gen-key 'Test Debian Archive' ed25519 sign never 2>/dev/null
gpg --homedir "$WORK/gnupg" --batch --export >"$WORK/debian-keyring.gpg"
SNAP=20261120T000000Z
M="$WORK/mirror"
deb_a="$(mkdeb "$WORK/debs" adduser 3.152 all)"
deb_b="$(mkdeb "$WORK/debs" libfoo1 1.0-1+deb13u1 arm64)"
pocket() { # archive suite deb...
  local root="$M/$1/$SNAP" suite="$2" d stanza=''; shift 2
  mkdir -p "$root/dists/$suite/main/binary-arm64"
  for d in "$@"; do
    local n c="${POOL_COMPONENT:-main}"; n="$(basename "$d")"; mkdir -p "$root/pool/$c/${n:0:1}"; cp "$d" "$root/pool/$c/${n:0:1}/$n"
    stanza+="$(dpkg-deb -f "$d")"$'\n'"Filename: pool/$c/${n:0:1}/$n"$'\n'"Size: $(stat -c %s "$d")"$'\n'"SHA256: $(sha256sum "$d" | cut -d' ' -f1)"$'\n\n'
  done
  printf '%s' "$stanza" | xz -c >"$root/dists/$suite/main/binary-arm64/Packages.xz"
  printf 'Suite: %s\nSHA256:\n %s %s main/binary-arm64/Packages.xz\n' "$suite" \
    "$(sha256sum "$root/dists/$suite/main/binary-arm64/Packages.xz" | cut -d' ' -f1)" "$(stat -c %s "$root/dists/$suite/main/binary-arm64/Packages.xz")" >"$root/dists/$suite/Release"
  gpg --homedir "$WORK/gnupg" --batch --yes --quiet --pinentry-mode loopback --passphrase '' --clearsign \
    --output "$root/dists/$suite/InRelease" "$root/dists/$suite/Release" 2>/dev/null
}
deb_d="$(mkdeb "$WORK/debs" libdup1 2.0-1 arm64)"
pocket debian trixie "$WORK/debs/adduser_3.152_all.deb" "$WORK/debs/libdup1_2.0-1_arm64.deb"
# security republishes libdup1 byte for byte under another pool path
POOL_COMPONENT=updates/main pocket debian-security trixie-security "$WORK/debs/libfoo1_1.0-1+deb13u1_arm64.deb" "$WORK/debs/libdup1_2.0-1_arm64.deb"
export CERALIVE_EXPORT_SNAPSHOT_BASE="file://$M"
SNAPARGS=(--snapshot "$SNAP" --debian-keyring "$WORK/debian-keyring.gpg")

lock() { # out extra-rows-json
  printf '{"packages":[{"name":"adduser","version":"3.152","arch":"all","origin":"debian","sha256":"%s"},{"name":"libfoo1","version":"1.0-1+deb13u1","arch":"arm64","origin":"debian","sha256":"%s"},{"name":"libdup1","version":"2.0-1","arch":"arm64","origin":"debian","sha256":"%s"},{"name":"ceralive-device","version":"2026.12.1-1","arch":"arm64","origin":"first-party-local-override","sha256":"%s"},{"name":"armbian-firmware-full","version":"26.8.3","arch":"all","origin":"bsp","sha256":"%s"},{"name":"linux-image-test","version":"7.2.0-1","arch":"arm64","origin":"source-built","artifact":{"sha256":{"linux-image-test_7.2.0-1_arm64.deb":"%s"}}},{"name":"rauc","version":"1.15.2-1","arch":"arm64","origin":"generated-locally","sha256":"%s"}%s]}' \
    "$deb_a" "$deb_b" "$deb_d" "$fp" "$bsp" "$krn" "$rau" "${2:-}" >"$1"
}
lock "$WORK/lock.json"
X=(python3 "$ROOT/lib/export-debs.py")
x() { "${X[@]}" "$@" "${SNAPARGS[@]}"; }
check env SOURCE_DATE_EPOCH=1794083621 bash -c '"$@"' _ "${X[@]}" "$WORK/lock.json" "$S" "$WORK/a.debs.tar" "${SNAPARGS[@]}"
check test "$(tar -tf "$WORK/a.debs.tar" | grep '^files/' | tr '\n' ' ')" = 'files/adduser_3.152_all.deb files/armbian-firmware-full_26.8.3_all.deb files/ceralive-device_2026.12.1-1_arm64.deb files/libdup1_2.0-1_arm64.deb files/libfoo1_1.0-1+deb13u1_arm64.deb files/linux-image-test_7.2.0-1_arm64.deb files/rauc_1.15.2-1_arm64.deb '
mkdir "$WORK/x" && tar -xf "$WORK/a.debs.tar" -C "$WORK/x"
check bash -c "cd '$WORK/x' && sha256sum -c --quiet SHA256SUMS"
check test -s "$WORK/x/indexes/debian-security/trixie-security/InRelease"
check test -s "$WORK/x/indexes/debian/trixie/main/binary-arm64/Packages.xz"
check grep -q '"staged_as": "kernel-build/linux-image-test_7.2.0-1_arm64.deb"' "$WORK/x/export.json"
check python3 -c 'import json,sys; p={x["name"]:x for x in json.load(open(sys.argv[1]))["packages"]}; f=p["libfoo1"]; sys.exit(not (f["pocket"]=="trixie-security" and f["archive"]=="debian-security" and f["filename"]=="pool/updates/main/l/libfoo1_1.0-1+deb13u1_arm64.deb"))' "$WORK/x/export.json"
check python3 -c 'import json,sys; p={x["name"]:x for x in json.load(open(sys.argv[1]))["packages"]}; d=p["libdup1"]; sys.exit(not (d["pocket"]=="trixie" and [l["filename"] for l in d["listed_in"]]==["pool/main/l/libdup1_2.0-1_arm64.deb","pool/updates/main/l/libdup1_2.0-1_arm64.deb"]))' "$WORK/x/export.json"
check env SOURCE_DATE_EPOCH=1794083621 bash -c '"$@"' _ "${X[@]}" "$WORK/lock.json" "$S" "$WORK/b.debs.tar" "${SNAPARGS[@]}"
check cmp -s "$WORK/a.debs.tar" "$WORK/b.debs.tar"
refused 'an existing output' x "$WORK/lock.json" "$S" "$WORK/a.debs.tar"
refused 'a name without .debs.tar' x "$WORK/lock.json" "$S" "$WORK/c.tar"
# Debian side refusals
gpg --homedir "$WORK/gnupg" --batch --quiet --pinentry-mode loopback --passphrase '' --quick-gen-key 'Other' ed25519 sign never 2>/dev/null
gpg --homedir "$WORK/gnupg" --batch --export Other >"$WORK/other-keyring.gpg"
refused 'a snapshot signed by another key' "${X[@]}" "$WORK/lock.json" "$S" "$WORK/k.debs.tar" --snapshot "$SNAP" --debian-keyring "$WORK/other-keyring.gpg"
check grep -q 'gpgv refused' "$WORK/refused.log"
lock "$WORK/nodeb.json" ',{"name":"libbar2","version":"2.0","arch":"arm64","origin":"debian","sha256":"2222222222222222222222222222222222222222222222222222222222222222"}'
refused 'a Debian row in no pocket' x "$WORK/nodeb.json" "$S" "$WORK/n.debs.tar"
check grep -q 'in no pocket of snapshot' "$WORK/refused.log"
check test ! -e "$WORK/n.debs.tar"
cp "$M/debian/$SNAP/dists/trixie/main/binary-arm64/Packages.xz" "$WORK/px.keep"
printf 'x' >>"$M/debian/$SNAP/dists/trixie/main/binary-arm64/Packages.xz"
refused 'an index that differs from its InRelease' x "$WORK/lock.json" "$S" "$WORK/i.debs.tar"
cp "$WORK/px.keep" "$M/debian/$SNAP/dists/trixie/main/binary-arm64/Packages.xz"
# the first listing of a digest that is listed twice is gone: the other signed listing serves it
mv "$M/debian/$SNAP/pool/main/l/libdup1_2.0-1_arm64.deb" "$WORK/libdup.keep"
check x "$WORK/lock.json" "$S" "$WORK/g.debs.tar"
check bash -c "tar -xOf '$WORK/g.debs.tar' files/libdup1_2.0-1_arm64.deb | sha256sum | grep -q '^$deb_d '"
mv "$WORK/libdup.keep" "$M/debian/$SNAP/pool/main/l/libdup1_2.0-1_arm64.deb"
refused 'a bad snapshot stamp' "${X[@]}" "$WORK/lock.json" "$S" "$WORK/s.debs.tar" --snapshot 2026 --debian-keyring "$WORK/debian-keyring.gpg"
lock "$WORK/missing.json" ',{"name":"srtla","version":"4.2.0","arch":"arm64","origin":"first-party","sha256":"1111111111111111111111111111111111111111111111111111111111111111"}'
refused 'a row without a staged file' x "$WORK/missing.json" "$S" "$WORK/d.debs.tar"
check grep -q 'no staged file for first-party srtla' "$WORK/refused.log"
check test ! -e "$WORK/d.debs.tar"
cred="$(mkdeb "$S/firstparty" ceralive-apt-credentials 1.0.1 all)"
lock "$WORK/cred.json" ",{\"name\":\"ceralive-apt-credentials\",\"version\":\"1.0.1\",\"arch\":\"all\",\"origin\":\"first-party\",\"sha256\":\"$cred\"}"
check x "$WORK/cred.json" "$S" "$WORK/e.debs.tar"
if tar -tf "$WORK/e.debs.tar" | grep -q credentials; then bad 'credentials exported'; else ok 'credentials never exported'; fi
lock "$WORK/wrong.json" ",{\"name\":\"srtla\",\"version\":\"4.2.0\",\"arch\":\"arm64\",\"origin\":\"first-party\",\"sha256\":\"$fp\"}"
refused 'a staged file whose control is another package' x "$WORK/wrong.json" "$S" "$WORK/f.debs.tar"
check grep -Fq 'stage_export_debs' "$ROOT/lib/orchestrate.sh"

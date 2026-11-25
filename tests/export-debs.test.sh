#!/usr/bin/env bash
# lib/export-debs.py: the exact non-Debian .debs of a lock, from the staging tree, as one reproducible tar.
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
  [[ -z "$WORK" ]] || rm -rf "$WORK"
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
lock() { # out extra-rows-json
  printf '{"packages":[{"name":"adduser","version":"3.152","arch":"all","origin":"debian","sha256":"%s"},{"name":"ceralive-device","version":"2026.12.1-1","arch":"arm64","origin":"first-party-local-override","sha256":"%s"},{"name":"armbian-firmware-full","version":"26.8.3","arch":"all","origin":"bsp","sha256":"%s"},{"name":"linux-image-test","version":"7.2.0-1","arch":"arm64","origin":"source-built","artifact":{"sha256":{"linux-image-test_7.2.0-1_arm64.deb":"%s"}}},{"name":"rauc","version":"1.15.2-1","arch":"arm64","origin":"generated-locally","sha256":"%s"}%s]}' \
    "$(printf '0%.0s' {1..64})" "$fp" "$bsp" "$krn" "$rau" "${2:-}" >"$1"
}
lock "$WORK/lock.json"
X=(python3 "$ROOT/lib/export-debs.py")
check env SOURCE_DATE_EPOCH=1794083621 "${X[@]}" "$WORK/lock.json" "$S" "$WORK/a.debs.tar"
check test "$(tar -tf "$WORK/a.debs.tar" | tr '\n' ' ')" = 'SHA256SUMS export.json armbian-firmware-full_26.8.3_all.deb ceralive-device_2026.12.1-1_arm64.deb linux-image-test_7.2.0-1_arm64.deb rauc_1.15.2-1_arm64.deb '
mkdir "$WORK/x" && tar -xf "$WORK/a.debs.tar" -C "$WORK/x"
check bash -c "cd '$WORK/x' && sha256sum -c --quiet SHA256SUMS"
if grep -q adduser "$WORK/x/SHA256SUMS"; then bad 'a Debian row was exported'; else ok 'Debian rows are not exported'; fi
check grep -q '"staged_as": "kernel-build/linux-image-test_7.2.0-1_arm64.deb"' "$WORK/x/export.json"
check env SOURCE_DATE_EPOCH=1794083621 "${X[@]}" "$WORK/lock.json" "$S" "$WORK/b.debs.tar"
check cmp -s "$WORK/a.debs.tar" "$WORK/b.debs.tar"
refused 'an existing output' "${X[@]}" "$WORK/lock.json" "$S" "$WORK/a.debs.tar"
refused 'a name without .debs.tar' "${X[@]}" "$WORK/lock.json" "$S" "$WORK/c.tar"
lock "$WORK/missing.json" ',{"name":"srtla","version":"4.2.0","arch":"arm64","origin":"first-party","sha256":"1111111111111111111111111111111111111111111111111111111111111111"}'
refused 'a row without a staged file' "${X[@]}" "$WORK/missing.json" "$S" "$WORK/d.debs.tar"
check grep -q 'no staged file for first-party srtla' "$WORK/refused.log"
check test ! -e "$WORK/d.debs.tar"
cred="$(mkdeb "$S/firstparty" ceralive-apt-credentials 1.0.1 all)"
lock "$WORK/cred.json" ",{\"name\":\"ceralive-apt-credentials\",\"version\":\"1.0.1\",\"arch\":\"all\",\"origin\":\"first-party\",\"sha256\":\"$cred\"}"
refused 'the credentials package' "${X[@]}" "$WORK/cred.json" "$S" "$WORK/e.debs.tar"
lock "$WORK/wrong.json" ",{\"name\":\"srtla\",\"version\":\"4.2.0\",\"arch\":\"arm64\",\"origin\":\"first-party\",\"sha256\":\"$fp\"}"
refused 'a staged file whose control is another package' "${X[@]}" "$WORK/wrong.json" "$S" "$WORK/f.debs.tar"
check grep -Fq 'stage_export_debs' "$ROOT/lib/orchestrate.sh"

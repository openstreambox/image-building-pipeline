#!/usr/bin/env bash
# Real, offline APT: a first-party package installed from a local override stays
# the candidate when apt.ceralive.tv publishes a newer build of the same name, so
# the device's package check offers nothing for it (and holds nothing).
set -uo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "${ROOT}/tests/lib/assertions.sh"
check() { if "$@"; then ok "$*"; else bad "$*"; fi; }
work=''
server_pid=''
finish() {
  local status=$?
  [[ "$status" -eq 0 || "$FAIL" -gt 0 ]] || bad "unexpected exit: $status"
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || :; wait "$server_pid" 2>/dev/null || :; fi
  [[ -z "$work" ]] || rm -rf -- "$work"
  printf ' RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]]
}
trap 'finish; exit $?' EXIT
if [[ "${1:-}" != --in-container ]]; then
  command -v docker >/dev/null || { printf 'Docker is required for the local override pin test\n' >&2; exit 1; }
  docker image inspect debian:trixie-slim >/dev/null || { printf 'offline Debian trixie image missing\n' >&2; exit 1; }
  exec docker run --rm --network none -e CERALIVE_APT_FIXTURE_CONTAINER=1 -v "${ROOT}:${ROOT}:ro" debian:trixie-slim bash "${ROOT}/tests/first-party-local-override-pin.test.sh" --in-container
fi
[[ "${CERALIVE_APT_FIXTURE_CONTAINER:-}" == 1 ]] || { printf 'APT fixture must run in a disposable offline container\n' >&2; exit 1; }
work="$(mktemp -d)"; chmod 0755 "$work"  # the _apt sandbox reads the file: archive

# The device's own apt: drop the image's public sources (no network here).
rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*
mkdir -p "${work}/ours" "${work}/debian"

# Installed state: three packages from a local override (srtla's newer CeraLive
# build differs from it only in letter case), one ordinary first-party package
# from apt.ceralive.tv, and one removed package whose conffile is left (state rc).
make_deb() { # name version [conffile]
  local d="${work}/build/$1"
  mkdir -p "$d/DEBIAN"
  printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: Fixture <fixture@example.invalid>\nDescription: fixture\n' "$1" "$2" >"$d/DEBIAN/control"
  if [[ -n "${3:-}" ]]; then mkdir -p "$d/etc"; : >"$d$3"; printf '%s\n' "$3" >"$d/DEBIAN/conffiles"; fi
  dpkg-deb --root-owner-group -b "$d" "${work}/$1_$2_all.deb" >/dev/null
}
make_deb ceralive-device 2.0-local1
make_deb modemmanager 1.0+osb2
make_deb srtla 2.0-T1
make_deb cerastream 1.0
make_deb libqrtr-glib0 1.0 /etc/fixture-qrtr.conf
dpkg -i "${work}"/*.deb >/dev/null
dpkg -r libqrtr-glib0 >/dev/null

package() { printf 'Package: %s\nVersion: %s\nArchitecture: all\nFilename: pool/%s_%s_all.deb\nSize: 100\nMaintainer: Fixture <fixture@example.invalid>\nDescription: %s\n\n' "$1" "$2" "$1" "$2" "$3"; }
{ package ceralive-device 3.0 'newer upstream build'; package modemmanager 1.1 'newer upstream build'
  package srtla 2.0-t1 'newer build, case-only difference'; package cerastream 1.1 'first-party update'; } >"${work}/ours/Packages"
package modemmanager 1.5 'same-name Debian build' >"${work}/debian/Packages"
for origin in ours debian; do
  bytes="$(stat -c %s "${work}/${origin}/Packages")"; digest="$(sha256sum "${work}/${origin}/Packages")"
  printf 'Origin: %s\nLabel: %s\nSuite: stable\nCodename: stable\nDate: Thu, 01 Jan 2026 00:00:00 UTC\nArchitectures: all amd64 arm64\nComponents: main\nSHA256:\n %s %s Packages\n' \
    "$origin" "$origin" "${digest%% *}" "$bytes" >"${work}/${origin}/Release"
done
# apt.ceralive.tv from loopback under its real name, so APT evaluates `Pin: origin`.
cat >"${work}/server.pl" <<'PERL'
use strict; use warnings; use IO::Socket::INET;
my ($root, $port_file) = @ARGV;
my $l = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 8, ReuseAddr => 1) or die $!;
open my $pf, '>', $port_file or die $!; print {$pf} $l->sockport; close $pf;
while (my $c = $l->accept) {
  my $r = <$c> // '';
  if ($r !~ m{^GET /ours/(?:\./)?(Packages|Release) HTTP/1\.[01]\r?\n$}) { print {$c} "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"; close $c; next; }
  my $n = $1; while (my $h = <$c>) { last if $h =~ /^\r?\n$/; }
  open my $f, '<', "$root/$n" or die $!; local $/; my $b = <$f>;
  print {$c} "HTTP/1.1 200 OK\r\nContent-Length: ", length($b), "\r\nConnection: close\r\n\r\n", $b; close $c;
}
PERL
perl "${work}/server.pl" "${work}/ours" "${work}/port" & server_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "${work}/port" ]] && break; sleep .1; done
[[ -s "${work}/port" ]] || { bad 'local APT fixture server did not start'; exit 1; }
printf '\n127.0.0.1 apt.ceralive.tv\n' >>/etc/hosts
printf 'deb [trusted=yes] http://apt.ceralive.tv:%s/ours/ ./\ndeb [trusted=yes] file:%s/debian/ ./\n' "$(<"${work}/port")" "${work}" >/etc/apt/sources.list
apt-get -o Acquire::Languages=none -o Acquire::http::Proxy=DIRECT update >"${work}/update.log" 2>&1 || { bad 'fixture apt update failed'; cat "${work}/update.log" >&2; exit 1; }

# The image's origin pin, from its real writer.
export APT_CERALIVE_REPO_NO_AUTORUN=1 CERALIVE_FIRST_PARTY_NAMES_B64
CERALIVE_FIRST_PARTY_NAMES_B64="$(base64 -w0 "${ROOT}/manifests/first-party-apt-names.txt")"
# shellcheck source=/dev/null
source "${ROOT}/mkosi/customize/apt-ceralive-repo.sh"
install_apt_preferences >/dev/null 2>&1 || { bad 'origin pin writer failed'; exit 1; }

candidate() { apt-cache policy "$1" | perl -0777 -ne 'print "$1\n" if /^\s*Candidate: (.+)$/m'; }
# The device's two package checks: CeraUI's capable mode simulates
# `upgrade --with-new-pkgs`; its legacy mode reads `dist-upgrade --assume-no`.
upgrades() { apt-get -s -o Debug::NoLocking=1 upgrade --with-new-pkgs 2>/dev/null | awk '$1 == "Inst" {print $2}' | sort | tr '\n' ' '; }
legacy() { apt-get -o Debug::NoLocking=1 dist-upgrade --assume-no 2>/dev/null | perl -0777 -ne 'print join(" ", sort split " ", $1), " " if /upgraded:\n((?:  .*\n)+)/'; }
kept_back() { apt-get -o Debug::NoLocking=1 dist-upgrade --assume-no 2>/dev/null | grep -c 'kept back'; }

# Without the local override pin (non-vacuity): the newer CeraLive builds win.
assert_eq 'without the pin: ceralive-device candidate is CeraLive 3.0' 3.0 "$(candidate ceralive-device)"
assert_eq 'without the pin: modemmanager candidate is CeraLive 1.1' 1.1 "$(candidate modemmanager)"
assert_eq 'without the pin: srtla candidate is the case-only CeraLive 2.0-t1' 2.0-t1 "$(candidate srtla)"
assert_eq 'without the pin: capable mode would offer all three' 'ceralive-device cerastream modemmanager srtla ' "$(upgrades)"
assert_eq 'without the pin: legacy mode would offer all three' 'ceralive-device cerastream modemmanager srtla ' "$(legacy)"

# The app layer's real function, extracted without reimplementing it.
for fn in local_override_rows pin_first_party_local_overrides; do
  eval "$(FN="$fn" perl -0777 -ne 'print $1 if /(^\Q$ENV{FN}\E\(\) \{.*?^\})/ms' "${ROOT}/mkosi/mkosi.images/app/mkosi.postinst.chroot")"
  if declare -F "$fn" >/dev/null; then ok "extracted $fn"; else bad "cannot extract $fn"; exit 1; fi
done
log() { :; }
die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
pin=/etc/apt/preferences.d/ceralive-local-override
record() { printf '%s\n' "$1" >"${work}/record.json"; }

record '[{"package": "ceralive-device", "version": "2.0-local1", "arch": "all", "sha256": "0000000000000000000000000000000000000000000000000000000000000000", "filename": "f.deb"}, {"package": "modemmanager", "version": "1.0+osb2", "arch": "all", "sha256": "0000000000000000000000000000000000000000000000000000000000000000", "filename": "f.deb"}, {"package": "srtla", "version": "2.0-T1", "arch": "all", "sha256": "0000000000000000000000000000000000000000000000000000000000000000", "filename": "f.deb"}]'
check pin_first_party_local_overrides "${work}/record.json"
check test -f "$pin"
assert_eq 'pin file sorts before the origin pin' ceralive-local-override "$(cd /etc/apt/preferences.d && printf '%s\n' * | sort | head -1)"
assert_eq 'pinned: ceralive-device stays at the local build' 2.0-local1 "$(candidate ceralive-device)"
assert_eq 'pinned: modemmanager stays at the local build' 1.0+osb2 "$(candidate modemmanager)"
assert_eq 'pinned: srtla stays at the local build, not its case-only twin' 2.0-T1 "$(candidate srtla)"
assert_eq 'pinned: capable mode offers only the ordinary first-party update' 'cerastream ' "$(upgrades)"
assert_eq 'pinned: legacy mode offers only the ordinary first-party update' 'cerastream ' "$(legacy)"
assert_eq 'pinned: nothing reported as kept back' 0 "$(kept_back)"
assert_eq 'pinned: no dpkg hold (the package check refuses held first-party packages)' '' "$(apt-mark showhold)"
check grep -qxF 'Pin-Priority: 1001' "$pin"
check grep -qxF 'Pin: release a=now' "$pin"

# Refusals leave no pin behind; an empty or missing record writes none.
refused() { # label record-json reason
  record "$2"
  if (pin_first_party_local_overrides "${work}/record.json") >"${work}/refused.log" 2>&1; then
    bad "accepted $1"
  elif ! grep -Fq -- "$3" "${work}/refused.log"; then
    bad "refused $1 without naming: $3"; cat "${work}/refused.log" >&2
  elif [[ -e "$pin" ]]; then
    bad "refused $1 but left a pin file"
  else
    ok "refused $1"
  fi
}
refused 'a version that is not installed' '[{"package": "modemmanager", "version": "1.1", "arch": "all", "sha256": "0000000000000000000000000000000000000000000000000000000000000000", "filename": "f.deb"}]' 'is not what is installed: installed 1.0+osb2 all'
refused 'an architecture that is not installed' '[{"package": "modemmanager", "version": "1.0+osb2", "arch": "arm64", "sha256": "0000000000000000000000000000000000000000000000000000000000000000", "filename": "f.deb"}]' 'is not what is installed'
refused 'a package that is not installed' '[{"package": "libqmi-utils", "version": "1.0", "arch": "all", "sha256": "0000000000000000000000000000000000000000000000000000000000000000", "filename": "f.deb"}]' 'is not what is installed: absent'
refused 'a removed package with its conffile left' '[{"package": "libqrtr-glib0", "version": "1.0", "arch": "all", "sha256": "0000000000000000000000000000000000000000000000000000000000000000", "filename": "f.deb"}]' 'is not what is installed: config-files'
refused 'a repeated package' '[{"package": "modemmanager", "version": "1.0+osb2", "arch": "all", "sha256": "0000000000000000000000000000000000000000000000000000000000000000", "filename": "f.deb"}, {"package": "modemmanager", "version": "1.0+osb2", "arch": "all", "sha256": "0000000000000000000000000000000000000000000000000000000000000000", "filename": "f.deb"}]' 'unreadable first-party local override record'
refused 'a glob in the version' '[{"package": "modemmanager", "version": "1.*", "arch": "all", "sha256": "0000000000000000000000000000000000000000000000000000000000000000", "filename": "f.deb"}]' 'unreadable first-party local override record'
refused 'a record that is not a list' '{"package": "modemmanager"}' 'unreadable first-party local override record'
refused 'a trailing separator' '[{"package": "modemmanager", "version": "1.0+osb2", "arch": "all", "sha256": "0000000000000000000000000000000000000000000000000000000000000000", "filename": "f.deb"}, ]' 'unreadable first-party local override record'
refused 'a field in another order' '[{"version": "1.0+osb2", "package": "modemmanager", "arch": "all", "sha256": "0000000000000000000000000000000000000000000000000000000000000000", "filename": "f.deb"}]' 'unreadable first-party local override record'
# The exact shape lib/fetch/firstparty.sh writes (json.dump, one line).
record '[{"package": "ceralive-device", "version": "2.0-local1", "arch": "all", "sha256": "31f445723cbac62171d4c1f504d1500e61d697fcce40d15f72911115baebb8ce", "filename": "ceralive-device_2.0-local1_all.deb"}, {"package": "modemmanager", "version": "1.0+osb2", "arch": "all", "sha256": "a464c1b34464160447b19a49fe83c05d4510f3616b139406e35e1a05239148d3", "filename": "modemmanager_1.0+osb2_all.deb"}]'
assert_eq "the fetch writer's record parses" $'ceralive-device\t2.0-local1\tall\nmodemmanager\t1.0+osb2\tall' "$(local_override_rows "${work}/record.json")"
record '[]'
check pin_first_party_local_overrides "${work}/record.json"
check test ! -e "$pin"
if (pin_first_party_local_overrides "${work}/absent.json") >"${work}/absent.log" 2>&1; then
  bad 'accepted a missing record'
elif grep -Fq "local override record is missing" "${work}/absent.log" && [[ ! -e "$pin" ]]; then
  ok 'refused a missing record, no pin left'
else
  bad 'missing record refusal'; cat "${work}/absent.log" >&2
fi
assert_eq 'no pin: the CeraLive build is the candidate again' 3.0 "$(candidate ceralive-device)"

# The build calls it once the staged debs are installed.
check grep -Pzq 'install_first_party_apps\n\s+keep_ceraui_build_stamps\n\s+pin_first_party_local_overrides\n' "${ROOT}/mkosi/mkosi.images/app/mkosi.postinst.chroot"

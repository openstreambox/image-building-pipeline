#!/usr/bin/env bash
#
# packages-lock-capture.test.sh — the per-layer Debian receipt capture
# (mkosi/runtime/packages-lock-capture.sh) and its single-pass index lookup
# (lib/fetch-debs-auth.sh::auth_lookup_packages).
#
# The capture used to call auth_lookup_package once per installed package, and
# each call re-read the whole Debian index. auth_lookup_packages answers all of
# them in one pass. These cases hold it to the same answers:
#
#   differential   every lookup, on real trixie stanzas and on edge cases, gives
#                  the same row (or the same miss) as auth_lookup_package
#   real fixture   the capture script, run on a fixture tree of real image
#                  packages, writes exactly the receipts an independent oracle
#                  derives from the same index
#   re-run         a second run for the same layer writes the same receipt (the
#                  old capture emptied it, and mkosi ran base's finalize twice)
#   layers         later layers skip what earlier receipts and exclusions cover
#   fail closed    a missing, ambiguous, virtual-only or wrong-arch package, or
#                  no index at all, still fails the capture
#   inherited      a package an earlier layer recorded fails the capture when
#                  the index now lists it with other bytes
#   no partials    a failed capture leaves the published receipts as they were
#   one pass       the index is read a fixed number of times, not per package
#
# tests/fixtures/packages-lock-capture/ holds verbatim stanzas from the trixie
# main, -security, -updates and -debug arm64 indexes and the matching dpkg
# status stanzas of a built image. The InRelease files keep only their headers;
# the capture reads nothing else from them.
#
# Optional full-size differential: set CERALIVE_LOCK_CAPTURE_REAL_INDEX to a
# concatenated Packages file and CERALIVE_LOCK_CAPTURE_REAL_STATUS to a dpkg
# status file (for example from a built tree) to compare every installed
# package. It needs a few minutes because the reference lookup is per package.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$HERE/tests/lib/assertions.sh"
# shellcheck source=lib/fetch-debs-auth.sh
source "$HERE/lib/fetch-debs-auth.sh"
set +e

CAPTURE="$HERE/mkosi/runtime/packages-lock-capture.sh"
FIXTURE="$HERE/tests/fixtures/packages-lock-capture"
work="$(mktemp -d)"
finish() {
  rm -rf "$work"
  printf ' RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]]
}
trap 'finish; exit $?' EXIT

[[ -x /usr/lib/apt/apt-helper ]] || {
  bad "/usr/lib/apt/apt-helper is required (the capture reads lists through it)"
  exit 1
}

# --- helpers -----------------------------------------------------------------

# The index the capture builds: every list, each followed by a blank line.
real_index="$work/real-index"
: >"$real_index"
for list in "$FIXTURE"/lists/*_Packages; do
  cat "$list" >>"$real_index"
  printf '\n' >>"$real_index"
done

# reference_lookups <index> <wanted.tsv> — auth_lookup_package per line, in the
# output shape of auth_lookup_packages. This is the lookup the capture used.
reference_lookups() {
  local index="$1" wanted="$2" name version arch row
  while IFS=$'\t' read -r name version arch; do
    row="$(auth_lookup_package "$index" "$name" "$version" "$arch")" || continue
    printf '%s\t%s\t%s\t%s\n' "$name" "$version" "$arch" "$row"
  done <"$wanted"
}

# differential <label> <index> <wanted.tsv> — both lookups must agree exactly.
differential() {
  local label="$1" index="$2" wanted="$3"
  reference_lookups "$index" "$wanted" >"$work/reference.out"
  auth_lookup_packages "$index" "$wanted" >"$work/single-pass.out" || {
    bad "$label: auth_lookup_packages failed"
    return
  }
  if cmp -s "$work/reference.out" "$work/single-pass.out"; then
    ok "$label: $(wc -l <"$work/single-pass.out") hits, $(( $(wc -l <"$wanted") - $(wc -l <"$work/single-pass.out") )) misses, identical to auth_lookup_package"
  else
    bad "$label: single-pass lookup differs from auth_lookup_package"
    diff "$work/reference.out" "$work/single-pass.out" | head -20
  fi
}

installed_tsv() {
  dpkg-query --admindir="$1" -W -f='${Package}\t${Version}\t${Architecture}\t${Status}\n' \
    | awk -F'\t' '$4 ~ / ok installed$/ {print $1 "\t" $2 "\t" $3}'
}

# make_tree <dir> <status-file> — a capture root with the fixture lists.
make_tree() {
  local root="$1" status="$2"
  mkdir -p "$root/var/lib/dpkg" "$root/var/lib/apt/lists"
  cp "$status" "$root/var/lib/dpkg/status"
  cp "$FIXTURE"/lists/* "$root/var/lib/apt/lists/"
}

# capture <root> <layer> [excluded...] — run the real script against <root>.
src="$work/src"
mkdir -p "$src"
ln -s "$HERE/lib" "$src/lib"
capture() {
  local root="$1"
  shift
  env -u CERALIVE_MKOSI_CACHE_DIR CERALIVE_LOCK_CAPTURE_ROOT="$root" SRCDIR="$src" \
    APT_SUITE=trixie APT_SUITE_UPDATES=trixie-updates APT_SUITE_SECURITY=trixie-security \
    bash "$CAPTURE" "$@"
}

# oracle_receipts <index> <status-file> <skip.tsv> [excluded...] — independent
# Python reading of the rule: dedupe identical name/version/arch/sha stanzas,
# then exactly one stanza with the version and the arch (or all) per installed
# package that is neither excluded nor listed in <skip.tsv>.
oracle_receipts() {
  python3 - "$@" <<'PY'
import sys

index, status, skip = sys.argv[1:4]
excluded = set(sys.argv[4:])


def stanzas(path):
    for para in open(path).read().split("\n\n"):
        fields = {}
        for line in para.splitlines():
            if line and not line[0].isspace() and ": " in line:
                key, value = line.split(": ", 1)
                fields[key] = value
        if fields:
            yield fields


seen, rows = set(), []
for s in stanzas(index):
    key = (s.get("Package", ""), s.get("Version", ""), s.get("Architecture", ""), s.get("SHA256", ""))
    if key in seen:
        continue
    seen.add(key)
    if s.get("Filename") and s.get("SHA256"):
        rows.append(s)
skipped = {tuple(line.split("\t")) for line in open(skip).read().splitlines() if line}
for s in stanzas(status):
    if not s.get("Status", "").endswith(" ok installed"):
        continue
    name, version, arch = s["Package"], s["Version"], s["Architecture"]
    if name in excluded or (name, version, arch) in skipped:
        continue
    hits = [r for r in rows if r["Package"] == name and r["Version"] == version
            and r["Architecture"] in (arch, "all")]
    if len(hits) != 1:
        sys.exit(f"oracle: {name}={version}/{arch} has {len(hits)} verified stanzas")
    print('{"name":"%s","version":"%s","arch":"%s","origin":"debian","sha256":"%s"}'
          % (name, version, arch, hits[0]["SHA256"]))
PY
}

# --- differential: real stanzas ----------------------------------------------

fixture_admin="$work/fixture-admin"
mkdir -p "$fixture_admin"
cp "$FIXTURE/status" "$fixture_admin/status"
installed_tsv "$fixture_admin" >"$work/wanted-real"
[[ "$(wc -l <"$work/wanted-real")" -eq 14 ]] \
  && ok "real fixture: 14 installed packages" \
  || bad "real fixture: expected 14 installed packages, got $(wc -l <"$work/wanted-real")"
# Probes beyond the installed set, all against the same real stanzas.
cat "$work/wanted-real" - >"$work/wanted-real-probes" <<'EOF'
apt	3.0.3	arm64
apt	3.0.4	amd64
bash	5.2.37-2+b10	all
ca-certificates	20250419+deb13u1	arm64
ca-certificates	20250419	all
awk	1.3.4.20250131-1	arm64
tzdata-legacy	2026f-0+deb13u1	all
tzdata-legacy	2026c-0+deb13u1	all
tzdata	2026c-0+deb13u1	arm64
dnsmasq-base	2.91-1+deb13u1	arm64
apt-dbgsym	3.0.3	arm64
libc6	2.41-12	arm64
EOF
differential "real stanzas, raw index" "$real_index" "$work/wanted-real-probes"

# The raw index lists some stanzas twice (trixie-security mirrors trixie byte
# for byte), which is ambiguous to both lookups; the capture dedupes first.
awk -v RS='' -v ORS='\n\n' '
  { pkg = ""; ver = ""; arch = ""; sha = ""
    n = split($0, ln, "\n")
    for (i = 1; i <= n; i++) {
      if (ln[i] ~ /^Package: /) pkg = substr(ln[i], 10)
      else if (ln[i] ~ /^Version: /) ver = substr(ln[i], 10)
      else if (ln[i] ~ /^Architecture: /) arch = substr(ln[i], 15)
      else if (ln[i] ~ /^SHA256: /) sha = substr(ln[i], 9)
    }
    key = pkg SUBSEP ver SUBSEP arch SUBSEP sha
    if (!(key in seen)) { seen[key] = 1; print } }
' "$real_index" >"$work/real-index-dedup"
differential "real stanzas, deduped index" "$work/real-index-dedup" "$work/wanted-real-probes"
grep -q $'^bsdutils\t' "$work/single-pass.out" \
  && ok "deduped: bsdutils (same bytes in trixie and trixie-security) resolves" \
  || bad "deduped: bsdutils did not resolve"

# --- differential: edge cases ------------------------------------------------

sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
cat >"$work/edge-index" <<EOF
Package: multi
Version: 1.0
Architecture: arm64
Filename: pool/m/multi_1.0_arm64.deb
SHA256: $(sha multi1)

Package: multi
Version: 2.0
Architecture: arm64
Filename: pool/m/multi_2.0_arm64.deb
SHA256: $(sha multi2)

Package: both
Version: 1
Architecture: arm64
Filename: pool/b/both_1_arm64.deb
SHA256: $(sha both-arm64)

Package: both
Version: 1
Architecture: all
Filename: pool/b/both_1_all.deb
SHA256: $(sha both-all)

Package: indep
Version: 3
Architecture: all
Filename: pool/i/indep_3_all.deb
SHA256: $(sha indep)

Package: split
Version: 1
Architecture: arm64
Filename: pool/s/split_1_arm64.deb
SHA256: $(sha split-a)

Package: split
Version: 1
Architecture: arm64
Filename: pool/s/split_1_arm64.deb
SHA256: $(sha split-b)

Package: provider
Version: 1
Architecture: arm64
Provides: virtual-thing
Filename: pool/p/provider_1_arm64.deb
SHA256: $(sha provider)

Package: nohash
Version: 1
Architecture: arm64
Filename: pool/n/nohash_1_arm64.deb

Package: nofile
Version: 1
Architecture: arm64
SHA256: $(sha nofile)

Package: halfhashed
Version: 1
Architecture: arm64
Filename: pool/h/halfhashed_1_arm64.deb

Package: halfhashed
Version: 1
Architecture: arm64
Filename: pool/h/halfhashed_1_arm64.deb
SHA256: $(sha halfhashed)

Version: 1
Description: field order and a description
 continued line
Architecture: amd64
Filename: pool/f/fieldorder_1_amd64.deb
SHA256: $(sha fieldorder-amd64)
Package: fieldorder


Package: libfoo
Version: 1
Architecture: arm64
Filename: pool/l/libfoo_1_arm64.deb
SHA256: $(sha libfoo)

Package: libfoo2
Version: 1
Architecture: arm64
Filename: pool/l/libfoo2_1_arm64.deb
SHA256: $(sha libfoo2)

Package: epoch
Version: 1:2.0-1+b1
Architecture: arm64
Filename: pool/e/epoch_2.0-1+b1_arm64.deb
SHA256: $(sha epoch)
EOF
cat >"$work/edge-wanted" <<'EOF'
multi	1.0	arm64
multi	2.0	arm64
multi	3.0	arm64
both	1	arm64
both	1	all
indep	3	arm64
indep	3	all
indep	3	amd64
split	1	arm64
virtual-thing	1	arm64
provider	1	arm64
nohash	1	arm64
nofile	1	arm64
halfhashed	1	arm64
fieldorder	1	amd64
fieldorder	1	arm64
libfoo	1	arm64
libfoo2	1	arm64
libfo	1	arm64
epoch	1:2.0-1+b1	arm64
epoch	2.0-1+b1	arm64
absent	1	arm64
EOF
differential "edge cases" "$work/edge-index" "$work/edge-wanted"
# Pin the expected verdicts, so the differential cannot pass by both being wrong.
expect_hits="multi:1.0:arm64 multi:2.0:arm64 both:1:all indep:3:arm64 indep:3:all indep:3:amd64 provider:1:arm64 halfhashed:1:arm64 fieldorder:1:amd64 libfoo:1:arm64 libfoo2:1:arm64 epoch:1:2.0-1+b1:arm64"
actual_hits="$(awk -F'\t' '{printf "%s%s:%s:%s", sep, $1, $2, $3; sep=" "}' "$work/single-pass.out")"
[[ "$actual_hits" == "$expect_hits" ]] \
  && ok "edge cases: hits are exactly the unambiguous ones, in input order" \
  || bad "edge cases: hits '$actual_hits' != '$expect_hits'"
grep -q $'^indep\t3\tarm64\tpool/i/indep_3_all.deb\t' "$work/single-pass.out" \
  && ok "edge cases: an arm64 lookup resolves an Architecture: all stanza" \
  || bad "edge cases: Architecture: all fallback row missing"

# An empty version is never a match here (auth_lookup_package would accept any
# version, and the capture then refused the row anyway).
printf 'indep\t\tall\n' >"$work/empty-version"
[[ -z "$(auth_lookup_packages "$work/edge-index" "$work/empty-version")" ]] \
  && ok "empty version: no row" || bad "empty version produced a row"
auth_lookup_packages "$work/does-not-exist" "$work/edge-wanted" >/dev/null 2>&1 \
  && bad "unreadable index: lookup succeeded" || ok "unreadable index: lookup fails"

# --- the capture script on the real fixture ----------------------------------

tree="$work/tree"
make_tree "$tree" "$FIXTURE/status"
: >"$work/no-skip"
capture "$tree" base 2>"$work/capture.err" \
  && ok "capture base: exit 0" || { bad "capture base failed"; cat "$work/capture.err"; }
receipt="$tree/usr/lib/ceralive/build-lock/base.jsonl"
oracle_receipts "$work/real-index" "$FIXTURE/status" "$work/no-skip" >"$work/oracle-base.jsonl" \
  || bad "oracle failed on the real fixture"
[[ "$(wc -l <"$work/oracle-base.jsonl")" -eq 14 ]] || bad "oracle: expected 14 rows"
cmp -s "$receipt" "$work/oracle-base.jsonl" \
  && ok "capture base: 14 receipts byte-identical to the oracle" \
  || { bad "capture base: receipts differ from the oracle"; diff "$work/oracle-base.jsonl" "$receipt" | head; }
grep -Fq '{"name":"apt","version":"3.0.4","arch":"arm64","origin":"debian","sha256":"9a3ee57117d1' "$receipt" \
  && ok "capture base: apt resolves to its trixie-security stanza" || bad "capture base: apt row wrong"
grep -Fq '{"name":"tzdata","version":"2026f-0+deb13u1","arch":"all"' "$receipt" \
  && ok "capture base: tzdata resolves from trixie-updates" || bad "capture base: tzdata row wrong"
printf 'trixie\tSat, 12 Sep 2026 07:55:41 UTC\ntrixie-security\tThu, 19 Nov 2026 05:45:40 UTC\ntrixie-updates\tThu, 19 Nov 2026 08:27:03 UTC\n' \
  >"$work/expected.dates"
sort "$tree/usr/lib/ceralive/build-lock/base.dates" | cmp -s - "$work/expected.dates" \
  && ok "capture base: Release dates of the three forwarded suites (not -debug)" \
  || { bad "capture base: dates wrong"; cat "$tree/usr/lib/ceralive/build-lock/base.dates"; }

cp "$receipt" "$work/first-run.jsonl"
capture "$tree" base 2>"$work/capture.err" \
  && ok "capture base again: exit 0" || bad "capture base again failed"
cmp -s "$receipt" "$work/first-run.jsonl" \
  && ok "capture base again: same 14 receipts (a re-run no longer empties them)" \
  || bad "capture base again: receipt changed to $(wc -l <"$receipt") rows"

# --- layers: earlier receipts and exclusions ---------------------------------

# The next layer adds one package and installs a BSP-style one that it excludes.
{
  cat "$FIXTURE/status"
  printf '\nPackage: tzdata-legacy\nStatus: install ok installed\nArchitecture: all\nVersion: 2026f-0+deb13u1\n'
  printf '\nPackage: vendor-bsp\nStatus: install ok installed\nArchitecture: arm64\nVersion: 9\n'
  printf '\nPackage: removed-pkg\nStatus: deinstall ok config-files\nArchitecture: arm64\nVersion: 1\n'
} >"$work/status-platform"
cp "$work/status-platform" "$tree/var/lib/dpkg/status"
capture "$tree" platform vendor-bsp not-installed-bsp 2>"$work/capture.err" \
  && ok "capture platform: exit 0" || { bad "capture platform failed"; cat "$work/capture.err"; }
awk -F'"' '{print $4 "\t" $8 "\t" $12}' "$receipt" >"$work/skip-platform"
oracle_receipts "$work/real-index" "$work/status-platform" "$work/skip-platform" vendor-bsp not-installed-bsp \
  >"$work/oracle-platform.jsonl" || bad "oracle failed on the platform layer"
cmp -s "$tree/usr/lib/ceralive/build-lock/platform.jsonl" "$work/oracle-platform.jsonl" \
  && ok "capture platform: only the new Debian package ($(wc -l <"$work/oracle-platform.jsonl") row), base rows not repeated" \
  || { bad "capture platform: receipt differs"; cat "$tree/usr/lib/ceralive/build-lock/platform.jsonl"; }
[[ "$(cat "$tree/usr/lib/ceralive/build-lock/excluded.tsv")" == $'vendor-bsp\t9\tarm64' ]] \
  && ok "capture platform: the installed excluded package is recorded once" \
  || bad "capture platform: excluded.tsv is '$(cat "$tree/usr/lib/ceralive/build-lock/excluded.tsv")'"
cmp -s "$receipt" "$work/first-run.jsonl" \
  && ok "capture platform: base receipt untouched" || bad "capture platform: base receipt changed"
# A later layer neither re-checks the excluded package nor fails on it.
capture "$tree" runtime 2>"$work/capture.err" \
  && [[ ! -s "$tree/usr/lib/ceralive/build-lock/runtime.jsonl" ]] \
  && ok "capture runtime: nothing new, excluded BSP package still accounted for" \
  || { bad "capture runtime: unexpected result"; cat "$work/capture.err"; }

# --- fail closed --------------------------------------------------------------

# fail_case <label> <status-stanza> [index-stanza] — one extra installed package
# must stop the capture with the "no verified … SHA256" error.
fail_case() {
  local label="$1" stanza="$2" extra_index="${3:-}" root="$work/fail-$RANDOM"
  { cat "$FIXTURE/status"; printf '\n%s\n' "$stanza"; } >"$work/status-fail"
  make_tree "$root" "$work/status-fail"
  [[ -z "$extra_index" ]] || printf '%s\n' "$extra_index" >"$root/var/lib/apt/lists/deb.debian.org_debian_dists_trixie_main_binary-arm64_Packages.extra_Packages"
  if capture "$root" runtime 2>"$work/fail.err"; then
    bad "$label: capture succeeded"
  elif grep -q 'has no verified Debian Packages SHA256' "$work/fail.err"; then
    ok "$label: capture fails closed"
  else
    bad "$label: failed for another reason: $(cat "$work/fail.err")"
  fi
}
fail_case "missing package" $'Package: not-in-debian\nStatus: install ok installed\nArchitecture: arm64\nVersion: 1'
fail_case "version not in the index" $'Package: tzdata-legacy\nStatus: install ok installed\nArchitecture: all\nVersion: 2026a-0+deb13u1'
fail_case "virtual package only" $'Package: awk\nStatus: install ok installed\nArchitecture: arm64\nVersion: 1.3.4.20250131-1'
fail_case "other architecture only" $'Package: mawk-dbgsym\nStatus: install ok installed\nArchitecture: amd64\nVersion: 1.3.4.20250131-1'
fail_case "two stanzas with different bytes" \
  $'Package: twice\nStatus: install ok installed\nArchitecture: arm64\nVersion: 1' \
  "$(printf 'Package: twice\nVersion: 1\nArchitecture: arm64\nFilename: pool/t/twice_1_arm64.deb\nSHA256: %s\n\nPackage: twice\nVersion: 1\nArchitecture: arm64\nFilename: pool/t/twice_1_arm64.deb\nSHA256: %s\n' "$(sha one)" "$(sha two)")"
# The same bytes listed twice (as trixie-security mirrors trixie) are one stanza.
root="$work/dup-ok"
{ cat "$FIXTURE/status"; printf '\nPackage: twice\nStatus: install ok installed\nArchitecture: arm64\nVersion: 1\n'; } >"$work/status-dup"
make_tree "$root" "$work/status-dup"
printf 'Package: twice\nVersion: 1\nArchitecture: arm64\nFilename: pool/t/twice_1_arm64.deb\nSHA256: %s\n\nPackage: twice\nVersion: 1\nArchitecture: arm64\nFilename: pool/t/twice_1_arm64.deb\nSHA256: %s\n' \
  "$(sha one)" "$(sha one)" >"$root/var/lib/apt/lists/deb.debian.org_debian_dists_trixie_main_binary-arm64_Packages.extra_Packages"
capture "$root" runtime 2>"$work/capture.err" && grep -q '"name":"twice"' "$root/usr/lib/ceralive/build-lock/runtime.jsonl" \
  && ok "identical stanzas in two lists: one verified row" \
  || { bad "identical stanzas in two lists: not resolved"; cat "$work/capture.err"; }

root="$work/no-lists"
make_tree "$root" "$FIXTURE/status"
rm -f "$root"/var/lib/apt/lists/*_Packages
capture "$root" base 2>"$work/fail.err" \
  && bad "no lists: capture succeeded" \
  || { grep -q 'no apt-verified Debian Packages lists' "$work/fail.err" \
         && ok "no lists: capture fails closed" || bad "no lists: wrong error: $(cat "$work/fail.err")"; }

root="$work/empty-lists"
make_tree "$root" "$FIXTURE/status"
for list in "$root"/var/lib/apt/lists/*_Packages; do : >"$list"; done
capture "$root" base 2>"$work/fail.err" \
  && bad "empty lists: capture succeeded" \
  || { grep -q 'has no verified Debian Packages SHA256' "$work/fail.err" \
         && ok "empty lists: capture fails closed" || bad "empty lists: wrong error: $(cat "$work/fail.err")"; }

# --- an inherited receipt must agree with the index ---------------------------

# An earlier layer recorded demo=1 with one SHA256. If the index this layer
# reads lists the same version with OTHER bytes (for example its own apt lists
# disagree with mkosi's metadata cache), the capture fails instead of quietly
# trusting the earlier receipt. A version the mirror no longer lists at all
# stays valid, and an index that agrees is fine.
h1="$(sha demo-old-bytes)"
h2="$(sha demo-new-bytes)"
demo_tree() {
  local root="$1"
  mkdir -p "$root/var/lib/dpkg" "$root/var/lib/apt/lists" "$root/usr/lib/ceralive/build-lock"
  cp "$FIXTURE/lists/deb.debian.org_debian_dists_trixie_InRelease" "$root/var/lib/apt/lists/"
  printf 'Package: demo\nStatus: install ok installed\nArchitecture: arm64\nVersion: 1\n' >"$root/var/lib/dpkg/status"
  printf '{"name":"demo","version":"1","arch":"arm64","origin":"debian","sha256":"%s"}\n' "$h1" \
    >"$root/usr/lib/ceralive/build-lock/base.jsonl"
}
demo_list() {  # demo_list <root> <package> <sha>... — one stanza per digest
  local root="$1" package="$2" digest
  shift 2
  for digest in "$@"; do
    printf 'Package: %s\nVersion: 1\nArchitecture: arm64\nFilename: pool/d/%s_1_arm64.deb\nSHA256: %s\n\n' "$package" "$package" "$digest"
  done >"$root/var/lib/apt/lists/deb.debian.org_debian_dists_trixie_main_binary-arm64_Packages"
}
for case in "agree:demo:$h1" "gone:other:$h2" "other:demo:$h2" "both:demo:$h1 $h2"; do
  IFS=: read -r label package digests <<<"$case"
  root="$work/inherit-$label"
  demo_tree "$root"
  # shellcheck disable=SC2086 # the digests are a word list on purpose
  demo_list "$root" "$package" $digests
  capture "$root" platform 2>"$work/inherit.err"
  rc=$?
  case "$label" in
    agree|gone)
      if [[ "$rc" -eq 0 && ! -s "$root/usr/lib/ceralive/build-lock/platform.jsonl" ]]; then
        ok "inherited receipt, index $label: accepted, nothing re-recorded"
      else
        bad "inherited receipt, index $label: rc=$rc"; cat "$work/inherit.err"
      fi ;;
    *)
      if [[ "$rc" -ne 0 ]] && grep -q 'recorded by an earlier layer with SHA256' "$work/inherit.err"; then
        ok "inherited receipt, index $label: conflicting SHA256 fails closed"
      else
        bad "inherited receipt, index $label: rc=$rc"; cat "$work/inherit.err"
      fi ;;
  esac
done

# Two earlier layers that recorded the same package with different bytes.
root="$work/inherit-twice"
demo_tree "$root"
demo_list "$root" other "$h2"
printf '{"name":"demo","version":"1","arch":"arm64","origin":"debian","sha256":"%s"}\n' "$h2" \
  >"$root/usr/lib/ceralive/build-lock/platform.jsonl"
if capture "$root" runtime 2>"$work/inherit.err"; then
  bad "inherited receipts that disagree: capture succeeded"
else
  grep -q 'earlier layers recorded demo=1/arm64 with different SHA256s' "$work/inherit.err" \
    && ok "inherited receipts that disagree: capture fails closed" \
    || { bad "inherited receipts that disagree: wrong error"; cat "$work/inherit.err"; }
fi

# --- a failed capture publishes nothing ---------------------------------------

root="$work/partial"
make_tree "$root" "$FIXTURE/status"
capture "$root" base 2>/dev/null || bad "partial: first capture failed"
lock_dir="$root/usr/lib/ceralive/build-lock"
( cd "$lock_dir" && sha256sum ./* ) >"$work/partial.before"
printf '\nPackage: z-missing\nStatus: install ok installed\nArchitecture: all\nVersion: 1\n' >>"$root/var/lib/dpkg/status"
if capture "$root" base 2>"$work/partial.err"; then
  bad "partial: capture with an unverifiable package succeeded"
elif ( cd "$lock_dir" && sha256sum ./* ) | cmp -s - "$work/partial.before" \
    && [[ -z "$(find "$lock_dir" -name '.*' ! -name .)" ]]; then
  ok "partial: a failed re-run leaves the earlier receipts untouched and no temporary file"
else
  bad "partial: receipts changed by a failed run"; ls -la "$lock_dir"
fi
root="$work/partial-fresh"
make_tree "$root" "$FIXTURE/status"
printf '\nPackage: z-missing\nStatus: install ok installed\nArchitecture: all\nVersion: 1\n' >>"$root/var/lib/dpkg/status"
if capture "$root" platform vendor-bsp 2>/dev/null; then
  bad "partial-fresh: capture succeeded"
elif [[ -z "$(find "$root/usr/lib/ceralive/build-lock" -type f)" ]]; then
  ok "partial: a failed first run publishes no receipt, dates or excluded.tsv"
else
  bad "partial-fresh: files left"; find "$root/usr/lib/ceralive/build-lock"
fi

# --- one index pass, however many packages ------------------------------------

# The point of auth_lookup_packages is that the capture reads the merged index a
# fixed number of times (once to dedupe it, once to resolve every package), not
# once per package. The result tests above cannot see that, so count it: common
# text tools are wrapped to log each run that names the index file, and a
# per-package lookup through any of them shows up as one run per package.
spy="$work/spy"
mkdir -p "$spy"
for tool in awk mawk gawk grep sed perl python3 cat; do
  real="$(command -v "$tool")" || continue
  printf '#!/bin/bash\nfor arg in "$@"; do [[ "$arg" == */Packages ]] && printf "%%s\\n" %s >>"$SCAN_LOG"; done\nexec %q "$@"\n' \
    "$tool" "$real" >"$spy/$tool"
  chmod +x "$spy/$tool"
done
scan_count() {  # scan_count <root> — index reads during one base capture
  : >"$work/scans"
  PATH="$spy:$PATH" SCAN_LOG="$work/scans" capture "$1" base 2>"$work/scan.err" \
    || { bad "scan count: capture failed"; cat "$work/scan.err" >&2; }
  wc -l <"$work/scans"
}
root="$work/scan-small"
make_tree "$root" "$FIXTURE/status"
small="$(scan_count "$root")"
root="$work/scan-large"
make_tree "$root" "$FIXTURE/status"
for n in $(seq 1 40); do
  printf '\nPackage: bulk%02d\nStatus: install ok installed\nArchitecture: arm64\nVersion: 1\n' "$n" >>"$root/var/lib/dpkg/status"
  printf 'Package: bulk%02d\nVersion: 1\nArchitecture: arm64\nFilename: pool/b/bulk%02d.deb\nSHA256: %s\n\n' "$n" "$n" "$(sha "bulk$n")" \
    >>"$root/var/lib/apt/lists/deb.debian.org_debian_dists_trixie_main_binary-arm64_Packages.bulk_Packages"
done
large="$(scan_count "$root")"
[[ "$(wc -l <"$root/usr/lib/ceralive/build-lock/base.jsonl")" -eq 54 ]] \
  || bad "scan count: the large tree did not record 54 packages"
if [[ "$small" -eq 2 && "$large" -eq 2 ]]; then
  ok "index read twice (dedupe + one lookup pass) for 14 and for 54 packages"
else
  bad "index read $small times for 14 packages and $large times for 54 (expected 2 and 2)"
fi

# --- optional: a full-size real index -----------------------------------------

if [[ -n "${CERALIVE_LOCK_CAPTURE_REAL_INDEX:-}" && -n "${CERALIVE_LOCK_CAPTURE_REAL_STATUS:-}" ]]; then
  full_admin="$work/full-admin"
  mkdir -p "$full_admin"
  cp "$CERALIVE_LOCK_CAPTURE_REAL_STATUS" "$full_admin/status"
  installed_tsv "$full_admin" >"$work/wanted-full"
  differential "full-size real index ($(wc -l <"$work/wanted-full") installed)" \
    "$CERALIVE_LOCK_CAPTURE_REAL_INDEX" "$work/wanted-full"
else
  printf '  skip full-size differential (set CERALIVE_LOCK_CAPTURE_REAL_INDEX and _STATUS)\n'
fi

#!/usr/bin/env bash
set -euo pipefail

layer="${1:?layer required}"
shift
case "$layer" in base|platform|runtime|app) ;; *) exit 2 ;; esac
source_dir="${SRCDIR:-${CHROOT_SRCDIR:-}}"
: "${source_dir:?mkosi source mount required for verified index helpers}"
: "${APT_SUITE:?suite must be forwarded by orchestrator}"
: "${APT_SUITE_UPDATES:?updates suite must be forwarded by orchestrator}"
: "${APT_SUITE_SECURITY:?security suite must be forwarded by orchestrator}"
source "${source_dir}/lib/fetch-debs-auth.sh"
log_error() { printf 'packages lock: %s\n' "$*" >&2; }

# The tree whose packages are captured. mkosi runs this script inside that tree
# (mkosi-chroot), so this is empty there and every path below is the chroot's
# own. tests/packages-lock-capture.test.sh points it at a fixture tree.
root="${CERALIVE_LOCK_CAPTURE_ROOT:-}"
receipts="$root/usr/lib/ceralive/build-lock"
mkdir -p "$receipts"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
index="$work/Packages"
: >"$index"
shopt -s nullglob

# mkosi >= 25 syncs apt's gpgv-verified InRelease/Packages ONCE per build into a
# package-manager metadata cache and bind-mounts it onto /var/lib/apt/lists only
# for the duration of an actual apt/dpkg transaction; it is never copied into the
# built rootfs, so /var/lib/apt/lists is permanently empty by the time any
# postinst/finalize script runs, on every layer, regardless of
# CleanPackageMetadata=. The verified index still exists on disk: mkosi's
# metadata-cache directory ("<cache-directory>/<cache_key>.metadata.cache/") is a
# plain subdirectory of $SRCDIR and stays mounted here even after a mkosi-chroot
# re-root into /buildroot (mkosi re-binds /work on top of the remap), so it is
# read as a fallback. CERALIVE_MKOSI_CACHE_DIR (orchestrate.sh) names the exact
# per-board/per-privilege-domain leaf; the <cache_key> prefix is globbed rather
# than hardcoded so a future mkosi renaming it does not silently defeat this
# check.
apt_lists_dirs=("$root/var/lib/apt/lists")
if [[ -n "${CERALIVE_MKOSI_CACHE_DIR:-}" ]]; then
  apt_lists_dirs+=("${source_dir}/${CERALIVE_MKOSI_CACHE_DIR}"/*.metadata.cache/lib/apt/lists)
fi

lists=()
for apt_lists_dir in "${apt_lists_dirs[@]}"; do
  lists+=("${apt_lists_dir}"/*deb.debian.org*_Packages*)
done
(( ${#lists[@]} > 0 )) || { log_error "$layer: no apt-verified Debian Packages lists"; exit 1; }
for list in "${lists[@]}"; do
  /usr/lib/apt/apt-helper cat-file "$list" >>"$index"
  printf '\n' >>"$index"
done

# Debian legitimately re-publishes the SAME package/version/sha256 across
# multiple suites (trixie-security commonly mirrors a trixie entry byte-for-byte
# under a different pool path), and this layer's index now spans all three
# forwarded suites (APT_SUITE*) at once. auth_lookup_package requires EXACTLY
# ONE matching stanza, so an unambiguous package that happens to be verified
# twice would otherwise read as "not found". Collapse stanzas that agree on
# name+version+arch+sha256 to one; stanzas that DISAGREE on sha256 for the same
# name+version+arch are left as distinct rows, so that real ambiguity still
# fails the lookup exactly as before.
index_dedup="$work/Packages.dedup"
awk -v RS='' -v ORS='\n\n' '
  {
    pkg = ""; ver = ""; arch = ""; sha = ""
    n = split($0, ln, "\n")
    for (i = 1; i <= n; i++) {
      if (ln[i] ~ /^Package: /) pkg = substr(ln[i], 10)
      else if (ln[i] ~ /^Version: /) ver = substr(ln[i], 10)
      else if (ln[i] ~ /^Architecture: /) arch = substr(ln[i], 15)
      else if (ln[i] ~ /^SHA256: /) sha = substr(ln[i], 9)
    }
    key = pkg SUBSEP ver SUBSEP arch SUBSEP sha
    if (!(key in seen)) { seen[key] = 1; print }
  }
' "$index" >"$index_dedup"
mv "$index_dedup" "$index"

# Packages named on the command line are excluded from THIS layer's Debian-
# archive check because they are BSP/first-party origin, verified separately by
# the host-side fetch stage's own receipt (staging/packages-lock/*.jsonl, folded
# in by the final [6d/9] merge) — never by an apt index. That exclusion is a
# per-INVOCATION argument, though, and only the layer that actually installs a
# given BSP package (platform, for the kernel/DTB/U-Boot/firmware set) lists it.
# A LATER layer's dpkg status still carries that package (it stays installed),
# but that layer's own invocation never names it as excluded, so without a
# persistent record the "previously accounted for" check below cannot see it and
# tries — and fails — to verify a non-Debian package against the Debian archive.
# excluded.tsv is that record: written once, by whichever layer's exclusion list
# first names an installed package, and read by every later layer alongside the
# .jsonl receipts. It ships in the same directory the .jsonl receipts already
# do; packages-lock.py only globs *.jsonl, so this file is inert to it.
excluded_marker="$receipts/excluded.tsv"
: >>"$excluded_marker"

output="$receipts/$layer.jsonl"
# A layer's OWN receipt from an earlier run of this script is not "previously
# accounted for": a second run would then skip every package it verified and
# leave the receipt empty. mkosi used to run base/mkosi.finalize twice (see
# tests/mkosi-contract.bats), which shipped an empty base.jsonl and made the
# platform layer re-verify all of base. Only OTHER layers' receipts count, so a
# re-run re-verifies and writes the same rows again.
previous="$work/previous"
: >"$previous"
for receipt in "$receipts"/*.jsonl; do
  [[ -f "$receipt" && "$receipt" != "$output" ]] || continue
  awk -F'"' '{print $4 "\t" $8 "\t" $12}' "$receipt" >>"$previous"
done
cat "$excluded_marker" >>"$previous"
declare -A accounted=()
while IFS= read -r line || [[ -n "$line" ]]; do
  accounted["$line"]=1
done <"$previous"
: >"$output"
dpkg-query --admindir="$root/var/lib/dpkg" -W -f='${Package}\t${Version}\t${Architecture}\t${Status}\n' >"$work/status"

# Resolve every installed package against the index in ONE pass
# (auth_lookup_packages: same exactly-one-stanza rule as auth_lookup_package).
# Looking each package up separately re-read the ~75 MB index once per package,
# about 9 s each under qemu-user and most of the build's mkosi time. Packages
# without exactly one verified stanza get no row and fail in the loop below.
awk -F'\t' '$4 ~ / ok installed$/ {print $1 "\t" $2 "\t" $3}' "$work/status" >"$work/wanted"
declare -A resolved=()
if [[ -s "$index" ]]; then
  auth_lookup_packages "$index" "$work/wanted" >"$work/resolved" || {
    log_error "$layer: could not read the verified Debian Packages index"
    exit 1
  }
  while IFS=$'\t' read -r r_name r_version r_arch r_row; do
    resolved["$r_name"$'\t'"$r_version"$'\t'"$r_arch"]="$r_row"
  done <"$work/resolved"
fi

while IFS=$'\t' read -r name version arch status; do
  [[ "$status" == *' ok installed' ]] || continue
  skip=0
  for excluded in "$@"; do
    [[ "$name" != "$excluded" ]] || skip=1
  done
  if (( skip == 1 )); then
    printf '%s\t%s\t%s\n' "$name" "$version" "$arch" >>"$excluded_marker"
    continue
  fi
  key="$name"$'\t'"$version"$'\t'"$arch"
  [[ -z "${accounted[$key]+x}" ]] || continue
  [[ -s "$index" ]] || log_error "$layer: verified Debian Packages index is missing or empty: $index"
  [[ -n "${resolved[$key]+x}" ]] || {
    log_error "$layer: newly installed $name=$version/$arch has no verified Debian Packages SHA256"
    exit 1
  }
  IFS=$'\t' read -r _filename sha resolved_version <<<"${resolved[$key]}"
  [[ "$resolved_version" == "$version" && "$sha" =~ ^[0-9a-f]{64}$ ]] || exit 1
  printf '{"name":"%s","version":"%s","arch":"%s","origin":"debian","sha256":"%s"}\n' \
    "$name" "$version" "$arch" "$sha" >>"$output"
done < "$work/status"

dates="$receipts/$layer.dates"
: >"$dates"
for apt_lists_dir in "${apt_lists_dirs[@]}"; do
  for release in "${apt_lists_dir}"/*deb.debian.org*_InRelease; do
    [[ -f "$release" ]] || continue
    suite="${release##*_dists_}"
    suite="${suite%_InRelease}"
    case "$suite" in
      "$APT_SUITE"|"$APT_SUITE_UPDATES"|"$APT_SUITE_SECURITY") ;;
      *) continue ;;
    esac
    date="$(awk '/^Date: / {sub(/^Date: /, ""); print; exit}' "$release")"
    [[ -n "$date" ]] || { log_error "$layer: missing Release Date for $suite"; exit 1; }
    printf '%s\t%s\n' "$suite" "$date" >>"$dates"
  done
done

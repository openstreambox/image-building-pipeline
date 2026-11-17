#!/usr/bin/env bash
#
# verify-no-apt-archives.sh — assert an emitted rootfs tar ships no downloaded apt
# packages in apt's archive directories.
#
# The app layer empties both directories a build can download into (apt's default
# /var/cache/apt/archives and the device cache /data/ceralive/apt-archives that
# 81ceralive-cache redirects to) and checks them in the chroot. This is the same
# check against the artifact that actually ships, so a later step, or a clean
# that followed the wrong Dir::Cache::archives, cannot slip packages past it.
#
# Only those two directories are judged: a .deb anywhere else in the tree is not
# this check's business. Inside them every package name counts, whatever its
# version, architecture or suffix (.deb, .udeb, .ddeb, .deb.FAILED), and so does
# any file left in partial/.
#
# Usage: verify-no-apt-archives.sh <rootfs.tar>

set -euo pipefail

PROG="$(basename "${BASH_SOURCE[0]}")"
log() { printf '[%s] %s\n' "${PROG}" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# Kept in step with the runtime layer's 81ceralive-cache by
# tests/apt-archives-shipped.test.sh.
APT_ARCHIVE_DIRS=(var/cache/apt/archives data/ceralive/apt-archives)

(($# == 1)) || die "usage: ${PROG} <rootfs.tar>"
TAR="$1"
[[ -f "${TAR}" ]] || die "no such tar: ${TAR}"

members="$(mktemp)"
trap 'rm -f "${members}"' EXIT
tar -tf "${TAR}" >"${members}" || die "cannot list ${TAR}"

found="$(awk -v dirs="${APT_ARCHIVE_DIRS[*]}" '
  BEGIN { n = split(dirs, d, " ") }
  {
    name = $0
    sub(/^\.\//, "", name)
    if (name ~ /\/$/) next
    for (i = 1; i <= n; i++) {
      prefix = d[i] "/"
      if (substr(name, 1, length(prefix)) != prefix) continue
      rest = substr(name, length(prefix) + 1)
      if (rest ~ /\.(u|d)?deb(\.[^\/]*)?$/ || rest ~ /^partial\/./) print name
    }
  }' "${members}")"

if [[ -n "${found}" ]]; then
  log "$(wc -l <<<"${found}") downloaded package file(s) in the rootfs, first ones:"
  head -n 5 <<<"${found}" | sed 's/^/  /' >&2
  die "${TAR} ships downloaded apt packages"
fi
log "no downloaded apt packages in ${TAR}"

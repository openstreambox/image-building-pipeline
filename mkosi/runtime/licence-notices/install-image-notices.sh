#!/usr/bin/env bash
#
# install-image-notices.sh — licence and notice texts for the files the image
# build installs itself, outside any package.
#
# Run by the app layer (mkosi.images/app/mkosi.postinst.chroot). The runtime layer
# copies this repository's scripts, units and configuration into the rootfs, and
# the portal brand mark to /usr/share/ceralive/brand; no package owns them, so no
# copyright file covers them. image-notices.tsv (next to this script) names each
# text, its source and commit, and its sha256; texts/ holds the verbatim copies.
# This installs every text unchanged at its destination and adds a README naming
# where the repository's licence files came from. Nothing here writes licence
# terms of its own.
#
# The brand notice describes one exact file: when the brand mark is installed, its
# sha256 must equal the one recorded for it in the pinned brand-assets.lock.json.
#
# Fails the build when a row is malformed, a pinned text is missing or changed, a
# destination is a symlink, or the installed brand mark is not the pinned one.
#
# Test seams: IMAGE_NOTICES_DESTROOT (install prefix, default /),
# IMAGE_NOTICES_TABLE.
#
# shellcheck shell=bash

set -euo pipefail

log() { printf '[image-notices] %s\n' "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TABLE="${IMAGE_NOTICES_TABLE:-${HERE}/image-notices.tsv}"
DESTROOT="${IMAGE_NOTICES_DESTROOT:-}"
BRAND_MARK="/usr/share/ceralive/brand/ceralive-mark-small-dark.svg"
LICENCE_DIR="/usr/share/licenses/image-building-pipeline"

[[ -f "${TABLE}" ]] || die "notice table not found: ${TABLE}"
BASE="$(dirname -- "${TABLE}")"

licence_source="" licence_commit="" brand_lock=""
rows=0
while IFS=$'\t' read -r dest source commit path text sha extra || [[ -n "${dest:-}" ]]; do
  [[ -z "${dest}" || "${dest}" == \#* ]] && continue
  if [[ "${dest}" != /* || "${dest}" == */../* || "${dest}" == */.. || -z "${source}" \
        || ! "${commit}" =~ ^[0-9a-f]{40}$ || -z "${path}" || -z "${text}" \
        || ! "${sha}" =~ ^[0-9a-f]{64}$ || -n "${extra}" ]]; then
    die "malformed row for '${dest}' in ${TABLE}"
  fi
  [[ -f "${BASE}/${text}" ]] || die "pinned notice text missing: ${BASE}/${text}"
  actual="$(sha256sum "${BASE}/${text}" | awk '{print $1}')"
  [[ "${actual}" == "${sha}" ]] || die "pinned notice text changed: ${text} (expected ${sha}, got ${actual})"

  target="${DESTROOT}${dest}"
  if [[ -L "${target}" || -L "$(dirname -- "${target}")" ]]; then
    die "refusing to write ${dest} through a symlink"
  fi
  install -D -m 0644 "${BASE}/${text}" "${target}"
  log "installed ${dest} (${path} at ${commit:0:12})"
  rows=$((rows + 1))

  if [[ "${dest}" == "${LICENCE_DIR}/"* ]]; then
    if [[ -n "${licence_commit}" && ( "${licence_source}" != "${source}" || "${licence_commit}" != "${commit}" ) ]]; then
      die "licence rows for ${LICENCE_DIR} must name one source and commit"
    fi
    licence_source="${source}" licence_commit="${commit}"
  fi
  [[ "${dest}" != */brand-assets.lock.json ]] || brand_lock="${BASE}/${text}"
done < "${TABLE}"
(( rows > 0 )) || die "no notice rows in ${TABLE}"

if [[ -n "${licence_commit}" ]]; then
  install -d -m 0755 "${DESTROOT}${LICENCE_DIR}"
  cat > "${DESTROOT}${LICENCE_DIR}/README" <<EOF
image-building-pipeline

These are the licence files of the source repository that builds this image,
copied verbatim from ${licence_source} at
${licence_commit}. The scripts, service units and configuration that
the build installs from that repository, and that no package owns, come from it.

The brand mark under /usr/share/ceralive/brand is not covered by these licence
files. Its own notice and the record of where it comes from are next to it.
EOF
  chmod 0644 "${DESTROOT}${LICENCE_DIR}/README"
fi

if [[ -e "${DESTROOT}${BRAND_MARK}" ]]; then
  [[ -n "${brand_lock}" ]] || die "${BRAND_MARK} is installed but no brand-assets.lock.json row names its origin"
  expected="$(awk -v want="/$(basename -- "${BRAND_MARK}")" '
    /"to":/ { to = $0; sub(/.*"to":[[:space:]]*"/, "", to); sub(/".*/, "", to) }
    /"sha256":/ {
      sha = $0; sub(/.*"sha256":[[:space:]]*"/, "", sha); sub(/".*/, "", sha)
      if (substr(to, length(to) - length(want) + 1) == want) print sha
    }' "${brand_lock}")"
  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || die "brand-assets.lock.json records no sha256 for ${BRAND_MARK}"
  actual="$(sha256sum "${DESTROOT}${BRAND_MARK}" | awk '{print $1}')"
  [[ "${actual}" == "${expected}" ]] \
    || die "installed ${BRAND_MARK} (${actual}) is not the pinned brand asset (${expected}); refresh its notice"
  log "brand mark matches its pinned origin (${expected:0:12})"
fi

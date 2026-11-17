#!/usr/bin/env bash
#
# install-licence-notices.sh — licence texts for first-party packages that ship
# without a copyright file.
#
# Run by the app layer (mkosi.images/app/mkosi.postinst.chroot) after the
# first-party .debs are installed. notices.tsv (next to this script) names, per
# package version, the component sources and the exact licence files at pinned
# commits; texts/ holds verbatim copies pinned by sha256. For every INSTALLED
# package named there this writes /usr/share/doc/<package>/copyright, the only
# doc file name the image keeps. A component whose source has no licence file is
# listed as such, and no text is reproduced for it.
#
# Fails the build when a row is malformed, a pinned text is missing or changed,
# an installed package's version differs from its rows (refresh them together
# with the pin), or the package already ships its own copyright file (drop its
# rows). Packages that are not installed are skipped.
#
# Test seams: LICENCE_NOTICES_DESTROOT (install prefix, default /),
# LICENCE_NOTICES_DPKG_QUERY (dpkg-query stand-in), LICENCE_NOTICES_TABLE.
#
# shellcheck shell=bash

set -euo pipefail

log() { printf '[licence-notices] %s\n' "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TABLE="${LICENCE_NOTICES_TABLE:-${HERE}/notices.tsv}"
DESTROOT="${LICENCE_NOTICES_DESTROOT:-}"
QUERY="${LICENCE_NOTICES_DPKG_QUERY:-dpkg-query}"
RULE='=============================================================================='

[[ -f "${TABLE}" ]] || die "notice table not found: ${TABLE}"
BASE="$(dirname -- "${TABLE}")"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Query the complete database once. Failure cannot mean "not installed".
"${QUERY}" -W -f='${Package} ${db:Status-Status} ${Version}\n' > "${WORK}/installed" \
  || die "dpkg-query failed; cannot establish installed package coverage"
installed_version() {
  awk -v pkg="$1" '$1 == pkg && $2 == "installed" {print $3}' "${WORK}/installed"
}
packages=()
while IFS=$'\t' read -r pkg ver component source commit path text sha extra || [[ -n "${pkg:-}" ]]; do
  [[ -z "${pkg}" || "${pkg}" == \#* ]] && continue
  if [[ -z "${ver}" || -z "${component}" || -z "${source}" || ! "${commit}" =~ ^[0-9a-f]{40}$ \
        || -z "${path}" || -z "${text}" || -z "${sha}" || -n "${extra}" ]]; then
    die "malformed row for '${pkg}' in ${TABLE}"
  fi
  if [[ "${text}" == "-" ]]; then
    [[ "${path}" == "-" && "${sha}" == "-" ]] || die "row for '${pkg}' (${component}) mixes '-' with a text"
  else
    [[ -f "${BASE}/${text}" ]] || die "pinned licence text missing: ${BASE}/${text}"
    actual="$(sha256sum "${BASE}/${text}" | awk '{print $1}')"
    [[ "${actual}" == "${sha}" ]] || die "pinned licence text changed: ${text} (expected ${sha}, got ${actual})"
  fi

  installed="$(installed_version "${pkg}")"
  if [[ -z "${installed}" ]]; then
    log "${pkg} is not installed in this image; skipped"
    continue
  fi
  [[ "${installed}" == "${ver}" ]] \
    || die "${pkg} ${installed} is installed, but notices.tsv pins ${ver}; refresh its rows"

  if [[ ! -f "${WORK}/${pkg}" ]]; then
    packages+=("${pkg}")
    {
      printf '%s %s\n\n' "${pkg}" "${ver}"
      printf 'This package ships without a copyright file. The image build added this\n'
      printf 'one, with licence texts copied verbatim from the sources named below.\n'
    } > "${WORK}/${pkg}"
  fi
  {
    printf '\n%s\nComponent: %s\nSource: %s at %s\n' "${RULE}" "${component}" "${source}" "${commit}"
    if [[ "${text}" == "-" ]]; then
      printf '%s\n\n' "${RULE}"
      printf 'No licence file exists in this source at this commit, so no licence text\n'
      printf 'is reproduced for this component. The other texts in this file do not\n'
      printf 'cover it.\n'
    else
      printf 'File: %s\n%s\n\n' "${path}" "${RULE}"
      cat "${BASE}/${text}"
    fi
  } >> "${WORK}/${pkg}"
done < "${TABLE}"

for pkg in "${packages[@]}"; do
  docdir="${DESTROOT}/usr/share/doc/${pkg}"
  if [[ -L "${docdir}" || -e "${docdir}/copyright" || -L "${docdir}/copyright" ]]; then
    die "${pkg} now ships its own /usr/share/doc/${pkg}; drop its rows from notices.tsv"
  fi
  install -D -m 0644 "${WORK}/${pkg}" "${docdir}/copyright"
  log "wrote /usr/share/doc/${pkg}/copyright"
done

# Scope follows the first-party application package list. Two packages without
# public texts are explicit outstanding gaps, documented beside this script.
while read -r pkg; do
  [[ -z "${pkg}" || "${pkg}" == \#* ]] && continue
  [[ -n "$(installed_version "${pkg}")" ]] || continue
  [[ -s "${DESTROOT}/usr/share/doc/${pkg}/copyright" ]] \
    || die "installed first-party package lacks copyright: ${pkg}"
done < "${LICENCE_NOTICES_COVERAGE:-${HERE}/copyright-required.txt}"

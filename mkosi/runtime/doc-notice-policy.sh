#!/usr/bin/env bash
#
# doc-notice-policy.sh — the ONE rule for what survives the /usr/share/doc prune.
#
# Sourced by both consumers, so the build and the device cannot disagree:
#   * the app layer's prune_package_docs() (mkosi.images/app/mkosi.postinst.chroot),
#     from ${SRCDIR}/runtime/doc-notice-policy.sh at build time;
#   * the on-device apt hook ceralive-reprune (mkosi/runtime/ceralive-reprune.sh),
#     from /usr/lib/ceralive/doc-notice-policy.sh, which the runtime layer installs.
#
# KEPT: every regular file whose name, or whose directory below the package's doc
# directory, names a licence, notice or authorship text: copyright (and
# copyright.fonts.gz style variants), COPYING*, LICENSE/LICENCE*, NOTICE*, AUTHORS*,
# CREDITS*, CONTRIBUTORS*, PATENTS*, WHENCE*, EULA*, and third-party/attribution
# texts, in any letter case and with any compression suffix. Several Debian
# packages carry their Apache NOTICE, a second copyright file or their authors list
# only there, so keeping `copyright` alone dropped texts the package ships.
# EVERYTHING ELSE under the doc root (changelogs, READMEs, examples) is removed.
#
# Never follows a symlink: a symlink is neither kept-by-target nor descended into,
# and a doc root that is itself a symlink is refused, so a link can neither
# preserve an unchecked document nor point the delete outside the doc root.
# Directory symlinks (Debian's /usr/share/doc/<pkg> -> <sibling>) stay as they are.
#
# Library only: no shell options are changed, nothing runs on source. Callers own
# their failure policy (the build dies on a non-zero return, the apt hook logs).
#
# shellcheck shell=bash

# doc_notice_name_kept <name> — 0 when one path component names a notice text.
doc_notice_name_kept() {
  local name="${1,,}"
  [[ "${name}" =~ (^|[^a-z0-9])(copyrights?|copying|licen[cs]es?|notices?|authors?|credits|contributors|patents?|whence|eula)[0-9]*([^a-z0-9]|$) ]] \
    && return 0
  [[ "${name}" =~ third[-_.]?part(y|ies)|attributions? ]]
}

# doc_notice_path_kept <path relative to the doc root> — 0 when the file is kept.
# The first component is the package's directory and is not judged (a package
# named, say, license-reconcile must not keep its whole doc tree); every component
# below it is.
doc_notice_path_kept() {
  local rel="$1" rest
  if [[ "${rel}" != */* ]]; then
    doc_notice_name_kept "${rel}"
    return
  fi
  rest="${rel#*/}"
  while :; do
    doc_notice_name_kept "${rest%%/*}" && return 0
    [[ "${rest}" == */* ]] || return 1
    rest="${rest#*/}"
  done
}

# doc_notice_prune <doc root> — remove every regular file the policy does not
# keep, then the directories that became empty. Returns non-zero (after doing what
# it safely can) on an unsafe root or a file it could not remove.
doc_notice_prune() {
  local root="${1%/}" file rel status=0
  [[ -n "${root}" && "${root}" == /* && "${root}" != / ]] || {
    printf 'doc-notice-policy: refusing unsafe doc root: %s\n' "${1}" >&2
    return 2
  }
  [[ -d "${root}" ]] || return 0
  [[ ! -L "${root}" ]] || {
    printf 'doc-notice-policy: refusing symlinked doc root: %s\n' "${root}" >&2
    return 2
  }
  local list
  list="$(mktemp)" || return 1
  find "${root}" -xdev -mindepth 1 -type f -print0 >"${list}" || status=1
  while IFS= read -r -d '' file; do
    rel="${file#"${root}"/}"
    doc_notice_path_kept "${rel}" && continue
    rm -f -- "${file}" || status=1
  done <"${list}"
  rm -f -- "${list}"
  find "${root}" -xdev -mindepth 1 -depth -type d -empty -delete || status=1
  return "${status}"
}

#!/usr/bin/env bash
# kernel/cache-dir.sh — where the kernel caches live. Sourced, never executed.
#
# CERALIVE_KERNEL_CACHE_DIR moves the kernel caches (artifact cache, ccache and
# the default source mirror) out of the checkout, so every checkout on one host
# shares them. Unset keeps the in-tree defaults. Artifact entries stay keyed by
# the full input fingerprint, so a shared root changes who can reuse an entry,
# never which entry a build accepts.
#
# shellcheck shell=bash

# kernel_shared_cache_dir [<in-tree path>] — the shared root, or with an
# argument the same leaf under it (the ccache and the source mirror: the leaf
# names stay defined once, in lib/paths.sh). Prints nothing when unset.
kernel_shared_cache_dir() {
  local dir="${CERALIVE_KERNEL_CACHE_DIR:-}" leaf=""
  [[ -n "${dir}" ]] || return 0
  if [[ "${dir}" != /* || "${dir}" == *$'\n'* ]]; then
    die "CERALIVE_KERNEL_CACHE_DIR must be an absolute path (got '${dir}')"
    return 1
  fi
  dir="${dir%/}"
  if (( $# )); then
    leaf="${1##*/}"
    if [[ -z "${leaf}" || "${leaf}" == . || "${leaf}" == .. ]]; then
      die "no kernel cache leaf name in '${1}'"
      return 1
    fi
    dir="${dir}/${leaf}"
  fi
  printf '%s' "${dir}"
}

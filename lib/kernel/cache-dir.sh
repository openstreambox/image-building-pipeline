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

# kernel_cache_dir_trusted <dir> — refuse a directory another account controls:
# it must be owned by the effective uid and not writable by group or other (the
# rule ssh's StrictModes applies). An absent directory is created later with
# the caller's umask and passes.
kernel_cache_dir_trusted() {
  local dir="$1" owner mode
  [[ -e "${dir}" ]] || return 0
  if [[ -L "${dir}" || ! -d "${dir}" ]]; then
    die "kernel cache directory ${dir} is not a plain directory"
    return 1
  fi
  read -r owner mode < <(stat -c '%u %a' -- "${dir}") || return 1
  if [[ "${owner}" != "$(id -u)" ]] || (( (8#${mode} & 8#022) != 0 )); then
    die "kernel cache directory ${dir} must be owned by uid $(id -u) and not group/other writable (owner ${owner}, mode ${mode})"
    return 1
  fi
}

# kernel_shared_cache_dir [<in-tree path>] — the shared root, or with an
# argument the same leaf under it (the ccache and the source mirror: the leaf
# names stay defined once, in lib/paths.sh). Prints nothing when unset.
kernel_shared_cache_dir() {
  local dir="${CERALIVE_KERNEL_CACHE_DIR:-}" leaf=""
  [[ -n "${dir}" ]] || return 0
  # ':' and ',' would split the container -v mount specification.
  if [[ "${dir}" != /* || "${dir}" == *$'\n'* || "${dir}" == *[:,]* ]]; then
    die "CERALIVE_KERNEL_CACHE_DIR must be an absolute path without ':' or ',' (got '${dir}')"
    return 1
  fi
  dir="${dir%/}"
  kernel_cache_dir_trusted "${dir}" || return 1
  if (( $# )); then
    leaf="${1##*/}"
    if [[ -z "${leaf}" || "${leaf}" == . || "${leaf}" == .. ]]; then
      die "no kernel cache leaf name in '${1}'"
      return 1
    fi
    dir="${dir}/${leaf}"
    kernel_cache_dir_trusted "${dir}" || return 1
  fi
  printf '%s' "${dir}"
}

# kernel_ccache_leaf <ccache base> <builder image id> — one ccache directory per
# builder image. ccache's default compiler check (mtime) stats only the gcc
# driver, not the assembler or linker, so a shared directory must never serve
# two toolchains; the image id covers every binary in the image.
kernel_ccache_leaf() {
  local base="${1%/}" id="${2#sha256:}"
  [[ "${id}" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s/%s' "${base}" "${id}"
}

# kernel_ccache_owner <runtime> — uid:gid the container hands /ccache back to,
# or empty. Only a rootful Docker daemon writes host-uid-0 files; rootless
# Docker and Podman already map container root to the invoking user.
kernel_ccache_owner() {
  local runtime="$1" options
  [[ "${runtime}" == docker && "$(id -u)" != 0 ]] || return 0
  options="$(docker info --format '{{.SecurityOptions}}' 2>/dev/null)" || return 0
  [[ "${options}" == *rootless* ]] && return 0
  printf '%s:%s' "$(id -u)" "$(id -g)"
}

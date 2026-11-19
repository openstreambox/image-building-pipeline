#!/usr/bin/env bash
#
# bundle-version.test.sh — the RAUC bundle's [update] version and build fields.
#
# A box shows each slot's bundle version in its slot list. With only the git
# short SHA there, a slot installed by OTA showed the pipeline commit while the
# rootfs said 2026.11.x. A release build sets CERALIVE_OS_RELEASE_VERSION, which
# is what /etc/ceralive/os-release-version holds, so the bundle now carries the
# same CalVer; without it the short SHA stays the default. The full commit goes
# into the manifest's [update] build field either way, so provenance is kept.
#
# Part A — stage_mkosi picks the version (stubbed build, no mkosi).
# Part B — write_manifest writes the build field only when it has one.
# The real-rauc round trip (rauc info, deferred-signing check) is in
# tests/deferred-rauc-signing.test.sh.
#
# Profile: contract-test (docs/shell-profiles.md) — collects, owns its exit code.
#
# shellcheck disable=SC2016 # the bash -c bodies expand in the child shell

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
COMMON_SH="${PIPELINE_DIR}/lib/common.sh"
MKOSI_STAGE="${PIPELINE_DIR}/lib/stages/mkosi.sh"
BUNDLE="${PIPELINE_DIR}/lib/build-bundle.sh"

# shellcheck source=lib/assertions.sh
source "${HERE}/lib/assertions.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

short_sha="$(GIT_MASTER=1 git -C "${PIPELINE_DIR}" rev-parse --short HEAD)"
full_sha="$(GIT_MASTER=1 git -C "${PIPELINE_DIR}" rev-parse HEAD)"

# stage_mkosi in a child shell with every build step stubbed; prints the chosen
# build_version. A refusal dies, so the shell exits non-zero before printing and
# the die message is left in ${WORK}/stage.log.
stage_version() { # [env...]
  env -u CERALIVE_OS_RELEASE_VERSION "$@" bash -c '
    source "$1"; source "$2"
    prune_local_conf_lock() { :; }
    prune_local_conf_preflight_locked() { :; }
    generate_prune_local_conf() { :; }
    prune_local_conf_cleanup() { :; }
    run_mkosi_build() { :; }
    MKOSI_DIR="$3"; PIPELINE_DIR="$4"; mkosi_arch=arm64; bsp_dir=; firstparty_dir=
    stage_mkosi >/dev/null
    printf "%s\n" "${build_version}"
  ' _ "${COMMON_SH}" "${MKOSI_STAGE}" "${WORK}/mkosi" "${PIPELINE_DIR}" 2>"${WORK}/stage.log"
}
mkdir -p "${WORK}/mkosi/build/app"

printf '== A: stage_mkosi bundle version\n'
assert_eq "CERALIVE_OS_RELEASE_VERSION becomes the bundle version" \
  2026.11.11192 "$(stage_version CERALIVE_OS_RELEASE_VERSION=2026.11.11192)"
assert_eq "without it the git short SHA stays the default" \
  "${short_sha}" "$(stage_version)"
assert_eq "an empty value is the same as unset" \
  "${short_sha}" "$(stage_version CERALIVE_OS_RELEASE_VERSION=)"
for bad_version in 69d7b4e 2026.11 v2026.11.3 '2026.11.3 ' '2026.11.3-rc1'; do
  out="$(stage_version CERALIVE_OS_RELEASE_VERSION="${bad_version}")"
  rc=$?
  if [[ "${rc}" -ne 0 && -z "${out}" ]] && grep -q 'must be YYYY.MINOR.PATCH CalVer' "${WORK}/stage.log"; then
    ok "a non-CalVer value ('${bad_version}') stops the build"
  else
    bad "a non-CalVer value ('${bad_version}') was accepted (rc ${rc}, version '${out}')"
  fi
done

printf '== B: write_manifest build field\n'
manifest() { # <out> <board> <build>
  env BOARD_ID="$2" bash -c 'source "$1"; write_manifest "$2" ceralive-rock-5b-plus 2026.11.11192 "$3"' \
    _ "${BUNDLE}" "$1" "$3" >/dev/null 2>&1
}
manifest "${WORK}/with.raucm" rock-5b-plus "${full_sha}"
expected="[update]
compatible=ceralive-rock-5b-plus
version=2026.11.11192
build=${full_sha}

[bundle]
format=verity

[image.rootfs]
filename=rootfs.ext4
adaptive=block-hash-index

[hooks]
filename=layout-check
hooks=install-check"
assert_eq "the manifest carries the version and the full commit as build" \
  "${expected}" "$(cat "${WORK}/with.raucm")"
manifest "${WORK}/without.raucm" x86-64 ""
if grep -q '^build=' "${WORK}/without.raucm"; then
  bad "a build field is written without a commit"
else
  ok "no build field without a commit"
fi
assert_eq "the rest of the manifest is unchanged without a commit" \
  "$(grep -v '^build=' "${WORK}/with.raucm" | sed '/^$/,$d')" "$(sed '/^$/,$d' "${WORK}/without.raucm")"

# bundle_identity hands the full commit to both signing paths.
build="$(COMPATIBLE_STRING=ceralive-x86-64 BUNDLE_OUT_DIR="${WORK}/out" bash -c 'source "$1"; bundle_identity x86-64; printf "%s\n" "${build}"' \
  _ "${BUNDLE}" 2>/dev/null)"
assert_eq "bundle_identity sets build to the full pipeline commit" "${full_sha}" "${build}"

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]

#!/usr/bin/env bash
# Select the guest-only privileged contract rows for ./run-tests on this runner.
#
# Usage: ci/privileged-contracts.sh <env-file>   (in Actions: "$GITHUB_ENV")
#
# Only the real RAUC contract needs a marked disposable KVM/QEMU guest: it can
# unmount any /mnt/rauc/* mount, bind over /proc/cmdline and expose rootfs_a/b
# partition labels to host udev. On a marked guest it runs; anywhere else (an
# ordinary hosted runner, a workstation) it is skipped with a visible
# "skipped: needs marked guest" line instead of failing at the guard.
# The confined privileged rows (real Avahi, real kernel stage) are not selected
# here: the hosted job requires them directly.
# This only selects rows: each guarded harness still sources the guard itself
# and refuses on direct invocation. It never runs a privileged harness.
# How a guest is marked: docs/recovery-witness.md, "Privileged harness boundary".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:?usage: ci/privileged-contracts.sh <env-file>}"
# Test seam: a copy of the guard with a temporary marker path.
guard="${CERALIVE_GUEST_GUARD:-${ROOT}/tests/lib/require-disposable-guest.sh}"
if bash -c 'source "$1"' guard "${guard}" 2>/dev/null; then
  mode=marked rauc=disposable-marked-guest-only
else
  mode=unmarked rauc=skip
fi
printf 'CERALIVE_RUN_REAL_RAUC_CONTRACT=%s\n' "${rauc}" >>"${out}"
if [[ "${mode}" == unmarked ]]; then
  msg='skipped: needs marked guest (real RAUC contract)'
  printf '::notice title=Privileged contracts::%s\n' "${msg}"
  printf '%s\n' "${msg}"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "${msg}" >>"${GITHUB_STEP_SUMMARY}"
  fi
else
  printf 'privileged contracts: marked disposable guest, real RAUC contract runs\n'
fi

#!/usr/bin/env bash
# Select the real RAUC contract rows for ./run-tests on this runner.
#
# Usage: ci/privileged-contracts.sh <env-file>   (in Actions: "$GITHUB_ENV")
#
# The real RAUC contract changes host state: it can unmount any /mnt/rauc/*
# mount, binds over /proc/cmdline and exposes rootfs_a/b partition labels to
# host udev. It runs only where the machine is thrown away afterwards:
#   * a marked disposable KVM/QEMU guest   -> disposable-marked-guest-only
#   * a GitHub-hosted ephemeral runner VM  -> github-hosted-ephemeral
#     (GITHUB_ACTIONS=true, RUNNER_ENVIRONMENT=github-hosted, a VM)
# Anywhere else (a workstation, a self-hosted runner) it is skipped with a
# visible "skipped: needs marked guest" line instead of failing at the guard.
# The confined privileged rows (real Avahi, real kernel stage) are not selected
# here: the hosted job requires them directly.
# This only selects rows: each RAUC harness still sources its guard
# (tests/lib/require-ephemeral-host.sh) and refuses on direct invocation.
# How a guest is marked: docs/recovery-witness.md, "Privileged harness boundary".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:?usage: ci/privileged-contracts.sh <env-file>}"
# Test seam: a copy of the guard with a temporary marker path.
guard="${CERALIVE_GUEST_GUARD:-${ROOT}/tests/lib/require-disposable-guest.sh}"
virt="$(systemd-detect-virt --vm 2>/dev/null || true)"
if bash -c 'source "$1"' guard "${guard}" 2>/dev/null; then
  mode=marked rauc=disposable-marked-guest-only
elif [[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted \
        && -n "${virt}" && "${virt}" != none ]]; then
  mode=hosted rauc=github-hosted-ephemeral
else
  mode=unmarked rauc=skip
fi
printf 'CERALIVE_RUN_REAL_RAUC_CONTRACT=%s\n' "${rauc}" >>"${out}"
case "${mode}" in
  unmarked)
    msg='skipped: needs marked guest (real RAUC contract)'
    printf '::notice title=Privileged contracts::%s\n' "${msg}"
    printf '%s\n' "${msg}"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      printf '%s\n' "${msg}" >>"${GITHUB_STEP_SUMMARY}"
    fi
    ;;
  hosted) printf 'privileged contracts: GitHub-hosted ephemeral runner, real RAUC contract runs\n' ;;
  *) printf 'privileged contracts: marked disposable guest, real RAUC contract runs\n' ;;
esac

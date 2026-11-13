#!/usr/bin/env bash
# Select the privileged contract rows for ./run-tests on this runner.
#
# Usage: ci/privileged-contracts.sh <env-file>   (in Actions: "$GITHUB_ENV")
#
# On a marked disposable KVM/QEMU guest every guarded row runs. Anywhere else
# (an ordinary hosted runner, a workstation) the guarded rows are skipped with a
# visible "skipped: needs marked guest" line instead of failing at the guard.
# This only selects rows: each privileged harness still sources the guard
# itself and refuses on direct invocation. It never runs a privileged harness.
# How a guest is marked: docs/recovery-witness.md, "Privileged harness boundary".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:?usage: ci/privileged-contracts.sh <env-file>}"
# Test seam: a copy of the guard with a temporary marker path.
guard="${CERALIVE_GUEST_GUARD:-${ROOT}/tests/lib/require-disposable-guest.sh}"
if bash -c 'source "$1"' guard "${guard}" 2>/dev/null; then
  mode=marked
  avahi=required rauc=disposable-marked-guest-only kernel_stage=required
else
  mode=unmarked
  avahi=skip rauc=skip kernel_stage=skip
fi
printf 'CERALIVE_RUN_REAL_AVAHI_CONTRACT=%s\nCERALIVE_RUN_REAL_RAUC_CONTRACT=%s\nCERALIVE_RUN_REAL_KERNEL_STAGE_CONTRACT=%s\n' \
  "${avahi}" "${rauc}" "${kernel_stage}" >>"${out}"
if [[ "${mode}" == unmarked ]]; then
  msg='skipped: needs marked guest (real Avahi, real RAUC and real kernel-stage contracts)'
  printf '::notice title=Privileged contracts::%s\n' "${msg}"
  printf '%s\n' "${msg}"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "${msg}" >>"${GITHUB_STEP_SUMMARY}"
  fi
else
  printf 'privileged contracts: marked disposable guest, all guarded rows run\n'
fi

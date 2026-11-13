#!/usr/bin/env bash
# Guard for the real RAUC pair. Must run before any privileged harness mutation,
# even on direct invocation. Admits either
#   * a marked disposable KVM/QEMU guest (tests/lib/require-disposable-guest.sh), or
#   * a GitHub-hosted ephemeral runner VM, only on the explicit opt-in spelling
#     CERALIVE_RUN_REAL_RAUC_CONTRACT=github-hosted-ephemeral: the runner sets
#     GITHUB_ACTIONS=true and RUNNER_ENVIRONMENT=github-hosted, and the machine
#     must be a VM (systemd-detect-virt --vm not "none"). The runner is thrown
#     away after the job, which is why this harness ran there before the guard.
# A workstation is bare metal ("none") and refuses even with those variables.
# shellcheck shell=bash
_ceralive_guest_guard="$(dirname "${BASH_SOURCE[0]}")/require-disposable-guest.sh"
if ! bash -c 'source "$1"' guard "${_ceralive_guest_guard}" 2>/dev/null; then
  _ceralive_virt="$(systemd-detect-virt --vm 2>/dev/null || true)"
  if [[ "${CERALIVE_RUN_REAL_RAUC_CONTRACT:-}" != github-hosted-ephemeral \
        || "${GITHUB_ACTIONS:-}" != true || "${RUNNER_ENVIRONMENT:-}" != github-hosted \
        || -z "${_ceralive_virt}" || "${_ceralive_virt}" == none ]]; then
    printf 'REFUSE: real RAUC contract requires a marked disposable KVM/QEMU guest or a GitHub-hosted ephemeral runner VM.\n' >&2
    exit 2
  fi
  unset _ceralive_virt
fi
unset _ceralive_guest_guard

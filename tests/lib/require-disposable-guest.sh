#!/usr/bin/env bash
# Must run before any privileged harness mutation, even on direct invocation.
# shellcheck shell=bash
if [[ "$(systemd-detect-virt --vm 2>/dev/null)" != kvm && "$(systemd-detect-virt --vm 2>/dev/null)" != qemu ]] \
  || [[ ! -d /sys/firmware/qemu_fw_cfg/by_name/opt/ceralive ]]; then
  printf 'REFUSE: privileged contract requires a marked disposable KVM/QEMU guest.\n' >&2
  exit 2
fi

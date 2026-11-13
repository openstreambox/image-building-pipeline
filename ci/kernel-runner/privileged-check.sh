#!/usr/bin/env bash
# Guest half of ci/kernel-runner/privileged-guest.sh. vm.py passes this file as
# the `opt/ceralive/check` firmware item and guest-job.sh runs it as root INSIDE
# the disposable guest; it is never run on a host. It unpacks the read-only
# public-source capsule for the unprivileged guest user and runs only the
# registry's `privileged` rows (ci-tests.sh --privileged-only) as that user.
set -euo pipefail
capsule=/dev/disk/by-id/virtio-ceralive-source
user=ubuntu
home="/home/${user}"
src="${home}/source"
say() { printf 'privileged-check: %s\n' "$*"; }

[[ -b "${capsule}" ]] || { say "source capsule ${capsule} missing"; exit 1; }
install -d -m 0755 -o "${user}" -g "${user}" "${src}" "${home}/runner-temp"
# Root opens the disk-group device; the unprivileged user only unpacks the stream.
runuser -u "${user}" -- tar -xf - -C "${src}" <"${capsule}"
say "source $(runuser -u "${user}" -- cat "${src}/.capsule-revision" 2>/dev/null || printf unknown)"
say "virt=$(systemd-detect-virt --vm 2>/dev/null || true) marker=$(ls /sys/firmware/qemu_fw_cfg/by_name/opt/ceralive)"
# The same guard every privileged harness sources; report its verdict up front.
if bash -c 'source "$1"' guard "${src}/tests/lib/require-disposable-guest.sh"; then
  say 'guard admits this guest'
else
  say 'guard refused inside the guest'
  exit 1
fi
cd "${src}"
runuser -u "${user}" -- env -i HOME="${home}" USER="${user}" LANG=C.UTF-8 LC_ALL=C.UTF-8 \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  TMPDIR=/var/tmp RUNNER_TEMP="${home}/runner-temp" \
  bash -c 'umask 022; exec bash ci/kernel-runner/ci-tests.sh --privileged-only'

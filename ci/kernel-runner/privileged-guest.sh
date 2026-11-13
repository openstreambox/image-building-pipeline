#!/usr/bin/env bash
# Run the registry's `privileged` rows (real Avahi, real RAUC, real kernel stage)
# inside a marked, disposable QEMU guest, on demand or from CI.
#
# Usage: ci/kernel-runner/privileged-guest.sh [--accel kvm|tcg] [--smp N] [--memory MiB]
#
# The host side only runs QEMU as the invoking user: no sudo, no host mounts,
# no host directory shares and no credentials. vm.py boots a fresh overlay of a
# pristine base for the one run, passes this checkout's tracked source as a
# read-only tar capsule and the guest script as the `opt/ceralive/check`
# firmware item (which is the marker the guard looks for), and deletes the
# overlay afterwards. The destructive fixtures run only inside that guest.
#
# The base is built once per set of base inputs and reused; its file name
# carries their digest, so changed runner files build a new base.
#
# Environment:
#   CERALIVE_GUEST_CACHE  directory for the base, lock and logs
#                         (default: mkosi/cache/kernel-runner)
#   CERALIVE_GUEST_TIMEOUT guest deadline in seconds per boot (default 10800)
#   CERALIVE_GUEST_BASE   base path to use (or build) instead of the cached one
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"

accel="" smp="" memory=""
while (( $# )); do
  case "$1" in
    --accel) accel="${2:?}"; shift 2 ;;
    --smp) smp="${2:?}"; shift 2 ;;
    --memory) memory="${2:?}"; shift 2 ;;
    *) printf 'usage: %s [--accel kvm|tcg] [--smp N] [--memory MiB]\n' "$0" >&2; exit 2 ;;
  esac
done

if [[ "$(id -u)" -eq 0 ]]; then
  printf 'privileged-guest: run as an ordinary user; the host path needs no root\n' >&2
  exit 2
fi
for tool in qemu-system-x86_64 qemu-img xorriso flock git python3 curl; do
  command -v "${tool}" >/dev/null || { printf 'privileged-guest: %s not on PATH\n' "${tool}" >&2; exit 2; }
done
python3 -c 'import yaml' 2>/dev/null || { printf 'privileged-guest: python3 PyYAML missing\n' >&2; exit 2; }

if [[ -z "${accel}" ]]; then
  if [[ -r /dev/kvm && -w /dev/kvm ]]; then accel=kvm; else accel=tcg; fi
fi
case "${accel}" in
  kvm) [[ -r /dev/kvm && -w /dev/kvm ]] || { printf 'privileged-guest: /dev/kvm not accessible to %s\n' "$(id -un)" >&2; exit 2; } ;;
  tcg) printf 'privileged-guest: no KVM access, using software emulation (TCG); expect a slow run\n' ;;
  *) printf 'privileged-guest: --accel must be kvm or tcg\n' >&2; exit 2 ;;
esac
cpus="$(nproc)"
smp="${smp:-$(( cpus > 2 ? (cpus - 2 > 16 ? 16 : cpus - 2) : 1 ))}"
memory="${memory:-8192}"

cache="${CERALIVE_GUEST_CACHE:-${ROOT}/mkosi/cache/kernel-runner}"
mkdir -p "${cache}"
cache="$(cd "${cache}" && pwd)"
timeout="${CERALIVE_GUEST_TIMEOUT:-10800}"

# Everything vm.py bakes into the base, so a changed input never reuses an old base.
key="$(cd "${HERE}" && cat vm.py provision.sh guest-job.sh keyring.sh admit-job.sh \
  armbian-old.asc armbian-new.asc | sha256sum | cut -c1-16)"
base="${CERALIVE_GUEST_BASE:-${cache}/base-${key}.qcow2}"
lock="${cache}/runner.lock"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
log="${cache}/privileged-${stamp}.log"
vm=(python3 "${HERE}/vm.py")
machine=(--accel "${accel}" --smp "${smp}" --memory "${memory}" --timeout "${timeout}")

work="$(mktemp -d "${cache}/capsule.XXXXXX")"
trap 'rm -rf -- "${work}"' EXIT

# Tracked source only, including uncommitted edits to tracked files; untracked
# files stay out. `git stash create` writes an object without touching the stash.
revision="$(git -C "${ROOT}" stash create 2>/dev/null || true)"
label="$(git -C "${ROOT}" rev-parse HEAD)"
[[ -z "${revision}" ]] || label="${label}+worktree"
revision="${revision:-HEAD}"
printf '%s\n' "${label}" >"${work}/.capsule-revision"
git -C "${ROOT}" archive --format=tar -o "${work}/source.tar" "${revision}"
tar -rf "${work}/source.tar" -C "${work}" .capsule-revision
# A block device is read in whole sectors; keep the tar padded to 512 bytes.
truncate -s "%512" "${work}/source.tar"

started="${SECONDS}"
rc=0
{
  printf 'privileged-guest: source %s, accel %s, %s CPUs, %s MiB\n' "${label}" "${accel}" "${smp}" "${memory}"
  if [[ ! -f "${base}" ]]; then
    printf 'privileged-guest: building base %s\n' "${base##*/}"
    flock --exclusive --close "${lock}" "${vm[@]}" build-base --base "${base}" "${machine[@]}"
    printf 'privileged-guest: base ready after %ss\n' "$((SECONDS - started))"
  fi
  rc=0
  flock --exclusive --close "${lock}" "${vm[@]}" check --base "${base}" "${machine[@]}" \
    --check-script "${HERE}/privileged-check.sh" --source-bundle "${work}/source.tar" || rc=$?
  printf 'privileged-guest: finished rc=%s after %ss\n' "${rc}" "$((SECONDS - started))"
  exit "${rc}"
} 2>&1 | tee "${log}" || rc=$?
printf '\nprivileged-guest: summary (log %s)\n' "${log}"
grep -a 'CERALIVE_PRIVILEGED_ROW ' "${log}" | sed 's/^.*CERALIVE_PRIVILEGED_ROW /  /' || printf '  no row results reached the console\n'
exit "${rc}"

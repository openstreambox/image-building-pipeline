#!/usr/bin/env bash
# The marked-guest launcher for the privileged rows, with QEMU stubbed. Nothing
# here boots a guest or runs a privileged harness; it checks what the host hands
# the guest, that the host path needs no root, and that results reach the host.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT}/tests/lib/assertions.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/privileged-guest.XXXXXX")"
trap 'rm -rf -- "${WORK}"' EXIT
mkdir "${WORK}/bin" "${WORK}/cache"
LAUNCHER="${ROOT}/ci/kernel-runner/privileged-guest.sh"
CHECK="${ROOT}/ci/kernel-runner/privileged-check.sh"
CI_TESTS="${ROOT}/ci/kernel-runner/ci-tests.sh"

if [[ "$(id -u)" -eq 0 ]]; then
  printf 'SKIP privileged-guest launcher: runs as an ordinary user only\n'
  exit 0
fi

# ---- vm.py machine selection -------------------------------------------------
machine() { python3 - "${ROOT}" "$@" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + '/ci/kernel-runner')
import vm
print(' '.join(vm.machine_args(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))))
PY
}
if python3 -c 'import yaml' 2>/dev/null; then
  kvm="$(machine kvm 16 16384)"
  tcg="$(machine tcg 4 4096)"
  [[ "${kvm}" == "-enable-kvm -cpu host -machine q35 -smp 16 -m 16384" ]] \
    && ok 'KVM stays the default machine (unchanged for the kernel-release runner)' || bad "kvm machine: ${kvm}"
  [[ "${tcg}" == *"-accel tcg,"* && "${tcg}" != *-enable-kvm* && "${tcg}" == *"-smp 4 -m 4096"* ]] \
    && ok 'TCG is software emulation without /dev/kvm' || bad "tcg machine: ${tcg}"
else
  bad 'python3 PyYAML missing; vm.py cannot be imported'
fi

# ---- stubbed host tools ---------------------------------------------------------
# vm.py gives QEMU only PATH and LANG, so the stub finds its files beside itself.
printf '%s\n' "${CHECK}" >"${WORK}/check-path"
printf '0\n' >"${WORK}/result"
cat >"${WORK}/bin/qemu-img" <<'SH'
#!/usr/bin/env bash
touch "${@: -1}"
SH
printf '#!/bin/sh\nexit 0\n' >"${WORK}/bin/xorriso"
cat >"${WORK}/bin/qemu-system-x86_64" <<'PY'
#!/usr/bin/env python3
import io, os, pathlib, sys, tarfile
args = sys.argv[1:]
work = pathlib.Path(sys.argv[0]).resolve().parent.parent
(work / 'qemu-args').write_text('\n'.join(args))
entry = args[args.index('-fw_cfg') + 1]
assert entry.startswith('name=opt/ceralive/check,'), entry
data = pathlib.Path(entry.split('file=', 1)[1]).read_bytes()
check = pathlib.Path((work / 'check-path').read_text().strip())
assert data == check.read_bytes(), 'check item is not privileged-check.sh'
capsule = next(a for a in args if 'id=source,' in a)
assert capsule.endswith(',readonly=on'), capsule
path = pathlib.Path(capsule.split(',')[0].split('=', 1)[1])
raw = path.read_bytes()
assert len(raw) % 512 == 0, 'capsule is not sector padded'
with tarfile.open(fileobj=io.BytesIO(raw)) as tar:
    names = set(tar.getnames())
    revision = tar.extractfile('.capsule-revision').read().decode().strip()
assert 'tests/registry.tsv' in names and 'tests/lib/require-disposable-guest.sh' in names
assert not any(n.startswith('.git/') for n in names), 'capsule carries git metadata'
(work / 'capsule-revision').write_text(revision)
assert 'GH_TOKEN' not in os.environ
print('CERALIVE_PRIVILEGED_ROW rc=0 seconds=1 tests/real-rauc-contract.sh')
print('CERALIVE_JOB_DONE=' + (work / 'result').read_text().strip())
PY
chmod 755 "${WORK}/bin/"*
touch "${WORK}/base.qcow2"
launch() {
  env PATH="${WORK}/bin:${PATH}" CERALIVE_GUEST_CACHE="${WORK}/cache" \
    CERALIVE_GUEST_BASE="${WORK}/base.qcow2" bash "${LAUNCHER}" "$@"
}

if launch --accel tcg --smp 2 --memory 4096 >"${WORK}/pass.log" 2>&1; then
  ok 'launcher passes a finished guest'
else bad "launcher failed: $(tail -5 "${WORK}/pass.log")"; fi
grep -q '^  rc=0 seconds=1 tests/real-rauc-contract.sh$' "${WORK}/pass.log" \
  && ok 'row results reach the host summary' || bad 'row results missing from the summary'
grep -qx -- '-enable-kvm' "${WORK}/qemu-args" && bad 'tcg run asked for KVM' || ok 'tcg run never asks for KVM'
grep -qx 'virtio-blk-pci,drive=source,serial=ceralive-source' "${WORK}/qemu-args" \
  && ok 'source arrives as a read-only capsule device, not a host share' || bad 'no source capsule device'
[[ "$(cat "${WORK}/capsule-revision")" =~ ^[0-9a-f]{40}(\+worktree)?$ ]] \
  && ok 'capsule names the source revision it carries' || bad 'capsule revision missing'
[[ -z "$(find "${WORK}/cache" -maxdepth 1 -name 'capsule.*')" ]] \
  && ok 'capsule removed after the run' || bad 'capsule left behind'
compgen -G "${WORK}/cache/privileged-*.log" >/dev/null && ok 'run log kept for triage' || bad 'no run log'

printf '1\n' >"${WORK}/result"
if launch --accel tcg >"${WORK}/fail.log" 2>&1; then
  bad 'a failed guest was reported as a pass'
else ok 'a failed guest fails the launcher'; fi
if launch --accel bogus >/dev/null 2>&1; then bad 'unknown accelerator accepted'; else ok 'unknown accelerator refused'; fi
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  ok 'kvm requested with /dev/kvm access (refusal not testable here)'
elif launch --accel kvm >/dev/null 2>&1; then
  bad 'kvm requested without /dev/kvm access was accepted'
else ok 'kvm without /dev/kvm access refuses instead of falling back silently'; fi
if grep -Eq '(^|[^[:alnum:]_-])sudo([^[:alnum:]_-]|$)' <(grep -v '^[[:space:]]*#' "${LAUNCHER}"); then
  bad 'host launcher uses sudo'
else ok 'host launcher never uses sudo'; fi

# ---- guest half and CI wiring (static: never executed on a host) ----------------
guard_line="$(grep -n 'require-disposable-guest.sh' "${CI_TESTS}" | grep source | head -1 | cut -d: -f1)"
sudo_line="$(grep -n 'sudo ' "${CI_TESTS}" | head -1 | cut -d: -f1)"
[[ -n "${guard_line}" && -n "${sudo_line}" && "${guard_line}" -lt "${sudo_line}" ]] \
  && ok 'ci-tests.sh sources the guard before its first privileged command' || bad 'ci-tests.sh guard order'
if bash "${CI_TESTS}" --bogus >/dev/null 2>&1; then bad 'ci-tests.sh accepted an unknown option'; else ok 'ci-tests.sh rejects unknown options'; fi
grep -Fq 'ci-tests.sh --privileged-only' "${CHECK}" && grep -Fq 'runuser -u "${user}"' "${CHECK}" \
  && ok 'guest runs only the privileged rows, as the unprivileged guest user' || bad 'guest check wiring'
grep -Fq 'source "$1"' "${CHECK}" && grep -Fq 'require-disposable-guest.sh' "${CHECK}" \
  && ok 'guest reports the guard verdict before running rows' || bad 'guest check skips the guard verdict'
printf 'Privileged guest launcher: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" == 0 ]]

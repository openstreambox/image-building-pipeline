#!/usr/bin/env bash
# SHA-pinned kernel reuse through the real lib/kernel/released.sh entrypoint.
# Only the container/compiler boundary is stubbed (tests/lib/kernel-release-fixtures.sh);
# a "COMPILE" line in the runtime log is the proof that the producer compiled.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT}/tests/lib/assertions.sh"
source "${ROOT}/tests/lib/kernel-release-fixtures.sh"
umask 022
WORK="$(mktemp -d)"
HTTP_PID=""
finish() {
  [[ -z "${HTTP_PID}" ]] || kill "${HTTP_PID}" 2>/dev/null || :
  rm -rf -- "${WORK}"
}
trap finish EXIT
export ROOT WORK
repo="${WORK}/repo"
kernel_test_repo "${repo}"
kernel_test_version "${repo}" 7.2.0-ceralive2
export CERALIVE_KERNEL_HISTORY_DIR="${WORK}/history"
kernel_test_artifact "${WORK}/history/7.2.0-ceralive2" 7.2.0-ceralive2 "${repo}"
kernel_test_version "${repo}" 7.2.0-ceralive3
kernel_test_artifact "${WORK}/source-result" 7.2.0-ceralive3 "${repo}"
name=linux-image-7.2.0-ceralive-rk3588_7.2.0-ceralive3_arm64.deb
pin="${repo}/manifests/kernel/pins/7.2.0-ceralive3.json"

mkdir -p "${WORK}/bin"
export KERNEL_TEST_RUNTIME_LOG="${WORK}/runtime.log" KERNEL_TEST_BUILD_INPUT="${WORK}/source-result"
export CERALIVE_KERNEL_SRC_MIRROR=0 CERALIVE_REMOTE_CACHE=0 CERALIVE_APT_PROXY=off
export CERALIVE_KERNEL_CACHE_DIR="${WORK}/shared"
kernel_test_builder_stub "${WORK}/bin"
export PATH="${WORK}/bin:${PATH}"

stage() {
  local out="$1"; shift
  rm -rf -- "${out}"
  : >"${KERNEL_TEST_RUNTIME_LOG}"
  (
    set -a
    eval "$("${repo}/lib/resolve.sh" rock-5b-plus)"
    set +a
    unset KERNEL_VARIANT
    bash "${repo}/lib/kernel/released.sh" --board rock-5b-plus --out "${out}" "$@"
  ) >"${WORK}/stage.log" 2>&1
}
compiled() { grep -qxF COMPILE "${KERNEL_TEST_RUNTIME_LOG}"; }
expect_refusal() {
  local label="$1" message="$2" mode="$3" out="$4"
  if (export CERALIVE_KERNEL_PIN="${mode}"; stage "${out}"); then bad "${label}: accepted"
  elif ! grep -Fq "${message}" "${WORK}/stage.log"; then bad "${label}: wrong guard: $(tail -3 "${WORK}/stage.log")"
  elif compiled; then bad "${label}: compiled anyway"
  else ok "${label}"; fi
}

expect_refusal 'require with no pin refuses before compiling' 'there is no kernel pin' \
  require "${WORK}/none"

if stage "${WORK}/cold" && compiled && [[ -f "${WORK}/cold/${name}" ]]; then
  ok 'without a pin the stage compiles as before'
else bad "cold build: $(tail -5 "${WORK}/stage.log")"; fi

(
  set -a; eval "$("${repo}/lib/resolve.sh" rock-5b-plus)"; set +a; unset KERNEL_VARIANT
  cp "${WORK}/cold/kernel-artifact.json" "${WORK}/cold/kernel-artifact.json.orig"
  bash "${repo}/lib/kernel/released.sh" --board rock-5b-plus --write-pin "${WORK}/cold"
) >"${WORK}/write.log" 2>&1 || { bad "write pin: $(tail -3 "${WORK}/write.log")"; }
if python3 - "${pin}" "${WORK}/cold" "${name}" "${repo}" <<'PY'
import hashlib, json, pathlib, subprocess, sys, yaml
pin, cold, name, repo = json.load(open(sys.argv[1])), pathlib.Path(sys.argv[2]), sys.argv[3], pathlib.Path(sys.argv[4])
src = yaml.safe_load((repo / 'manifests/families/rk3588.yaml').read_text())['variants']['edge']['kernel_source']
assert pin['format'] == 'ceralive-kernel-pin/1'
assert pin['sha256'][name] == hashlib.sha256((cold / name).read_bytes()).hexdigest()
assert pin['artifact']['deb_sha256'] == pin['sha256'][name] and pin['artifact']['validated_boards'] == []
assert pin['source']['commit'] == src['commit'] and pin['source']['patches_commit'] == src['patches_commit']
assert pin['source']['fragments'][0]['path'] == src['defconfig_fragment']
assert pin['produced_by']['pipeline_commit'] == subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
PY
then ok 'the pin records the bytes, the source inputs, the producer record and the pipeline commit'
else bad 'pin content wrong'; fi

if CERALIVE_KERNEL_PIN=require stage "${WORK}/pinned" && ! compiled &&
   cmp -s "${WORK}/pinned/${name}" "${WORK}/cold/${name}" &&
   grep -Fq 'kernel PINNED' "${WORK}/stage.log" &&
   jq -e --arg d "$(sha256sum "${WORK}/cold/${name}" | cut -d' ' -f1)" \
     '.deb_sha256 == $d and .validated_boards == []' "${WORK}/pinned/kernel-artifact.json" >/dev/null; then
  ok 'require mode stages the pinned bytes from the artifact cache without compiling'
else bad "pinned stage: $(tail -5 "${WORK}/stage.log")"; fi

# A producer-code change moves the cache key; the byte-identical kernel stays usable.
cp "${repo}/lib/kernel/artifact-cache.sh" "${WORK}/ac.orig"
printf '\n# producer code changed\n' >>"${repo}/lib/kernel/artifact-cache.sh"
if CERALIVE_KERNEL_PIN=require stage "${WORK}/moved" && ! compiled && cmp -s "${WORK}/moved/${name}" "${WORK}/cold/${name}"; then
  ok 'a moved cache key does not hide the pinned bytes (lookup is by content)'
else bad "moved key: $(tail -5 "${WORK}/stage.log")"; fi
cp "${WORK}/ac.orig" "${repo}/lib/kernel/artifact-cache.sh"

# Tampered cached bytes are never staged, and require mode does not fall back to compiling.
entry="$(dirname "$(find "${WORK}/shared/kernel-artifacts" -mindepth 2 -maxdepth 2 -name "${name}" | head -1)")"
cp "${entry}/${name}" "${WORK}/good.deb"
printf 'x' >>"${entry}/${name}"
expect_refusal 'tampered cached deb is refused and require mode does not compile' 'in no trusted store' \
  require "${WORK}/tampered"
cp "${WORK}/good.deb" "${entry}/${name}"

# Published release asset as the store.
rm -rf "${WORK}/shared/kernel-artifacts"
mkdir -p "${WORK}/www/good" "${WORK}/www/bad"
cp "${WORK}/cold/${name}" "${WORK}/cold/resolved.config" "${WORK}/cold/built-modules.txt" "${WORK}/www/good/"
cp "${WORK}/www/good/"* "${WORK}/www/bad/"; printf 'x' >>"${WORK}/www/bad/${name}"
python3 -u -m http.server --bind 127.0.0.1 0 --directory "${WORK}/www" >"${WORK}/http.log" 2>&1 &
HTTP_PID=$!
port=""
for _ in $(seq 1 50); do
  port="$(sed -n 's/.* port \([0-9]*\).*/\1/p' "${WORK}/http.log" | head -1)"
  [[ -n "${port}" ]] && break
  sleep 0.1
done
[[ -n "${port}" ]] || { bad 'loopback HTTP fixture did not start'; exit 1; }
cp "${pin}" "${WORK}/pin.orig"
jq --arg bad "http://127.0.0.1:${port}/bad" --arg good "http://127.0.0.1:${port}/good" '.sources = [$bad, $good]' \
  "${WORK}/pin.orig" >"${pin}"
if CERALIVE_KERNEL_PIN=require stage "${WORK}/remote" && ! compiled &&
   cmp -s "${WORK}/remote/${name}" "${WORK}/cold/${name}" &&
   grep -Fq 'served bytes that differ from the pin' "${WORK}/stage.log" &&
   grep -Fq "from pinned source http://127.0.0.1:${port}/good" "${WORK}/stage.log"; then
  ok 'pinned sources: wrong bytes are skipped, the matching source is staged without compiling'
else bad "pinned source: $(tail -5 "${WORK}/stage.log")"; fi
jq '.sources = ["http://example.invalid/kernel"]' "${WORK}/pin.orig" >"${pin}"
expect_refusal 'a non-HTTPS pin source makes the pin invalid' 'is not an HTTPS URL' \
  require "${WORK}/http"
cp "${WORK}/pin.orig" "${pin}"

# Provenance: the manifest must ask for exactly the pinned kernel.
cp "${repo}/manifests/families/rk3588.yaml" "${WORK}/family.orig"
sed -i -E '0,/patches_commit: [0-9a-f]{40}/s//patches_commit: 0123456789abcdef0123456789abcdef01234567/' "${repo}/manifests/families/rk3588.yaml"
expect_refusal 'a manifest patch commit other than the pinned one stops the build' 'source.patches_commit' \
  auto "${WORK}/patches"
cp "${WORK}/family.orig" "${repo}/manifests/families/rk3588.yaml"
fragment="$(jq -r '.source.fragments[0].path' "${pin}")"
cp "${repo}/${fragment}" "${WORK}/fragment.orig"
printf 'CONFIG_PIN_DRIFT=y\n' >>"${repo}/${fragment}"
expect_refusal 'changed fragment bytes stop the build' 'source.fragments' \
  auto "${WORK}/fragment"
cp "${WORK}/fragment.orig" "${repo}/${fragment}"
jq '.sha256 |= with_entries(.value = ("0" * 64))' "${WORK}/pin.orig" >"${pin}"
expect_refusal 'a pin whose embedded record disagrees with its digests is invalid' 'embedded kernel-artifact.json' \
  auto "${WORK}/inconsistent"
cp "${WORK}/pin.orig" "${pin}"

# auto with no store holding the bytes: compile, and the result must equal the pin.
kill "${HTTP_PID}"; wait "${HTTP_PID}" 2>/dev/null || :; HTTP_PID=""
rm -rf "${WORK}/shared/kernel-artifacts"
if stage "${WORK}/auto" && compiled && grep -Fq 'reproduced the pin' "${WORK}/stage.log"; then
  ok 'auto mode compiles when no store has the bytes, and checks the result against the pin'
else bad "auto fallback: $(tail -5 "${WORK}/stage.log")"; fi

# verify: the scheduled cold check always compiles and must reproduce the pin.
if CERALIVE_KERNEL_PIN=verify CERALIVE_KERNEL_ARTIFACT_CACHE=0 stage "${WORK}/verify" && compiled &&
   grep -Fq 'reproduced the pin' "${WORK}/stage.log"; then
  ok 'verify mode compiles even with the pinned bytes cached and confirms the pin'
else bad "verify: $(tail -5 "${WORK}/stage.log")"; fi
cp -a "${WORK}/source-result" "${WORK}/other-result"
dpkg-deb -R "${WORK}/other-result/${name}" "${WORK}/other-tree"
sed -i 's/^Description: .*/Description: different bytes/' "${WORK}/other-tree/DEBIAN/control"
dpkg-deb --root-owner-group --build "${WORK}/other-tree" "${WORK}/other-result/${name}" >/dev/null
jq --arg d "$(sha256sum "${WORK}/other-result/${name}" | cut -d' ' -f1)" '.deb_sha256 = $d' \
  "${WORK}/source-result/kernel-artifact.json" >"${WORK}/other-result/kernel-artifact.json"
if KERNEL_TEST_BUILD_INPUT="${WORK}/other-result" CERALIVE_KERNEL_PIN=verify CERALIVE_KERNEL_ARTIFACT_CACHE=0 \
     stage "${WORK}/differs"; then
  bad 'a compiled kernel that differs from its pin was accepted'
elif grep -Fq 'is not the pinned kernel' "${WORK}/stage.log"; then
  ok 'a compiled kernel that differs from its pin stops the build'
else bad "differs: $(tail -5 "${WORK}/stage.log")"; fi

# 0 ignores the pin entirely (old behaviour), even one that no longer matches.
jq '.source.commit = "0000000000000000000000000000000000000000"' "${WORK}/pin.orig" >"${pin}"
if CERALIVE_KERNEL_PIN=0 CERALIVE_KERNEL_ARTIFACT_CACHE=0 stage "${WORK}/off" && compiled && ! grep -Fq 'kernel pin' "${WORK}/stage.log"; then
  ok 'CERALIVE_KERNEL_PIN=0 ignores pins'
else bad "pin off: $(tail -5 "${WORK}/stage.log")"; fi
cp "${WORK}/pin.orig" "${pin}"
expect_refusal 'an unknown pin mode is refused' 'CERALIVE_KERNEL_PIN must be' \
  yes "${WORK}/mode"

printf 'Kernel pin contract: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" == 0 ]]

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
export TMPDIR="${WORK}/tmp"
mkdir -p "${TMPDIR}"
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
    # KERNEL_OVERRIDE=NAME=value simulates a caller overriding a resolved pin.
    [[ -z "${KERNEL_OVERRIDE:-}" ]] || export "${KERNEL_OVERRIDE?}"
    bash "${repo}/lib/kernel/released.sh" --board rock-5b-plus --out "${out}" "$@"
  ) >"${WORK}/stage.log" 2>&1
}
compiled() { grep -qxF COMPILE "${KERNEL_TEST_RUNTIME_LOG}"; }
no_kernel_in() { ! compgen -G "$1/*.deb" >/dev/null; }
# expect_refusal <label> <message> <mode> <out> [VAR=value ...] [-- released.sh args]
expect_refusal() {
  local label="$1" message="$2" mode="$3" out="$4"; shift 4
  local -a env_args=() stage_args=()
  while (( $# )); do
    if [[ "$1" == -- ]]; then shift; stage_args=("$@"); break; fi
    env_args+=("$1"); shift
  done
  if (export CERALIVE_KERNEL_PIN="${mode}"; for assignment in "${env_args[@]}"; do export "${assignment?}"; done
      stage "${out}" "${stage_args[@]}"); then bad "${label}: accepted"
  elif ! grep -Fq -- "${message}" "${WORK}/stage.log"; then bad "${label}: wrong guard: $(grep -E 'ERROR|refused' "${WORK}/stage.log" | tail -3)"
  elif compiled; then bad "${label}: compiled anyway"
  elif ! no_kernel_in "${out}"; then bad "${label}: a kernel was left in --out"
  elif compgen -G "${WORK}/.kernel-pin.*" >/dev/null; then bad "${label}: a private staging directory was left behind"
  else ok "${label}"; fi
}
commit_repo() {
  git -C "${repo}" add -A
  git -C "${repo}" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
    commit -qm "${1:-fixture}"
}

expect_refusal 'require with no pin refuses before compiling' 'there is no kernel pin' require "${WORK}/none"

if stage "${WORK}/plain" && compiled && [[ -f "${WORK}/plain/${name}" ]]; then
  ok 'without a pin the stage compiles as before (and fills the artifact cache)'
else bad "plain build: $(tail -5 "${WORK}/stage.log")"; fi

# --- write: a pin is only ever written from a cold build of committed inputs ---
if CERALIVE_KERNEL_PIN='write' stage "${WORK}/dirty-write"; then bad 'write accepted uncommitted inputs'
elif grep -Fq 'needs a clean, fully committed checkout' "${WORK}/stage.log" && [[ ! -e "${pin}" ]] && no_kernel_in "${WORK}/dirty-write"; then
  ok 'write refuses uncommitted inputs and writes no pin'
else bad "dirty write: $(tail -3 "${WORK}/stage.log")"; fi
commit_repo 'inputs'
# P2-A (T1183 round 3): the manifest decides the source pins, so the whole tree
# must be committed, and the build's KERNEL_SOURCE_* must be the manifest's.
cp "${repo}/manifests/families/rk3588.yaml" "${WORK}/family.committed"
sed -i -E '0,/patches_commit: [0-9a-f]{40}/s//patches_commit: 0123456789abcdef0123456789abcdef01234567/' \
  "${repo}/manifests/families/rk3588.yaml"
expect_refusal 'write refuses an uncommitted manifest change (patch commit)' 'needs a clean, fully committed checkout' \
  write "${WORK}/manifest-write"
cp "${WORK}/family.committed" "${repo}/manifests/families/rk3588.yaml"
touch "${repo}/stray-file"
expect_refusal 'write refuses an untracked file in the checkout' 'needs a clean, fully committed checkout' \
  write "${WORK}/untracked-write"
rm -f "${repo}/stray-file"
expect_refusal 'write refuses a KERNEL_SOURCE_* override of the committed manifest' 'differs from the committed manifest' \
  write "${WORK}/override-write" KERNEL_OVERRIDE=KERNEL_SOURCE_PATCHES_COMMIT=0123456789abcdef0123456789abcdef01234567
[[ ! -e "${pin}" ]] || bad 'a refused write left a pin behind'
expect_refusal 'write refuses a caller ccache (the pin must come from a cold build)' '--ccache-dir is refused' \
  write "${WORK}/write-cc" -- --ccache-dir "${WORK}/warm"
if CERALIVE_KERNEL_PIN='write' stage "${WORK}/written" && compiled &&
   grep -Fq 'COLD build for write (CERALIVE_KERNEL_ARTIFACT_CACHE=0, fresh ccache' "${WORK}/stage.log" &&
   [[ -f "${pin}" && -f "${WORK}/written/${name}" ]] && ! compgen -G "${TMPDIR:-/tmp}/kernel-cold-ccache.*" >/dev/null; then
  ok 'write compiles cold, writes the pin, stages the kernel and removes its fresh ccache'
else bad "write: $(tail -5 "${WORK}/stage.log")"; fi
if python3 - "${pin}" "${WORK}/written" "${name}" "${repo}" <<'PY'
import hashlib, json, pathlib, re, subprocess, sys, yaml
pin, built, name, repo = json.load(open(sys.argv[1])), pathlib.Path(sys.argv[2]), sys.argv[3], pathlib.Path(sys.argv[4])
src = yaml.safe_load((repo / 'manifests/families/rk3588.yaml').read_text())['variants']['edge']['kernel_source']
assert pin['format'] == 'ceralive-kernel-pin/2'
assert pin['sha256'][name] == hashlib.sha256((built / name).read_bytes()).hexdigest()
assert pin['artifact']['deb_sha256'] == pin['sha256'][name] and pin['artifact']['validated_boards'] == []
values, files = pin['inputs']['values'], [f['path'] for f in pin['inputs']['files']]
assert values['commit'] == src['commit'] and values['patches_commit'] == src['patches_commit']
assert values['builder_image'] == src['builder_image']
assert files[0] == src['defconfig_fragment']
produced = pin['produced_by']
assert produced['cold'] is True and re.fullmatch(r'sha256:[0-9a-f]{64}', produced['builder_image_id'])
assert produced['pipeline_commit'] == subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
assert pin['reproduced'] == [] and pin['sources'] == []
PY
then ok 'the pin records bytes, all inputs, the producer record, the commit, the builder id and cold=true'
else bad 'pin content wrong'; fi
# The pin covers the producer fingerprint's own file list, not a second one.
mapfile -t listed < <(sed -n '/^kernel_input_files() {/,/^}/p' "${repo}/lib/kernel/artifact-cache.sh" \
  | grep -oE '/[A-Za-z0-9._/-]+\.(sh|dtsi|list|txt)"|Dockerfile' | tr -d '"' | xargs -n1 basename | sort -u)
missing=()
for base in "${listed[@]}"; do
  [[ "${base}" == Dockerfile ]] && base=Dockerfile.kernel
  jq -e --arg b "${base}" '[.inputs.files[].path | split("/")[-1]] | index($b)' "${pin}" >/dev/null || missing+=("${base}")
done
if (( ${#listed[@]} >= 15 && ${#missing[@]} == 0 )); then
  ok "the pin covers every file of the fingerprint's input list (${#listed[@]})"
else bad "pin misses fingerprint inputs: ${missing[*]} (listed ${#listed[@]})"; fi
expect_refusal 'write refuses to replace an existing pin' 'a pin is replaced only by removing it' write "${WORK}/rewrite"
commit_repo 'pin'
expect_refusal 'production require refuses a pin without a recorded independent cold verify' \
  'needs the pin reproduced by at least one recorded independent cold verify' require "${WORK}/prod-norepro" CERALIVE_BUILD_MODE=production
expect_refusal 'production refuses a KERNEL_SOURCE_* override of the committed manifest' 'differs from the committed manifest' \
  require "${WORK}/prod-override" CERALIVE_BUILD_MODE=production KERNEL_OVERRIDE=KERNEL_SOURCE_PATCHES_COMMIT=0123456789abcdef0123456789abcdef01234567

# --- require/auto take the pinned bytes without compiling ----------------------
if CERALIVE_KERNEL_PIN=require stage "${WORK}/pinned" && ! compiled &&
   cmp -s "${WORK}/pinned/${name}" "${WORK}/written/${name}" &&
   grep -Fq 'kernel PINNED' "${WORK}/stage.log" &&
   jq -e --arg d "$(sha256sum "${WORK}/written/${name}" | cut -d' ' -f1)" \
     '.deb_sha256 == $d and .validated_boards == []' "${WORK}/pinned/kernel-artifact.json" >/dev/null &&
   ! compgen -G "${WORK}/.kernel-pin.*" >/dev/null; then
  ok 'require stages the pinned bytes from the artifact cache, without compiling or leftovers'
else bad "pinned stage: $(tail -5 "${WORK}/stage.log")"; fi

# --- P1-1: every producer input invalidates the pin ---------------------------
cp "${pin}" "${WORK}/pin.orig"
mutate_input() {
  local label="$1" file="$2" message="$3"
  cp "${repo}/${file}" "${WORK}/input.orig"
  printf '\n# changed input\n' >>"${repo}/${file}"
  expect_refusal "${label}" "${message}" auto "${WORK}/mutated"
  cp "${WORK}/input.orig" "${repo}/${file}"
}
mutate_input 'the ramoops reservation (dtsi) invalidates the pin' manifests/kernel/rk3588-ramoops.dtsi \
  'input file manifests/kernel/rk3588-ramoops.dtsi'
mutate_input 'the ramoops injection script invalidates the pin' lib/kernel/ramoops.sh 'input file lib/kernel/ramoops.sh'
mutate_input 'the builder Dockerfile invalidates the pin' ci/Dockerfile.kernel 'input file ci/Dockerfile.kernel'
mutate_input 'the producer and its container script invalidate the pin' lib/build-kernel.sh 'input file lib/build-kernel.sh'
fragment="$(jq -r '.inputs.files[0].path' "${pin}")"
mutate_input 'changed fragment bytes invalidate the pin' "${fragment}" "input file ${fragment}"
cp "${repo}/manifests/families/rk3588.yaml" "${WORK}/family.orig"
sed -i -E '0,/(builder_image: debian:trixie-[0-9]+-slim@sha256:)[0-9a-f]{64}/s//\1'"$(printf '0%.0s' {1..64})"'/' \
  "${repo}/manifests/families/rk3588.yaml"
expect_refusal 'a different builder image in the manifest invalidates the pin' 'input builder_image' auto "${WORK}/builder"
cp "${WORK}/family.orig" "${repo}/manifests/families/rk3588.yaml"
sed -i -E '0,/patches_commit: [0-9a-f]{40}/s//patches_commit: 0123456789abcdef0123456789abcdef01234567/' \
  "${repo}/manifests/families/rk3588.yaml"
expect_refusal 'a different patch commit invalidates the pin' 'input patches_commit' require "${WORK}/patches"
cp "${WORK}/family.orig" "${repo}/manifests/families/rk3588.yaml"
jq '.produced_by.cold = false' "${WORK}/pin.orig" >"${pin}"
expect_refusal 'a pin that does not record a cold build is refused' 'does not record a cold build' require "${WORK}/warm-pin"
jq '.sha256 |= with_entries(.value = ("0" * 64))' "${WORK}/pin.orig" >"${pin}"
expect_refusal 'a pin whose record disagrees with its digests is refused' 'embedded kernel-artifact.json' auto "${WORK}/inconsistent"
cp "${WORK}/pin.orig" "${pin}"

# --- stores --------------------------------------------------------------------
entry="$(dirname "$(find "${WORK}/shared/kernel-artifacts" -mindepth 2 -maxdepth 2 -name "${name}" | head -1)")"
cp "${entry}/${name}" "${WORK}/good.deb"
printf 'x' >>"${entry}/${name}"
expect_refusal 'a tampered cached deb is refused and require does not compile' 'in no trusted store' require "${WORK}/tampered"
cp "${WORK}/good.deb" "${entry}/${name}"

mkdir -p "${WORK}/www/good" "${WORK}/www/bad"
cp "${WORK}/written/${name}" "${WORK}/written/resolved.config" "${WORK}/written/built-modules.txt" "${WORK}/www/good/"
cp "${WORK}/www/good/"* "${WORK}/www/bad/"; printf 'x' >>"${WORK}/www/bad/${name}"
cat >"${WORK}/server.py" <<'PY'
import functools, http.server, sys
class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/redirect/'):  # plain-HTTP redirect to the good copy
            self.send_response(302)
            self.send_header('Location', '/good/' + self.path.split('/', 2)[2])
            self.end_headers()
            return
        super().do_GET()
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=sys.argv[1]))
print(f'Serving HTTP on 127.0.0.1 port {server.server_port}', flush=True)
server.serve_forever()
PY
python3 -u "${WORK}/server.py" "${WORK}/www" >"${WORK}/http.log" 2>&1 &
HTTP_PID=$!
port=""
for _ in $(seq 1 50); do
  port="$(sed -n 's/.* port \([0-9]*\).*/\1/p' "${WORK}/http.log" | head -1)"
  [[ -n "${port}" ]] && break
  sleep 0.1
done
[[ -n "${port}" ]] || { bad 'loopback HTTP fixture did not start'; exit 1; }
jq --arg bad "http://127.0.0.1:${port}/bad" --arg good "http://127.0.0.1:${port}/good" '.sources = [$bad, $good]' \
  "${WORK}/pin.orig" >"${pin}"
if CERALIVE_KERNEL_PIN=require CERALIVE_KERNEL_ARTIFACT_CACHE=0 stage "${WORK}/remote" && ! compiled &&
   cmp -s "${WORK}/remote/${name}" "${WORK}/written/${name}" &&
   grep -Fq 'served bytes that differ from the pin' "${WORK}/stage.log" &&
   grep -Fq "from pinned source http://127.0.0.1:${port}/good" "${WORK}/stage.log"; then
  ok 'with the cache off only the pinned sources are used: wrong bytes skipped, matching source staged'
else bad "pinned source: $(tail -5 "${WORK}/stage.log")"; fi
expect_refusal 'a fetch timeout that is not a number of seconds is refused' 'CERALIVE_KERNEL_PIN_FETCH_TIMEOUT must be' \
  require "${WORK}/timeout" CERALIVE_KERNEL_ARTIFACT_CACHE=0 CERALIVE_KERNEL_PIN_FETCH_TIMEOUT=soon
jq --arg r "http://127.0.0.1:${port}/redirect" '.sources = [$r]' "${WORK}/pin.orig" >"${pin}"
expect_refusal 'a pinned source that redirects to plain HTTP is not followed' 'in no trusted store' \
  require "${WORK}/redirect" CERALIVE_KERNEL_ARTIFACT_CACHE=0
jq --arg dead "http://127.0.0.1:${port}/missing" '.sources = [$dead]' "${WORK}/pin.orig" >"${pin}"
expect_refusal 'with the cache off, a cached copy does not satisfy the pin' 'in no trusted store' \
  require "${WORK}/cache-off" CERALIVE_KERNEL_ARTIFACT_CACHE=0
jq '.sources = ["http://example.invalid/kernel"]' "${WORK}/pin.orig" >"${pin}"
expect_refusal 'a non-HTTPS pin source makes the pin invalid' 'is not an HTTPS URL' require "${WORK}/http"
cp "${WORK}/pin.orig" "${pin}"
kill "${HTTP_PID}"; wait "${HTTP_PID}" 2>/dev/null || :; HTTP_PID=""

mkdir -p "${WORK}/pins-elsewhere"; cp "${pin}" "${WORK}/pins-elsewhere/"
expect_refusal 'a production build refuses CERALIVE_KERNEL_PIN_DIR (in-tree pins only)' 'not honoured in production' \
  require "${WORK}/prod-dir" CERALIVE_BUILD_MODE=production "CERALIVE_KERNEL_PIN_DIR=${WORK}/pins-elsewhere"

# --- auto falls back to a compile that must equal the pin ------------------------
rm -rf "${WORK}/shared/kernel-artifacts"
if stage "${WORK}/auto" && compiled && grep -Fq 'reproduced the pin' "${WORK}/stage.log"; then
  ok 'auto compiles when no store has the bytes, and checks the result against the pin'
else bad "auto fallback: $(tail -5 "${WORK}/stage.log")"; fi

# Different bytes from the same inputs (nondeterminism) never reach --out.
cp -a "${WORK}/source-result" "${WORK}/other-result"
dpkg-deb -R "${WORK}/other-result/${name}" "${WORK}/other-tree"
sed -i 's/^Description: .*/Description: different bytes/' "${WORK}/other-tree/DEBIAN/control"
dpkg-deb --root-owner-group --build "${WORK}/other-tree" "${WORK}/other-result/${name}" >/dev/null
jq --arg d "$(sha256sum "${WORK}/other-result/${name}" | cut -d' ' -f1)" '.deb_sha256 = $d' \
  "${WORK}/source-result/kernel-artifact.json" >"${WORK}/other-result/kernel-artifact.json"
rm -rf "${WORK}/shared/kernel-artifacts"
if KERNEL_TEST_BUILD_INPUT="${WORK}/other-result" stage "${WORK}/auto-differs"; then
  bad 'auto accepted a compiled kernel that differs from its pin'
elif grep -Fq 'is not the pinned kernel' "${WORK}/stage.log" && no_kernel_in "${WORK}/auto-differs"; then
  ok 'auto: a compiled kernel that differs from its pin stops the build and leaves --out without a kernel'
else bad "auto differs: $(tail -5 "${WORK}/stage.log")"; fi

# --- P1-2: verify is always cold ---------------------------------------------------
CERALIVE_KERNEL_PIN=0 stage "${WORK}/seed" >/dev/null 2>&1 || bad 'seed build failed'
cp "${pin}" "${WORK}/pin.before-verify"
if CERALIVE_KERNEL_PIN=verify stage "${WORK}/verify" && compiled &&
   ! grep -Fq 'artifact cache HIT' "${WORK}/stage.log" &&
   grep -Fq 'COLD build for verify' "${WORK}/stage.log" && grep -Fq 'verified by a cold build' "${WORK}/stage.log" &&
   jq -e '.cold == true and .compiled == true and .result == "reproduced"' "${WORK}/verify/kernel-pin-verify.json" >/dev/null &&
   cmp -s "${pin}" "${WORK}/pin.before-verify"; then
  ok 'verify with no other settings compiles cold although the cache holds the bytes, and records it'
else bad "verify: $(tail -5 "${WORK}/stage.log")"; fi
expect_refusal 'verify refuses a caller ccache' '--ccache-dir is refused' verify "${WORK}/verify-cc" -- --ccache-dir "${WORK}/warm"
if KERNEL_TEST_BUILD_INPUT="${WORK}/other-result" CERALIVE_KERNEL_PIN=verify stage "${WORK}/differs"; then
  bad 'verify accepted a kernel that differs from its pin'
elif grep -Fq 'did not reproduce the pin' "${WORK}/stage.log" && no_kernel_in "${WORK}/differs"; then
  ok 'verify: a differing cold build stops the build and leaves --out without a kernel'
else bad "verify differs: $(tail -5 "${WORK}/stage.log")"; fi
jq '.artifact.builder_closure.compiler = "another compiler"' "${WORK}/pin.orig" >"${pin}"
if CERALIVE_KERNEL_PIN=verify stage "${WORK}/closure"; then bad 'verify accepted a different builder record'
elif grep -Fq 'record differs from the pin in: builder_closure' "${WORK}/stage.log"; then
  ok 'verify also compares the builder record (closure, epoch, fingerprint)'
else bad "verify closure: $(tail -5 "${WORK}/stage.log")"; fi
cp "${WORK}/pin.orig" "${pin}"
if CERALIVE_KERNEL_PIN=verify CERALIVE_KERNEL_PIN_RECORD=1 stage "${WORK}/recorded" &&
   jq -e '(.reproduced | length) == 1 and .reproduced[0].cold == true and .reproduced[0].tree == "clean"' "${pin}" >/dev/null; then
  ok 'CERALIVE_KERNEL_PIN_RECORD=1 appends the cold run to the pin'
else bad "record: $(tail -5 "${WORK}/stage.log")"; fi
# The cache may hold the differing deb from the nondeterminism case above
# (the cache keeps whatever was built); reseed it with the pinned bytes.
rm -rf "${WORK}/shared/kernel-artifacts"
CERALIVE_KERNEL_PIN=0 stage "${WORK}/reseed" || bad "reseed build: $(tail -3 "${WORK}/stage.log")"
if CERALIVE_KERNEL_PIN=require CERALIVE_BUILD_MODE=production stage "${WORK}/prod-ok" && ! compiled &&
   [[ -f "${WORK}/prod-ok/${name}" ]]; then
  ok 'production require accepts the pin once a cold verify is recorded'
else bad "production require: $(tail -5 "${WORK}/stage.log")"; fi
cp "${WORK}/pin.orig" "${pin}"

# --- 0 and bad modes -----------------------------------------------------------------
jq '.inputs.values.commit = "0000000000000000000000000000000000000000"' "${WORK}/pin.orig" >"${pin}"
if CERALIVE_KERNEL_PIN=0 CERALIVE_KERNEL_ARTIFACT_CACHE=0 stage "${WORK}/off" && compiled && ! grep -Fq 'kernel pin' "${WORK}/stage.log"; then
  ok 'CERALIVE_KERNEL_PIN=0 ignores pins'
else bad "pin off: $(tail -5 "${WORK}/stage.log")"; fi
cp "${WORK}/pin.orig" "${pin}"
expect_refusal 'an unknown pin mode is refused' 'CERALIVE_KERNEL_PIN must be' yes "${WORK}/mode"

printf 'Kernel pin contract: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" == 0 ]]

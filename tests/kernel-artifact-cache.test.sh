#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
source "${HERE}/lib/assertions.sh"
source "${HERE}/lib/clear-workflow-env.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

printf 'CONFIG_CACHE_TEST=y\n# CONFIG_CACHE_BAD is not set\n' >"${WORK}/fragment"
cp "${WORK}/fragment" "${WORK}/resolved.config"
printf 'CONFIG_CACHE_TEST=y\n' >"${WORK}/required"
printf 'CONFIG_CACHE_BAD\n' >"${WORK}/forbidden"
if bash "${ROOT}/lib/verify-kernel-config.sh" --config "${WORK}/resolved.config" \
  --declared "${WORK}/fragment" --required "${WORK}/required" \
  --forbidden "${WORK}/forbidden" >/dev/null; then
  ok 'baseline: real survival and closure verifier accepts a valid resolved config'
else
  bad 'baseline: real config verifier rejected valid fixture'
fi
printf '# CONFIG_CACHE_TEST is not set\nCONFIG_CACHE_BAD=y\n' >"${WORK}/invalid.config"
if bash "${ROOT}/lib/verify-kernel-config.sh" --config "${WORK}/invalid.config" \
  --declared "${WORK}/fragment" --required "${WORK}/required" \
  --forbidden "${WORK}/forbidden" >/dev/null 2>&1; then
  bad 'baseline: dropped/forbidden symbols were accepted'
else
  ok 'baseline: real verifier rejects dropped and forbidden symbols'
fi

if [[ -f "${ROOT}/lib/kernel/artifact-cache.sh" ]] &&
  grep -Fq 'kernel_artifact_cache_hit' "${ROOT}/lib/build-kernel.sh"; then
  ok 'cache hit is wired into the real stage'
else
  bad 'cache hit is not wired into the real stage'
fi

source "${ROOT}/lib/kernel/artifact-cache.sh"
export CERALIVE_REMOTE_CACHE=0
source "${ROOT}/lib/kernel/package.sh"
log_info() { :; }
log_warn() { printf '%s\n' "$*" >>"${WORK}/warnings"; }
log_error() { printf '%s\n' "$*" >&2; }
log_success() { :; }
die() { printf '%s\n' "$*" >&2; return 1; }
PIPELINE_DIR="${ROOT}"
HERE="${ROOT}/lib"
KERNEL_LIB_DIR="${ROOT}/lib/kernel"
KERNEL_BUILDER_DOCKERFILE="${ROOT}/ci/Dockerfile.kernel"
CERALIVE_REL_MKOSI_CACHE_ROOT="cache"
kernel_artifact_cache_root() { printf '%s/cache' "${WORK}"; }
git_url='https://example.test/kernel'
tag=v7.2
commit="$(printf 'a%.0s' {1..40})"
patches_url='https://example.test/patches'
patches_commit="$(printf 'b%.0s' {1..40})"
patches_series='series'
config_mode=defconfig
defconfig_base=defconfig
config_git_url=''
config_commit=''
config_path=''
builder_image='base@sha256:123'
builder_digest='sha256:builder'
builder_packages='gcc-aarch64-linux-gnu=14.2 arm64'
builder_compiler='aarch64-linux-gnu-gcc 14.2'
KERNEL_VARIANT=edge
arch=arm64
kernel_pkg=linux-image-cache-test
kernel_release=7.2.0-cache
local_version=-cache
package_version=1
epoch=100
dtb_path='/usr/lib/linux-image-7.2.0-cache/rockchip/test.dtb'
absent_list=''
fragments=("${WORK}/fragment")
BASE_KEY="$(kernel_artifact_cache_key)"
[[ "${BASE_KEY}" =~ ^[0-9a-f]{64}$ ]] && ok 'key is a SHA-256 digest' || bad 'invalid key'

check_key_mutation() {
  local label="$1" name="$2" replacement="$3" old="${!2}"
  printf -v "${name}" '%s' "${replacement}"
  [[ "$(kernel_artifact_cache_key)" != "${BASE_KEY}" ]] && ok "key changes with ${label}" || bad "key ignores ${label}"
  printf -v "${name}" '%s' "${old}"
}
for name in git_url commit patches_commit patches_url patches_series config_mode \
  defconfig_base builder_image builder_digest builder_packages builder_compiler KERNEL_VARIANT kernel_pkg \
  package_version kernel_release local_version arch epoch dtb_path \
  config_git_url config_commit config_path; do
  check_key_mutation "${name}" "${name}" "changed-${!name}"
done
printf 'CONFIG_OTHER=y\n' >>"${WORK}/fragment"
[[ "$(kernel_artifact_cache_key)" != "${BASE_KEY}" ]] && ok 'fragment byte mutation changes key' || bad 'fragment bytes ignored'
printf 'CONFIG_CACHE_TEST=y\n# CONFIG_CACHE_BAD is not set\n' >"${WORK}/fragment"
touch "${WORK}/fragment"
[[ "$(kernel_artifact_cache_key)" == "${BASE_KEY}" ]] && ok 'fragment mtime is not a key input' || bad 'mtime changed key'
cp "${WORK}/fragment" "${WORK}/fragment-2"
fragments+=("${WORK}/fragment-2")
[[ "$(kernel_artifact_cache_key)" != "${BASE_KEY}" ]] && ok 'ordered fragment list changes key' || bad 'fragment count ignored'
fragments=("${WORK}/fragment")

KEY_HERE="${WORK}/source/lib"
mkdir -p "${KEY_HERE}/kernel" "${KEY_HERE}/shared" "${WORK}/source/ci"
cp "${ROOT}/lib/build-kernel.sh" "${ROOT}/lib/verify-kernel-config.sh" "${ROOT}/lib/verify-boot-artifacts.sh" "${KEY_HERE}/"
cp "${ROOT}/lib/kernel/"*.sh "${KEY_HERE}/kernel/"
cp "${ROOT}/lib/shared/remote-cache.sh" "${KEY_HERE}/shared/"
cp "${ROOT}/ci/Dockerfile.kernel" "${WORK}/source/ci/"
mkdir -p "${WORK}/source/manifests/kernel" "${WORK}/source/mkosi/runtime" "${WORK}/source/mkosi/customize"
cp "${ROOT}/manifests/kernel/required-symbols.list" "${ROOT}/manifests/kernel/forbidden-symbols.list" \
  "${ROOT}/manifests/kernel/rk3588-ramoops.dtsi" "${WORK}/source/manifests/kernel/"
cp "${ROOT}/manifests/rk3588-bluetooth-firmware-roots.txt" "${WORK}/source/manifests/"
cp "${ROOT}/mkosi/runtime/ceralive-kernel-boot-staging.sh" "${WORK}/source/mkosi/runtime/"
cp "${ROOT}/mkosi/customize/bluetooth-firmware.sh" "${WORK}/source/mkosi/customize/"
PIPELINE_DIR="${WORK}/source"
HERE="${KEY_HERE}"
KERNEL_LIB_DIR="${HERE}/kernel"
KERNEL_BUILDER_DOCKERFILE="${WORK}/source/ci/Dockerfile.kernel"
SOURCE_KEY="$(kernel_artifact_cache_key)"
[[ "${SOURCE_KEY}" == "${BASE_KEY}" ]] && ok 'key is the same in a second checkout of the same tree (paths are checkout-relative)' \
  || bad 'key depends on where the checkout lives'
for file in "${HERE}/build-kernel.sh" "${HERE}/verify-kernel-config.sh" "${HERE}/verify-boot-artifacts.sh" \
  "${KERNEL_LIB_DIR}/config.sh" "${KERNEL_LIB_DIR}/checkout.sh" \
  "${KERNEL_LIB_DIR}/builder.sh" "${KERNEL_LIB_DIR}/package.sh" \
  "${KERNEL_LIB_DIR}/artifact-cache.sh" "${KERNEL_LIB_DIR}/cache-dir.sh" "${KERNEL_LIB_DIR}/only.sh" \
  "${KERNEL_LIB_DIR}/ramoops.sh" "${PIPELINE_DIR}/manifests/kernel/rk3588-ramoops.dtsi" \
  "${KEY_HERE}/shared/remote-cache.sh" "${KERNEL_BUILDER_DOCKERFILE}" \
  "${PIPELINE_DIR}/manifests/rk3588-bluetooth-firmware-roots.txt" \
  "${PIPELINE_DIR}/mkosi/customize/bluetooth-firmware.sh"; do
  printf '\n' >>"${file}"
  [[ "$(kernel_artifact_cache_key)" != "${SOURCE_KEY}" ]] && ok "key changes with $(basename "${file}") bytes" || bad "key ignores ${file}"
  truncate -s -1 "${file}"
done
PIPELINE_DIR="${ROOT}"
HERE="${ROOT}/lib"
KERNEL_LIB_DIR="${ROOT}/lib/kernel"
KERNEL_BUILDER_DOCKERFILE="${ROOT}/ci/Dockerfile.kernel"

mkdir -p "${WORK}/payload/usr/lib/linux-image-7.2.0-cache/rockchip" "${WORK}/control/DEBIAN" "${WORK}/built" "${WORK}/staged"
printf 'test dtb\n' >"${WORK}/payload${dtb_path}"
printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: Test <test@example.test>\nDescription: test\n' \
  "${kernel_pkg}" "${package_version}" "${arch}" >"${WORK}/control/DEBIAN/control"
cp -a "${WORK}/payload/." "${WORK}/control/"
dpkg-deb --build --root-owner-group "${WORK}/control" "${WORK}/built/${kernel_pkg}_${package_version}_${arch}.deb" >/dev/null
cp "${WORK}/resolved.config" "${WORK}/built/resolved.config"
printf 'drivers/test.ko\n' >"${WORK}/built/built-modules.txt"
if validate_built_kernel_deb "${WORK}/built/${kernel_pkg}_${package_version}_${arch}.deb" \
  "${kernel_pkg}" "${package_version}" "${arch}" "${dtb_path}" >/dev/null; then
  ok 'baseline: real deb validator accepts synthetic Debian archive and DTB'
else
  bad 'baseline: real deb validator rejected synthetic archive'
fi

eval "$(declare -f validate_built_kernel_deb | sed '1s/validate_built_kernel_deb/real_validate_built_kernel_deb/')"
validate_built_kernel_deb() {
  printf 'deb\n' >>"${WORK}/spy"
  real_validate_built_kernel_deb "$@"
}
eval "$(declare -f kernel_artifact_verify_config | sed '1s/kernel_artifact_verify_config/real_kernel_artifact_verify_config/')"
kernel_artifact_verify_config() {
  printf 'config\n' >>"${WORK}/spy"
  bash "${ROOT}/lib/verify-kernel-config.sh" --config "$1" \
    --declared "${WORK}/fragment" --required "${WORK}/required" \
    --forbidden "${WORK}/forbidden" >/dev/null
}
MKOSI_PACKAGE_STAGING_SH="${ROOT}/lib/stage-mkosi-package.sh"
kernel_artifact_cache_store "${BASE_KEY}" "${WORK}/built/${kernel_pkg}_${package_version}_${arch}.deb" "${WORK}/built"
ENTRY="$(kernel_artifact_cache_root)/${BASE_KEY}"
[[ -f "${ENTRY}/manifest.json" ]] && ok 'store publishes SHA256 manifest' || bad 'no manifest'
if kernel_artifact_cache_hit "${BASE_KEY}" "${WORK}/staged" "${kernel_pkg}_${package_version}_${arch}.deb"; then
  ok 'hit stages verified deb/config/modules'
else
  bad 'cache hit failed'
fi
[[ "$(wc -l <"${WORK}/spy")" == 2 ]] && ok 'hit reruns deb and config validators' || bad 'validator skipped on hit'
[[ -s "${WORK}/staged/resolved.config" && -s "${WORK}/staged/built-modules.txt" ]] && ok 'hit stages both metadata files' || bad 'missing staged metadata'
printf x >>"${ENTRY}/${kernel_pkg}_${package_version}_${arch}.deb"
if kernel_artifact_cache_hit "${BASE_KEY}" "${WORK}/staged" "${kernel_pkg}_${package_version}_${arch}.deb" 2>/dev/null; then
  bad 'one-byte corrupt deb was accepted'
else
  ok 'one-byte corrupt deb forces miss'
fi
[[ ! -d "${ENTRY}" ]] && ok 'corrupt cache entry removed for rebuild' || bad 'corrupt entry retained'
[[ -s "${WORK}/warnings" ]] && ok 'corruption is logged' || bad 'corruption was silent'
kernel_artifact_cache_store "${BASE_KEY}" "${WORK}/built/${kernel_pkg}_${package_version}_${arch}.deb" "${WORK}/built"
printf '# CONFIG_CACHE_TEST is not set\nCONFIG_CACHE_BAD=y\n' >"${ENTRY}/resolved.config"
kernel_artifact_cache_manifest "${ENTRY}" "${kernel_pkg}_${package_version}_${arch}.deb" "${BASE_KEY}"
if kernel_artifact_cache_hit "${BASE_KEY}" "${WORK}/staged" "${kernel_pkg}_${package_version}_${arch}.deb" 2>/dev/null; then
  bad 'hash-valid but invalid config was accepted'
else
  ok 'config-survival/closure failure evicts hash-valid entry'
fi
[[ ! -d "${ENTRY}" ]] && ok 'invalid config entry removed' || bad 'invalid config retained'
for mode in auto 0 invalid; do
  CERALIVE_KERNEL_ARTIFACT_CACHE="$mode"
  result="$(kernel_artifact_cache_mode 2>/dev/null)"; rc=$?
  if [[ "$mode" == invalid ]]; then
    (( rc != 0 )) && ok 'invalid mode rejected' || bad 'invalid mode accepted'
  else
    [[ "$result" == "$mode" ]] && ok "mode ${mode} accepted" || bad "mode ${mode} refused"
  fi
done
unset CERALIVE_KERNEL_ARTIFACT_CACHE
if grep -Fq 'if [[ "${cache_mode}" == '\''auto'\'' ]]' "${ROOT}/lib/build-kernel.sh"; then
  ok 'off mode bypasses cache lookup and store in the stage'
else
  bad 'off mode can still enter cache path'
fi

kernel_artifact_cache_store "${BASE_KEY}" "${WORK}/built/${kernel_pkg}_${package_version}_${arch}.deb" "${WORK}/built"
REMOTE_ENTRY="${WORK}/http-root/kernel/${BASE_KEY}"
mkdir -p "${REMOTE_ENTRY}"
cp "${ENTRY}/"* "${REMOTE_ENTRY}/"
rm -rf "${ENTRY}"
cat >"${WORK}/server.py" <<'PY'
import http.server
import pathlib
import sys

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), lambda *args, **kwargs: http.server.SimpleHTTPRequestHandler(*args, directory=sys.argv[1], **kwargs))
pathlib.Path(sys.argv[2]).write_text(str(server.server_port))
server.serve_forever()
PY
python3 "${WORK}/server.py" "${WORK}/http-root" "${WORK}/port" >"${WORK}/http.log" 2>&1 &
HTTP_PID=$!
for _ in $(seq 1 50); do [[ -s "${WORK}/port" ]] && break; sleep 0.1; done
CERALIVE_REMOTE_CACHE=auto
CERALIVE_REMOTE_CACHE_URL="http://127.0.0.1:$(<"${WORK}/port")"
export CERALIVE_REMOTE_CACHE_URL
if kernel_artifact_cache_hit "${BASE_KEY}" "${WORK}/staged" "${kernel_pkg}_${package_version}_${arch}.deb" && [[ -f "${ENTRY}/manifest.json" ]]; then
  ok 'remote kernel HTTP hit verifies manifest, deb and config before local publication'
else
  bad 'remote kernel HTTP hit failed'
fi
printf x >>"${ENTRY}/${kernel_pkg}_${package_version}_${arch}.deb"
if kernel_artifact_cache_hit "${BASE_KEY}" "${WORK}/staged" "${kernel_pkg}_${package_version}_${arch}.deb" &&
   cmp -s "${ENTRY}/${kernel_pkg}_${package_version}_${arch}.deb" "${REMOTE_ENTRY}/${kernel_pkg}_${package_version}_${arch}.deb"; then
  ok 'corrupt local kernel entry is evicted and refilled from validated remote bytes'
else
  bad 'corrupt local kernel entry skipped the remote tier'
fi
rm -rf "${ENTRY}"
printf '# CONFIG_CACHE_TEST is not set\nCONFIG_CACHE_BAD=y\n' >"${REMOTE_ENTRY}/resolved.config"
kernel_artifact_cache_manifest "${REMOTE_ENTRY}" "${kernel_pkg}_${package_version}_${arch}.deb" "${BASE_KEY}"
if kernel_artifact_cache_hit "${BASE_KEY}" "${WORK}/staged" "${kernel_pkg}_${package_version}_${arch}.deb" 2>/dev/null; then
  bad 'hash-valid remote kernel config bypassed semantic validation'
else
  ok 'hash-valid remote kernel with invalid config falls back to source build'
fi
[[ ! -d "${ENTRY}" ]] && ok 'invalid remote kernel entry never reached local cache' || bad 'invalid remote kernel entry published locally'
CERALIVE_REMOTE_CACHE=0
requests_before="$(wc -l <"${WORK}/http.log")"
kernel_artifact_cache_hit "${BASE_KEY}" "${WORK}/staged" "${kernel_pkg}_${package_version}_${arch}.deb" 2>/dev/null
[[ "$(wc -l <"${WORK}/http.log")" == "${requests_before}" ]] && ok 'remote-disabled kernel lookup does no HTTP' || bad 'remote-disabled kernel lookup contacted HTTP'
kill "${HTTP_PID}"; wait "${HTTP_PID}" 2>/dev/null || :
# --- shared kernel cache root (CERALIVE_KERNEL_CACHE_DIR) --------------------
DEB_NAME="${kernel_pkg}_${package_version}_${arch}.deb"
source "${ROOT}/lib/paths.sh"
eval "$(sed -n '/^kernel_artifact_cache_root() {/,/^}/p' "${ROOT}/lib/kernel/artifact-cache.sh")"
source "${ROOT}/lib/kernel/checkout.sh"
unset CERALIVE_KERNEL_CACHE_DIR CERALIVE_KERNEL_SRC_MIRROR_DIR
[[ "$(kernel_artifact_cache_root)" == "${ROOT}/${CERALIVE_REL_MKOSI_CACHE_ROOT}/kernel-artifacts" ]] \
  && ok 'unset shared root keeps the in-tree artifact cache' || bad 'in-tree default moved'
export CERALIVE_KERNEL_CACHE_DIR="${WORK}/shared/"
[[ "$(kernel_artifact_cache_root)" == "${WORK}/shared/kernel-artifacts" ]] \
  && ok 'shared root holds the artifact cache' || bad "artifact root $(kernel_artifact_cache_root)"
[[ "$(kernel_src_mirror_dir)" == "${WORK}/shared/kernel-src.git" ]] \
  && ok 'shared root holds the default source mirror' || bad "mirror $(kernel_src_mirror_dir)"
CERALIVE_KERNEL_SRC_MIRROR_DIR="${WORK}/elsewhere.git"
[[ "$(kernel_src_mirror_dir)" == "${WORK}/elsewhere.git" ]] \
  && ok 'explicit mirror dir still wins over the shared root' || bad 'mirror override lost'
unset CERALIVE_KERNEL_SRC_MIRROR_DIR
for bad_dir in relative/cache './cache'; do
  if (CERALIVE_KERNEL_CACHE_DIR="${bad_dir}"; kernel_artifact_cache_root) >/dev/null 2>&1; then
    bad "relative shared root '${bad_dir}' accepted"
  else
    ok "relative shared root '${bad_dir}' refused"
  fi
done
for shared_case in set unset relative; do
  case "${shared_case}" in
    set) env_args=(CERALIVE_KERNEL_CACHE_DIR="${WORK}/plan") ;;
    unset) env_args=(-u CERALIVE_KERNEL_CACHE_DIR) ;;
    relative) env_args=(CERALIVE_KERNEL_CACHE_DIR=plan) ;;
  esac
  env "${env_args[@]}" DRY_RUN=1 "${ROOT}/build" rk3588 --kernel-only >"${WORK}/plan.log" 2>&1; rc=$?
  case "${shared_case}" in
    set)
      if (( rc == 0 )) && grep -Fq "artifacts ${WORK}/plan/kernel-artifacts " "${WORK}/plan.log" &&
         grep -Fq "ccache ${WORK}/plan/kernel-ccache" "${WORK}/plan.log" &&
         grep -Fq "mirror dir ${WORK}/plan/kernel-src.git " "${WORK}/plan.log"; then
        ok 'real stage plan puts artifacts, ccache and mirror under the shared root'
      else bad "shared root plan: $(<"${WORK}/plan.log")"; fi ;;
    unset)
      if (( rc == 0 )) && grep -Fq "ccache ${ROOT}/mkosi/cache/kernel-ccache" "${WORK}/plan.log" &&
         grep -Fq "artifacts ${ROOT}/mkosi/cache/kernel-artifacts " "${WORK}/plan.log"; then
        ok 'real stage plan keeps the in-tree caches without a shared root'
      else bad "in-tree plan: $(<"${WORK}/plan.log")"; fi ;;
    relative)
      if (( rc != 0 )) && grep -Fq 'CERALIVE_KERNEL_CACHE_DIR must be an absolute path' "${WORK}/plan.log" &&
         ! grep -Fq '=== kernel-build-from-source' "${WORK}/plan.log"; then
        ok 'real stage refuses a relative shared root before planning any kernel work'
      else bad "relative plan: $(<"${WORK}/plan.log")"; fi ;;
  esac
done

# A second checkout of the same tree hits what the first one stored.
: >"${WORK}/spy"
kernel_artifact_cache_store "${BASE_KEY}" "${WORK}/built/${DEB_NAME}" "${WORK}/built"
SHARED_ENTRY="${WORK}/shared/kernel-artifacts/${BASE_KEY}"
[[ -f "${SHARED_ENTRY}/manifest.json" ]] && ok 'store publishes into the shared root' || bad 'nothing stored under the shared root'
PIPELINE_DIR="${WORK}/source"; HERE="${KEY_HERE}"; KERNEL_LIB_DIR="${HERE}/kernel"
KERNEL_BUILDER_DOCKERFILE="${WORK}/source/ci/Dockerfile.kernel"
rm -rf "${WORK}/staged-2"; mkdir -p "${WORK}/staged-2"
if [[ "$(kernel_artifact_cache_key)" == "${BASE_KEY}" ]] &&
   kernel_artifact_cache_hit "${BASE_KEY}" "${WORK}/staged-2" "${DEB_NAME}" &&
   cmp -s "${WORK}/staged-2/${DEB_NAME}" "${WORK}/built/${DEB_NAME}"; then
  ok 'second checkout hits the entry the first checkout stored'
else
  bad 'second checkout missed the shared entry'
fi
PIPELINE_DIR="${ROOT}"; HERE="${ROOT}/lib"; KERNEL_LIB_DIR="${ROOT}/lib/kernel"
KERNEL_BUILDER_DOCKERFILE="${ROOT}/ci/Dockerfile.kernel"

python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["key"]==sys.argv[2] and m["format"]=="ceralive-kernel-artifact-cache/2" and m["inputs"]["builder_digest"]==sys.argv[3] and m["inputs"]["dtb_path"]==sys.argv[4]' \
  "${SHARED_ENTRY}/manifest.json" "${BASE_KEY}" "${builder_digest}" "${dtb_path}" \
  && ok 'manifest records format, key and key inputs' || bad 'manifest does not bind the key'

# --- fail closed on any key or input mismatch -------------------------------
reseed() {
  rm -rf "${SHARED_ENTRY}"
  kernel_artifact_cache_store "${BASE_KEY}" "${WORK}/built/${DEB_NAME}" "${WORK}/built"
}
refused_and_evicted() {
  local label="$1" key="${2:-${BASE_KEY}}"
  : >"${WORK}/warnings"
  rm -rf "${WORK}/staged-3"; mkdir -p "${WORK}/staged-3"
  if kernel_artifact_cache_hit "${key}" "${WORK}/staged-3" "${DEB_NAME}" 2>/dev/null; then
    bad "${label}: accepted"
  elif [[ -e "${WORK}/shared/kernel-artifacts/${key}" || -e "${WORK}/staged-3/${DEB_NAME}" ]]; then
    bad "${label}: refused but entry kept or bytes staged"
  elif ! grep -Fq 'failed its key, input, digest or kernel gates' "${WORK}/warnings"; then
    bad "${label}: refused silently"
  else
    ok "${label}: refused, evicted and logged"
  fi
}
old_digest="${builder_digest}"
builder_digest='sha256:other-builder'
OTHER_KEY="$(kernel_artifact_cache_key)"
builder_digest="${old_digest}"
reseed
cp -a "${SHARED_ENTRY}" "${WORK}/shared/kernel-artifacts/${OTHER_KEY}"
builder_digest='sha256:other-builder'
refused_and_evicted 'entry copied under another key' "${OTHER_KEY}"
builder_digest="${old_digest}"

reseed
python3 - "${SHARED_ENTRY}/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
json.dump({'sha256': m['sha256']}, open(sys.argv[1], 'w'))
PY
refused_and_evicted 'format 1 manifest (no key binding)'

reseed
python3 - "${SHARED_ENTRY}/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
m['inputs']['builder_digest'] = 'sha256:tampered'
json.dump(m, open(sys.argv[1], 'w'))
PY
refused_and_evicted 'recorded inputs that do not derive the key'

reseed
python3 - "${SHARED_ENTRY}/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
m['key'] = 'f' * 64
json.dump(m, open(sys.argv[1], 'w'))
PY
refused_and_evicted 'manifest naming a different key'

# Self-consistent entry for OTHER inputs: intact on its own terms, refused for
# this build's inputs. Proves --inputs compares, not only re-derives.
builder_digest='sha256:other-builder'
kernel_artifact_cache_store "${OTHER_KEY}" "${WORK}/built/${DEB_NAME}" "${WORK}/built"
builder_digest="${old_digest}"
OTHER_ENTRY="${WORK}/shared/kernel-artifacts/${OTHER_KEY}"
if kernel_artifact_cache_intact "${OTHER_ENTRY}" "${DEB_NAME}" "${OTHER_KEY}" &&
   ! kernel_artifact_cache_intact "${OTHER_ENTRY}" "${DEB_NAME}" "${OTHER_KEY}" --inputs; then
  ok 'an entry for other inputs is intact on its own but refused for this build'
else
  bad 'input comparison does not distinguish builds'
fi
rm -rf "${OTHER_ENTRY}"
if kernel_artifact_cache_hit 'not-a-key' "${WORK}/staged-3" "${DEB_NAME}" 2>/dev/null; then
  bad 'malformed key accepted'
else ok 'malformed key refused before any path is built from it'; fi

# --- first writer wins -------------------------------------------------------
reseed
mkdir -p "${WORK}/built-b/control"
cp -a "${WORK}/control/." "${WORK}/built-b/control/"
sed -i 's/^Description: test$/Description: other bytes/' "${WORK}/built-b/control/DEBIAN/control"
dpkg-deb --build --root-owner-group "${WORK}/built-b/control" "${WORK}/built-b/${DEB_NAME}" >/dev/null
cp "${WORK}/built/resolved.config" "${WORK}/built/built-modules.txt" "${WORK}/built-b/"
: >"${WORK}/warnings"
kernel_artifact_cache_store "${BASE_KEY}" "${WORK}/built-b/${DEB_NAME}" "${WORK}/built-b"
if cmp -s "${SHARED_ENTRY}/${DEB_NAME}" "${WORK}/built/${DEB_NAME}" &&
   grep -Fq 'DIFFERENT deb' "${WORK}/warnings"; then
  ok 'a second store keeps the first entry and reports the differing deb'
else
  bad 'a second store replaced the entry or stayed silent'
fi
: >"${WORK}/warnings"
kernel_artifact_cache_store "${BASE_KEY}" "${WORK}/built/${DEB_NAME}" "${WORK}/built"
[[ ! -s "${WORK}/warnings" ]] && ok 'an identical second store is quiet' || bad 'identical store warned'

# --- concurrency: parallel builds on one key --------------------------------
rm -rf "${WORK}/shared/kernel-artifacts"
pids=()
for worker in 1 2 3 4 5 6 7 8; do
  (
    mkdir -p "${WORK}/race/${worker}"
    kernel_artifact_cache_store "${BASE_KEY}" "${WORK}/built/${DEB_NAME}" "${WORK}/built"
    kernel_artifact_cache_hit "${BASE_KEY}" "${WORK}/race/${worker}" "${DEB_NAME}"
  ) &
  pids+=("$!")
done
race_failures=0
for pid in "${pids[@]}"; do wait "${pid}" || race_failures=$((race_failures + 1)); done
race_same=1
for worker in 1 2 3 4 5 6 7 8; do
  cmp -s "${WORK}/race/${worker}/${DEB_NAME}" "${WORK}/built/${DEB_NAME}" || race_same=0
done
leftovers="$(find "${WORK}/shared/kernel-artifacts" -maxdepth 1 -name '.pending.*' -o -maxdepth 1 -name '.remote.*' | wc -l)"
if (( race_failures == 0 && race_same == 1 && leftovers == 0 )) &&
   kernel_artifact_cache_intact "${SHARED_ENTRY}" "${DEB_NAME}" "${BASE_KEY}" --inputs; then
  ok 'eight concurrent store+hit workers on one key: all staged the same bytes, entry intact, no debris'
else
  bad "concurrent workers: ${race_failures} failed, same=${race_same}, leftovers=${leftovers}"
fi
unset CERALIVE_KERNEL_CACHE_DIR
printf 'Kernel artifact cache contract: %s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))

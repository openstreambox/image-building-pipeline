#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154
# shellcheck source=../shared/remote-cache.sh
source "$(dirname "${BASH_SOURCE[0]}")/../shared/remote-cache.sh"
# shellcheck source=cache-dir.sh
source "$(dirname "${BASH_SOURCE[0]}")/cache-dir.sh"

kernel_artifact_cache_mode() {
  case "${CERALIVE_KERNEL_ARTIFACT_CACHE:-auto}" in
    auto|0) printf '%s' "${CERALIVE_KERNEL_ARTIFACT_CACHE:-auto}" ;;
    *) die "CERALIVE_KERNEL_ARTIFACT_CACHE must be auto or 0 (got '${CERALIVE_KERNEL_ARTIFACT_CACHE}')" ;;
  esac
}

kernel_artifact_cache_root() {
  local shared
  shared="$(kernel_shared_cache_dir)" || return 1
  if [[ -n "${shared}" ]]; then
    kernel_cache_dir_trusted "${shared}/kernel-artifacts" || return 1
    printf '%s/kernel-artifacts' "${shared}"
  else
    printf '%s/%s' "${PIPELINE_DIR}" "${CERALIVE_REL_MKOSI_CACHE_ROOT}/kernel-artifacts"
  fi
}

# The producer's inputs, defined ONCE. The cache key (below) and the kernel pin
# check (lib/kernel/pinned.sh) both read these two lists, so a new input cannot
# reach one and miss the other.
#
# kernel_input_values — NUL-separated name/value pairs for every scalar input
# that is known before the builder container runs. The three that are only known
# inside it (builder package closure, compiler banner, kernel commit epoch) are
# added by the fingerprint itself.
kernel_input_values() {
  printf '%s\0' \
    git_url "${git_url}" tag "${tag}" commit "${commit}" \
    patches_git_url "${patches_url}" patches_commit "${patches_commit}" \
    patches_series "${patches_series}" config_mode "${config_mode}" \
    defconfig_base "${defconfig_base}" config_git_url "${config_git_url}" \
    config_commit "${config_commit}" config_path "${config_path}" \
    builder_image "${builder_image}" variant "${KERNEL_VARIANT:-default}" \
    arch "${arch}" package "${kernel_pkg}" kernel_release "${kernel_release}" \
    local_version "${local_version}" package_version "${package_version}"
}

# kernel_input_files — every file the producer's output depends on, one path per
# line: the config fragments in merge order, then the fixed set.
kernel_input_files() {
  local file
  for file in "${fragments[@]}" "${absent_list:-}" \
      "${HERE}/build-kernel.sh" "${KERNEL_LIB_DIR}/config.sh" \
      "${KERNEL_LIB_DIR}/checkout.sh" "${KERNEL_LIB_DIR}/builder.sh" \
      "${KERNEL_LIB_DIR}/package.sh" "${KERNEL_LIB_DIR}/artifact-cache.sh" \
      "${KERNEL_LIB_DIR}/only.sh" \
      "${KERNEL_LIB_DIR}/ramoops.sh" \
      "${KERNEL_LIB_DIR}/cache-dir.sh" \
      "${PIPELINE_DIR}/manifests/kernel/rk3588-ramoops.dtsi" \
      "${KERNEL_LIB_DIR}/rock-5b-plus-fan.sh" \
      "${PIPELINE_DIR}/manifests/kernel/rk3588-fan-driver-support.patch" \
      "${PIPELINE_DIR}/manifests/kernel/rock-5b-plus-fan.dtsi" \
      "${HERE}/shared/remote-cache.sh" \
      "${KERNEL_CONFIG_VERIFIER_SH:-${HERE}/verify-kernel-config.sh}" \
      "${HERE}/verify-boot-artifacts.sh" \
      "${PIPELINE_DIR}/mkosi/runtime/ceralive-kernel-boot-staging.sh" \
      "${PIPELINE_DIR}/mkosi/customize/bluetooth-firmware.sh" \
      "${PIPELINE_DIR}/manifests/rk3588-bluetooth-firmware-roots.txt" \
      "${PIPELINE_DIR}/manifests/kernel/required-symbols.list" \
      "${PIPELINE_DIR}/manifests/kernel/forbidden-symbols.list" \
      "${KERNEL_BUILDER_DOCKERFILE}"; do
    [[ -n "${file}" ]] && printf '%s\n' "${file}"
  done
}

kernel_input_fingerprint() {
  local file
  {
    printf '%s\0' 'kernel-input-v3'
    kernel_input_values
    printf '%s\0' builder_packages "${builder_packages}" builder_compiler "${builder_compiler}" \
      epoch "${epoch}"
    while IFS= read -r file; do
      printf '%s\0' "${file#"${PIPELINE_DIR}/"}"
      sha256sum "${file}" | cut -d' ' -f1
    done < <(kernel_input_files)
  } | sha256sum | cut -d' ' -f1
}
kernel_artifact_cache_key() {
  printf '%s\0' "$(kernel_input_fingerprint)" "${builder_digest}" "${dtb_path}" \
    | sha256sum | cut -d' ' -f1
}

kernel_artifact_identity() {
  local out="$1" deb="$2"
  python3 - "${out}" "${deb}" "${kernel_pkg}" "${package_version}" "${arch}" \
    "${kernel_release}" "${input_fingerprint}" "${epoch}" "${builder_image}" \
    "${builder_packages}" "${builder_compiler}" "${KERNEL_BUILDER_DOCKERFILE}" <<'PY'
import hashlib
import json
import pathlib
import sys
out, deb, package, version, arch, release, fingerprint, epoch, base, packages, compiler, dockerfile = sys.argv[1:]
record = dict(package=package, version=version, arch=arch, kernel_release=release,
              deb_sha256=hashlib.sha256(pathlib.Path(deb).read_bytes()).hexdigest(),
              input_fingerprint=fingerprint, kernel_epoch=int(epoch), validated_boards=[],
              builder_closure=dict(base_image=base, packages=packages.splitlines(),
                                   compiler=compiler, dockerfile_sha256=hashlib.sha256(
                                       pathlib.Path(dockerfile).read_bytes()).hexdigest()))
(pathlib.Path(out) / 'kernel-artifact.json').write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
PY
}

# The entry manifest binds the three files to each other AND to the cache key
# and the inputs the key derives from. An entry copied or renamed under another
# key, written for other inputs, or in an older format is refused, never staged.
KERNEL_ARTIFACT_CACHE_FORMAT='ceralive-kernel-artifact-cache/2'

kernel_artifact_cache_manifest() {
  local dir="$1" deb_name="$2" key="$3" fingerprint
  fingerprint="$(kernel_input_fingerprint)" || return 1
  python3 - "${dir}" "${deb_name}" "${key}" "${fingerprint}" \
    "${builder_digest}" "${dtb_path}" "${KERNEL_ARTIFACT_CACHE_FORMAT}" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
key, fingerprint, digest, dtb, fmt = sys.argv[3:]
derived = hashlib.sha256(f'{fingerprint}\0{digest}\0{dtb}\0'.encode()).hexdigest()
if derived != key:
    sys.exit(f'cache key {key} does not derive from the recorded inputs ({derived})')
names = [sys.argv[2], 'resolved.config', 'built-modules.txt']
hashes = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in names}
record = {'format': fmt, 'key': key,
          'inputs': {'input_fingerprint': fingerprint, 'builder_digest': digest, 'dtb_path': dtb},
          'sha256': hashes}
(root / 'manifest.json').write_text(json.dumps(record, sort_keys=True) + '\n')
PY
}

# kernel_artifact_cache_intact <dir> <deb name> <key> [--inputs]
# Fails closed on: another format, a key other than the requested one, recorded
# inputs that do not derive that key, any file digest mismatch, and (with
# --inputs) recorded inputs other than this build's.
kernel_artifact_cache_intact() {
  local dir="$1" deb_name="$2" key="$3" fingerprint="" digest="" dtb=""
  if [[ "${4:-}" == '--inputs' ]]; then
    fingerprint="$(kernel_input_fingerprint)" || return 1
    digest="${builder_digest:-}"
    dtb="${dtb_path:-}"
    [[ -n "${fingerprint}" && -n "${digest}" && -n "${dtb}" ]] || return 1
  fi
  python3 - "${dir}" "${deb_name}" "${key}" "${KERNEL_ARTIFACT_CACHE_FORMAT}" \
    "${fingerprint}" "${digest}" "${dtb}" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
deb_name, key, fmt, fingerprint, digest, dtb = sys.argv[2:]
names = {deb_name, 'resolved.config', 'built-modules.txt'}
try:
    assert re.fullmatch(r'[0-9a-f]{64}', key)
    manifest = json.loads((root / 'manifest.json').read_text())
    assert set(manifest) == {'format', 'key', 'inputs', 'sha256'}
    assert manifest['format'] == fmt and manifest['key'] == key
    inputs = manifest['inputs']
    assert set(inputs) == {'input_fingerprint', 'builder_digest', 'dtb_path'}
    assert all(isinstance(value, str) and value for value in inputs.values())
    recorded = (inputs['input_fingerprint'], inputs['builder_digest'], inputs['dtb_path'])
    assert hashlib.sha256('\0'.join(recorded + ('',)).encode()).hexdigest() == key
    if fingerprint:
        assert recorded == (fingerprint, digest, dtb)
    hashes = manifest['sha256']
    assert set(hashes) == names
    assert all(isinstance(hashes[name], str) and len(hashes[name]) == 64 and
               hashlib.sha256((root / name).read_bytes()).hexdigest() == hashes[name]
               for name in names)
    assert (root / 'built-modules.txt').stat().st_size > 0
except (OSError, ValueError, KeyError, AssertionError, TypeError, AttributeError):
    sys.exit(1)
PY
}

kernel_artifact_verify_config() {
  local resolved="$1" declared="" expected="" config_tree="" rc=0
  local -a args=(--config "${resolved}")
  if [[ "${config_mode}" == 'defconfig' ]]; then
    if (( ${#fragments[@]} == 1 )); then
      declared="${fragments[0]}"
    else
      expected="$(mktemp)"
      python3 - "${expected}" "${fragments[@]}" <<'PY'
import pathlib
import re
import sys

entries = {}
for path in sys.argv[2:]:
    for line in pathlib.Path(path).read_text().splitlines():
        match = re.match(r'(?:# )?(CONFIG_[A-Za-z0-9_]+)(?:=.*| is not set)$', line)
        if match:
            entries[match.group(1)] = line
pathlib.Path(sys.argv[1]).write_text('\n'.join(entries.values()) + '\n')
PY
      declared="${expected}"
    fi
  else
    config_tree="$(mktemp -d)"
    if ! fetch_pinned_tree "${config_tree}/config" "${config_git_url}" "" "${config_commit}" "config repo"; then
      rm -rf -- "${config_tree}"
      return 1
    fi
    declared="${config_tree}/config/${config_path}"
    if [[ ! -f "${declared}" ]]; then
      rm -rf -- "${config_tree}"
      return 1
    fi
    [[ -z "${absent_list}" ]] || args+=(--allow-absent "${absent_list}")
  fi
  [[ -z "${declared}" ]] || args+=(--declared "${declared}")
  args+=(--required "${PIPELINE_DIR}/manifests/kernel/required-symbols.list")
  if [[ "${KERNEL_VARIANT:-edge}" == 'edge' ]]; then
    args+=(--forbidden "${PIPELINE_DIR}/manifests/kernel/forbidden-symbols.list")
  fi
  bash "${KERNEL_CONFIG_VERIFIER_SH:-${HERE}/verify-kernel-config.sh}" "${args[@]}" || rc=$?
  [[ -z "${expected}" ]] || rm -f -- "${expected}"
  [[ -z "${config_tree}" ]] || rm -rf -- "${config_tree}"
  return "${rc}"
}

# Evicted entries keep their evidence: an entry in the current format that failed
# its key, input, digest or kernel gates moves to .quarantine/ (newest eight
# kept). Older-format or incomplete entries carry nothing worth keeping and are
# deleted. Called with the entry's key lock held.
KERNEL_ARTIFACT_QUARANTINE_KEEP=8
kernel_artifact_cache_evict() {
  local root="$1" key="$2" entry="$1/$2" format="" dest="" old
  format="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("format",""))' \
    "${entry}/manifest.json" 2>/dev/null)" || format=""
  if [[ "${format}" == "${KERNEL_ARTIFACT_CACHE_FORMAT}" ]] && mkdir -p "${root}/.quarantine" &&
     dest="$(mktemp -d "${root}/.quarantine/${key}.$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"; then
    # rename(2) replaces the empty placeholder atomically.
    if mv -T -- "${entry}" "${dest}"; then
      touch -- "${dest}" || :
      log_warn "kernel artifact cache entry ${key} quarantined: ${dest}"
      while read -r old; do
        rm -rf -- "${old}"
      done < <(find "${root}/.quarantine" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
                 | sort -rn | tail -n +$((KERNEL_ARTIFACT_QUARANTINE_KEEP + 1)) | cut -d' ' -f2-)
      return 0
    fi
    rmdir -- "${dest}" 2>/dev/null || :
  fi
  rm -rf -- "${entry}"
}

# Interrupted stores and remote fills leave .pending.*/.remote.* directories
# (a whole kernel each). Anything older than six hours is not in flight.
kernel_artifact_cache_sweep() {
  local root="$1"
  find "${root}" -mindepth 1 -maxdepth 1 -type d \( -name '.pending.*' -o -name '.remote.*' \) \
    -mmin +360 -exec rm -rf -- {} + 2>/dev/null || :
}

kernel_artifact_cache_remote_fill() {
  local key="$1" deb_name="$2" root entry tmp base file rc=0
  [[ "${DRY_RUN:-0}" != 1 ]] || return 1
  [[ "$(ceralive_remote_cache_mode)" == auto ]] || return 1
  [[ "${key}" =~ ^[0-9a-f]{64}$ && "${deb_name}" =~ ^[A-Za-z0-9._+~-]+\.deb$ ]] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  base="$(ceralive_remote_cache_url)" || return 1
  root="$(kernel_artifact_cache_root)" || return 1
  entry="${root}/${key}"
  mkdir -p "${root}/.locks" || return 1
  tmp="$(mktemp -d "${root}/.remote.XXXXXXXX")" || return 1
  for file in manifest.json "${deb_name}" resolved.config built-modules.txt; do
    if ! curl --fail --silent --show-error --proto '=https,http' \
        --connect-timeout 2 --max-time 120 \
        -o "${tmp}/${file}" "${base}/kernel/${key}/${file}" 2>/dev/null; then
      rm -rf -- "${tmp}"
      return 1
    fi
  done
  # The manifest binds the downloaded files to each other and to this key and
  # this build's key inputs. The key comes from pinned build inputs; the
  # four-axis deb gate and Kconfig survival plus required/forbidden closure are
  # rerun, never delegated to R2.
  if ! kernel_artifact_cache_intact "${tmp}" "${deb_name}" "${key}" --inputs ||
     ! (validate_built_kernel_deb "${tmp}/${deb_name}" "${kernel_pkg}" "${package_version}" "${arch}" "${dtb_path}" &&
        kernel_artifact_verify_config "${tmp}/resolved.config"); then
    log_warn "kernel remote cache rejected invalid manifest/deb/config for ${key} — rebuilding"
    rm -rf -- "${tmp}"
    return 1
  fi
  (
    flock -w 3600 9 || exit 1
    if [[ -d "${entry}" ]]; then
      rm -rf -- "${tmp}"
    else
      mv -T -- "${tmp}" "${entry}" || exit 1
    fi
  ) 9>"${root}/.locks/${key}.lock" || rc=$?
  if (( rc != 0 )); then rm -rf -- "${tmp}"; return 1; fi
  log_info "kernel remote cache HIT ${key} (manifest and kernel gates verified)"
}

kernel_artifact_cache_hit() {
  local key="$1" out="$2" deb_name="$3" root entry rc=0
  [[ "${key}" =~ ^[0-9a-f]{64}$ ]] || return 1
  root="$(kernel_artifact_cache_root)" || return 1
  entry="${root}/${key}"
  if [[ ! -d "${entry}" ]]; then
    kernel_artifact_cache_remote_fill "${key}" "${deb_name}" || :
  fi
  [[ -d "${entry}" ]] || return 1
  mkdir -p "${root}/.locks" || return 1
  (
    flock -w 3600 9 || exit 1
    [[ -d "${entry}" ]] || exit 1
    if ! kernel_artifact_cache_intact "${entry}" "${deb_name}" "${key}" --inputs ||
       ! (validate_built_kernel_deb "${entry}/${deb_name}" "${kernel_pkg}" "${package_version}" "${arch}" "${dtb_path}" &&
          kernel_artifact_verify_config "${entry}/resolved.config"); then
      log_warn "kernel artifact cache entry ${entry} failed its key, input, digest or kernel gates — evicted, rebuilding"
      kernel_artifact_cache_evict "${root}" "${key}"
      exit 1
    fi
    "${MKOSI_PACKAGE_STAGING_SH:-${HERE}/stage-mkosi-package.sh}" "${entry}/${deb_name}" "${out}" || exit 1
    install -m 0644 "${entry}/resolved.config" "${out}/resolved.config" || exit 1
    install -m 0644 "${entry}/built-modules.txt" "${out}/built-modules.txt" || exit 1
  ) 9>"${root}/.locks/${key}.lock" || rc=$?
  if (( rc != 0 )); then
    if [[ ! -d "${entry}" ]] && kernel_artifact_cache_remote_fill "${key}" "${deb_name}"; then
      kernel_artifact_cache_hit "${key}" "${out}" "${deb_name}"
      return $?
    fi
    return 1
  fi
  log_info "kernel artifact cache HIT ${key}"
}

# kernel_artifact_cache_build_strict — whether a second, different deb for one
# key stops the build. Production builds stop; development builds warn.
kernel_artifact_cache_build_strict() {
  [[ "${CERALIVE_BUILD_MODE:-}" == production ]]
}

# First intact writer wins. Two builds of one key can run at once on a shared
# root; the later one keeps the published entry rather than swapping it under a
# reader. If its own deb differs (nondeterminism, or a poisoned ccache object),
# it returns 3: the stage then refuses to ship in production and warns with
# both digests in development. Every other failure only skips the store.
kernel_artifact_cache_store() {
  local key="$1" deb="$2" built_dir="$3" root entry tmp deb_name rc=0
  [[ "${key}" =~ ^[0-9a-f]{64}$ ]] || return 0
  root="$(kernel_artifact_cache_root)" || return 0
  entry="${root}/${key}"
  deb_name="$(basename "${deb}")"
  mkdir -p "${root}/.locks" || return 0
  kernel_artifact_cache_sweep "${root}"
  (
    flock -w 3600 9 || exit 1
    if [[ -d "${entry}" ]] && kernel_artifact_cache_intact "${entry}" "${deb_name}" "${key}" --inputs; then
      if cmp -s -- "${deb}" "${entry}/${deb_name}"; then
        log_info "kernel artifact cache already holds ${key} with the same deb"
        exit 0
      fi
      log_warn "kernel artifact cache already holds ${key} with a DIFFERENT deb ($(sha256sum "${entry}/${deb_name}" | cut -d' ' -f1) cached, $(sha256sum "${deb}" | cut -d' ' -f1) built); keeping the first. This kernel build is not reproducible for these inputs."
      exit 3
    fi
    # The key is recomputed from the inputs as they are NOW. If a host-side
    # input changed during the build, the deb belongs to neither key: skip it.
    if [[ "$(kernel_artifact_cache_key)" != "${key}" ]]; then
      log_warn "kernel artifact cache: build inputs changed during the build (key ${key} no longer derives); not stored"
      exit 0
    fi
    tmp="$(mktemp -d "${root}/.pending.XXXXXXXX")" || exit 1
    if install -m 0644 "${deb}" "${tmp}/${deb_name}" &&
       install -m 0644 "${built_dir}/resolved.config" "${tmp}/resolved.config" &&
       install -m 0644 "${built_dir}/built-modules.txt" "${tmp}/built-modules.txt" &&
       kernel_artifact_cache_manifest "${tmp}" "${deb_name}" "${key}"; then
      [[ ! -e "${entry}" ]] || kernel_artifact_cache_evict "${root}" "${key}"
      if mv -T -- "${tmp}" "${entry}"; then
        log_info "kernel artifact cache STORE ${key} -> ${root}"
      else
        rm -rf -- "${tmp}"
        exit 1
      fi
    else
      rm -rf -- "${tmp}"
      exit 1
    fi
  ) 9>"${root}/.locks/${key}.lock" || rc=$?
  case "${rc}" in
    0) return 0 ;;
    3) return 3 ;;
    *) log_warn "kernel artifact cache store unavailable; the built output is unaffected"; return 0 ;;
  esac
}

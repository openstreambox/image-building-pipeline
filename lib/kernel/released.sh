#!/usr/bin/env bash
# Release admission/reuse entrypoint around the byte-frozen kernel producer.
# shellcheck shell=bash
# shellcheck disable=SC2154
# shellcheck source=pinned.sh
source "$(dirname "${BASH_SOURCE[0]}")/pinned.sh"

kernel_fingerprint_from() (
  local metadata="$1" recorded_base
  local inputs
  inputs="$(python3 - "${PIPELINE_DIR}" "${metadata}" <<'PY'
import json, pathlib, shlex, sys
sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / 'lib'))
from kernel_release import artifact
artifact(pathlib.Path(sys.argv[2]))
row = json.load(open(sys.argv[2]))
closure = row['builder_closure']
for name, value in (
    ('epoch', str(row['kernel_epoch'])),
    ('builder_packages', '\n'.join(closure['packages'])),
    ('builder_compiler', closure['compiler']),
    ('recorded_base', closure['base_image']),
):
    print(name + '=' + shlex.quote(value))
PY
)" || return 1
  eval "${inputs}"
  [[ "${recorded_base}" == "${builder_image}" ]] \
    || { log_error "bump package_version: kernel builder base changed"; return 1; }
  kernel_input_fingerprint
)

kernel_reuse_released() (
  local deb="$1" out="$2" board="$3" metadata fingerprint
  metadata="$(mktemp -d)" || return 1
  trap 'rm -rf -- "${metadata}"' EXIT
  python3 "${PIPELINE_DIR}/ci/check-kernel-version-monotonic.py" \
    --metadata "${package_version}" --out "${metadata}" || return 1
  fingerprint="$(kernel_fingerprint_from "${metadata}/kernel-artifact.json")" || return 1
  python3 - "${PIPELINE_DIR}" "${metadata}/kernel-artifact.json" "${deb}" \
    "${kernel_pkg}" "${package_version}" "${fingerprint}" "${board}" <<'PY' || return 1
import hashlib, pathlib, sys
sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / 'lib'))
from kernel_release import artifact
record = artifact(pathlib.Path(sys.argv[2]))
deb, package, version, fingerprint, board = sys.argv[3:]
if (record.identity.package, record.identity.version) != (package, version):
    sys.exit('released kernel identity mismatch')
if record.identity.deb_sha256 != hashlib.sha256(pathlib.Path(deb).read_bytes()).hexdigest():
    sys.exit('APT kernel digest differs from released artifact')
if record.fingerprint != fingerprint:
    sys.exit('bump package_version: released kernel input_fingerprint mismatch')
if board not in record.boards:
    sys.exit('board absent from released validated_boards')
PY
  validate_built_kernel_deb "${deb}" "${kernel_pkg}" "${package_version}" "${arch}" "${dtb_path}" \
    || return 1
  kernel_artifact_verify_config "${metadata}/resolved.config" || return 1
  install -d -m 0755 "${out}" || return 1
  if [[ "$(realpath "${deb}")" != "$(realpath -m "${out}/$(basename "${deb}")")" ]]; then
    "${MKOSI_PACKAGE_STAGING_SH:-${HERE}/stage-mkosi-package.sh}" "${deb}" "${out}" || return 1
  fi
  local name
  for name in kernel-artifact.json resolved.config built-modules.txt SHA256SUMS; do
    install -m 0644 "${metadata}/${name}" "${out}/${name}" || return 1
  done
  log_success "reused authenticated APT kernel ${kernel_pkg}=${package_version}; no compilation"
)

# kernel_pin_cold_build <dir> — the producer, cold: no artifact cache, a fresh
# ccache that is removed afterwards. A caller-supplied ccache would make the
# proof warm, so it is refused.
# The producer runs in a subshell so that its die/exit returns here and the
# caller can remove its private directories.
kernel_pin_cold_build() {
  local out="$1" ccache rc=0
  ccache="$(mktemp -d "${TMPDIR:-/tmp}/kernel-cold-ccache.XXXXXXXX")" || return 1
  log_info "kernel pin: COLD build for ${pin_mode} (CERALIVE_KERNEL_ARTIFACT_CACHE=0, fresh ccache ${ccache})"
  ( CERALIVE_KERNEL_ARTIFACT_CACHE=0 main --board "${board}" --out "${out}" --ccache-dir "${ccache}" ) || rc=$?
  rm -rf -- "${ccache}" || log_warn "could not remove the cold ccache ${ccache}"
  return "${rc}"
}

kernel_release_main() {
  local board="" out_dir="" fingerprint_from="" reuse_deb="" ccache_arg=""
  local -a producer_args=()
  while (( $# )); do
    case "$1" in
      --board) board="${2:-}"; producer_args+=("$1" "${2:-}"); shift 2 ;;
      --out) out_dir="${2:-}"; producer_args+=("$1" "${2:-}"); shift 2 ;;
      --ccache-dir) ccache_arg="${2:-}"; producer_args+=("$1" "${2:-}"); shift 2 ;;
      --fingerprint-from) fingerprint_from="${2:-}"; shift 2 ;;
      --reuse-deb) reuse_deb="${2:-}"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) die "unknown kernel release argument: $1" ;;
    esac
  done
  [[ -n "${board}" ]] || die "--board is required"
  [[ -n "${out_dir}${fingerprint_from}" ]] || die "--out is required"

  # Mirror the producer's dynamic input frame without editing its hashed bytes.
  local git_url="${KERNEL_SOURCE_GIT_URL:-}" tag="${KERNEL_SOURCE_TAG:-}"
  local commit="${KERNEL_SOURCE_COMMIT:-}" patches_url="${KERNEL_SOURCE_PATCHES_GIT_URL:-}"
  local patches_commit="${KERNEL_SOURCE_PATCHES_COMMIT:-}" patches_series="${KERNEL_SOURCE_PATCHES_SERIES:-}"
  local defconfig_base="${KERNEL_SOURCE_DEFCONFIG_BASE:-}" fragment_rel="${KERNEL_SOURCE_DEFCONFIG_FRAGMENT:-}"
  local fragments_rel="${KERNEL_SOURCE_DEFCONFIG_FRAGMENTS:-}"
  local config_git_url="${KERNEL_SOURCE_CONFIG_GIT_URL:-}" config_commit="${KERNEL_SOURCE_CONFIG_COMMIT:-}"
  local config_path="${KERNEL_SOURCE_CONFIG_PATH:-}" absent_rel="${KERNEL_SOURCE_CONFIG_ABSENT_SYMBOLS:-}"
  local builder_image="${KERNEL_SOURCE_BUILDER_IMAGE:-}" local_version="${KERNEL_SOURCE_LOCAL_VERSION:-}"
  local kernel_release="${KERNEL_SOURCE_KERNEL_RELEASE:-}" package_version="${KERNEL_SOURCE_PACKAGE_VERSION:-}"
  local dtb_deb_dir="${KERNEL_SOURCE_DTB_DEB_DIR:-}" arch="${ARCH:-}" dtb_name="${DTB_NAME:-}"
  local local_patches="${CERALIVE_KERNEL_PATCHES_LOCAL_REPO:-}"
  local config_mode="" config_desc="" absent_list="" kernel_pkg=""
  local -a fragments=() fragments_rel_list=()
  validate_kernel_source_inputs
  resolve_kernel_config_mode
  resolve_kernel_package_name
  kernel_artifact_cache_mode >/dev/null
  ceralive_remote_cache_mode >/dev/null
  local dtb_path="${dtb_deb_dir%/}/${dtb_name}"
  if [[ -n "${fingerprint_from}" ]]; then
    kernel_fingerprint_from "${fingerprint_from}"
    return $?
  fi
  if [[ -n "${reuse_deb}" ]]; then
    kernel_reuse_released "${reuse_deb}" "${out_dir}" "${board}"
    return $?
  fi
  local pin_mode pin_file
  pin_mode="$(kernel_pin_mode)" || exit 1
  pin_file="$(kernel_pin_file)" || exit 1
  if [[ "${DRY_RUN:-0}" != 1 && "${kernel_pkg}" != *-test ]]; then
    python3 "${PIPELINE_DIR}/ci/check-kernel-version-monotonic.py" \
      --published --board "${board}" --version "${package_version}" \
      || die "bump package_version: unpublished local builds must exceed released kernels"
  fi
  if [[ "${pin_mode}" == 0 || ( "${pin_mode}" == auto && ! -f "${pin_file}" ) ]]; then
    main "${producer_args[@]}"
    return
  fi
  case "${pin_mode}" in
    require|verify) [[ -f "${pin_file}" ]] || die "CERALIVE_KERNEL_PIN=${pin_mode} but there is no kernel pin ${pin_file}" ;;
    write) [[ ! -e "${pin_file}" ]] || die "CERALIVE_KERNEL_PIN=write: ${pin_file} exists; a pin is replaced only by removing it in a reviewed change" ;;
  esac
  if [[ "${pin_mode}" == verify || "${pin_mode}" == write ]]; then
    [[ -z "${ccache_arg}" ]] \
      || die "CERALIVE_KERNEL_PIN=${pin_mode} builds cold with a fresh ccache; --ccache-dir is refused"
  fi
  if [[ "${pin_mode}" == write && "${DRY_RUN:-0}" != 1 ]]; then
    kernel_pin_inputs_committed || die "CERALIVE_KERNEL_PIN=write needs every kernel input committed and unmodified"
  fi
  if [[ "${pin_mode}" != write ]]; then
    kernel_pin_check "${pin_file}" \
      || die "the kernel inputs differ from the pin ${pin_file}; restore the pinned inputs, or remove the pin and write a new one with CERALIVE_KERNEL_PIN=write"
  fi
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    log_info "DRY-RUN kernel pin: CERALIVE_KERNEL_PIN=${pin_mode}, pin ${pin_file}"
    main "${producer_args[@]}"
    return
  fi

  # Every pin path builds or stages into a private directory and publishes into
  # --out only after the pin checks pass, so --out never holds a kernel that
  # differs from its pin.
  local staged
  install -d -m 0755 "${out_dir}" || die "cannot create ${out_dir}"
  staged="$(mktemp -d "$(dirname "${out_dir}")/.kernel-pin.XXXXXXXX")" || die "cannot create a staging directory"
  case "${pin_mode}" in
    require|auto)
      if kernel_pin_stage "${pin_file}" "${staged}"; then
        kernel_pin_publish "${staged}" "${out_dir}" || die "cannot publish the pinned kernel into ${out_dir}"
        return 0
      fi
      if [[ "${pin_mode}" == require ]]; then
        rm -rf -- "${staged}"
        die "CERALIVE_KERNEL_PIN=require: the pinned kernel ${pin_file} is in no trusted store; refusing to compile"
      fi
      log_info "kernel pin: pinned bytes not found in any trusted store; compiling and comparing with ${pin_file}"
      ( main --board "${board}" --out "${staged}" ${ccache_arg:+--ccache-dir "${ccache_arg}"} ) \
        || { rm -rf -- "${staged}"; die "kernel build failed for board '${board}'"; }
      kernel_pin_compare "${staged}" "${pin_file}" \
        || { rm -rf -- "${staged}"; die "the compiled kernel is not the pinned kernel (${pin_file}); nothing staged"; }
      ;;
    verify|write)
      kernel_pin_cold_build "${staged}" \
        || { rm -rf -- "${staged}"; die "the cold kernel build failed for board '${board}'"; }
      if [[ "${pin_mode}" == write ]]; then
        kernel_pin_inputs_committed \
          || { rm -rf -- "${staged}"; die "CERALIVE_KERNEL_PIN=write needs every kernel input committed and unmodified"; }
        kernel_pin_write "${staged}" "${pin_file}" \
          || { rm -rf -- "${staged}"; die "cannot write kernel pin ${pin_file}"; }
        log_success "kernel pin written from a cold build: ${pin_file}"
      else
        kernel_pin_compare "${staged}" "${pin_file}" --record \
          || { rm -rf -- "${staged}"; die "the cold build did not reproduce the pin ${pin_file}; nothing staged"; }
        kernel_pin_verify_record "${staged}" "${pin_file}" \
          || { rm -rf -- "${staged}"; die "cannot record the verify run"; }
        log_success "kernel pin verified by a cold build: ${pin_file}"
      fi
      ;;
  esac
  kernel_pin_publish "${staged}" "${out_dir}" || die "cannot publish the kernel into ${out_dir}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # shellcheck source=../build-kernel.sh
  source "$(dirname "${BASH_SOURCE[0]}")/../build-kernel.sh"
  kernel_release_main "$@"
fi

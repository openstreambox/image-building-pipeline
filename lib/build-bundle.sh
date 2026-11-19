#!/usr/bin/env bash
# Build a signed verity/adaptive RAUC OS bundle from a full-size ext4 slot image.
# The root signing key never enters the builder; the leaf and chain sign the bundle.
# `prepare` (deferred signing) writes the same content unsigned, with a hashed
# descriptor, for lib/sign-bundle.sh to sign in a separate short step.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/common.sh"
# shellcheck source=lib/disk/slot-image.sh
source "${HERE}/disk/slot-image.sh"
# shellcheck source=lib/rauc-pki-contract.sh
source "${HERE}/rauc-pki-contract.sh"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
IMAGES_DIR="${PIPELINE_DIR}/images"
SOURCE_DATE_EPOCH="$(resolve_source_date_epoch "${PIPELINE_DIR}")"
export SOURCE_DATE_EPOCH

# The signing PKI is only needed where a bundle is signed: the inline
# `<board> <tree>` path and lib/sign-bundle.sh. `prepare` (deferred signing)
# writes the unsigned bundle content and never reads it.
bundle_pki_paths() {
  RAUC_PKI_DIR="${CERALIVE_RAUC_PKI_DIR:-}"
  RAUC_ROOT_CA="${RAUC_PKI_DIR}/root-ca.pem"
  RAUC_CHAIN="${RAUC_PKI_DIR}/chain.pem"
  RAUC_LEAF_CERT="${RAUC_PKI_DIR}/leaf-signing.pem"
  RAUC_LEAF_KEY="${RAUC_PKI_DIR}/leaf-signing.key"
  RAUC_ROOT_KEY="${RAUC_PKI_DIR}/root-ca.key"
}
bundle_pki_paths
RAUC_VERIFY_OPTS=(-C keyring:check-purpose=codesign)
# Where the device reads its RAUC keyring (mkosi/runtime/rauc/system.conf).
RAUC_DEVICE_KEYRING_PATH=/etc/rauc/ceralive-keyring.pem
UNSIGNED_BUNDLE_SCHEMA=ceralive-unsigned-bundle/1

usage() {
  printf 'Usage: build-bundle.sh <board> <rootfs-tree>\n' >&2
  printf '       build-bundle.sh prepare <board> <rootfs-tree>   (unsigned content for lib/sign-bundle.sh)\n' >&2
}

assert_pki() {
  [[ -n "${RAUC_PKI_DIR}" ]] \
    || die "CERALIVE_RAUC_PKI_DIR is required (resolve it with rauc-pki-contract.sh)"
  local f
  for f in "${RAUC_ROOT_CA}" "${RAUC_CHAIN}" "${RAUC_LEAF_CERT}" "${RAUC_LEAF_KEY}"; do
    [[ -s "${f}" ]] || die "RAUC PKI file missing or empty: ${f}"
  done
}

assert_no_root_signing() {
  local rendered="$*"
  [[ "${rendered}" != *"$(basename "${RAUC_ROOT_KEY}")"* ]] \
    || die "REFUSING to sign: root-ca.key must stay offline"
  [[ "${rendered}" == *leaf-signing.key* ]] \
    || die "signing invocation does not use leaf-signing.key"
}

write_manifest() {
  local path="$1" compatible="$2" version="$3" build="${4:-}"
  cat >"${path}" <<EOF
[update]
compatible=${compatible}
version=${version}
EOF
  # RAUC's own build-id field: the pipeline commit, shown by `rauc info` and per
  # slot by `rauc status`, so a CalVer version keeps its provenance.
  [[ -z "${build}" ]] || printf 'build=%s\n' "${build}" >>"${path}"
  cat >>"${path}" <<EOF

[bundle]
format=verity

[image.rootfs]
filename=rootfs.ext4
adaptive=block-hash-index
EOF
  if [[ "${BOARD_ID:-}" == rock-5b-plus ]]; then
    printf '\n[hooks]\nfilename=layout-check\nhooks=install-check\n' >>"${path}"
  fi
}

# The canonical build already has the builder image; direct/native callers use
# their local RAUC. Verification uses the same keyring and purpose on both paths.
bundle_with_rauc() {
  local content="$1" out="$2" runtime image out_dir
  # RAUC's verity bundler refuses a squashfs payload <= 4096 bytes (bundle.c:
  # "squashfs size (%llu) must be larger than 4096 bytes" — a single dm-verity
  # block has no hash tree to build). A tiny bundle (e.g. the cert-rotation
  # payload) can compress right up against that floor; callers with genuinely
  # small content set RAUC_BUNDLE_MKSQUASHFS_ARGS (e.g. "-noD -noF") so `rauc
  # bundle --mksquashfs-args=` skips data/fragment compression instead of this
  # helper silently failing on input the OS-bundle path never has to worry
  # about. Unset for every other caller — behaviour there is unchanged.
  local -a mksquashfs_opt=()
  [[ -n "${RAUC_BUNDLE_MKSQUASHFS_ARGS:-}" ]] \
    && mksquashfs_opt=("--mksquashfs-args=${RAUC_BUNDLE_MKSQUASHFS_ARGS}")
  if [[ -n "${MKOSI_BUILDER_IMAGE:-}" && "${MKOSI_NATIVE:-0}" != 1 ]]; then
    if command -v docker >/dev/null 2>&1; then runtime=docker
    elif command -v podman >/dev/null 2>&1; then runtime=podman
    else die "no container runtime for canonical RAUC bundle build"; fi
    image="${MKOSI_BUILDER_IMAGE}"
    out_dir="$(dirname "${out}")"
    # ci/Dockerfile deliberately ships no `rauc` (Debian trixie's is 1.13, which
    # cannot build/verify format=verity bundles). This container is AMD64-native
    # (debian:trixie-slim, no arch qualifier), so RAUC_DEB_DIR here MUST be the
    # HOST-NATIVE (amd64) pair stage_rauc_build ([2c/9]) builds at
    # rauc_build_dir_host — never the target board's own rauc pair (which may be
    # a different architecture, e.g. arm64 for RK3588): apt's ordinary default
    # resolution only works because this transaction sees a single self-consistent
    # amd64 rauc+rauc-service pair, with zero foreign-arch candidates.
    [[ -n "${RAUC_DEB_DIR:-}" && -d "${RAUC_DEB_DIR}" ]] \
      || die "RAUC_DEB_DIR is required for the containerized bundle build (the host-native RAUC 1.15.2 .deb pair from stage [2c/9]/lib/build-rauc.sh)"
    assert_no_root_signing rauc bundle --key=/pki/leaf-signing.key
    # /bundle is writable: since RAUC 1.12, `rauc bundle` hard-links the whole
    # content dir into a .rauc-workdir it creates INSIDE it, so a read-only
    # mount here fails every containerized build ("Read-only file system") —
    # not a signing/security boundary, since ${content} is this function's own
    # ephemeral mktemp scratch dir, discarded by build-bundle()'s RETURN trap.
    "${runtime}" run --rm \
      -e "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}" \
      -e "RAUC_BUNDLE_MKSQUASHFS_ARGS=${RAUC_BUNDLE_MKSQUASHFS_ARGS:-}" \
      -v "${content}:/bundle" -v "${out_dir}:/out" \
      -v "${RAUC_PKI_DIR}:/pki:ro" -v "${RAUC_DEB_DIR}:/rauc-debs:ro" "${image}" \
      bash -euo pipefail -c '
        apt-get update -qq
        # squashfs-tools is only a Suggests: of rauc (bundle CREATION is a
        # build-host operation; unsquashfs alone — a Depends: — is enough on
        # the device to INSTALL one), so this builder needs it named explicitly.
        apt-get install -y --no-install-recommends squashfs-tools /rauc-debs/rauc_*.deb /rauc-debs/rauc-service_*.deb >/dev/null
        extra=()
        [[ -n "${RAUC_BUNDLE_MKSQUASHFS_ARGS:-}" ]] && extra=("--mksquashfs-args=${RAUC_BUNDLE_MKSQUASHFS_ARGS}")
        rauc bundle --cert=/pki/leaf-signing.pem --key=/pki/leaf-signing.key \
          --intermediate=/pki/chain.pem "${extra[@]}" /bundle "/out/$1"
        rauc info -C keyring:check-purpose=codesign \
          --keyring=/pki/root-ca.pem "/out/$1"
      ' _ "$(basename "${out}")"
  else
    require_cmd rauc
    local -a sign_cmd=(rauc bundle --cert="${RAUC_LEAF_CERT}" \
      --key="${RAUC_LEAF_KEY}" --intermediate="${RAUC_CHAIN}" \
      "${mksquashfs_opt[@]}" "${content}" "${out}")
    assert_no_root_signing "${sign_cmd[@]}"
    "${sign_cmd[@]}"
    rauc info "${RAUC_VERIFY_OPTS[@]}" --keyring="${RAUC_ROOT_CA}" "${out}"
  fi
}

# bundle_read_device_keyring <rootfs.ext4> <out-file> — copy the keyring the
# device will trust out of the slot image (no mount, no root).
bundle_read_device_keyring() {
  local img="$1" dest="$2"
  require_cmd debugfs
  debugfs -R "cat ${RAUC_DEVICE_KEYRING_PATH}" "${img}" >"${dest}" 2>/dev/null \
    || die "cannot read ${RAUC_DEVICE_KEYRING_PATH} from ${img}"
  [[ -s "${dest}" ]] || die "the slot image has no ${RAUC_DEVICE_KEYRING_PATH}"
}

# bundle_identity <board> — compatible/version/build/ts/out_dir for both paths.
# Sets the caller's locals of the same names (dynamic scope). build is the full
# pipeline commit, empty outside a git checkout.
bundle_identity() {
  local board="$1"
  compatible="${COMPATIBLE_STRING:-}"
  [[ -n "${compatible}" ]] || die "COMPATIBLE_STRING is unset/empty — refusing a bundle the device would reject"
  version="${BUNDLE_VERSION:-}"
  if [[ -z "${version}" ]]; then
    version="$(GIT_MASTER=1 git -C "${PIPELINE_DIR}" rev-parse --short HEAD 2>/dev/null)" || version=""
  fi
  build="$(GIT_MASTER=1 git -C "${PIPELINE_DIR}" rev-parse HEAD 2>/dev/null)" || build=""
  ts="${BUNDLE_TS:-$(date -u +%Y%m%dT%H%M%SZ)}"
  [[ -n "${version}" ]] || version="${ts}"
  out_dir="${BUNDLE_OUT_DIR:-${IMAGES_DIR}/${board}/bundles}"
  mkdir -p "${out_dir}"
}

# bundle_fill_content <rootfs-tree> <content-dir> <compatible> <version> <build> —
# the bundle payload, identical for inline and deferred signing.
bundle_fill_content() {
  local rootfs_tree="$1" content="$2" compatible="$3" version="$4" build="$5"
  BOARD_ID="${BOARD_ID}" SLOT_IMAGE_LABEL=rootfs make_slot_image "${rootfs_tree}" "${content}/rootfs.ext4" \
    || die "failed to make ext4 rootfs slot image"
  write_manifest "${content}/manifest.raucm" "${compatible}" "${version}" "${build}"
  if [[ "${BOARD_ID:-}" == rock-5b-plus ]]; then
    install -m 0755 "${PIPELINE_DIR}/mkosi/runtime/ceralive-layout-install-check.sh" "${content}/layout-check"
  fi
}

build-bundle() {
  [[ $# -eq 2 ]] || { usage; die "expected exactly 2 args, got $#"; }
  local board="$1" rootfs_tree="$2" compatible version build ts out_dir out content
  [[ -n "${board}" && -d "${rootfs_tree}" ]] \
    || die "board and a rootfs directory are required (tar/plain input is not an ext4 slot image)"
  # shellcheck disable=SC2034 # Shared layout helpers read the CLI board dynamically.
  local BOARD_ID="$board"
  ceralive_rootfs_mb >/dev/null || return $?
  assert_pki
  bundle_identity "${board}"
  content="$(mktemp -d "${out_dir}/.bundle-content.XXXXXX")"
  trap 'rm -rf "${content}"' RETURN
  out="${out_dir}/${ts}.raucb"
  bundle_fill_content "${rootfs_tree}" "${content}" "${compatible}" "${version}" "${build}"
  bundle_with_rauc "${content}" "${out}"
  ( cd "${out_dir}" && sha256sum "$(basename "${out}")" >"$(basename "${out}").sha256" )
  log_success "verity adaptive bundle: ${out}"
  printf '%s\n' "${out}"
}

# bundle-prepare <board> <rootfs-tree> — deferred signing. Writes the exact
# content `rauc bundle` will later sign, unsigned, as <ts>.raucb-content/, plus
# <ts>.raucb-content.json (schema, pipeline commit, compatible, version, the
# root the slot image trusts, and size/mode/sha256 of every file) and
# <ts>.raucb-content.json.sha256. That digest is what lib/sign-bundle.sh must be
# given (--expect) before it signs anything. No signing key is read here.
bundle-prepare() {
  [[ $# -eq 2 ]] || { usage; die "prepare: expected <board> <rootfs-tree>"; }
  local board="$1" rootfs_tree="$2" compatible version build ts out_dir content stage desc
  local keyring_tmp keyring_sha commit digest
  [[ -n "${board}" && -d "${rootfs_tree}" ]] \
    || die "board and a rootfs directory are required (tar/plain input is not an ext4 slot image)"
  # shellcheck disable=SC2034 # Shared layout helpers read the CLI board dynamically.
  local BOARD_ID="$board"
  ceralive_rootfs_mb >/dev/null || return $?
  require_cmd python3
  bundle_identity "${board}"
  content="${out_dir}/${ts}.raucb-content"
  desc="${content}.json"
  local existing
  for existing in "${content}" "${desc}" "${desc}.sha256" "${out_dir}/${ts}.raucb"; do
    [[ ! -e "${existing}" && ! -L "${existing}" ]] || die "refusing to overwrite ${existing}"
  done
  stage="$(mktemp -d "${out_dir}/.bundle-content.XXXXXX")"
  keyring_tmp="$(mktemp)"
  # EXIT, not RETURN: die() exits, and a half-written stage must not stay behind.
  # shellcheck disable=SC2064 # Bind these paths now.
  trap "rm -rf '${stage}' '${keyring_tmp}' '${desc}.tmp'" EXIT
  chmod 0755 "${stage}"
  bundle_fill_content "${rootfs_tree}" "${stage}" "${compatible}" "${version}" "${build}"
  # Fixed modes, so the record does not depend on the caller's umask.
  chmod 0644 "${stage}/manifest.raucm" "${stage}/rootfs.ext4"
  [[ ! -e "${stage}/layout-check" ]] || chmod 0755 "${stage}/layout-check"

  # The root this slot image will trust, read back from the image itself.
  bundle_read_device_keyring "${stage}/rootfs.ext4" "${keyring_tmp}"
  rauc_keyring_check_single_root "${keyring_tmp}" \
    || die "the slot image's RAUC keyring is not exactly one root certificate"
  keyring_sha="$(rauc_cert_sha256 "${keyring_tmp}")"
  if [[ -n "${RAUC_ROOT_SHA256:-}" && "${RAUC_ROOT_SHA256}" != "${keyring_sha}" ]]; then
    die "the slot image trusts root ${keyring_sha}, not the build's keyring ${RAUC_ROOT_SHA256}"
  fi

  # The commit the signing step must run from (a fresh clone, never this tree).
  commit="$(GIT_MASTER=1 git -C "${PIPELINE_DIR}" rev-parse HEAD 2>/dev/null)" \
    || die "deferred signing needs a git checkout: the signing step runs from the same commit"
  # A release build must be exactly that commit: a tracked change (made before or
  # during the build) would not be in the clone that signs.
  if [[ "${CERALIVE_BUILD_MODE:-development}" == production || "${CERALIVE_FORK_RELEASE:-}" == 1 ]]; then
    [[ -z "$(GIT_MASTER=1 git -C "${PIPELINE_DIR}" status --porcelain --untracked-files=no 2>&1)" ]] \
      || die "release build from a pipeline tree with tracked changes: refusing to prepare content for ${commit}"
  fi

  python3 -I - "${stage}" "${desc}.tmp" "${UNSIGNED_BUNDLE_SCHEMA}" "${board}" \
    "${compatible}" "${version}" "${ts}" "${keyring_sha}" "${commit}" \
    "${SOURCE_DATE_EPOCH}" <<'PY' \
    || die "could not write the unsigned bundle descriptor"
import hashlib, json, os, stat, sys
stage, out, schema, board, compatible, version, ts, keyring, commit, epoch = sys.argv[1:]
files = []
for name in sorted(os.listdir(stage)):
    path = os.path.join(stage, name)
    st = os.lstat(path)
    if not stat.S_ISREG(st.st_mode):
        sys.exit(f"unexpected non-regular entry in bundle content: {name}")
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    files.append({"name": name, "mode": "%04o" % stat.S_IMODE(st.st_mode),
                  "size": st.st_size, "sha256": h.hexdigest()})
doc = {"schema": schema, "board": board, "compatible": compatible, "version": version,
       "bundle": f"{ts}.raucb", "device_keyring_sha256": keyring,
       "pipeline_commit": commit, "source_date_epoch": int(epoch), "files": files}
with open(out, "x") as f:
    json.dump(doc, f, indent=1, sort_keys=True)
    f.write("\n")
PY
  mv -T "${stage}" "${content}" || die "could not publish ${content}"
  mv -T "${desc}.tmp" "${desc}" || die "could not publish ${desc}"
  ( cd "${out_dir}" && sha256sum "$(basename "${desc}")" >"$(basename "${desc}").sha256" )
  trap - EXIT
  rm -f "${keyring_tmp}"
  digest="$(cut -d' ' -f1 <"${desc}.sha256")"
  log_success "unsigned bundle content: ${content} (descriptor sha256 ${digest}, device root ${keyring_sha})"
  log_info "sign it from a fresh clone at ${commit}: lib/sign-bundle.sh check, sign, finish (--expect ${digest})"
  printf '%s\n' "${desc}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    -h | --help | "") usage; exit 0 ;;
    prepare) shift; bundle-prepare "$@" ;;
    *)
      # The orchestrator's [8/9] call is the same in both modes; deferred
      # signing turns it into `prepare` (unsigned content, no key needed).
      if [[ "${CERALIVE_RAUC_SIGNING:-inline}" == deferred ]]; then
        bundle-prepare "$@"
      else
        build-bundle "$@"
      fi
      ;;
  esac
fi

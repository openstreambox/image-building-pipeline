#!/usr/bin/env bash
# Sign RAUC bundle content that an image build prepared unsigned
# (CERALIVE_RAUC_SIGNING=deferred, `build-bundle.sh prepare`).
#
#   lib/sign-bundle.sh sign --content <dir>/<ts>.raucb-content --expect <sha256>
#                           [--expect-root-sha256 <sha256>] [--out <file>.raucb]
#
# The image build then never needs the signing key: it bakes only the public
# root into the image and writes the bundle content plus a descriptor
# (<ts>.raucb-content.json). This step is the only one that reads the key, and
# it is short: it checks, signs once and verifies.
#
# Fail closed, in this order, before anything is signed:
#   1. --expect must equal the sha256 of the descriptor (the digest the build
#      printed and wrote to <ts>.raucb-content.json.sha256). Take it from the
#      build's record, not from next to the content.
#   2. The content is copied into a private staging directory, and the copy must
#      hold exactly the descriptor's files, as regular files with the recorded
#      size, mode and sha256. Signing reads only that copy.
#   3. manifest.raucm must be exactly what this pipeline writes for the
#      descriptor's board, compatible and version (verity, adaptive), and the
#      install hook must be this checkout's own.
#   4. The keyring inside the staged rootfs.ext4 must be exactly one canonical
#      root certificate, equal to the descriptor's root, to the signer's root and,
#      when given, to --expect-root-sha256.
# After signing: `rauc info` must verify the bundle under the signer root with the
# codesign purpose, and its compatible, version, format and rootfs sha256/size
# must match the descriptor. Any failure removes the bundle.
#
# Containerized builds name an offline signer image in the descriptor (prepared
# without any key at the end of the build): the signer runs from it with no
# network and no capabilities. Without one, the host's rauc signs.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/build-bundle.sh
source "${HERE}/build-bundle.sh"

sign_usage() {
  printf 'Usage: sign-bundle.sh sign --content DIR --expect SHA256 [--expect-root-sha256 SHA256] [--out FILE]\n' >&2
}

is_sha256() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }

# Cleanup state for the EXIT trap: a run that did not finish leaves no bundle.
SIGN_WORK="" SIGN_INFO="" SIGN_OUT="" SIGN_DONE=0
sign_cleanup() {
  [[ -z "${SIGN_WORK}" ]] || rm -rf "${SIGN_WORK}"
  [[ -z "${SIGN_INFO}" ]] || rm -f "${SIGN_INFO}"
  if [[ "${SIGN_DONE}" != 1 && -n "${SIGN_OUT}" ]]; then
    rm -f "${SIGN_OUT}" "${SIGN_OUT}.sha256"
  fi
}

sign-bundle() {
  local content="" expect="" expect_root="" out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --content) content="${2:-}"; shift 2 ;;
      --expect) expect="${2:-}"; shift 2 ;;
      --expect-root-sha256) expect_root="${2:-}"; shift 2 ;;
      --out) out="${2:-}"; shift 2 ;;
      *) sign_usage; die "unknown argument: $1" ;;
    esac
  done
  [[ -n "${content}" ]] || { sign_usage; die "--content is required"; }
  is_sha256 "${expect}" || die "--expect must be 64 lowercase hex (the descriptor sha256 from the build)"
  [[ -z "${expect_root}" ]] || is_sha256 "${expect_root}" \
    || die "--expect-root-sha256 must be 64 lowercase hex"
  content="${content%/}"
  [[ -d "${content}" && ! -L "${content}" ]] || die "bundle content is not a directory: ${content}"
  local desc="${content}.json"
  [[ -f "${desc}" && ! -L "${desc}" ]] || die "descriptor missing: ${desc}"
  require_cmd python3

  # 1. The descriptor is the one the build recorded.
  local actual
  actual="$(sha256sum <"${desc}" | cut -c1-64)"
  [[ "${actual}" == "${expect}" ]] \
    || die "descriptor ${desc} has sha256 ${actual}, not --expect ${expect}: refusing to sign"

  # The signing PKI (with-signing-keys.sh exports it in production mode).
  rauc_pki_resolve "${CERALIVE_BUILD_MODE:-development}" "${CERALIVE_RAUC_PKI_DIR:-}" "${RAUC_KEYRING_FILE:-}" \
    || die "RAUC signing PKI did not resolve"
  bundle_pki_paths
  assert_pki

  local fields
  fields="$(python3 -I - "${desc}" "${UNSIGNED_BUNDLE_SCHEMA}" <<'PY'
import json, re, sys
path, schema = sys.argv[1:]
with open(path, "rb") as f:
    doc = json.loads(f.read().decode("utf-8"))
def fail(msg):
    sys.exit(f"bad unsigned bundle descriptor: {msg}")
keys = {"schema", "board", "compatible", "version", "bundle", "device_keyring_sha256", "signer_image",
        "source_date_epoch", "files"}
if not isinstance(doc, dict) or set(doc) != keys:
    fail("unexpected keys")
if doc["schema"] != schema:
    fail(f"schema {doc['schema']!r}")
word = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,127}\Z")
for k in ("board", "compatible", "version"):
    if not isinstance(doc[k], str) or not word.match(doc[k]):
        fail(f"{k} is not a plain token")
if not isinstance(doc["bundle"], str) or not re.match(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.raucb\Z", doc["bundle"]):
    fail("bundle name")
hexre = re.compile(r"[0-9a-f]{64}\Z")
if not isinstance(doc["device_keyring_sha256"], str) or not hexre.match(doc["device_keyring_sha256"]):
    fail("device_keyring_sha256")
signer = doc["signer_image"]
if signer is not None:
    if (not isinstance(signer, dict) or set(signer) != {"tag", "id"}
            or not isinstance(signer["id"], str) or not re.match(r"sha256:[0-9a-f]{64}\Z", signer["id"])):
        fail("signer_image")
epoch = doc["source_date_epoch"]
if not isinstance(epoch, int) or isinstance(epoch, bool) or not 0 <= epoch < 2**63:
    fail("source_date_epoch")
allowed = {"manifest.raucm": "0644", "rootfs.ext4": "0644", "layout-check": "0755"}
files = doc["files"]
if not isinstance(files, list):
    fail("files")
names = [e.get("name") if isinstance(e, dict) else None for e in files]
if len(set(names)) != len(names) or not {"manifest.raucm", "rootfs.ext4"} <= set(names):
    fail("files must list manifest.raucm and rootfs.ext4 once each")
for e in files:
    if (set(e) != {"name", "mode", "size", "sha256"} or e["name"] not in allowed
            or e["mode"] != allowed[e["name"]] or not isinstance(e["size"], int)
            or isinstance(e["size"], bool) or e["size"] < 0
            or not isinstance(e["sha256"], str) or not hexre.match(e["sha256"])):
        fail(f"file entry {e.get('name')!r}")
print(doc["board"], doc["compatible"], doc["version"], doc["bundle"],
      doc["device_keyring_sha256"], signer["id"] if signer else "-", epoch)
PY
)" || die "refusing to sign: the descriptor does not validate"
  local board compatible version bundle_name desc_root signer_id epoch
  read -r board compatible version bundle_name desc_root signer_id epoch <<<"${fields}"
  # The squashfs timestamps follow the build, not this checkout's HEAD.
  SOURCE_DATE_EPOCH="${epoch}"
  export SOURCE_DATE_EPOCH

  local out_dir
  [[ -n "${out}" ]] || out="$(dirname "${content}")/${bundle_name}"
  out_dir="$(cd "$(dirname "${out}")" && pwd -P)" || die "output directory missing: $(dirname "${out}")"
  out="${out_dir}/$(basename "${out}")"
  local existing
  for existing in "${out}" "${out}.sha256"; do
    [[ ! -e "${existing}" && ! -L "${existing}" ]] || die "refusing to overwrite ${existing}"
  done

  local work stage info
  work="$(mktemp -d "${out_dir}/.sign-stage.XXXXXX")"
  stage="${work}/content"
  info="${out_dir}/.$(basename "${out}").info.json"
  SIGN_WORK="${work}" SIGN_INFO="${info}" SIGN_OUT="${out}" SIGN_DONE=0
  trap sign_cleanup EXIT
  mkdir -m 0700 "${stage}"

  # 2. Private copy, then verify the copy (never the shared original).
  local name
  while IFS= read -r -d '' name; do
    name="${name##*/}"
    [[ -f "${content}/${name}" && ! -L "${content}/${name}" ]] \
      || die "bundle content entry is not a regular file: ${name}"
    cp --reflink=auto --sparse=always --no-preserve=all "${content}/${name}" "${stage}/${name}" \
      || die "cannot copy ${name} into the signing stage"
  done < <(find "${content}" -mindepth 1 -maxdepth 1 -print0)
  python3 -I - "${desc}" "${stage}" <<'PY' || die "refusing to sign: the content is not what the build recorded"
import hashlib, json, os, sys
desc, stage = sys.argv[1:]
with open(desc, "rb") as f:
    files = {e["name"]: e for e in json.load(f)["files"]}
present = sorted(os.listdir(stage))
if present != sorted(files):
    sys.exit(f"content holds {present}, descriptor lists {sorted(files)}")
for name, e in files.items():
    path = os.path.join(stage, name)
    h = hashlib.sha256()
    size = 0
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
            size += len(chunk)
    if size != e["size"] or h.hexdigest() != e["sha256"]:
        sys.exit(f"{name}: sha256 {h.hexdigest()} size {size}, recorded {e['sha256']} size {e['size']}")
    os.chmod(path, int(e["mode"], 8))
PY

  # 3. The manifest and hook are the ones this pipeline writes.
  local expected_manifest="${work}/manifest.expected"
  BOARD_ID="${board}" write_manifest "${expected_manifest}" "${compatible}" "${version}"
  cmp -s "${expected_manifest}" "${stage}/manifest.raucm" \
    || die "manifest.raucm is not the verity manifest this pipeline writes for ${board} ${compatible} ${version}"
  if [[ "${board}" == rock-5b-plus || -e "${stage}/layout-check" ]]; then
    [[ "${board}" == rock-5b-plus ]] || die "unexpected install hook for board ${board}"
    cmp -s "${PIPELINE_DIR}/mkosi/runtime/ceralive-layout-install-check.sh" "${stage}/layout-check" \
      || die "layout-check differs from this checkout's install hook: sign from the pipeline commit that built it"
  fi

  # 4. The image trusts exactly the root we sign under.
  local keyring_copy image_root
  keyring_copy="${work}/device-keyring.pem"
  bundle_read_device_keyring "${stage}/rootfs.ext4" "${keyring_copy}"
  rauc_keyring_check_single_root "${keyring_copy}" \
    || die "the image's RAUC keyring is not exactly one root certificate"
  image_root="$(rauc_cert_sha256 "${keyring_copy}")"
  [[ "${image_root}" == "${desc_root}" ]] \
    || die "the image trusts root ${image_root}, the descriptor says ${desc_root}"
  [[ "${image_root}" == "${RAUC_ROOT_SHA256}" ]] \
    || die "the image trusts root ${image_root}, but the signer chains to ${RAUC_ROOT_SHA256}"
  [[ -z "${expect_root}" || "${image_root}" == "${expect_root}" ]] \
    || die "the image trusts root ${image_root}, not the expected ${expect_root}"

  # Sign once, from the verified stage.
  local signer_image=""
  if [[ "${signer_id}" != - ]]; then
    local runtime
    runtime="$(bundle_container_runtime)"
    "${runtime}" image inspect "${signer_id}" >/dev/null 2>&1 \
      || die "offline signer image ${signer_id} is not present; prepare it with the same build"
    signer_image="${signer_id}"
  fi
  log_info "signing ${bundle_name} (compatible=${compatible}, version=${version}, root=${image_root})"
  # Either the offline signer image or the host's rauc; never the online builder.
  # umask 022 as in the build: RAUC writes the block-hash index with it, and the
  # key-handling scope around this step runs with 077.
  ( umask 022
    RAUC_SIGNER_IMAGE="${signer_image}" RAUC_INFO_JSON="${info}" MKOSI_BUILDER_IMAGE="" \
      bundle_with_rauc "${stage}" "${out}" ) || die "RAUC signing failed"

  # After signing: the bundle verifies and carries exactly the recorded image.
  python3 -I - "${desc}" "${info}" <<'PY' || die "the signed bundle does not match the descriptor"
import json, sys
desc_path, info_path = sys.argv[1:]
with open(desc_path) as f:
    desc = json.load(f)
with open(info_path) as f:
    info = json.load(f)
rootfs = next(e for e in desc["files"] if e["name"] == "rootfs.ext4")
def need(cond, msg):
    if not cond:
        sys.exit(msg)
update = info.get("update") or {}
need(update.get("compatible") == desc["compatible"], f"compatible {update.get('compatible')!r}")
need(update.get("version") == desc["version"], f"version {update.get('version')!r}")
need((info.get("bundle") or {}).get("format") == "verity", f"format {info.get('bundle')!r}")
images = info.get("images") or []
need(len(images) == 1, f"{len(images)} images in the bundle")
img = images[0]
need(img.get("filename") == "rootfs.ext4" and img.get("slot-class") == "rootfs",
     f"image {img.get('filename')!r} for {img.get('slot-class')!r}")
need(img.get("checksum") == rootfs["sha256"] and img.get("size") == rootfs["size"],
     f"rootfs checksum {img.get('checksum')} size {img.get('size')}")
need(img.get("adaptive") == ["block-hash-index"], f"adaptive {img.get('adaptive')!r}")
PY
  ( cd "${out_dir}" && sha256sum "$(basename "${out}")" >"$(basename "${out}").sha256" )
  SIGN_DONE=1
  log_success "signed verity bundle: ${out} (rootfs sha256 matches the build's record)"
  printf '%s\n' "${out}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    sign) shift; sign-bundle "$@" ;;
    -h | --help | "") sign_usage; exit 0 ;;
    *) sign_usage; exit 2 ;;
  esac
fi

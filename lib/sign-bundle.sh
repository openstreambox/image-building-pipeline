#!/usr/bin/env bash
# Sign RAUC bundle content that an image build prepared unsigned
# (CERALIVE_RAUC_SIGNING=deferred, `build-bundle.sh prepare`), in three phases.
# Only `sign` needs the signing key:
#
#   S="$(lib/sign-bundle.sh check --content <dir>/<ts>.raucb-content --expect <sha256> \
#          [--expect-root-sha256 <sha256>] [--stage-parent <dir>])"
#   lib/sign-bundle.sh sign --stage "$S" --expect <sha256> [--expect-root-sha256 <sha256>]
#   lib/sign-bundle.sh finish --stage "$S" --expect <sha256> [--expect-root-sha256 <sha256>] \
#          --out <dir>/<ts>.raucb
#
# Run this from a fresh clone of the pipeline at the commit the build recorded,
# never from the build's own tree: the privileged build container can write that
# tree, and these scripts run while the key is unlocked. `check` refuses a
# checkout whose HEAD is not the descriptor's pipeline_commit.
#
# check (no key): the descriptor must hash to --expect (the digest the build
#   printed; take it from the build record, not from next to the content). It is
#   read once and copied into a private 0700 stage, and every later phase uses
#   only that copy. The content is copied into the stage without following
#   symlinks, and the copy must be exactly the descriptor's regular files with
#   the recorded size, mode and sha256. manifest.raucm and the install hook must
#   be exactly what this checkout writes, and the keyring inside rootfs.ext4 must
#   be one canonical root equal to the descriptor's (and --expect-root-sha256).
# sign (key): re-hashes the stage, requires the signer root to be the
#   descriptor's root, and signs with the host's rauc into the stage's empty out/
#   directory, under the build's SOURCE_DATE_EPOCH and umask 022. Caller
#   RAUC_BUNDLE_MKSQUASHFS_ARGS is ignored. No container: the key stays in the
#   caller's scope.
# finish (no key): verifies the bundle on the host. `rauc info` must pass under
#   the root read from the image, with the device's default purpose and with
#   codesign; its manifest must match the descriptor; the squashfs must list
#   exactly the expected files; rootfs.ext4 and the hook read back from the
#   squashfs must hash to the descriptor. Only then is the bundle copied to
#   --out. Any failure in sign or finish removes the bundle.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/build-bundle.sh
source "${HERE}/build-bundle.sh"
# The signing step never takes extra mksquashfs arguments from its environment:
# a pseudo-file definition (-pf) could add anything to the signed payload.
unset RAUC_BUNDLE_MKSQUASHFS_ARGS

SIGN_RAUC_MIN=1.15
# The sign phase resolves rauc, mksquashfs and openssl only from root-owned
# system directories, never from a PATH entry the caller's user could write.
SIGN_SYSTEM_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

sign_usage() {
  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

is_sha256() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }

# Cleanup state for the EXIT trap.
SIGN_RM_DIR="" SIGN_RM_FILES=()
sign_cleanup() {
  [[ -z "${SIGN_RM_DIR}" ]] || rm -rf "${SIGN_RM_DIR}"
  ((${#SIGN_RM_FILES[@]} == 0)) || rm -f "${SIGN_RM_FILES[@]}"
}
trap sign_cleanup EXIT

# One Python helper for everything that reads the descriptor: it reads the file
# once, hashes those bytes, validates them, and (verify mode) checks the stage
# content against them.
#   ingest <shared descriptor> <expect> <private copy>
#   verify <private copy> <expect> <content dir|-> <schema>   -> prints the fields
sign_py() {
  python3 -I - "$@" <<'PY'
import hashlib, json, os, re, stat, sys

def fail(msg):
    sys.exit(f"sign-bundle: {msg}")

def read_nofollow(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            fail(f"{path} is not a regular file")
        chunks = []
        while True:
            b = os.read(fd, 1 << 16)
            if not b:
                break
            chunks.append(b)
        return b"".join(chunks)
    finally:
        os.close(fd)

mode = sys.argv[1]
if mode == "ingest":
    src, expect, dst = sys.argv[2:]
    data = read_nofollow(src)
    got = hashlib.sha256(data).hexdigest()
    if got != expect:
        fail(f"descriptor has sha256 {got}, not --expect {expect}: refusing")
    fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    sys.exit(0)

if mode != "verify":
    fail(f"unknown helper mode {mode}")
path, expect, content, schema = sys.argv[2:]
data = read_nofollow(path)
got = hashlib.sha256(data).hexdigest()
if got != expect:
    fail(f"staged descriptor has sha256 {got}, not --expect {expect}: refusing")
doc = json.loads(data.decode("utf-8"))
keys = {"schema", "board", "compatible", "version", "bundle", "device_keyring_sha256",
        "pipeline_commit", "source_date_epoch", "files"}
if not isinstance(doc, dict) or set(doc) != keys:
    fail("bad descriptor: unexpected keys")
if doc["schema"] != schema:
    fail(f"bad descriptor: schema {doc['schema']!r}")
word = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,127}\Z")
for k in ("board", "compatible", "version"):
    if not isinstance(doc[k], str) or not word.match(doc[k]):
        fail(f"bad descriptor: {k} is not a plain token")
if not isinstance(doc["bundle"], str) or not re.match(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.raucb\Z", doc["bundle"]):
    fail("bad descriptor: bundle name")
if not isinstance(doc["device_keyring_sha256"], str) or not re.match(r"[0-9a-f]{64}\Z", doc["device_keyring_sha256"]):
    fail("bad descriptor: device_keyring_sha256")
if not isinstance(doc["pipeline_commit"], str) or not re.match(r"[0-9a-f]{40}\Z", doc["pipeline_commit"]):
    fail("bad descriptor: pipeline_commit")
epoch = doc["source_date_epoch"]
if not isinstance(epoch, int) or isinstance(epoch, bool) or not 0 <= epoch < 2**63:
    fail("bad descriptor: source_date_epoch")
allowed = {"manifest.raucm": "0644", "rootfs.ext4": "0644", "layout-check": "0755"}
files = doc["files"]
if not isinstance(files, list):
    fail("bad descriptor: files")
names = [e.get("name") if isinstance(e, dict) else None for e in files]
if len(set(names)) != len(names) or not {"manifest.raucm", "rootfs.ext4"} <= set(names):
    fail("bad descriptor: files must list manifest.raucm and rootfs.ext4 once each")
for e in files:
    if (set(e) != {"name", "mode", "size", "sha256"} or e["name"] not in allowed
            or e["mode"] != allowed[e["name"]] or not isinstance(e["size"], int)
            or isinstance(e["size"], bool) or e["size"] < 0
            or not isinstance(e["sha256"], str) or not re.match(r"[0-9a-f]{64}\Z", e["sha256"])):
        fail(f"bad descriptor: file entry {e.get('name')!r}")

if content != "-":
    present = sorted(os.listdir(content))
    if present != sorted(names):
        fail(f"content holds {present}, the descriptor lists {sorted(names)}")
    for e in files:
        p = os.path.join(content, e["name"])
        fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                fail(f"{e['name']} is not a regular file")
            h, size = hashlib.sha256(), 0
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
                size += len(chunk)
        if size != e["size"] or h.hexdigest() != e["sha256"]:
            fail(f"{e['name']}: sha256 {h.hexdigest()} size {size}, recorded {e['sha256']} size {e['size']}")
        os.chmod(p, int(e["mode"], 8), follow_symlinks=False)

rootfs = next(e for e in files if e["name"] == "rootfs.ext4")
hook = next((e for e in files if e["name"] == "layout-check"), None)
print(doc["board"], doc["compatible"], doc["version"], doc["bundle"],
      doc["device_keyring_sha256"], doc["pipeline_commit"], epoch,
      rootfs["sha256"], rootfs["size"],
      hook["sha256"] if hook else "-", hook["size"] if hook else "-")
PY
}

# sign_fields <stage> <expect> <content|-> — verify the staged descriptor (and
# content) and load its fields into D_* globals.
sign_fields() {
  local fields
  fields="$(sign_py verify "$1/descriptor.json" "$2" "$3" "${UNSIGNED_BUNDLE_SCHEMA}")" \
    || die "refusing: the stage does not match the descriptor the build recorded"
  read -r D_BOARD D_COMPAT D_VERSION D_BUNDLE D_ROOT D_COMMIT D_EPOCH \
    D_ROOTFS_SHA D_ROOTFS_SIZE D_HOOK_SHA D_HOOK_SIZE <<<"${fields}"
}

# sign_stage_ok <stage> — a private stage made by `check`, owned by this user.
sign_stage_ok() {
  local s="$1"
  [[ -d "${s}" && ! -L "${s}" && -O "${s}" && "$(stat -c %a "${s}")" == 700 ]] \
    || die "not a private signing stage: ${s}"
  [[ -d "${s}/content" && ! -L "${s}/content" && -d "${s}/out" && ! -L "${s}/out" ]] \
    || die "incomplete signing stage: ${s}"
}

# sign_image_root <stage> <expect-root|""> — the image's keyring must be one root,
# equal to the descriptor's and the expected one. Writes it to <stage>/device-keyring.pem.
sign_image_root() {
  local s="$1" want="$2" root
  rm -f "${s}/device-keyring.pem"
  bundle_read_device_keyring "${s}/content/rootfs.ext4" "${s}/device-keyring.pem"
  rauc_keyring_check_single_root "${s}/device-keyring.pem" \
    || die "the image's RAUC keyring is not exactly one root certificate"
  root="$(rauc_cert_sha256 "${s}/device-keyring.pem")"
  [[ "${root}" == "${D_ROOT}" ]] || die "the image trusts root ${root}, the descriptor says ${D_ROOT}"
  [[ -z "${want}" || "${root}" == "${want}" ]] || die "the image trusts root ${root}, not the expected ${want}"
}

sign_parse_args() {
  A_CONTENT="" A_EXPECT="" A_ROOT="" A_STAGE="" A_OUT="" A_PARENT=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --content) A_CONTENT="${2:-}"; shift 2 ;;
      --expect) A_EXPECT="${2:-}"; shift 2 ;;
      --expect-root-sha256) A_ROOT="${2:-}"; shift 2 ;;
      --stage) A_STAGE="${2:-}"; shift 2 ;;
      --stage-parent) A_PARENT="${2:-}"; shift 2 ;;
      --out) A_OUT="${2:-}"; shift 2 ;;
      *) sign_usage; die "unknown argument: $1" ;;
    esac
  done
  is_sha256 "${A_EXPECT}" || die "--expect must be 64 lowercase hex (the descriptor sha256 from the build record)"
  [[ -z "${A_ROOT}" ]] || is_sha256 "${A_ROOT}" || die "--expect-root-sha256 must be 64 lowercase hex"
  require_cmd python3
}

sign-check() {
  sign_parse_args "$@"
  local content="${A_CONTENT%/}" parent="${A_PARENT:-${TMPDIR:-/var/tmp}}" stage name head
  [[ -n "${content}" && -d "${content}" && ! -L "${content}" ]] || die "--content must be the build's <ts>.raucb-content directory"
  umask 077
  stage="$(mktemp -d "${parent}/sign-stage.XXXXXX")" || die "cannot create a stage in ${parent}"
  SIGN_RM_DIR="${stage}"
  mkdir "${stage}/content" "${stage}/out"
  sign_py ingest "${content}.json" "${A_EXPECT}" "${stage}/descriptor.json" \
    || die "refusing: ${content}.json is not the descriptor the build recorded"
  while IFS= read -r -d '' name; do
    # -P: copy a symlink as a symlink (the verify below refuses it), never its target.
    cp -P --sparse=always --no-preserve=all "${name}" "${stage}/content/" \
      || die "cannot copy ${name##*/} into the stage"
  done < <(find "${content}" -mindepth 1 -maxdepth 1 -print0)
  sign_fields "${stage}" "${A_EXPECT}" "${stage}/content"

  head="$(GIT_MASTER=1 git -C "${PIPELINE_DIR}" rev-parse HEAD 2>/dev/null)" || head=""
  [[ "${head}" == "${D_COMMIT}" ]] \
    || die "this checkout is at ${head:-no commit}, the build ran ${D_COMMIT}: sign from a fresh clone at that commit"
  BOARD_ID="${D_BOARD}" write_manifest "${stage}/manifest.expected" "${D_COMPAT}" "${D_VERSION}"
  cmp -s "${stage}/manifest.expected" "${stage}/content/manifest.raucm" \
    || die "manifest.raucm is not the verity manifest this pipeline writes for ${D_BOARD} ${D_COMPAT} ${D_VERSION}"
  rm -f "${stage}/manifest.expected"
  if [[ "${D_BOARD}" == rock-5b-plus || -e "${stage}/content/layout-check" ]]; then
    [[ "${D_BOARD}" == rock-5b-plus ]] || die "unexpected install hook for board ${D_BOARD}"
    cmp -s "${PIPELINE_DIR}/mkosi/runtime/ceralive-layout-install-check.sh" "${stage}/content/layout-check" \
      || die "layout-check differs from this checkout's install hook"
  fi
  sign_image_root "${stage}" "${A_ROOT}"
  SIGN_RM_DIR=""
  log_success "checked ${D_BUNDLE} content into ${stage} (root ${D_ROOT}, commit ${D_COMMIT})"
  printf '%s\n' "${stage}"
}

sign_require_host_rauc() {
  require_cmd rauc
  require_cmd mksquashfs
  local v
  v="$(rauc --version 2>/dev/null | awk '{print $2; exit}')"
  [[ "${v}" =~ ^([0-9]+)\.([0-9]+) ]] || die "cannot read the rauc version"
  (( BASH_REMATCH[1] > 1 || (BASH_REMATCH[1] == 1 && BASH_REMATCH[2] >= ${SIGN_RAUC_MIN#1.}) )) \
    || die "host rauc ${v} is older than ${SIGN_RAUC_MIN}"
}

sign-sign() {
  export PATH="${SIGN_SYSTEM_PATH}"
  hash -r
  sign_parse_args "$@"
  local stage="${A_STAGE%/}" out
  sign_stage_ok "${stage}"
  sign_require_host_rauc
  rauc_pki_resolve "${CERALIVE_BUILD_MODE:-development}" "${CERALIVE_RAUC_PKI_DIR:-}" "${RAUC_KEYRING_FILE:-}" \
    || die "RAUC signing PKI did not resolve"
  bundle_pki_paths
  assert_pki
  [[ -z "$(ls -A "${stage}/out")" ]] || die "the stage already holds a bundle: start again from check"
  sign_fields "${stage}" "${A_EXPECT}" "${stage}/content"
  [[ "${D_ROOT}" == "${RAUC_ROOT_SHA256}" ]] \
    || die "the image trusts root ${D_ROOT}, but the signer chains to ${RAUC_ROOT_SHA256}"
  [[ -z "${A_ROOT}" || "${D_ROOT}" == "${A_ROOT}" ]] || die "the image trusts root ${D_ROOT}, not the expected ${A_ROOT}"
  out="${stage}/out/${D_BUNDLE}"
  SIGN_RM_FILES=("${out}")
  local -a sign_cmd=(rauc bundle --cert="${RAUC_LEAF_CERT}" --key="${RAUC_LEAF_KEY}"
    --intermediate="${RAUC_CHAIN}" "${stage}/content" "${out}")
  assert_no_root_signing "${sign_cmd[@]}"
  log_info "signing ${D_BUNDLE} (compatible=${D_COMPAT}, version=${D_VERSION}, root=${D_ROOT})"
  # umask 022 as in the build: RAUC writes the block-hash index with it.
  ( umask 022; SOURCE_DATE_EPOCH="${D_EPOCH}" "${sign_cmd[@]}" ) || die "rauc bundle failed"
  rauc info "${RAUC_VERIFY_OPTS[@]}" --keyring="${RAUC_ROOT_CA}" "${out}" >/dev/null \
    || die "the new bundle does not verify under the signer root"
  # The tools that made the bundle, for the record `finish` writes next to it.
  {
    printf 'rauc=%s (%s)\n' "$(rauc --version 2>&1 | head -n1)" "$(command -v rauc)"
    printf 'mksquashfs=%s (%s)\n' "$(mksquashfs -version 2>&1 | head -n1)" "$(command -v mksquashfs)"
    printf 'signer=%s\n' "$(openssl x509 -in "${RAUC_LEAF_CERT}" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')"
  } >"${stage}/signing-tools.txt"
  SIGN_RM_FILES=()
  log_success "signed ${out}; run finish to verify and place it"
}

sign-finish() {
  sign_parse_args "$@"
  local stage="${A_STAGE%/}" out="${A_OUT}" bundle info listing out_dir sha
  sign_stage_ok "${stage}"
  require_cmd rauc
  require_cmd unsquashfs
  [[ -n "${out}" ]] || die "--out is required"
  sign_fields "${stage}" "${A_EXPECT}" -
  bundle="${stage}/out/${D_BUNDLE}"
  # Whatever happens next, an unverified bundle does not survive a failure.
  SIGN_RM_FILES=("${bundle}")
  [[ "$(ls -A "${stage}/out")" == "${D_BUNDLE}" && -f "${bundle}" && ! -L "${bundle}" ]] \
    || die "the stage's out/ must hold exactly ${D_BUNDLE}"
  out_dir="$(cd "$(dirname "${out}")" && pwd -P)" || die "output directory missing: $(dirname "${out}")"
  out="${out_dir}/$(basename "${out}")"
  [[ ! -e "${out}" && ! -L "${out}" && ! -e "${out}.sha256" && ! -e "${out}.signing" ]] \
    || die "refusing to overwrite ${out}"

  sign_image_root "${stage}" "${A_ROOT}"
  rauc info --keyring="${stage}/device-keyring.pem" "${bundle}" >/dev/null 2>&1 \
    || die "the bundle does not verify under the image's root with the device's default purpose"
  info="$(rauc info "${RAUC_VERIFY_OPTS[@]}" --output-format=json-2 \
    --keyring="${stage}/device-keyring.pem" "${bundle}" 2>/dev/null)" \
    || die "the bundle does not verify under the image's root (codesign)"
  listing="$(unsquashfs -lls -d R "${bundle}" 2>/dev/null)" || die "cannot list the bundle's squashfs"
  python3 -I - "${D_COMPAT}" "${D_VERSION}" "${D_ROOTFS_SHA}" "${D_ROOTFS_SIZE}" "${D_HOOK_SHA}" \
    "${D_HOOK_SIZE}" "${bundle}" "${info}" "${listing}" <<'PY' || die "the signed bundle does not match the descriptor"
import hashlib, json, re, subprocess, sys
compat, version, rootfs_sha, rootfs_size, hook_sha, hook_size, bundle, info, listing = sys.argv[1:]
def need(cond, msg):
    if not cond:
        sys.exit(f"sign-bundle: {msg}")
d = json.loads(info)
update = d.get("update") or {}
need(update.get("compatible") == compat, f"compatible {update.get('compatible')!r}")
need(update.get("version") == version, f"version {update.get('version')!r}")
need((d.get("bundle") or {}).get("format") == "verity", f"format {d.get('bundle')!r}")
images = d.get("images") or []
need(len(images) == 1, f"{len(images)} images in the bundle")
img = images[0]
need(img.get("filename") == "rootfs.ext4" and img.get("slot-class") == "rootfs", f"image {img!r}")
need(img.get("checksum") == rootfs_sha and img.get("size") == int(rootfs_size), "manifest rootfs checksum/size")
need(img.get("adaptive") == ["block-hash-index"], f"adaptive {img.get('adaptive')!r}")
# The squashfs itself: exactly these regular files, nothing else.
want = {"manifest.raucm", "rootfs.ext4", "rootfs.ext4.block-hash-index"}
if hook_sha != "-":
    want.add("layout-check")
seen = set()
for line in listing.splitlines():
    m = re.match(r"(\S{10}) \S+\s+\d+ \S+ \S+ (.*)\Z", line)
    need(m, f"unexpected listing line {line!r}")
    perm, path = m.groups()
    if path == "R":
        need(perm[0] == "d", "squashfs root is not a directory")
        continue
    need(perm[0] == "-" and path.startswith("R/") and "/" not in path[2:], f"unexpected entry {path!r}")
    seen.add(path[2:])
need(seen == want, f"squashfs holds {sorted(seen)}, expected {sorted(want)}")
# Read the payload back out of the squashfs and compare with the build's record.
def cat_sha(name):
    p = subprocess.Popen(["unsquashfs", "-cat", bundle, name], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    h, n = hashlib.sha256(), 0
    for chunk in iter(lambda: p.stdout.read(1 << 20), b""):
        h.update(chunk); n += len(chunk)
    need(p.wait() == 0, f"cannot read {name} from the squashfs")
    return h.hexdigest(), n
sha, n = cat_sha("rootfs.ext4")
need(sha == rootfs_sha and n == int(rootfs_size), f"squashfs rootfs.ext4 sha256 {sha} size {n}")
if hook_sha != "-":
    need(cat_sha("layout-check") == (hook_sha, int(hook_size)), "squashfs layout-check differs from the record")
PY
  sha="$(sha256sum <"${bundle}" | cut -c1-64)"
  [[ ! -e "${out}.partial" && ! -L "${out}.partial" ]] || die "${out}.partial is in the way"
  SIGN_RM_FILES=("${bundle}" "${out}.partial")
  cp --no-preserve=all "${bundle}" "${out}.partial"
  [[ "$(sha256sum <"${out}.partial" | cut -c1-64)" == "${sha}" ]] || die "copy to ${out} changed the bundle"
  chmod 0644 "${out}.partial"
  mv -T "${out}.partial" "${out}"
  printf '%s  %s\n' "${sha}" "$(basename "${out}")" >"${out}.sha256"
  # Signing record: what was signed, from which commit, with which tools.
  {
    printf 'bundle=%s\nbundle_sha256=%s\ndescriptor_sha256=%s\npipeline_commit=%s\nroot_sha256=%s\n' \
      "$(basename "${out}")" "${sha}" "${A_EXPECT}" "${D_COMMIT}" "${D_ROOT}"
    [[ -f "${stage}/signing-tools.txt" && ! -L "${stage}/signing-tools.txt" ]] && cat "${stage}/signing-tools.txt"
  } >"${out}.signing"
  chmod 0644 "${out}.sha256" "${out}.signing"
  SIGN_RM_FILES=()
  SIGN_RM_DIR="${stage}"
  log_success "verified and placed ${out} (sha256 ${sha}); squashfs payload matches the build's record"
  printf '%s\n' "${out}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    check) shift; sign-check "$@" ;;
    sign) shift; sign-sign "$@" ;;
    finish) shift; sign-finish "$@" ;;
    -h | --help | "") sign_usage; exit 0 ;;
    *) sign_usage; exit 2 ;;
  esac
fi

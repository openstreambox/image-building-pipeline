#!/usr/bin/env bash
# Deferred RAUC signing: the image build bakes only the public root and writes
# unsigned bundle content (build-bundle.sh prepare); lib/sign-bundle.sh signs it
# in a separate short step and refuses anything that changed in between.
#
# Throwaway keys only: the ignored .dev-keys CI fixture (root A) and a second
# root generated here (root B). Needs rauc, e2fsprogs (mkfs.ext4, debugfs),
# openssl and python3 on the host, like verity-bundle.test.sh.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "${here}/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "${repo}/tests/lib/assertions.sh"
check() { if "$@"; then ok "$*"; else bad "$*"; fi; }
refuse() { # <label> <command...>: must fail
  local label="$1"; shift
  if "$@" >"${work}/last.log" 2>&1; then bad "accepted: ${label}"
  else ok "refused: ${label} ($(grep -v '^ ' "${work}/last.log" | tail -n1 | cut -c1-150))"; fi
}
require() { "$@" || { bad "fixture: $*"; exit 1; }; }
work=''
finish() {
  local status=$?
  [[ "$status" -eq 0 || "$FAIL" -gt 0 ]] || bad "unexpected exit: $status"
  [[ -z "$work" || -n "${KEEP_WORK:-}" ]] || rm -rf "$work"
  printf ' RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]]
}
trap 'finish; exit $?' EXIT

work="$(mktemp -d "${TMPDIR:-/var/tmp}/deferred-signing.XXXXXX")" || { bad 'fixture: mktemp'; exit 1; }
require "${repo}/tests/generate-dev-rauc-pki.sh" >/dev/null
for tool in rauc mkfs.ext4 debugfs openssl python3; do require command -v "$tool" >/dev/null; done

PKI="${repo}/lib/rauc-pki-contract.sh"
BUNDLE="${repo}/lib/build-bundle.sh"
SIGN="${repo}/lib/sign-bundle.sh"
keys_a="${repo}/.dev-keys"
root_a_sha="$(openssl x509 -in "${keys_a}/root-ca.pem" -outform DER | sha256sum | cut -c1-64)"

# Root B: a second, unrelated throwaway chain (stand-in for "a root the image
# does not trust" in both directions).
keys_b="${work}/keys-b"
mkdir -p "${keys_b}"
require openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 \
  -subj '/CN=deferred-signing test root B (NON-PRODUCTION)' \
  -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -keyout "${keys_b}/root.key" -out "${keys_b}/root-ca.pem" >/dev/null 2>&1
require openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -subj '/CN=deferred-signing test leaf B (NON-PRODUCTION)' \
  -keyout "${keys_b}/leaf-signing.key" -out "${work}/leaf-b.csr" >/dev/null 2>&1
printf '%s\n' 'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature' \
  'extendedKeyUsage=codeSigning,emailProtection' >"${work}/leaf-b.ext"
require openssl x509 -req -in "${work}/leaf-b.csr" -days 2 -sha256 -CA "${keys_b}/root-ca.pem" \
  -CAkey "${keys_b}/root.key" -set_serial 7 -extfile "${work}/leaf-b.ext" \
  -out "${keys_b}/leaf-signing.pem" >/dev/null 2>&1
cp "${keys_b}/root-ca.pem" "${keys_b}/chain.pem"
root_b_sha="$(openssl x509 -in "${keys_b}/root-ca.pem" -outform DER | sha256sum | cut -c1-64)"

# --- 1. The build's keyring-only resolver ------------------------------------
echo '# keyring-only resolver'
refuse 'a PKI directory handed to a deferred build' \
  "${PKI}" resolve-keyring --mode development --pki-dir "${keys_a}"
refuse 'production without an explicit keyring' "${PKI}" resolve-keyring --mode production
"${PKI}" resolve-keyring --mode production --keyring "${keys_a}/root-ca.pem" >"${work}/resolved"
check grep -qx "RAUC_ROOT_SHA256=${root_a_sha}" "${work}/resolved"
check grep -qx "RAUC_KEYRING_FILE=${repo}/.dev-keys/root-ca.pem" \
  <("${PKI}" resolve-keyring --mode development)
{ cat "${keys_a}/root-ca.pem"; sed 's/CERTIFICATE/TRUSTED CERTIFICATE/' "${keys_b}/root-ca.pem"; } >"${work}/two-roots.pem"
refuse 'a second root under another PEM label' \
  "${PKI}" resolve-keyring --mode production --keyring "${work}/two-roots.pem"
{ cat "${keys_a}/root-ca.pem"; cat "${keys_b}/root.key"; } >"${work}/with-key.pem"
refuse 'a keyring carrying a private key' \
  "${PKI}" resolve-keyring --mode production --keyring "${work}/with-key.pem"
sed 's/$/\r/' "${keys_a}/root-ca.pem" >"${work}/crlf.pem"
refuse 'a CRLF keyring' "${PKI}" resolve-keyring --mode production --keyring "${work}/crlf.pem"
check grep -q 'rauc_keyring_resolve "${CERALIVE_BUILD_MODE}"' "${repo}/lib/orchestrate.sh"

# --- 2. prepare: unsigned content, no key ------------------------------------
echo '# prepare'
make_tree() { # <dir> <root.pem>
  mkdir -p "$1/etc/rauc"
  printf 'deferred fixture\n' >"$1/etc/hostname"
  cp "$2" "$1/etc/rauc/ceralive-keyring.pem"
}
make_tree "${work}/tree-a" "${keys_a}/root-ca.pem"
make_tree "${work}/tree-b" "${keys_b}/root-ca.pem"
mkdir -p "${work}/tree-none/etc"
printf 'x\n' >"${work}/tree-none/etc/hostname"
common_env=(COMPATIBLE_STRING=ceralive-rock-5b-plus BUNDLE_VERSION=deferred-test
  SOURCE_DATE_EPOCH=1700000000 MKOSI_BUILDER_IMAGE= MKOSI_NATIVE=1 CERALIVE_RAUC_PKI_DIR=)
prepare() { # <out-dir> <tree> [env...]
  local out="$1" tree="$2"; shift 2
  mkdir -p "${out}"
  env "${common_env[@]}" BUNDLE_TS=t BUNDLE_OUT_DIR="${out}" "$@" \
    "${BUNDLE}" prepare rock-5b-plus "${tree}"
}
check prepare "${work}/p" "${work}/tree-a" RAUC_ROOT_SHA256="${root_a_sha}"
desc="${work}/p/t.raucb-content.json"
check test -s "${desc}"
check test ! -e "${work}/p/t.raucb"
digest="$(cut -c1-64 "${desc}.sha256")"
check test "${digest}" = "$(sha256sum <"${desc}" | cut -c1-64)"
check python3 -I - "${desc}" "${root_a_sha}" "$(git -C "${repo}" rev-parse HEAD)" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["device_keyring_sha256"] == sys.argv[2], d
assert [f["name"] for f in d["files"]] == ["layout-check", "manifest.raucm", "rootfs.ext4"], d
assert [f["mode"] for f in d["files"]] == ["0755", "0644", "0644"], d
assert d["schema"] == "ceralive-unsigned-bundle/1" and "signer_image" not in d, d
assert d["pipeline_commit"] == sys.argv[3], d
assert d["source_date_epoch"] == 1700000000, d
PY
refuse 'prepare over an existing content directory' prepare "${work}/p" "${work}/tree-a"
refuse 'an image whose keyring is not the build keyring' \
  prepare "${work}/p-mismatch" "${work}/tree-b" RAUC_ROOT_SHA256="${root_a_sha}"
check test ! -e "${work}/p-mismatch/t.raucb-content"
refuse 'an image without a RAUC keyring' prepare "${work}/p-none" "${work}/tree-none"
# The orchestrator's unchanged [8/9] call prepares instead of signing.
mkdir -p "${work}/p-cli"
check env "${common_env[@]}" BUNDLE_TS=t BUNDLE_OUT_DIR="${work}/p-cli" CERALIVE_RAUC_SIGNING=deferred \
  "${BUNDLE}" rock-5b-plus "${work}/tree-a"
check test -s "${work}/p-cli/t.raucb-content.json"
check test ! -e "${work}/p-cli/t.raucb"

# --- 3. check / sign / finish: the happy path ----------------------------------
echo '# check, sign, finish'
check_c() { # <content> <expect> <stage-parent> [args...]: no PKI in the environment
  local content="$1" expect="$2" parent="$3"; shift 3
  mkdir -p "${parent}"
  env -u CERALIVE_RAUC_PKI_DIR "${SIGN}" check --content "${content}" --expect "${expect}" \
    --stage-parent "${parent}" "$@"
}
sign_s() { # <stage> <expect> [args...] with PKI from $sign_pki
  local stage="$1" expect="$2"; shift 2
  env CERALIVE_BUILD_MODE=production CERALIVE_RAUC_PKI_DIR="${sign_pki}" \
    RAUC_KEYRING_FILE="${sign_pki}/root-ca.pem" "${SIGN}" sign --stage "${stage}" --expect "${expect}" "$@"
}
finish_s() { # <stage> <expect> <out> [args...]
  local stage="$1" expect="$2" out="$3"; shift 3
  env -u CERALIVE_RAUC_PKI_DIR "${SIGN}" finish --stage "${stage}" --expect "${expect}" --out "${out}" "$@"
}
fresh() { # <name> -> copy of the prepared output under $work/<name>
  rm -rf "${work:?}/$1"
  cp -a --sparse=always "${work}/p" "${work}/$1"
}
empty_dir() { [[ -z "$(ls -A "$1" 2>/dev/null)" ]]; }
sign_pki="${keys_a}"
fresh ok
stage="$(check_c "${work}/ok/t.raucb-content" "${digest}" "${work}/ok-stages" --expect-root-sha256 "${root_a_sha}")"
check test -d "${stage}"
check test "$(stat -c %a "${stage}")" = 700
check cmp -s "${stage}/descriptor.json" "${desc}"
# A caller's mksquashfs arguments are ignored: a pseudo file would add a file.
printf 'secret\n' >"${work}/secret"
printf 'leak f 0444 0 0 cat %s\n' "${work}/secret" >"${work}/leak.pf"
check env "RAUC_BUNDLE_MKSQUASHFS_ARGS=-pf ${work}/leak.pf" CERALIVE_BUILD_MODE=production \
  CERALIVE_RAUC_PKI_DIR="${sign_pki}" RAUC_KEYRING_FILE="${sign_pki}/root-ca.pem" \
  "${SIGN}" sign --stage "${stage}" --expect "${digest}" --expect-root-sha256 "${root_a_sha}"
check test -s "${stage}/out/t.raucb"
check test ! -e "${work}/ok/t.raucb"
check finish_s "${stage}" "${digest}" "${work}/ok/t.raucb" --expect-root-sha256 "${root_a_sha}"
check test -s "${work}/ok/t.raucb"
check test ! -e "${stage}"
check test "$(cut -c1-64 "${work}/ok/t.raucb.sha256")" = "$(sha256sum <"${work}/ok/t.raucb" | cut -c1-64)"
check rauc info -C keyring:check-purpose=codesign --keyring="${keys_a}/root-ca.pem" "${work}/ok/t.raucb"
refuse 'rauc info of the signed bundle under another root' \
  rauc info --keyring="${keys_b}/root-ca.pem" "${work}/ok/t.raucb"
refuse 'the pseudo-file entry in the signed squashfs' unsquashfs -cat "${work}/ok/t.raucb" leak
check test -z "$(find "${work}/ok" -name '*.partial')"
check grep -Fxq 'unset RAUC_BUNDLE_MKSQUASHFS_ARGS' "${SIGN}"
if grep -Eq '(docker|podman) ' "${SIGN}"; then bad 'the signing step runs a container'; else ok 'the signing step runs no container'; fi

# Same payload as an inline host-rauc build of the same tree (umask 022, as the
# build): byte-identical squashfs, same format, image checksum and adaptive mode.
# RAUC salts the verity tree randomly per bundle, so that hash differs between
# ANY two bundles.
mkdir -p "${work}/inline"
check bash -c 'umask 022; exec env "$@"' _ "${common_env[@]}" CERALIVE_RAUC_PKI_DIR="${keys_a}" \
  BUNDLE_TS=t BUNDLE_OUT_DIR="${work}/inline" "${BUNDLE}" rock-5b-plus "${work}/tree-a"
payload() { # <bundle>: sha256 of its squashfs image (superblock bytes_used)
  python3 -I - "$1" <<'PY'
import hashlib, struct, sys
with open(sys.argv[1], "rb") as f:
    sb = f.read(96)
    assert sb[:4] == b"hsqs", "no squashfs at the start of the bundle"
    used = struct.unpack_from("<Q", sb, 40)[0]
    f.seek(0)
    print(hashlib.sha256(f.read(used)).hexdigest(), used)
PY
}
info_json() { rauc info --output-format=json-2 --keyring="${keys_a}/root-ca.pem" "$1" 2>/dev/null \
  | python3 -Ic 'import json,sys; d=json.load(sys.stdin); i=d["images"][0]; print(d["bundle"]["format"], i["checksum"], i["size"], i["adaptive"], d["update"])'; }
check test -n "$(payload "${work}/inline/t.raucb")"
check test "$(payload "${work}/inline/t.raucb")" = "$(payload "${work}/ok/t.raucb")"
check test "$(info_json "${work}/inline/t.raucb")" = "$(info_json "${work}/ok/t.raucb")"

# --- 4. refusals; none leaves a stage or a bundle behind -----------------------
echo '# refusals'
refuse_check() { # <label> <name> <expect> [args...]: check must refuse and leave no stage
  local label="$1" name="$2" expect="$3"; shift 3
  refuse "${label}" check_c "${work}/${name}/t.raucb-content" "${expect}" "${work}/${name}-stages" "$@"
  check empty_dir "${work}/${name}-stages"
}
fresh wrong-digest
refuse_check 'a wrong --expect' wrong-digest "$(printf '0%.0s' {1..64})"

fresh flipped
printf 'X' | dd of="${work}/flipped/t.raucb-content/rootfs.ext4" bs=1 seek=4096 conv=notrunc status=none
refuse_check 'rootfs.ext4 changed after the build' flipped "${digest}"

fresh extra
printf 'payload\n' >"${work}/extra/t.raucb-content/extra.bin"
refuse_check 'an extra file in the content' extra "${digest}"

fresh link
mv "${work}/link/t.raucb-content/layout-check" "${work}/link/hook"
ln -s ../hook "${work}/link/t.raucb-content/layout-check"
refuse_check 'a symlink in the content' link "${digest}"

fresh desc-link
mv "${work}/desc-link/t.raucb-content.json" "${work}/desc-link/real.json"
ln -s real.json "${work}/desc-link/t.raucb-content.json"
refuse_check 'a symlinked descriptor' desc-link "${digest}"

rewrite() { # <dir> <file|-> [python expr on d] -> re-record that file; prints the new digest
  python3 -I - "${work}/$1/t.raucb-content.json" "${work}/$1/t.raucb-content/$2" "${3:-}" <<'PY'
import hashlib, json, os, sys
desc, path, expr = sys.argv[1:]
d = json.load(open(desc))
for e in d["files"]:
    if e["name"] == os.path.basename(path):
        data = open(path, "rb").read()
        e["sha256"], e["size"] = hashlib.sha256(data).hexdigest(), len(data)
if expr:
    exec(expr)
with open(desc, "w") as f:
    json.dump(d, f, indent=1, sort_keys=True); f.write("\n")
PY
  sha256sum <"${work}/$1/t.raucb-content.json" | cut -c1-64
}
fresh plain
sed -i 's/format=verity/format=plain/' "${work}/plain/t.raucb-content/manifest.raucm"
refuse_check 'a non-verity manifest, even with a matching descriptor' plain "$(rewrite plain manifest.raucm)"

fresh hook
printf 'exit 0\n' >>"${work}/hook/t.raucb-content/layout-check"
refuse_check 'a changed install hook, even with a matching descriptor' hook "$(rewrite hook layout-check)"

fresh commit
refuse_check 'a build commit other than this checkout' commit \
  "$(rewrite commit - 'd["pipeline_commit"] = "a" * 40')"

fresh want-root
refuse_check 'an --expect-root-sha256 that is not the image root' want-root "${digest}" \
  --expect-root-sha256 "${root_b_sha}"

# The descriptor is read once: swapping the shared file after check changes nothing,
# changing the staged copy is refused.
fresh swap
stage="$(check_c "${work}/swap/t.raucb-content" "${digest}" "${work}/swap-stages")"
printf '{}\n' >"${work}/swap/t.raucb-content.json"
printf ' ' >>"${stage}/descriptor.json"
refuse 'a staged descriptor changed after check' sign_s "${stage}" "${digest}"
check empty_dir "${stage}/out"

fresh restage
stage="$(check_c "${work}/restage/t.raucb-content" "${digest}" "${work}/restage-stages")"
printf 'X' | dd of="${stage}/content/rootfs.ext4" bs=1 seek=8192 conv=notrunc status=none
refuse 'staged content changed between check and sign' sign_s "${stage}" "${digest}"
check empty_dir "${stage}/out"

fresh open-stage
stage="$(check_c "${work}/open-stage/t.raucb-content" "${digest}" "${work}/open-stage-stages")"
chmod 0755 "${stage}"
refuse 'a stage that is not private' sign_s "${stage}" "${digest}"

# A failing signer leaves nothing in out/.
fresh fail-sign
stage="$(check_c "${work}/fail-sign/t.raucb-content" "${digest}" "${work}/fail-sign-stages")"
mkdir -p "${work}/fake-rauc"
cat >"${work}/fake-rauc/rauc" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == --version ]] && { echo 'rauc 1.15.9'; exit 0; }
for a; do out="$a"; done
printf 'half a bundle' >"${out}"
exit 1
EOF
chmod +x "${work}/fake-rauc/rauc"
refuse 'a signer that fails half way' env PATH="${work}/fake-rauc:${PATH}" \
  bash -c "$(declare -f sign_s); sign_pki='${sign_pki}' SIGN='${SIGN}' sign_s '${stage}' '${digest}'"
check empty_dir "${stage}/out"

# An image that trusts root B cannot be signed with chain A.
check prepare "${work}/pb" "${work}/tree-b"
pb_digest="$(cut -c1-64 "${work}/pb/t.raucb-content.json.sha256")"
stage="$(check_c "${work}/pb/t.raucb-content" "${pb_digest}" "${work}/pb-stages")"
refuse 'a signer root that is not the root the image trusts' sign_s "${stage}" "${pb_digest}"
check empty_dir "${stage}/out"

# finish refuses a bundle that was swapped after signing: here one signed with
# the right key over the right content but with an extra squashfs file.
fresh swapped-bundle
stage="$(check_c "${work}/swapped-bundle/t.raucb-content" "${digest}" "${work}/swapped-bundle-stages")"
check sign_s "${stage}" "${digest}"
rm -f "${stage}/out/t.raucb"
check rauc bundle --cert="${keys_a}/leaf-signing.pem" --key="${keys_a}/leaf-signing.key" \
  --intermediate="${keys_a}/chain.pem" "--mksquashfs-args=-pf ${work}/leak.pf" \
  "${stage}/content" "${stage}/out/t.raucb"
check rauc info --keyring="${keys_a}/root-ca.pem" "${stage}/out/t.raucb"
refuse 'a signed bundle with an extra file in its squashfs' \
  finish_s "${stage}" "${digest}" "${work}/swapped-bundle/t.raucb"
check test ! -e "${work}/swapped-bundle/t.raucb"
check test ! -e "${stage}/out/t.raucb"

fresh exists
stage="$(check_c "${work}/exists/t.raucb-content" "${digest}" "${work}/exists-stages")"
check sign_s "${stage}" "${digest}"
printf 'older\n' >"${work}/exists/t.raucb"
refuse 'finishing over an existing bundle' finish_s "${stage}" "${digest}" "${work}/exists/t.raucb"
check grep -qx older "${work}/exists/t.raucb"
[[ "$FAIL" -eq 0 ]]

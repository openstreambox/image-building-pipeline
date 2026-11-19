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
  if "$@" >"${work}/last.log" 2>&1; then bad "accepted: ${label}"; else ok "refused: ${label}"; fi
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
  SOURCE_DATE_EPOCH=1700000000 "RAUC_BUNDLE_MKSQUASHFS_ARGS=-noD -noF"
  MKOSI_BUILDER_IMAGE= MKOSI_NATIVE=1 CERALIVE_RAUC_PKI_DIR=)
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
check python3 -I - "${desc}" "${root_a_sha}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["device_keyring_sha256"] == sys.argv[2], d
assert [f["name"] for f in d["files"]] == ["layout-check", "manifest.raucm", "rootfs.ext4"], d
assert [f["mode"] for f in d["files"]] == ["0755", "0644", "0644"], d
assert d["signer_image"] is None and d["schema"] == "ceralive-unsigned-bundle/1"
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

# --- 3. sign: the happy path ---------------------------------------------------
echo '# sign'
sign() { # <content> <expect> [args...] with PKI from $sign_pki
  local content="$1" expect="$2"; shift 2
  env MKOSI_NATIVE=1 CERALIVE_BUILD_MODE=production CERALIVE_RAUC_PKI_DIR="${sign_pki}" \
    RAUC_KEYRING_FILE="${sign_pki}/root-ca.pem" "RAUC_BUNDLE_MKSQUASHFS_ARGS=-noD -noF" \
    "${SIGN}" sign --content "${content}" --expect "${expect}" "$@"
}
fresh() { # <name> -> copy of the prepared output under $work/<name>
  rm -rf "${work:?}/$1"
  cp -a --sparse=always "${work}/p" "${work}/$1"
}
sign_pki="${keys_a}"
fresh ok
check sign "${work}/ok/t.raucb-content" "${digest}" --expect-root-sha256 "${root_a_sha}"
check test -s "${work}/ok/t.raucb"
check test "$(cut -c1-64 "${work}/ok/t.raucb.sha256")" = "$(sha256sum <"${work}/ok/t.raucb" | cut -c1-64)"
check rauc info -C keyring:check-purpose=codesign --keyring="${keys_a}/root-ca.pem" "${work}/ok/t.raucb"
refuse 'rauc info of the signed bundle under another root' \
  rauc info --keyring="${keys_b}/root-ca.pem" "${work}/ok/t.raucb"
check test -z "$(find "${work}/ok" -name '.sign-stage.*' -o -name '.*.info.json')"
refuse 'signing twice over an existing bundle' sign "${work}/ok/t.raucb-content" "${digest}"
check test -s "${work}/ok/t.raucb"

# Same payload as the inline path (built under the build's umask 022): the
# squashfs image inside both bundles is byte-identical, and so are format,
# image checksum and adaptive mode. RAUC salts the verity tree randomly per
# bundle, so the verity hash itself differs between ANY two bundles.
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

# --- 4. sign refuses whatever changed, and leaves no bundle --------------------
echo '# sign refusals'
no_bundle() { check test ! -e "${work}/$1/t.raucb"; }
fresh wrong-digest
refuse 'a wrong --expect' sign "${work}/wrong-digest/t.raucb-content" "$(printf '0%.0s' {1..64})"
no_bundle wrong-digest

fresh flipped
printf 'X' | dd of="${work}/flipped/t.raucb-content/rootfs.ext4" bs=1 seek=4096 conv=notrunc status=none
refuse 'rootfs.ext4 changed after the build' sign "${work}/flipped/t.raucb-content" "${digest}"
no_bundle flipped

fresh extra
printf 'payload\n' >"${work}/extra/t.raucb-content/extra.bin"
refuse 'an extra file in the content' sign "${work}/extra/t.raucb-content" "${digest}"
no_bundle extra

fresh link
mv "${work}/link/t.raucb-content/layout-check" "${work}/link/hook"
ln -s ../hook "${work}/link/t.raucb-content/layout-check"
refuse 'a symlink in the content' sign "${work}/link/t.raucb-content" "${digest}"
no_bundle link

# A rewritten descriptor only helps if --expect follows it; even then the
# manifest and hook must be this pipeline's own.
rewrite() { # <dir> <file> -> re-record that file in the descriptor; prints the new digest
  python3 -I - "${work}/$1/t.raucb-content.json" "${work}/$1/t.raucb-content/$2" <<'PY'
import hashlib, json, os, sys
desc, path = sys.argv[1:]
d = json.load(open(desc))
for e in d["files"]:
    if e["name"] == os.path.basename(path):
        data = open(path, "rb").read()
        e["sha256"], e["size"] = hashlib.sha256(data).hexdigest(), len(data)
with open(desc, "w") as f:
    json.dump(d, f, indent=1, sort_keys=True); f.write("\n")
PY
  sha256sum <"${work}/$1/t.raucb-content.json" | cut -c1-64
}
fresh plain
sed -i 's/format=verity/format=plain/' "${work}/plain/t.raucb-content/manifest.raucm"
refuse 'a non-verity manifest, even with a matching descriptor' \
  sign "${work}/plain/t.raucb-content" "$(rewrite plain manifest.raucm)"
no_bundle plain

fresh hook
printf 'exit 0\n' >>"${work}/hook/t.raucb-content/layout-check"
refuse 'a changed install hook, even with a matching descriptor' \
  sign "${work}/hook/t.raucb-content" "$(rewrite hook layout-check)"
no_bundle hook

fresh want-root
refuse 'an --expect-root-sha256 that is not the image root' \
  sign "${work}/want-root/t.raucb-content" "${digest}" --expect-root-sha256 "${root_b_sha}"
no_bundle want-root

# An image that trusts root B cannot be signed with chain A.
check prepare "${work}/pb" "${work}/tree-b"
sign_pki="${keys_a}"
refuse 'a signer root that is not the root the image trusts' \
  sign "${work}/pb/t.raucb-content" "$(cut -c1-64 "${work}/pb/t.raucb-content.json.sha256")"
check test ! -e "${work}/pb/t.raucb"

# --- 5. The offline signer container: no network, nothing installed -----------
echo '# offline signer invocation'
mkdir -p "${work}/bin" "${work}/c-out" "${work}/c-content"
cat >"${work}/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"${DOCKER_LOG}"
EOF
chmod +x "${work}/bin/docker"
check env PATH="${work}/bin:${PATH}" DOCKER_LOG="${work}/docker.log" \
  CERALIVE_RAUC_PKI_DIR="${keys_a}" RAUC_SIGNER_IMAGE="sha256:$(printf 'a%.0s' {1..64})" \
  bash -c 'source "$1"; bundle_with_rauc "$2" "$3"' _ "${BUNDLE}" "${work}/c-content" "${work}/c-out/x.raucb"
for flag in --network none --cap-drop ALL --read-only no-new-privileges "${keys_a}:/pki:ro"; do
  check grep -Fxq -- "${flag}" "${work}/docker.log"
done
check grep -Fxq -- "--user" "${work}/docker.log"
if grep -Eq 'apt-get|rauc-debs' "${work}/docker.log"; then
  bad 'the offline signer fetches or installs packages'
else
  ok 'the offline signer fetches and installs nothing'
fi
check grep -q 'signer_image' "${repo}/lib/build-bundle.sh"
[[ "$FAIL" -eq 0 ]]

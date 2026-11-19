#!/usr/bin/env bash
set -euo pipefail

rauc_cert_sha256() {
  openssl x509 -in "$1" -outform DER | sha256sum | cut -d' ' -f1
}

rauc_pki_resolve() {
  local mode="$1" requested_pki="${2:-}" requested_keyring="${3:-}"
  local here v2 pki keyring cert_pub key_pub eku
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  v2="$(cd "${here}/.." && pwd)"
  case "${mode}" in
    development)
      pki="${requested_pki:-${v2}/.dev-keys}"
      keyring="${requested_keyring:-${pki}/root-ca.pem}"
      ;;
    production)
      [[ -n "${requested_pki}" && -n "${requested_keyring}" ]] || {
        printf 'production RAUC PKI requires explicit CERALIVE_RAUC_PKI_DIR and RAUC_KEYRING_FILE\n' >&2
        return 1
      }
      pki="${requested_pki}"
      keyring="${requested_keyring}"
      ;;
    *) printf 'CERALIVE_BUILD_MODE must be development or production\n' >&2; return 2 ;;
  esac
  for file in root-ca.pem chain.pem leaf-signing.pem leaf-signing.key; do
    [[ -s "${pki}/${file}" ]] || { printf 'missing RAUC PKI file: %s/%s\n' "${pki}" "${file}" >&2; return 1; }
  done
  [[ -s "${keyring}" ]] || { printf 'missing RAUC device keyring: %s\n' "${keyring}" >&2; return 1; }
  [[ "$(rauc_cert_sha256 "${pki}/root-ca.pem")" == "$(rauc_cert_sha256 "${keyring}")" ]] || {
    printf 'RAUC signer root and device keyring do not match\n' >&2
    return 1
  }
  cert_pub="$(openssl x509 -in "${pki}/leaf-signing.pem" -pubkey -noout)"
  key_pub="$(openssl pkey -in "${pki}/leaf-signing.key" -pubout 2>/dev/null)"
  [[ "${cert_pub}" == "${key_pub}" ]] || { printf 'RAUC leaf certificate/private key mismatch\n' >&2; return 1; }
  # RAUC's unconfigured CMS verifier requires S/MIME signing; the leaf also
  # needs Code Signing EKU for newer RAUC versions.
  openssl verify -purpose smimesign -CAfile "${keyring}" \
    -untrusted "${pki}/chain.pem" "${pki}/leaf-signing.pem" >/dev/null || {
    printf 'RAUC leaf is not valid for the device S/MIME signing purpose\n' >&2
    return 1
  }
  eku="$(openssl x509 -in "${pki}/leaf-signing.pem" -noout -ext extendedKeyUsage)"
  [[ "$eku" == *'Code Signing'* ]] || {
    printf 'RAUC leaf is not valid for code signing\n' >&2
    return 1
  }
  CERALIVE_RAUC_PKI_DIR="${pki}"
  RAUC_KEYRING_FILE="${keyring}"
  RAUC_ROOT_SHA256="$(rauc_cert_sha256 "${keyring}")"
  export CERALIVE_RAUC_PKI_DIR RAUC_KEYRING_FILE RAUC_ROOT_SHA256
}

# rauc_keyring_check_single_root <file>: the keyring is exactly one certificate in
# canonical PEM form and nothing else. OpenSSL also loads TRUSTED CERTIFICATE and
# X509 CERTIFICATE blocks, so counting BEGIN lines is not enough; byte equality
# with the re-encoded first certificate refuses a second root under any label,
# trailing bytes, comments, CRLF and private keys.
rauc_keyring_check_single_root() {
  local keyring="$1" canonical
  [[ -s "${keyring}" ]] || { printf 'missing RAUC device keyring: %s\n' "${keyring}" >&2; return 1; }
  canonical="$(openssl x509 -in "${keyring}" -outform PEM 2>/dev/null)" \
    || { printf 'RAUC device keyring is not a PEM certificate: %s\n' "${keyring}" >&2; return 1; }
  cmp -s <(printf '%s\n' "${canonical}") "${keyring}" || {
    printf 'RAUC device keyring must be exactly one canonical PEM certificate: %s\n' "${keyring}" >&2
    return 1
  }
}

# rauc_keyring_resolve MODE PKI_DIR KEYRING — the deferred-signing variant of
# rauc_pki_resolve. The image build only needs the PUBLIC root it bakes into
# /etc/rauc/ceralive-keyring.pem; the signer key and chain are used later by
# lib/sign-bundle.sh, in a separate short step. A PKI directory handed to such a
# build is refused, so a signing key cannot ride along into the long build by
# mistake. Production still needs the keyring explicitly; development defaults
# to the repository's .dev-keys root (the public certificate only).
rauc_keyring_resolve() {
  local mode="$1" requested_pki="${2:-}" requested_keyring="${3:-}" here v2 keyring
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  v2="$(cd "${here}/.." && pwd)"
  [[ -z "${requested_pki}" ]] || {
    printf 'deferred RAUC signing: the build takes the public keyring only; unset CERALIVE_RAUC_PKI_DIR (sign later with lib/sign-bundle.sh)\n' >&2
    return 1
  }
  case "${mode}" in
    development) keyring="${requested_keyring:-${v2}/.dev-keys/root-ca.pem}" ;;
    production)
      [[ -n "${requested_keyring}" ]] || {
        printf 'production deferred signing requires an explicit RAUC_KEYRING_FILE\n' >&2
        return 1
      }
      keyring="${requested_keyring}"
      ;;
    *) printf 'CERALIVE_BUILD_MODE must be development or production\n' >&2; return 2 ;;
  esac
  rauc_keyring_check_single_root "${keyring}" || return 1
  unset CERALIVE_RAUC_PKI_DIR
  RAUC_KEYRING_FILE="${keyring}"
  RAUC_ROOT_SHA256="$(rauc_cert_sha256 "${keyring}")"
  export RAUC_KEYRING_FILE RAUC_ROOT_SHA256
}

main() {
  local cmd="${1:-}"
  [[ "${cmd}" == resolve || "${cmd}" == resolve-keyring ]] || {
    printf 'usage: %s resolve|resolve-keyring --mode MODE [--pki-dir DIR] [--keyring FILE]\n' "$0" >&2
    exit 2
  }
  shift
  local mode="" pki="" keyring=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode) mode="${2:-}"; shift 2 ;;
      --pki-dir) pki="${2:-}"; shift 2 ;;
      --keyring) keyring="${2:-}"; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  if [[ "${cmd}" == resolve-keyring ]]; then
    rauc_keyring_resolve "${mode}" "${pki}" "${keyring}"
    printf 'RAUC_KEYRING_FILE=%s\nRAUC_ROOT_SHA256=%s\n' "${RAUC_KEYRING_FILE}" "${RAUC_ROOT_SHA256}"
    return 0
  fi
  rauc_pki_resolve "${mode}" "${pki}" "${keyring}"
  printf 'CERALIVE_RAUC_PKI_DIR=%s\nRAUC_KEYRING_FILE=%s\nRAUC_ROOT_SHA256=%s\n' \
    "${CERALIVE_RAUC_PKI_DIR}" "${RAUC_KEYRING_FILE}" "${RAUC_ROOT_SHA256}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

#!/usr/bin/env bash
# lib/release-remote-access.sh — host-side checks for the opt-in remote-access
# options (mkosi/customize/postinst.d/remote-access.sh).
#
#   CERALIVE_TAILSCALE=0|1            ship Tailscale (inert until enrolled from BOOT)
#   CERALIVE_SSH_ROOT_KEYS_FILE=FILE  public keys to seed for root (one per line)
#   CERALIVE_SSH_PASSWORD_AUTH=no     sshd accepts keys only
#
# The keys file must hold only plain ssh-ed25519 / ecdsa-sha2-nistp* / ssh-rsa
# (3072 bit or more) public keys, no options, and no comment starting with
# "ceralive-ci-" (the first-boot CI guard would delete such a key). Key-only
# SSH cannot be combined with the lab debug image, which logs in by password.
# Exports CERALIVE_SSH_ROOT_KEYS_B64 (empty when no file).

set -euo pipefail

release_remote_access_die() { printf 'remote access: %s\n' "$*" >&2; return 1; }

release_remote_access_check_keys() {
  local file="$1" line n=0 type tmp out bits
  [[ -f "${file}" && ! -L "${file}" && -s "${file}" ]] \
    || { release_remote_access_die "SSH keys file missing or empty: ${file}"; return 1; }
  if grep -q 'PRIVATE KEY' "${file}"; then release_remote_access_die "SSH keys file holds a private key"; return 1; fi
  if LC_ALL=C grep -q $'\r' "${file}"; then release_remote_access_die "SSH keys file has CRLF line endings"; return 1; fi
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    n=$((n + 1))
    type="${line%% *}"
    case "${type}" in
      ssh-ed25519 | ecdsa-sha2-nistp256 | ecdsa-sha2-nistp384 | ecdsa-sha2-nistp521 | ssh-rsa) ;;
      *) rm -f "${tmp}"; release_remote_access_die "line ${n}: not a plain public key (options or unknown type '${type}')"; return 1 ;;
    esac
    if [[ "${line}" =~ \ ceralive-ci-[^\ ]*$ ]]; then
      rm -f "${tmp}"; release_remote_access_die "line ${n}: a 'ceralive-ci-' comment would be removed by the first-boot CI guard"; return 1
    fi
    printf '%s\n' "${line}" >"${tmp}"
    if ! out="$(ssh-keygen -l -f "${tmp}" 2>&1)"; then
      rm -f "${tmp}"; release_remote_access_die "line ${n}: ssh-keygen cannot read it: ${out}"; return 1
    fi
    bits="${out%% *}"
    if [[ "${type}" == ssh-rsa && "${bits}" -lt 3072 ]]; then
      rm -f "${tmp}"; release_remote_access_die "line ${n}: RSA key below 3072 bits"; return 1
    fi
  done <"${file}"
  rm -f "${tmp}"
  (( n > 0 )) || { release_remote_access_die "SSH keys file has no keys"; return 1; }
  (( n <= 16 )) || { release_remote_access_die "more than 16 seeded SSH keys"; return 1; }
}

release_remote_access_resolve() {
  local tailscale="${CERALIVE_TAILSCALE:-0}" file="${CERALIVE_SSH_ROOT_KEYS_FILE:-}"
  local password="${CERALIVE_SSH_PASSWORD_AUTH:-}"
  CERALIVE_SSH_ROOT_KEYS_B64=""
  [[ "${tailscale}" == 0 || "${tailscale}" == 1 ]] \
    || { release_remote_access_die "CERALIVE_TAILSCALE must be 0 or 1"; return 1; }
  [[ -z "${password}" || "${password}" == no ]] \
    || { release_remote_access_die "CERALIVE_SSH_PASSWORD_AUTH must be empty or 'no'"; return 1; }
  if [[ "${password}" == no && "${CERALIVE_DEBUG_IMAGE:-0}" == 1 ]]; then
    release_remote_access_die "key-only SSH cannot be combined with the lab debug image (password login)"; return 1
  fi
  if [[ "${password}" == no && -z "${file}" ]]; then
    release_remote_access_die "key-only SSH without seeded keys leaves no LAN way in (Tailscale may never be enrolled); set CERALIVE_SSH_ROOT_KEYS_FILE"; return 1
  fi
  if [[ -n "${file}" ]]; then
    release_remote_access_check_keys "${file}" || return 1
    CERALIVE_SSH_ROOT_KEYS_B64="$(base64 -w0 <"${file}")"
  fi
  CERALIVE_TAILSCALE="${tailscale}"
  CERALIVE_SSH_PASSWORD_AUTH="${password}"
  export CERALIVE_TAILSCALE CERALIVE_SSH_PASSWORD_AUTH CERALIVE_SSH_ROOT_KEYS_B64
}

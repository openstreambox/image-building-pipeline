#!/usr/bin/env bash
# lib/image-apt-source.sh — optional single signed apt source for a fork release.
#
#   CERALIVE_IMAGE_APT_SOURCE=1
#       The image ships exactly one apt source, <channel base>/apt/, with two
#       suites: <board>-<os version> (exactly the packages in this image's lock)
#       and <board>-<os version>-emergency (normally empty). No Debian and no
#       first-party archive source ships, and the first-party archive's client
#       credentials are not installed. mkosi/runtime/image-apt-source.sh writes the
#       files after the application layer's last apt transaction.
#   CERALIVE_IMAGE_APT_KEYRING_FILE
#       Binary OpenPGP keyring with the archive's public keys (active and standby).
#   CERALIVE_EXPECT_IMAGE_APT_FPRS
#       Space-separated primary fingerprints the keyring must hold, exactly: at
#       least two distinct signing keys (active and standby).
# With the flag unset or 0 the other two are ignored.
#
# Only a fork release (CERALIVE_FORK_RELEASE=1, so with an update-channel preset)
# can enable it: the apt base is derived from the preset's channelUrl, so the
# packages and the OS images come from the same place. The build also needs
# CERALIVE_OS_RELEASE_VERSION, which names the suites, and CERALIVE_DEBIAN_SNAPSHOT,
# so every Debian package in the lock stays retrievable by its digest.
#
# Usage (sourced by orchestrate.sh, after release_preset_resolve):
#   image_apt_source_resolve   # exports CERALIVE_IMAGE_APT_{SOURCE,URI_B64,KEYRING_B64}

set -euo pipefail

image_apt_source_die() { printf 'image apt source: %s\n' "$*" >&2; return 1; }

image_apt_source_resolve() {
  local flag="${CERALIVE_IMAGE_APT_SOURCE:-}" keyring="${CERALIVE_IMAGE_APT_KEYRING_FILE:-}"
  local fprs="${CERALIVE_EXPECT_IMAGE_APT_FPRS:-}" base here
  CERALIVE_IMAGE_APT_URI_B64="" CERALIVE_IMAGE_APT_KEYRING_B64=""
  if [[ -z "$flag" || "$flag" == 0 ]]; then
    # One switch turns the feature off: companion inputs left in the environment are ignored.
    CERALIVE_IMAGE_APT_SOURCE=0
    export CERALIVE_IMAGE_APT_SOURCE CERALIVE_IMAGE_APT_URI_B64 CERALIVE_IMAGE_APT_KEYRING_B64
    return 0
  fi
  [[ "$flag" == 1 ]] || { image_apt_source_die "CERALIVE_IMAGE_APT_SOURCE must be 0 or 1"; return 1; }
  [[ "${CERALIVE_FORK_RELEASE:-}" == 1 && -n "${CERALIVE_UPDATE_PRESET_CHANNEL_B64:-}" ]] \
    || { image_apt_source_die "needs CERALIVE_FORK_RELEASE=1 with an update-channel preset"; return 1; }
  [[ "${CERALIVE_OS_RELEASE_VERSION:-}" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]] \
    || { image_apt_source_die "needs CERALIVE_OS_RELEASE_VERSION=YYYY.M.N (it names the suites)"; return 1; }
  # The image suite republishes exactly the Debian packages this build installed;
  # a dated snapshot keeps every one of them retrievable by its locked digest.
  [[ -n "${CERALIVE_DEBIAN_SNAPSHOT:-}" ]] \
    || { image_apt_source_die "needs CERALIVE_DEBIAN_SNAPSHOT (a dated Debian snapshot build)"; return 1; }
  # release_preset_validate already proved channelUrl is a plain https URL without
  # query, fragment or credentials; read it from the same JSON payload.
  base="$(printf '%s' "${CERALIVE_UPDATE_PRESET_CHANNEL_B64}" | base64 -d \
    | python3 -c 'import json, sys; v = json.load(sys.stdin).get("channelUrl"); print(v if isinstance(v, str) else "")' 2>/dev/null)" \
    || { image_apt_source_die "the preset's channel file is not JSON"; return 1; }
  [[ "$base" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~-]+)*$ ]] \
    || { image_apt_source_die "the preset's channelUrl is not a plain https base"; return 1; }
  [[ -r "$keyring" && -s "$keyring" ]] || { image_apt_source_die "CERALIVE_IMAGE_APT_KEYRING_FILE is not readable"; return 1; }
  read -r -a fprs <<<"$fprs"
  # An active and a standby key, so a signing-key rotation never needs a box change.
  ((${#fprs[@]} >= 2)) || { image_apt_source_die "CERALIVE_EXPECT_IMAGE_APT_FPRS needs the active and the standby key"; return 1; }
  [[ "$(printf '%s\n' "${fprs[@]}" | sort -u | wc -l)" == "${#fprs[@]}" ]] \
    || { image_apt_source_die "CERALIVE_EXPECT_IMAGE_APT_FPRS repeats a fingerprint"; return 1; }
  local packets
  packets="$(gpg --batch --list-packets -- "$keyring" 2>/dev/null)" \
    || { image_apt_source_die "cannot inspect the keyring's OpenPGP packets"; return 1; }
  if grep -q '^:secret' <<<"$packets"; then
    image_apt_source_die "the keyring holds secret key material"; return 1
  fi
  here="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=lib/fetch-debs-auth.sh
  source "${here}/fetch-debs-auth.sh"
  auth_keyring_has_exact_fingerprints "$keyring" "${fprs[@]}" \
    || { image_apt_source_die "the keyring does not hold exactly the expected primary keys (or holds a secret, revoked or expired key)"; return 1; }
  CERALIVE_IMAGE_APT_URI_B64="$(printf '%s/apt/' "$base" | base64 -w0)"
  CERALIVE_IMAGE_APT_KEYRING_B64="$(base64 -w0 <"$keyring")"
  export CERALIVE_IMAGE_APT_SOURCE CERALIVE_IMAGE_APT_URI_B64 CERALIVE_IMAGE_APT_KEYRING_B64
}

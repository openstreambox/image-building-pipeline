#!/usr/bin/env bash
#
# runtime/image-apt-source.sh — optional single signed apt source for a fork release.
#
# With CERALIVE_IMAGE_APT_SOURCE=1 (lib/image-apt-source.sh resolves it on the host),
# the application layer calls image_apt_source_finalize after its last apt
# transaction. Every build-time source (Debian, the first-party archive) has done
# its job by then; the image ships exactly ONE apt source instead:
#
#   /etc/apt/sources.list.d/openstreambox.sources
#     two suites, <board>-<os version> (exactly the packages this image ships) and
#     <board>-<os version>-emergency (normally empty), signed by the keyring below
#   /usr/share/keyrings/openstreambox-archive-keyring.pgp
#   /etc/apt/preferences.d/openstreambox-origin
#     first-party names 990 and everything else 500 from that host only, installed
#     versions 100, every other source -1
#   /usr/lib/ceralive/image-apt-source.json   (for the device UI's package path)
#
# The legacy origin pins (ceralive-origin, ceralive-local-override) are replaced:
# a version-only override pin would block an emergency fix for that name, and the
# apt.ceralive.tv stanzas name a source the image no longer has. Boot-package holds
# and the reprune hook are untouched. The first-party archive's client credentials
# stay installed (the device UI's add-on downloader uses them without apt), but the
# image apt source never carries them, so they get no origin stanza and keep their
# installed version at priority 100.
#
# Inputs (environment, forwarded by lib/orchestrate.sh + mkosi.conf PassEnvironment=):
#   CERALIVE_IMAGE_APT_SOURCE        1 to enable; anything else is a no-op
#   CERALIVE_IMAGE_APT_URI_B64       https base URL of the apt tree, ends in /
#   CERALIVE_IMAGE_APT_KEYRING_B64   binary OpenPGP keyring (public keys only)
#   CERALIVE_OS_RELEASE_VERSION      YYYY.M.N, names the suites
#   CERALIVE_BOARD                   board manifest stem, names the suites
#   CERALIVE_FIRST_PARTY_NAMES_B64   the first-party name list (validated against
#                                    first-party-origin-names.txt)
# Test hooks: IMAGE_APT_ROOT (default /), IMAGE_APT_ARCH (default dpkg --print-architecture).
#
# shellcheck shell=bash

# Never served by the image apt source (see above), so never pinned to it.
IMAGE_APT_UNSERVED_NAMES=(ceralive-apt-credentials)

image_apt_die() { printf 'image-apt-source: %s\n' "$*" >&2; return 1; }

image_apt_host_of() { # https://host[:port]/path/ -> host
  local rest="${1#https://}"
  rest="${rest%%/*}"
  printf '%s' "${rest%%:*}"
}

image_apt_source_enabled() { [[ "${CERALIVE_IMAGE_APT_SOURCE:-}" == 1 ]]; }

image_apt_source_finalize() {
  image_apt_source_enabled || return 0
  local root="${IMAGE_APT_ROOT:-}" uri keyring_tmp version board arch host suite emergency names name
  version="${CERALIVE_OS_RELEASE_VERSION:-}"
  board="${CERALIVE_BOARD:-}"
  [[ "$version" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]] || { image_apt_die "CERALIVE_OS_RELEASE_VERSION must be YYYY.M.N, got '${version}'"; return 1; }
  [[ "$board" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || { image_apt_die "CERALIVE_BOARD is not a board id: '${board}'"; return 1; }
  uri="$(printf '%s' "${CERALIVE_IMAGE_APT_URI_B64:-}" | base64 -d 2>/dev/null)" || { image_apt_die 'CERALIVE_IMAGE_APT_URI_B64 does not decode'; return 1; }
  [[ "$uri" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._~/-]*/$ ]] || { image_apt_die 'the apt base must be an https URL ending in / (no query, fragment or credentials)'; return 1; }
  host="$(image_apt_host_of "$uri")"
  arch="${IMAGE_APT_ARCH:-$(dpkg --print-architecture)}"
  suite="${board}-${version}"
  emergency="${suite}-emergency"

  names="$(printf '%s' "${CERALIVE_FIRST_PARTY_NAMES_B64:-}" | base64 -d 2>/dev/null)" || { image_apt_die 'first-party names do not decode'; return 1; }
  # shellcheck source=mkosi/runtime/first-party-origin-policy.sh
  source "${BASH_SOURCE[0]%/*}/first-party-origin-policy.sh"
  validate_first_party_names "$names" || { image_apt_die 'first-party names differ from the independent authority'; return 1; }

  mkdir -p "${root}/etc/apt/sources.list.d" "${root}/etc/apt/preferences.d" "${root}/usr/share/keyrings" "${root}/usr/lib/ceralive"
  keyring_tmp="$(mktemp "${root}/usr/share/keyrings/.openstreambox.XXXXXXXX")"
  if ! printf '%s' "${CERALIVE_IMAGE_APT_KEYRING_B64:-}" | base64 -d >"$keyring_tmp" 2>/dev/null || [[ ! -s "$keyring_tmp" ]]; then
    rm -f -- "$keyring_tmp"; image_apt_die 'CERALIVE_IMAGE_APT_KEYRING_B64 is empty or does not decode'; return 1
  fi
  chmod 0644 "$keyring_tmp"
  mv -f -- "$keyring_tmp" "${root}/usr/share/keyrings/openstreambox-archive-keyring.pgp"

  # Every source the build used goes; exactly one is written.
  rm -f -- "${root}/etc/apt/sources.list"
  find "${root}/etc/apt/sources.list.d" -mindepth 1 -maxdepth 1 \( -name '*.list' -o -name '*.sources' \) -delete
  cat >"${root}/etc/apt/sources.list.d/openstreambox.sources" <<EOF
Types: deb
URIs: ${uri}
Suites: ${suite} ${emergency}
Components: main
Architectures: ${arch}
Signed-By: /usr/share/keyrings/openstreambox-archive-keyring.pgp
EOF
  chmod 0644 "${root}/etc/apt/sources.list.d/openstreambox.sources"
  # apt itself reads only this file: a source added later (by hand, or by an older
  # device UI) is never fetched or installed from, for every apt client on the box.
  mkdir -p "${root}/etc/apt/apt.conf.d"
  cat >"${root}/etc/apt/apt.conf.d/10openstreambox-source" <<'EOF2'
// Single image apt source (runtime/image-apt-source.sh): no other source is read.
Dir::Etc::SourceList "/etc/apt/sources.list.d/openstreambox.sources";
Dir::Etc::SourceParts "/dev/null";
EOF2
  chmod 0644 "${root}/etc/apt/apt.conf.d/10openstreambox-source"

  rm -f -- "${root}/etc/apt/preferences.d/ceralive-origin" "${root}/etc/apt/preferences.d/ceralive-local-override"
  {
    printf '# Single image apt source (runtime/image-apt-source.sh). Generated; never edited on the device.\n'
    printf '# Packages come only from %s; installed versions keep priority 100; any other source is refused.\n' "$host"
    for name in "${FIRST_PARTY_NAMES[@]}"; do
      [[ " ${IMAGE_APT_UNSERVED_NAMES[*]} " == *" ${name} "* ]] && continue
      printf '\nPackage: %s\nPin: origin "%s"\nPin-Priority: 990\n' "$name" "$host"
    done
    printf '\nPackage: *\nPin: origin "%s"\nPin-Priority: 500\n' "$host"
    printf '\nPackage: *\nPin: release a=now\nPin-Priority: 100\n'
    printf '\nPackage: *\nPin: release *\nPin-Priority: -1\n'
  } >"${root}/etc/apt/preferences.d/openstreambox-origin"
  chmod 0644 "${root}/etc/apt/preferences.d/openstreambox-origin"

  cat >"${root}/usr/lib/ceralive/image-apt-source.json" <<EOF
{"schema":1,"sourcesFile":"/etc/apt/sources.list.d/openstreambox.sources","host":"${host}","origin":"OpenStreamBox","label":"OpenStreamBox","suites":["${suite}","${emergency}"]}
EOF
  chmod 0644 "${root}/usr/lib/ceralive/image-apt-source.json"
  image_apt_source_assert || return 1
  printf 'image-apt-source: one source, %s suites %s and %s\n' "$host" "$suite" "$emergency" >&2
}

# The shipped tree has exactly the one source and the generated pins, nothing else.
image_apt_source_assert() {
  image_apt_source_enabled || return 0
  local root="${IMAGE_APT_ROOT:-}" d f count=0 legacy
  d="${root}/etc/apt/sources.list.d"
  [[ ! -e "${root}/etc/apt/sources.list" ]] || { image_apt_die 'sources.list is present'; return 1; }
  for f in "$d"/*; do
    [[ -e "$f" ]] || continue
    case "${f##*/}" in
      openstreambox.sources) count=$((count + 1)) ;;
      *.list|*.sources) image_apt_die "unexpected apt source ${f##*/}"; return 1 ;;
    esac
  done
  ((count == 1)) || { image_apt_die 'openstreambox.sources is missing'; return 1; }
  legacy="$(grep -rlE '^[[:space:]]*deb(-src)?[[:space:]]' "$d" 2>/dev/null || true)"
  [[ -z "$legacy" ]] || { image_apt_die "one-line deb entries in ${legacy//$'\n'/, }"; return 1; }
  [[ "$(grep -c '^Types: ' "$d/openstreambox.sources")" == 1 && "$(grep -c '^URIs: ' "$d/openstreambox.sources")" == 1 ]] \
    || { image_apt_die 'openstreambox.sources must hold exactly one stanza'; return 1; }
  for f in ceralive-origin ceralive-local-override; do
    [[ ! -e "${root}/etc/apt/preferences.d/${f}" ]] || { image_apt_die "legacy pin ${f} is still present"; return 1; }
  done
  [[ -s "${root}/etc/apt/preferences.d/openstreambox-origin" && -s "${root}/usr/share/keyrings/openstreambox-archive-keyring.pgp" ]] \
    || { image_apt_die 'pin file or keyring missing'; return 1; }
  if ! grep -Fxq 'Dir::Etc::SourceList "/etc/apt/sources.list.d/openstreambox.sources";' "${root}/etc/apt/apt.conf.d/10openstreambox-source" 2>/dev/null \
     || ! grep -Fxq 'Dir::Etc::SourceParts "/dev/null";' "${root}/etc/apt/apt.conf.d/10openstreambox-source"; then
    image_apt_die 'apt is not restricted to the one source file'; return 1
  fi
  if grep -rhsE '^[[:space:]]*Dir::Etc::(SourceList|SourceParts|sourcelist|sourceparts)' "${root}/etc/apt/apt.conf.d" \
       | grep -vqE '^Dir::Etc::Source(List "/etc/apt/sources.list.d/openstreambox.sources"|Parts "/dev/null");$'; then
    image_apt_die 'another apt.conf file redirects the source list'; return 1
  fi
}

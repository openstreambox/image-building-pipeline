#!/usr/bin/env bash
#
# postinst.d/remote-access.sh — opt-in remote access for release images.
#
# Sourced by customize/postinst-lib.sh (never executed). Three independent,
# build-time switches, all off by default so upstream images are unchanged
# (lib/release-remote-access.sh validates them on the build host):
#
#   CERALIVE_TAILSCALE=1
#       Install pinned Tailscale binaries (runtime/remote-access/tailscale.recipe.conf),
#       our tailscaled.service (userspace networking, inert until enrolled) and
#       the BOOT key-file enrollment service + timer. Its state lives on /data
#       (persistence.sh adds the /var/lib/tailscale bind for this flag).
#       tailscaled runs as the ceralive-tailscale account; its loopback re-dials
#       are limited to the CeraUI backend and DNS (tailscaled-loopback.nft,
#       matched by socket owner); auto-update is pinned off. Tailscale SSH
#       sessions run as that account and reach root with sudo.
#   CERALIVE_SSH_ROOT_KEYS_B64
#       Public keys seeded once into root's persistent authorized_keys store by
#       ceralive-ssh-key-seed.service. The once-flag means a rotated key does not
#       arrive by OTA: rotate through Tailscale SSH (edit the store on /data).
#   CERALIVE_SSH_PASSWORD_AUTH=no
#       sshd drop-in 05-ceralive-key-only.conf: keys only, no passwords.
#
# Test seams: TAILSCALE_RECIPE, TAILSCALE_ARCH, TAILSCALE_LOCAL_TARBALL,
# REMOTE_ACCESS_DESTROOT (install prefix; empty in the chroot).
#
# CHROOT-SAFE STANDALONE: carries its own log()/die() fallbacks like every module.
#
# shellcheck shell=bash

if ! declare -F log >/dev/null 2>&1; then
  log() { printf '[runtime-lib] %s\n' "$*" >&2; }
fi
if ! declare -F die >/dev/null 2>&1; then
  die() { log "FATAL: $*"; exit 1; }
fi

install_tailscale_binaries() {
  local src="$1" dest="$2"
  local recipe="${TAILSCALE_RECIPE:-${src}/tailscale.recipe.conf}"
  [[ -f "${recipe}" ]] || die "tailscale recipe not found: ${recipe}"
  local TAILSCALE_VERSION="" TAILSCALE_URL_TEMPLATE=""
  # shellcheck source=/dev/null
  source "${recipe}"
  [[ "${TAILSCALE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "${recipe}: TAILSCALE_VERSION must be X.Y.Z"
  [[ -n "${TAILSCALE_URL_TEMPLATE}" ]] || die "${recipe}: TAILSCALE_URL_TEMPLATE is required"
  local arch="${TAILSCALE_ARCH:-}"
  [[ -n "${arch}" ]] || arch="$(dpkg --print-architecture)"
  case "${arch}" in amd64 | arm64) ;; *) die "unsupported architecture for Tailscale: '${arch}'" ;; esac
  local sha_var="TAILSCALE_SHA256_${arch}"
  local expected="${!sha_var:-}"
  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || die "${recipe}: missing ${sha_var} pin"

  local tmp tarball actual dir
  tmp="$(mktemp -d)"
  tarball="${tmp}/tailscale.tgz"
  if [[ -n "${TAILSCALE_LOCAL_TARBALL:-}" ]]; then
    cp "${TAILSCALE_LOCAL_TARBALL}" "${tarball}" || { rm -rf "${tmp}"; die "TAILSCALE_LOCAL_TARBALL unreadable"; }
  else
    local url="${TAILSCALE_URL_TEMPLATE//\{ver\}/${TAILSCALE_VERSION}}"
    url="${url//\{arch\}/${arch}}"
    log "fetching Tailscale ${TAILSCALE_VERSION} (${arch}) from ${url}"
    curl -fsSL --retry 3 --retry-all-errors -o "${tarball}" "${url}" \
      || { rm -rf "${tmp}"; die "Tailscale fetch failed: ${url}"; }
  fi
  actual="$(sha256sum "${tarball}" | awk '{print $1}')"
  if [[ "${actual}" != "${expected}" ]]; then
    rm -rf "${tmp}"
    die "Tailscale ${TAILSCALE_VERSION} (${arch}) sha256 MISMATCH, build fails closed: expected=${expected} actual=${actual}"
  fi
  dir="tailscale_${TAILSCALE_VERSION}_${arch}"
  tar -xzf "${tarball}" -C "${tmp}" "${dir}/tailscale" "${dir}/tailscaled" \
    || { rm -rf "${tmp}"; die "Tailscale tarball lacks ${dir}/tailscale{,d}"; }
  install -D -m 0755 "${tmp}/${dir}/tailscaled" "${dest}/usr/local/sbin/tailscaled"
  install -D -m 0755 "${tmp}/${dir}/tailscale" "${dest}/usr/local/bin/tailscale"
  rm -rf "${tmp}"
  log "Tailscale ${TAILSCALE_VERSION} (${arch}) installed, sha256 ${actual}"
}

setup_remote_access() {
  local src="${CERALIVE_RUNTIME_SRC:-}/remote-access" dest="${REMOTE_ACCESS_DESTROOT:-}"
  local tailscale="${CERALIVE_TAILSCALE:-0}" keys="${CERALIVE_SSH_ROOT_KEYS_B64:-}"
  local password_auth="${CERALIVE_SSH_PASSWORD_AUTH:-}"
  if [[ "${tailscale}" != 1 && -z "${keys}" && -z "${password_auth}" ]]; then
    log "no remote-access options (upstream SSH defaults, no Tailscale)"
    return 0
  fi
  [[ -n "${CERALIVE_RUNTIME_SRC:-}" && -d "${src}" ]] || die "remote-access sources not found: ${src}"

  if [[ "${tailscale}" == 1 ]]; then
    # Enrollment reads the key file from the FAT partition mounted at /boot,
    # which only the arm64 board layout has (x86 mounts its ESP at /boot/efi).
    local target_arch="${TAILSCALE_ARCH:-}"
    [[ -n "${target_arch}" ]] || target_arch="$(dpkg --print-architecture)"
    [[ "${target_arch}" == arm64 ]] \
      || die "CERALIVE_TAILSCALE=1 needs the arm64 board layout (FAT /boot for key-file enrollment), not '${target_arch}'"
    install_tailscale_binaries "${src}" "${dest}"
    install -D -m 0644 "${src}/tailscaled.service" "${dest}/etc/systemd/system/tailscaled.service"
    install -D -m 0644 "${src}/tailscaled-loopback.nft" "${dest}/usr/lib/ceralive/tailscaled-loopback.nft"
    # tailscaled's own account (the loopback allowlist matches it by uid) and the
    # sudo rule that turns its Tailscale SSH sessions into root for admins.
    install -D -m 0644 "${src}/ceralive-tailscale.sysusers.conf" "${dest}/usr/lib/sysusers.d/ceralive-tailscale.conf"
    systemd-sysusers --root="${dest:-/}" "${dest}/usr/lib/sysusers.d/ceralive-tailscale.conf" \
      || die "could not create the ceralive-tailscale account"
    install -D -m 0440 "${src}/ceralive-tailscale.sudoers" "${dest}/etc/sudoers.d/ceralive-tailscale"
    if command -v visudo >/dev/null 2>&1; then
      visudo -c -q -f "${dest}/etc/sudoers.d/ceralive-tailscale" || die "sudoers drop-in does not parse"
    fi
    install -D -m 0755 "${src}/ceralive-tailscale-enroll.sh" "${dest}/usr/local/sbin/ceralive-tailscale-enroll"
    install -D -m 0644 "${src}/ceralive-tailscale-enroll.service" "${dest}/etc/systemd/system/ceralive-tailscale-enroll.service"
    install -D -m 0644 "${src}/ceralive-tailscale-enroll.timer" "${dest}/etc/systemd/system/ceralive-tailscale-enroll.timer"
    # Mountpoint for the /data/tailscale bind (persistence.sh).
    install -d -m 0700 "${dest}/var/lib/tailscale"
    enable_service tailscaled.service
    enable_service ceralive-tailscale-enroll.timer
  elif [[ "${tailscale}" != 0 ]]; then
    die "CERALIVE_TAILSCALE must be 0 or 1, got '${tailscale}'"
  fi

  if [[ -n "${keys}" ]]; then
    install -d -m 0755 "${dest}/usr/share/ceralive/ssh"
    printf '%s' "${keys}" | base64 -d >"${dest}/usr/share/ceralive/ssh/root_authorized_keys.seed" \
      || die "CERALIVE_SSH_ROOT_KEYS_B64 is not base64"
    chmod 0644 "${dest}/usr/share/ceralive/ssh/root_authorized_keys.seed"
    if grep -q 'PRIVATE KEY' "${dest}/usr/share/ceralive/ssh/root_authorized_keys.seed"; then
      die "SSH key seed contains a private key"
    fi
    install -D -m 0755 "${src}/ceralive-ssh-key-seed.sh" "${dest}/usr/local/sbin/ceralive-ssh-key-seed"
    install -D -m 0644 "${src}/ceralive-ssh-key-seed.service" "${dest}/etc/systemd/system/ceralive-ssh-key-seed.service"
    enable_service ceralive-ssh-key-seed.service
  fi

  case "${password_auth}" in
    "") ;;
    no) install -D -m 0644 "${src}/05-ceralive-key-only.conf" "${dest}/etc/ssh/sshd_config.d/05-ceralive-key-only.conf" ;;
    *) die "CERALIVE_SSH_PASSWORD_AUTH must be empty or 'no', got '${password_auth}'" ;;
  esac
  log "remote access configured (tailscale=${tailscale}, seeded keys=$([[ -n "${keys}" ]] && echo yes || echo no), password auth=${password_auth:-default})"
}

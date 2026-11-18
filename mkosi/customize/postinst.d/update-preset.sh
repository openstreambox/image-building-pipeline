#!/usr/bin/env bash
#
# postinst.d/update-preset.sh — factory update-channel preset (release builds).
#
# Sourced by customize/postinst-lib.sh (never executed). Writes the two CeraUI
# update preference files that lib/release-preset.sh validated on the build
# host and forwarded base64:
#   CERALIVE_UPDATE_PRESET_SETTINGS_B64 -> /opt/ceralive/update-settings.json
#   CERALIVE_UPDATE_PRESET_CHANNEL_B64  -> /opt/ceralive/update-image-channel.json
# ceralive-migrate-data copies /opt/ceralive/*.json onto /data on first boot only
# (never over an existing file), so these are factory defaults: a later OTA slot
# carrying different presets does not change a box's saved choices.
# Both empty is the normal (upstream) build and a no-op; exactly one is an error.
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

setup_update_preset() {
  local settings="${CERALIVE_UPDATE_PRESET_SETTINGS_B64:-}" channel="${CERALIVE_UPDATE_PRESET_CHANNEL_B64:-}"
  local dir="${CERALIVE_UPDATE_PRESET_ROOT:-}/opt/ceralive" name
  if [[ -z "${settings}" && -z "${channel}" ]]; then
    log "no update-channel preset (factory update defaults)"
    return 0
  fi
  [[ -n "${settings}" && -n "${channel}" ]] \
    || die "update preset: both update-settings and update-image-channel are required, got one"
  install -d -m 0755 "${dir}"
  for name in update-settings.json update-image-channel.json; do
    [[ ! -L "${dir}/${name}" ]] || die "update preset: ${dir}/${name} is a symlink"
  done
  printf '%s' "${settings}" | base64 -d >"${dir}/update-settings.json.tmp" \
    || die "update preset: update-settings payload is not base64"
  printf '%s' "${channel}" | base64 -d >"${dir}/update-image-channel.json.tmp" \
    || die "update preset: update-image-channel payload is not base64"
  for name in update-settings.json update-image-channel.json; do
    grep -q '^{' "${dir}/${name}.tmp" || die "update preset: ${name} is not a JSON object"
    # CeraUI refuses preference files that are group/world-writable or owned by
    # another non-root user; root 0644 is what its strict reader accepts.
    if [[ "${EUID}" -eq 0 ]]; then chown 0:0 "${dir}/${name}.tmp"; fi
    chmod 0644 "${dir}/${name}.tmp"
    mv -f "${dir}/${name}.tmp" "${dir}/${name}"
  done
  log "update-channel preset installed in ${dir} (seeded to /data on first boot)"
}

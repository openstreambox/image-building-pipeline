#!/usr/bin/env bash
#
# postinst.d/update-preset.sh — factory update-channel preset (release builds).
#
# Sourced by customize/postinst-lib.sh (never executed). Writes the two CeraUI
# update preference files that lib/release-preset.sh validated on the build
# host and forwarded base64:
#   CERALIVE_UPDATE_PRESET_SETTINGS_B64 -> /opt/ceralive/update-settings.json
#   CERALIVE_UPDATE_PRESET_CHANNEL_B64  -> /opt/ceralive/update-image-channel.json
# ceralive-migrate-data seeds the two files onto /data as one pair, and only
# when /data has neither (postinst.d/persistence.sh). It never overwrites them, so
# they are factory defaults: a box that already saved update settings, or a later
# OTA slot carrying a different preset, keeps the box's own choices. A box that
# never saved update settings picks the preset up on the boot after an OTA.
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
    # Content was validated on the build host (lib/release-preset.sh); this only
    # guards against an empty or truncated payload.
    [[ -s "${dir}/${name}.tmp" ]] || die "update preset: ${name} payload is empty"
    # root 0644: ceralive.service runs as root, cp -a in ceralive-migrate-data
    # keeps the mode, and CeraUI's later saves keep it.
    if [[ "${EUID}" -eq 0 ]]; then chown 0:0 "${dir}/${name}.tmp"; fi
    chmod 0644 "${dir}/${name}.tmp"
    mv -f "${dir}/${name}.tmp" "${dir}/${name}"
  done
  log "update-channel preset installed in ${dir} (seeded to /data on first boot)"
}

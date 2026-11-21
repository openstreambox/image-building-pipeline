#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154

stage_packages_lock() {
  local output="${out_dir}/${ts}.packages.lock.json"
  log_info "[6d/9] reconciling final dpkg status with verified package receipts -> ${output}"
  python3 "${HERE}/packages-lock.py" merge "${rootfs_tree}" "${staging}" "${output}" \
    "${SOURCE_DATE_EPOCH}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${KERNEL_SOURCE_COMMIT:-}" "${KERNEL_SOURCE_PATCHES_COMMIT:-}" \
    || die "package lock INCOMPLETE for board '${board}' — no artifact may be assembled"
  log_success "[6d/9] package lock: ${output}"
}

stage_image_sbom() {
  [[ -n "${CERALIVE_DEBIAN_SNAPSHOT:-}" ]] || return 0
  local stem="${out_dir}/${ts}" boot_blobs="" mediamtx_version
  local -a payload_args=() checksums=(--artifact "${artifact}.sha256")
  if [[ -n "${1:-}" ]]; then
    payload_args=(--boot-payload "$1")
  fi
  if [[ "${INSTALL_BOOT_BSP}" == "1" ]]; then
    checksums+=(--artifact "${stem}.raw.sha256" --artifact "${stem}.raw.xz.sha256"
                --artifact "${stem}.raucb.sha256")
    if [[ "${RAUC_BOOTLOADER_ADAPTER}" == "custom" ]]; then
      # The disk writer already verified these hashes against the written gap.
      boot_blobs="$("${WRITE_BOOTLOADER_SH:-${HERE}/write-bootloader.sh}" plan \
        --board "${BOARD_ID}" --variant "${KERNEL_VARIANT:-${variant}}")" \
        || die "cannot inventory raw-gap bootloader"
    fi
  fi
  mediamtx_version="$(sed -n 's/^MEDIAMTX_VERSION=//p' \
    "${MKOSI_DIR}/runtime/rtmp-gateway/mediamtx.recipe.conf")"
  [[ -n "${mediamtx_version}" ]] || die "missing MediaMTX version"
  python3 "${HERE}/image-sbom.py" emit \
    --root "${rootfs_tree}" --lock "${stem}.packages.lock.json" \
    --board "${board}" --snapshot "${CERALIVE_DEBIAN_SNAPSHOT}" \
    --image-version "${CERALIVE_OS_RELEASE_VERSION:-${build_version}}" \
    --mediamtx-version "${mediamtx_version}" --boot-blobs "${boot_blobs}" \
    --debian-suite "${APT_SUITE}" --armbian-suite "${ARMBIAN_SUITE}" \
    --userspace-pins "${RK3588_USERSPACE_DEB_VERSIONS_FILE:-${PIPELINE_DIR}/manifests/rk3588-userspace-deb-versions.txt}" \
    --kernel-release "${KERNEL_SOURCE_KERNEL_RELEASE:-}" "${payload_args[@]}" \
    "${checksums[@]}" --output "${stem}.sbom.cdx.json" || return 1
  log_success "image SBOM: ${stem}.sbom.cdx.json"
}

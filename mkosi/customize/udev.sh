#!/usr/bin/env bash
#
# customize/udev.sh — hardware-access udev rules for the streaming appliance.
#
# DECOMPOSED FROM (UNION) the two v1 sources, both since deleted: the
# customize-image.sh setup_hardware_access() hook AND a standalone udev-rules
# script. v1 only ever wrote the SHORT rule set from the hook; the standalone
# script held the richer vendor / DRM / QMI-MBIM / netdev policy but was never
# invoked by any build path. v2 folds both into ONE canonical, deduplicated
# rules file so the comprehensive policy actually ships.
#
# UNIFIED NAMING: file 99-ceraui-hardware.rules / 99-ceraui-devices.rules →
# 99-ceralive-hardware.rules. The dangling SYSTEMD_WANTS=ceralive-optimize@%k
# want was removed: no such unit ships in the image (the rule was a permanent
# no-op pointing at a never-provided template unit).
#
# CONTRACT: sourced by run-all.sh (chroot context). Strict; no `|| true`.
#
# shellcheck shell=bash

set -euo pipefail

# shellcheck source=../../lib/common.sh
source "${CERALIVE_COMMON_SH:-"$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"}"

# shellcheck source=postinst-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/postinst-lib.sh"
# The fastboot release payload is installed from mkosi/runtime/, as services.sh does.
CERALIVE_RUNTIME_SRC="${CERALIVE_RUNTIME_SRC:-$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/../runtime" 2>/dev/null && pwd)}"
export CERALIVE_RUNTIME_SRC

setup_hardware_access() {
  log_info "installing udev hardware-access rules (99-ceralive-hardware.rules)"
  mkdir -p /etc/udev/rules.d

  cat >/etc/udev/rules.d/99-ceralive-hardware.rules <<'EOF'
# CeraLive Hardware Access Rules
# Union of the two retired v1 sources: the customize-image.sh
# setup_hardware_access() hook + the standalone udev-rules script.

# =============================================================================
# USB Audio Devices
# =============================================================================
SUBSYSTEM=="sound", GROUP="audio", MODE="0664"
KERNEL=="controlC[0-9]*", GROUP="audio", MODE="0664"
KERNEL=="hwC[0-9]*D[0-9]*", GROUP="audio", MODE="0664"
KERNEL=="midiC[0-9]*D[0-9]*", GROUP="audio", MODE="0664"
SUBSYSTEMS=="usb", ATTRS{bInterfaceClass}=="01", ATTRS{bInterfaceSubClass}=="01", GROUP="audio", MODE="0664"
SUBSYSTEMS=="usb", ATTRS{bInterfaceClass}=="01", ATTRS{bInterfaceSubClass}=="02", GROUP="audio", MODE="0664"

# =============================================================================
# USB Video Devices (webcams, capture cards)
# =============================================================================
SUBSYSTEM=="video4linux", GROUP="video", MODE="0664"
KERNEL=="video[0-9]*", GROUP="video", MODE="0664"
SUBSYSTEMS=="usb", ATTRS{bInterfaceClass}=="0e", ATTRS{bInterfaceSubClass}=="01", GROUP="video", MODE="0664"
ATTRS{idVendor}=="1bcf", GROUP="video", MODE="0664"
ATTRS{idVendor}=="0c45", GROUP="video", MODE="0664"
ATTRS{idVendor}=="046d", GROUP="video", MODE="0664"
ATTRS{idVendor}=="1e4e", GROUP="video", MODE="0664"
ATTRS{idVendor}=="05ac", GROUP="video", MODE="0664"

# =============================================================================
# HDMI Input Capture (RK3588) + DRM render nodes
# =============================================================================
KERNEL=="video0", SUBSYSTEM=="video4linux", ATTRS{name}=="rk_hdmirx", GROUP="video", MODE="0664"
KERNEL=="video*", SUBSYSTEM=="video4linux", ATTRS{name}=="*hdmi*", GROUP="video", MODE="0664"
# Stable, collision-proof name for the SoC HDMI-IN capture node. Matched on the
# parent platform DRIVER name (never the /dev/videoN index), so it survives a USB
# capture card grabbing video0 and re-enumerating the HDMI-RX to a higher index —
# the enumeration-order conflict the bare node index cannot avoid. /dev/hdmirx
# also matches cerastream's canonical default HDMI device string.
#
# BOTH driver spellings are matched: the Rockchip vendor BSP names this driver
# `rk_hdmirx`, mainline (the `edge` variant) names the same IP block's upstream
# Synopsys driver `snps_hdmirx`. Board-confirmed on 7.1.5 — an rk_hdmirx-only
# rule produces no symlink there. Keep this in lockstep with the live twin in
# mkosi.images/runtime/mkosi.postinst.chroot::setup_hardware_access.
KERNEL=="video[0-9]*", SUBSYSTEM=="video4linux", DRIVERS=="rk_hdmirx|snps_hdmirx", SYMLINK+="hdmi-in", SYMLINK+="hdmirx"
KERNEL=="card[0-9]*", SUBSYSTEM=="drm", GROUP="video", MODE="0664"
KERNEL=="renderD[0-9]*", SUBSYSTEM=="drm", GROUP="video", MODE="0664"

# =============================================================================
# USB Modem Devices (4G/5G)
# =============================================================================
KERNEL=="ttyUSB[0-9]*", GROUP="dialout", MODE="0664"
KERNEL=="ttyACM[0-9]*", GROUP="dialout", MODE="0664"
KERNEL=="cdc-wdm[0-9]*", GROUP="dialout", MODE="0664"
KERNEL=="wwan[0-9]*", GROUP="dialout", MODE="0664"
SUBSYSTEM=="usb", ATTRS{bInterfaceClass}=="02", ATTRS{bInterfaceSubClass}=="02", GROUP="dialout", MODE="0664"
# Common modem vendors by USB ID (Quectel / Sierra / Huawei / ZTE / Telit)
ATTRS{idVendor}=="2c7c", GROUP="dialout", MODE="0664"
ATTRS{idVendor}=="1199", GROUP="dialout", MODE="0664"
ATTRS{idVendor}=="12d1", GROUP="dialout", MODE="0664"
ATTRS{idVendor}=="19d2", GROUP="dialout", MODE="0664"
ATTRS{idVendor}=="1bc7", GROUP="dialout", MODE="0664"
# USB Mass Storage mode (modems before mode-switching)
SUBSYSTEM=="usb", ATTR{bDeviceClass}=="08", GROUP="plugdev", MODE="0664"

# =============================================================================
# Network Interface Management
# =============================================================================
KERNEL=="eth[0-9]*", GROUP="netdev", MODE="0664"
KERNEL=="wlan[0-9]*", GROUP="netdev", MODE="0664"
KERNEL=="usb[0-9]*", GROUP="netdev", MODE="0664"

# =============================================================================
# GPIO / I2C / SPI (RK3588)
# =============================================================================
SUBSYSTEM=="gpio", GROUP="gpio", MODE="0664"
KERNEL=="gpiochip*", GROUP="gpio", MODE="0664"
KERNEL=="i2c-[0-9]*", GROUP="i2c", MODE="0664"
KERNEL=="spidev[0-9]*", GROUP="spi", MODE="0664"

# =============================================================================
# Streaming optimization + CeraLive user device permissions
# =============================================================================
KERNEL=="video[0-9]*", ATTR{name}=="*", RUN+="/bin/sh -c 'echo 8 > /sys/class/video4linux/%k/device/video_buffers'"
KERNEL=="video[0-9]*", RUN+="/bin/chmod g+rw /dev/%k"
KERNEL=="audio[0-9]*", RUN+="/bin/chmod g+rw /dev/%k"
KERNEL=="ttyUSB[0-9]*", RUN+="/bin/chmod g+rw /dev/%k"
KERNEL=="ttyACM[0-9]*", RUN+="/bin/chmod g+rw /dev/%k"
EOF

  log_success "udev hardware-access rules installed"
}


setup_hardware_access "$@"
generate_modem_slot_uid_rules "$@"
setup_internal_modem_rfkill
setup_internal_modem_fastboot_release

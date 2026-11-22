#!/usr/bin/env bash
set -euo pipefail

tag="$1" commit="$2" fragment="$3" dtb="$4" jobs="$5"
# shellcheck source=lib/kernel/checkout.sh
source /pipeline/lib/kernel/checkout.sh
fetch_pinned_tree /work/kernel https://github.com/torvalds/linux.git "$tag" "$commit" "companion kernel" /kernel-mirror
cd /work/kernel
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION=-zero3w
export KBUILD_BUILD_USER=builder KBUILD_BUILD_HOST=builder KBUILD_BUILD_VERSION=1
KBUILD_BUILD_TIMESTAMP="@$(git show -s --format=%ct HEAD)"
export KBUILD_BUILD_TIMESTAMP

make defconfig
scripts/kconfig/merge_config.sh -m .config "/pipeline/$fragment"
make olddefconfig
bash /pipeline/lib/verify-kernel-config.sh "/pipeline/$fragment" .config
for function in ACM NCM UAC2 HID; do
  grep -Fxq "CONFIG_USB_F_${function}=m" .config
done
printf '\n&usb_host0_xhci {\n\tdr_mode = "peripheral";\n\tmaximum-speed = "high-speed";\n\tphys = <&usb2phy0_otg>;\n\tphy-names = "usb2-phy";\n};\n' \
  >> "arch/arm64/boot/dts/rockchip/${dtb%.dtb}.dts"
make -j "$jobs" Image "rockchip/$dtb" modules
make INSTALL_MOD_PATH=/work/modules INSTALL_MOD_STRIP=1 modules_install
# kbuild installs a host-only source-tree link alongside the modules.
unlink "/work/modules/lib/modules/$(make -s kernelrelease)/build"

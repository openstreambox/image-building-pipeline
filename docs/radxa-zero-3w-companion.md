# Radxa ZERO 3W companion image

`./build radxa-zero-3w` builds a Debian SD image for the wired USB companion.
Set `ARMBIAN_APT_KEYRING` to the pinned Armbian archive keyring and
`CERALIVE_COMPANION_SSH_KEY` to an Ed25519 OpenSSH public key. Build on Linux
with Docker, arm64 binfmt support, passwordless sudo and the pipeline's
normal disk assembly tools, plus `fdtget` from device-tree-compiler. The
image and the SHA-256 files are written under `images/radxa-zero-3w/`.
Set `CERALIVE_KERNEL_SRC_MIRROR_DIR` to reuse a local Git mirror that
contains the pinned kernel commit.

USB-C 1 is the power inlet and the peripheral port. It presents CDC NCM and
CDC ACM at USB 2.0 speed. Configure the host's NCM link for IPv4 link-local
and connect as `root@169.254.77.1` using the supplied key. The serial
login prompt uses `ttyGS0`. The root password is locked at build time.
The board's debug UART uses 1500000 8N1. USB-C 2 stays a host port.

The SD image keeps the Rockchip GPT layout and boots slot A. The wired
userspace starts NetworkManager, SSH and the gadget service. The kernel
includes UAC2 and HID gadget modules for later companion work. The first
image ships without Wi-Fi or Bluetooth.

For onboard Wi-Fi in a later image, verify the SDIO ID first. Radxa
publishes the AIC8800 SDIO DKMS driver under GPL-2.0. Review the separate
firmware redistribution terms before packaging. Pin the firmware and
driver together, rebuild against each kernel update and test station and
AP operation on the board. A USB adapter with an in-tree driver avoids
the DKMS rebuild and uses the USB-C 2 port or a powered hub. [Radxa driver
and firmware releases](https://github.com/radxa-pkg/aic8800/releases)

For a userspace smoke test, extract `/boot/Image` from slot A and boot it
with `qemu-system-aarch64 -M virt -cpu cortex-a53 -m 1024`, a snapshot of
the raw image attached as `virtio-blk-device`, and
`-append 'root=/dev/vda2 rootwait rw console=ttyAMA0'`. The gadget service
should skip when the virtual board has no UDC. Rockchip BootROM, U-Boot,
the board DTB, power and USB link enumeration require the physical board.

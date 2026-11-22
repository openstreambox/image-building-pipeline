#!/usr/bin/env bash
set -euo pipefail

image="$1" work="$2" dtb="$3"
lib/verify-disk.sh do_verify "$image" radxa-zero3
lib/write-bootloader.sh verify --image "$image"
blob="$(awk -F '\t' '$1=="radxa-zero3" && $2=="default" {print $6}' manifests/bootloader-blobs.tsv)"
bsp_debs=("$work"/bsp/linux-u-boot-radxa-zero3-edge_*.deb)
dpkg-deb -x "${bsp_debs[0]}" "$work/loader"
loader="$work/loader/usr/lib/linux-u-boot-edge-radxa-zero3/u-boot-rockchip.bin"
readback="$(dd if="$image" iflag=skip_bytes,count_bytes skip=32768 count="$(stat -c %s "$loader")" status=none | sha256sum)"
[[ "${readback%% *}" == "$blob" ]]
printf 'Verified unified U-Boot at sector 64: %s\n' "$blob"

boot="$image@@$((32768 * 512))"
mtype -i "$boot" ::cera_board.env > "$work/board.env"
grep -Fx "fdtfile=$dtb" "$work/board.env"
mcopy -i "$boot" ::boot.scr "$work/boot.scr"
dumpimage -T script -p 0 -o "$work/boot.cmd" "$work/boot.scr"
grep -F 'part uuid ${devtype} ${devnum}:2' "$work/boot.cmd"
grep -F '/boot/dtb/rockchip/${fdtfile}' "$work/boot.cmd"

labels=(rootfs_a rootfs_b)
for part in 2 3; do
  start="$(sgdisk -i "$part" "$image" | awk '/^First sector:/ {print $3}')"
  slot="$work/slot-$part.ext4"
  dd if="$image" of="$slot" bs=1M iflag=skip_bytes skip="$((start * 512))" count=4096 \
    conv=sparse status=none
  lib/verify-disk.sh check-slot "$slot" "${labels[part - 2]}"
  debugfs -R "dump /boot/dtb/rockchip/$dtb $work/slot-$part.dtb" "$slot"
  # DWC3 at fcc00000 is USB-C 1. The other controller stays a host.
  [[ "$(fdtget "$work/slot-$part.dtb" /usb@fcc00000 dr_mode)" == peripheral ]]
  [[ "$(fdtget "$work/slot-$part.dtb" /usb@fd000000 dr_mode)" == host ]]
  debugfs -R 'cat /usr/libexec/zero3w-gadget' "$slot" | cmp mkosi/companion/zero3w-gadget.sh
  debugfs -R 'cat /etc/systemd/system/zero3w-gadget.service' "$slot" | cmp mkosi/companion/zero3w-gadget.service
  debugfs -R 'cat /etc/NetworkManager/system-connections/zero3w.nmconnection' "$slot" | cmp mkosi/companion/zero3w.nmconnection
  printf 'Verified slot %s DTB roles, NCM/ACM gadget service and network profile\n' "$part"
done

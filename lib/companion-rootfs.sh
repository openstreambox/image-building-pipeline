#!/usr/bin/env bash
set -euo pipefail

root="$1" work="$2" dtb="$3" key="$4"
config=mkosi/companion
boot_source="$work/kernel/arch/arm64/boot"
install -Dm0644 "$boot_source/Image" "$root/boot/Image"
install -Dm0644 "$work/kernel/.config" "$root/boot/config"
install -Dm0644 "$boot_source/dts/rockchip/$dtb" "$root/boot/dtb/rockchip/$dtb"
cp -a "$work/modules/lib/modules" "$root/usr/lib/"
install -Dm0755 "$config/zero3w-gadget.sh" "$root/usr/libexec/zero3w-gadget"
install -Dm0644 "$config/zero3w-gadget.service" "$root/etc/systemd/system/zero3w-gadget.service"
install -Dm0644 "$config/90-zero3w-gadget.rules" "$root/etc/udev/rules.d/90-zero3w-gadget.rules"
install -Dm0600 "$config/zero3w.nmconnection" \
  "$root/etc/NetworkManager/system-connections/zero3w.nmconnection"
install -Dm0644 "$config/sshd.conf" "$root/etc/ssh/sshd_config.d/10-zero3w.conf"
install -Dm0644 "$config/ssh-keygen.conf" "$root/etc/systemd/system/ssh.service.d/10-keygen.conf"
install -dm0700 "$root/root/.ssh"
# Drop the key comment, which may contain an operator or machine name.
awk '{print $1, $2}' "$key" > "$root/root/.ssh/authorized_keys"
chmod 0600 "$root/root/.ssh/authorized_keys"
find "$root/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*' -delete
printf 'zero3w-companion\n' > "$root/etc/hostname"
printf 'LANG=C.UTF-8\n' > "$root/etc/locale.conf"
printf 'tmpfs /tmp tmpfs mode=1777,nosuid,nodev,size=128M 0 0\n' >> "$root/etc/fstab"
# This fixture must finish boot without a display or an operator at a console.
systemctl --root="$root" set-default multi-user.target
systemctl --root="$root" mask ceralive.service cerastream.service \
  pipewire.service pipewire.socket wireplumber.service ceralive-rtmp-gateway.service \
  kiosk.service kiosk-onfailure.service kiosk-osk.service \
  ceralive-fan-curve.service ceralive-fan-kickstart.service \
  ceralive-hdmirx-edid.service ceralive-typec-policy.service rauc.service \
  ceralive-healthcheck.service ceralive-slot-sync.service ssh.socket \
  systemd-firstboot.service systemd-networkd.service systemd-networkd.socket \
  systemd-networkd-wait-online.service
systemctl --root="$root" enable zero3w-gadget.service NetworkManager.service ssh.service

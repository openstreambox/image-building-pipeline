#!/usr/bin/env bash
# Opt-in. Checks the RAUC side of power admission against the RAUC version a
# disposable container provides (e.g. the image's own 1.15.2 package in an
# arm64 container under qemu): systemd is not required, `rauc service` runs on
# the container's system bus with two file-backed slots, a slow post-install
# handler and the image's pre-install handler. Destructive only inside that
# container.
#   1. While an install runs, a competing D-Bus install is rejected; RAUC may
#      then report Operation=idle although the first install is still running,
#      but its bundle stays mounted under /mnt/rauc until it has finished.
#   2. With the power fence present, a direct D-Bus install is refused by the
#      pre-install handler and the target slot is not written.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
container="${CERALIVE_RAUC_TEST_CONTAINER:?Set the disposable container name}"
docker exec "$container" test -f /run/logind-contract-disposable
docker exec -i "$container" install -D -m 0755 /dev/stdin /usr/local/bin/ceralive-pre-install < "$root/mkosi/runtime/rauc/ceralive-pre-install"
docker exec -i "$container" bash -s <<'INNER'
set -euo pipefail
mkdir -p /etc/rauc /var/tmp/rauc /var/tmp/bundle /run/ceralive-power
cd /var/tmp/rauc
[ -f key.pem ] || openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 30 -subj '/CN=test signer' 2>/dev/null
cp cert.pem /etc/rauc/keyring.pem
truncate -s 16M /var/tmp/slot0.img /var/tmp/slot1.img
printf '[update]\ncompatible=power-test\nversion=1\n[bundle]\nformat=plain\n[image.rootfs]\nfilename=rootfs.img\n' > /var/tmp/bundle/manifest.raucm
bundle() { head -c 8M /dev/urandom > /var/tmp/bundle/rootfs.img; local b="/var/tmp/test-$1.raucb"; rauc bundle --cert=cert.pem --key=key.pem /var/tmp/bundle "$b" >/dev/null 2>&1; echo "$b"; }
printf '#!/bin/sh\nsleep 20\n' > /usr/local/bin/slow-post-install; chmod 0755 /usr/local/bin/slow-post-install
printf '[system]\ncompatible=power-test\nbootloader=noop\nbundle-formats=plain\ndata-directory=/var/tmp/rauc/data\n[keyring]\npath=/etc/rauc/keyring.pem\n[handlers]\npre-install=/usr/local/bin/ceralive-pre-install\npost-install=/usr/local/bin/slow-post-install\n[slot.rootfs.0]\ndevice=/var/tmp/slot0.img\ntype=raw\nbootname=A\n[slot.rootfs.1]\ndevice=/var/tmp/slot1.img\ntype=raw\nbootname=B\n' > /etc/rauc/system.conf
pkill -x rauc 2>/dev/null || true; sleep 1
(setsid /usr/bin/rauc service --override-boot-slot=A > /var/tmp/rauc-service.log 2>&1 &)
for _ in $(seq 1 40); do busctl get-property de.pengutronix.rauc / de.pengutronix.rauc.Installer Operation >/dev/null 2>&1 && break; sleep 0.5; done
op() { busctl get-property de.pengutronix.rauc / de.pengutronix.rauc.Installer Operation; }
mounts() { awk '$5 ~ "^/mnt/rauc/" {print $5}' /proc/1/mountinfo | tr '\n' ' '; }
echo "# $(rauc --version)"
first="$(bundle a)"; second="$(bundle b)"
(rauc install "$first" > /var/tmp/install-a.log 2>&1 &)
for _ in $(seq 1 60); do [ "$(op)" = 's "installing"' ] && break; sleep 0.5; done
for _ in $(seq 1 60); do grep -q 'post install handler' /var/tmp/rauc-service.log && break; sleep 0.5; done
busctl call de.pengutronix.rauc / de.pengutronix.rauc.Installer InstallBundle 'sa{sv}' "$second" 0 >/dev/null 2>&1 || true
sleep 1
running="$(pgrep -f "rauc install $first" >/dev/null && echo yes || echo no)"
echo "# after a rejected competing install: Operation=$(op), mounts=[$(mounts)], first install running=$running"
[ "$running" = yes ] && [ -n "$(mounts)" ] || { echo "not ok 1 the running install left no witness"; exit 1; }
echo "ok 1 a running install keeps its bundle mounted even when RAUC reports $(op)"
for _ in $(seq 1 90); do pgrep -f "rauc install $first" >/dev/null || break; sleep 1; done
[ -z "$(mounts)" ] || { echo "not ok 1b mounts left after the install"; exit 1; }
echo "ok 1b the mounts go when the install has finished: $(tail -1 /var/tmp/install-a.log)"
third="$(bundle c)"
before="$(sha256sum /var/tmp/slot1.img | cut -d' ' -f1)"
echo fence > /run/ceralive-power/fence
busctl call de.pengutronix.rauc / de.pengutronix.rauc.Installer InstallBundle 'sa{sv}' "$third" 0 >/dev/null
for _ in $(seq 1 60); do [ "$(op)" = 's "idle"' ] && [ -z "$(mounts)" ] && break; sleep 0.5; done
error="$(busctl get-property de.pengutronix.rauc / de.pengutronix.rauc.Installer LastError)"
after="$(sha256sum /var/tmp/slot1.img | cut -d' ' -f1)"
rm -f /run/ceralive-power/fence
[[ "$error" == *Pre-install* && "$before" = "$after" ]] || { echo "not ok 2 fenced install: $error"; exit 1; }
echo "ok 2 a direct D-Bus install under the power fence is refused before writing ($error); the target slot is unchanged"
INNER

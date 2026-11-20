#!/usr/bin/env bash
# Opt-in. Checks the RAUC side of power admission against the RAUC a disposable
# container provides (e.g. the image's own 1.15.2 package in an arm64 container
# under qemu), with RAUC started through its packaged unit: `--mount=/run/rauc/mnt`
# and MountFlags=slave, so its mounts live in RAUC's own mount namespace. A
# drop-in only adds --override-boot-slot (file-backed slots have no bootloader).
# Needs systemd as PID 1 and python3; destructive only inside that container.
#   1. While an install runs, a competing D-Bus install is rejected; RAUC may then
#      report Operation=idle although the first install still runs. The broker's
#      witness (RAUC's own namespace) sees the bundle until the install has
#      finished.
#   2. With a power fence present, a direct D-Bus install is refused by the
#      pre-install handler before writing; with the fence gone, the same install
#      is retried and succeeds.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
container="${CERALIVE_RAUC_TEST_CONTAINER:?Set the disposable container name}"
docker exec "$container" test -f /run/logind-contract-disposable
docker exec -i "$container" install -D -m 0755 /dev/stdin /usr/lib/rauc/ceralive-pre-install < "$root/mkosi/runtime/rauc/ceralive-pre-install"
docker exec -i "$container" install -D -m 0644 /dev/stdin /var/tmp/power-broker.py < "$root/mkosi/runtime/power/ceralive-power-broker.py"
docker exec -i "$container" bash -s <<'INNER'
set -euo pipefail
grep -qx 'ExecStart=/usr/bin/rauc --mount=/run/rauc/mnt service' /usr/lib/systemd/system/rauc.service
grep -qx 'MountFlags=slave' /usr/lib/systemd/system/rauc.service
mkdir -p /etc/rauc /var/tmp/rauc /var/tmp/bundle /etc/systemd/system/rauc.service.d
cd /var/tmp/rauc
[ -f key.pem ] || openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 30 -subj '/CN=test signer' 2>/dev/null
cp cert.pem /etc/rauc/keyring.pem
truncate -s 16M /var/tmp/slot0.img /var/tmp/slot1.img
printf '[update]\ncompatible=power-test\nversion=1\n[bundle]\nformat=plain\n[image.rootfs]\nfilename=rootfs.img\n' > /var/tmp/bundle/manifest.raucm
bundle() { head -c 8M /dev/urandom > /var/tmp/bundle/rootfs.img; local b="/var/tmp/test-$1-$$.raucb"; rauc bundle --cert=cert.pem --key=key.pem /var/tmp/bundle "$b" >/dev/null 2>&1; echo "$b"; }
printf '#!/bin/sh\nsleep 20\n' > /usr/local/bin/slow-post-install; chmod 0755 /usr/local/bin/slow-post-install
printf '[system]\ncompatible=power-test\nbootloader=noop\nbundle-formats=plain\ndata-directory=/var/tmp/rauc/data\n[keyring]\npath=/etc/rauc/keyring.pem\n[handlers]\npre-install=/usr/lib/rauc/ceralive-pre-install\npost-install=/usr/local/bin/slow-post-install\n[slot.rootfs.0]\ndevice=/var/tmp/slot0.img\ntype=raw\nbootname=A\n[slot.rootfs.1]\ndevice=/var/tmp/slot1.img\ntype=raw\nbootname=B\n' > /etc/rauc/system.conf
printf '[Service]\nExecStart=\nExecStart=/usr/bin/rauc --mount=/run/rauc/mnt --override-boot-slot=A service\n' > /etc/systemd/system/rauc.service.d/power-test.conf
systemctl daemon-reload
systemctl restart rauc
systemctl is-active --quiet rauc || { systemctl status rauc --no-pager | tail -5; exit 1; }
op() { busctl get-property de.pengutronix.rauc / de.pengutronix.rauc.Installer Operation; }
pid1_mounts() { awk '$5 ~ "^/run/rauc/mnt/|^/mnt/rauc/" {print $5}' /proc/1/mountinfo | tr '\n' ' '; }
witness() { python3 -I -c 'import importlib.util as u; s=u.spec_from_file_location("b","/var/tmp/power-broker.py"); m=u.module_from_spec(s); s.loader.exec_module(m); print(" ".join(m.rauc_mounts()))'; }
echo "# $(rauc --version); rauc.service MainPID $(systemctl show -p MainPID --value rauc)"
first="$(bundle a)"; second="$(bundle b)"
(rauc install "$first" > /var/tmp/install-a.log 2>&1 &)
for _ in $(seq 1 60); do [ "$(op)" = 's "installing"' ] && break; sleep 0.5; done
for _ in $(seq 1 60); do [ -n "$(witness)" ] && break; sleep 0.5; done
sleep 3  # into the slow post-install handler
busctl call de.pengutronix.rauc / de.pengutronix.rauc.Installer InstallBundle 'sa{sv}' "$second" 0 >/dev/null 2>&1 || true
sleep 1
running="$(pgrep -f "rauc install $first" >/dev/null && echo yes || echo no)"
seen="$(witness)"
echo "# after a rejected competing install: Operation=$(op), PID 1 mounts=[$(pid1_mounts)], broker witness=[$seen], first install running=$running"
[ "$running" = yes ] && [ -n "$seen" ] || { echo "not ok 1 the running install left no witness"; exit 1; }
echo "ok 1 the broker's witness (RAUC's own namespace) sees the running install while RAUC reports $(op)"
for _ in $(seq 1 90); do pgrep -f "rauc install $first" >/dev/null || break; sleep 1; done
[ -z "$(witness)" ] || { echo "not ok 1b mounts left after the install"; exit 1; }
echo "ok 1b the witness clears when the install has finished: $(tail -1 /var/tmp/install-a.log)"
third="$(bundle c)"
before="$(sha256sum /var/tmp/slot1.img | cut -d' ' -f1)"
mkdir -p /run/ceralive-power/fence.d
echo shutdown > /run/ceralive-power/fence.d/shutdown
busctl call de.pengutronix.rauc / de.pengutronix.rauc.Installer InstallBundle 'sa{sv}' "$third" 0 >/dev/null
for _ in $(seq 1 60); do [ "$(op)" = 's "idle"' ] && [ -z "$(witness)" ] && break; sleep 0.5; done
error="$(busctl get-property de.pengutronix.rauc / de.pengutronix.rauc.Installer LastError)"
[[ "$error" == *Pre-install* && "$(sha256sum /var/tmp/slot1.img | cut -d' ' -f1)" = "$before" ]] \
  || { echo "not ok 2 fenced install: $error"; exit 1; }
echo "ok 2 a direct D-Bus install under the fence is refused before writing ($error); the slot is unchanged"
mv /run/ceralive-power/fence.d/shutdown /var/tmp/fence-was-here
printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/slow-post-install
rauc install "$third" > /var/tmp/install-c.log 2>&1
[ "$(sha256sum /var/tmp/slot1.img | cut -d' ' -f1)" != "$before" ] && [ "$(op)" = 's "idle"' ] && [ -z "$(witness)" ] \
  || { echo "not ok 2b retry after the fence: $(tail -1 /var/tmp/install-c.log)"; exit 1; }
echo "ok 2b with the fence gone the same install is retried and succeeds: $(tail -1 /var/tmp/install-c.log)"
INNER

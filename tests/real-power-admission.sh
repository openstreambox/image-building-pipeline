#!/usr/bin/env bash
# Opt-in, destructive only inside an explicitly disposable systemd 257 container
# with dbus, polkitd, openssh-server, sudo, rauc + rauc-service (plain bundles),
# squashfs-tools and openssl, privileged for loop devices, and a persistent
# journal (/var/log/journal). Phase 1 uses inert, loaded power targets, so an
# accepted request is visible without shutting anything down. Phase 2 (only with
# --shutdown) restores the real targets and powers the container off once, then
# starts it again and reads the previous boot's journal.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
container="${CERALIVE_POWER_TEST_CONTAINER:?Set the disposable container name}"
docker exec "$container" test -f /run/logind-contract-disposable
docker exec "$container" sh -c '/lib/systemd/systemd --version | head -1' | grep -Eq '^systemd 257 '
docker exec "$container" test -x /usr/lib/polkit-1/polkitd
docker exec "$container" test -d /var/log/journal
# Units must sit directly under /system.slice, as on a box (private cgroup namespace).
docker exec "$container" grep -qx '0::/init.scope' /proc/1/cgroup

put() { docker exec -i "$container" install -D -m "$3" /dev/stdin "$2" < "$1"; }
p="$root/mkosi/runtime/power"
put "$p/ceralive-power-broker.py" /usr/libexec/ceralive/ceralive-power-broker 0755
put "$p/ceralive-poweroff" /usr/bin/ceralive-poweroff 0755
put "$p/ceralive-power.socket" /etc/systemd/system/ceralive-power.socket 0644
put "$p/ceralive-power.service" /etc/systemd/system/ceralive-power.service 0644
put "$p/ceralive-write-drain.service" /etc/systemd/system/ceralive-write-drain.service 0644
put "$p/60-ceralive-power-broker.rules" /etc/polkit-1/rules.d/60-ceralive-power-broker.rules 0644
put "$p/ceralive-power.sysusers.conf" /usr/lib/sysusers.d/ceralive-power.conf 0644
for t in poweroff reboot halt; do
  put "$p/60-ceralive-wait-for-writes.conf" "/etc/systemd/system/$t.target.d/60-ceralive-wait-for-writes.conf" 0644
done
put "$root/mkosi/runtime/rauc/ceralive-pre-install" /usr/lib/rauc/ceralive-pre-install 0755
put "$root/mkosi/runtime/ceralive-rauc-arm@.service" "/etc/systemd/system/ceralive-rauc-arm@.service" 0644
docker exec "$container" sh -c 'command -v dbus-send >/dev/null'

phase1() {
docker exec -i "$container" bash -s <<'INNER'
set -euo pipefail
ln -sfn ceralive-poweroff /usr/bin/ceralive-reboot
# Phase 2 reads the previous boot: keep the journal and the machine ID across boots.
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=persistent\n' > /etc/systemd/journald.conf.d/power-test.conf
systemd-machine-id-setup --commit >/dev/null 2>&1 || true
systemctl restart systemd-journald; journalctl --flush
systemd-sysusers /usr/lib/sysusers.d/ceralive-power.conf
id ceralive >/dev/null 2>&1 || useradd -m -s /bin/bash ceralive
id guest >/dev/null 2>&1 || useradd -m -s /bin/bash guest
usermod -aG ceralive-power ceralive
echo 'ceralive ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/test-ceralive; chmod 0440 /etc/sudoers.d/test-ceralive
[ -f /root/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519
for u in ceralive guest root; do h="$(getent passwd "$u" | cut -d: -f6)"; mkdir -p "$h/.ssh"
  cp /root/.ssh/id_ed25519.pub "$h/.ssh/authorized_keys"; chown -R "$u:$u" "$h/.ssh"; chmod 700 "$h/.ssh"; done
systemctl enable --now ssh >/dev/null 2>&1
# Inert, loaded targets: logind executes them, nothing powers off.
for t in poweroff reboot; do
  printf '[Unit]\nDescription=Inert %s target (test)\nDefaultDependencies=no\n' "$t" > "/etc/systemd/system/$t.target"
done
# RAUC on two file-backed slots; a slow post-install handler keeps an install
# "installing" long enough to observe (the service, not its client, does it).
mkdir -p /etc/rauc /var/tmp/rauc /var/tmp/bundle /etc/systemd/system/rauc.service.d
if [ ! -f /var/tmp/test.raucb ]; then
  ( cd /var/tmp/rauc && openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 30 -subj '/CN=test signer' 2>/dev/null )
  cp /var/tmp/rauc/cert.pem /etc/rauc/keyring.pem
  truncate -s 16M /var/tmp/slot0.img /var/tmp/slot1.img
  head -c 8M /dev/urandom > /var/tmp/bundle/rootfs.img
  printf '[update]\ncompatible=power-test-test\nversion=1\n[bundle]\nformat=plain\n[image.rootfs]\nfilename=rootfs.img\n' > /var/tmp/bundle/manifest.raucm
  rauc bundle --cert=/var/tmp/rauc/cert.pem --key=/var/tmp/rauc/key.pem /var/tmp/bundle /var/tmp/test.raucb >/dev/null 2>&1
fi
printf '[system]\ncompatible=power-test-test\nbootloader=noop\nbundle-formats=plain\ndata-directory=/var/tmp/rauc/data\n[keyring]\npath=/etc/rauc/keyring.pem\n[handlers]\npre-install=/usr/lib/rauc/ceralive-pre-install\npost-install=/usr/local/bin/slow-post-install\n[slot.rootfs.0]\ndevice=/var/tmp/slot0.img\ntype=raw\nbootname=A\n[slot.rootfs.1]\ndevice=/var/tmp/slot1.img\ntype=raw\nbootname=B\n' > /etc/rauc/system.conf
printf '#!/bin/sh\nsleep 25\n' > /usr/local/bin/slow-post-install; chmod 0755 /usr/local/bin/slow-post-install
printf '[Service]\nExecStart=\nExecStart=/usr/bin/rauc service --override-boot-slot=A\n' > /etc/systemd/system/rauc.service.d/test.conf
systemctl daemon-reload
systemctl restart polkit systemd-logind
systemctl restart rauc
systemctl enable --now ceralive-power.socket >/dev/null 2>&1
systemctl restart ceralive-power.service
INNER
}

docker exec -i "$container" tee /usr/local/bin/power-test-request >/dev/null <<'PY'
#!/usr/bin/python3
import socket, sys
c = socket.socket(socket.AF_UNIX); c.connect('/run/ceralive-power/request.sock')
c.sendall(sys.argv[1].encode() + b'\n'); c.settimeout(60); out = b''
try:
    while True:
        d = c.recv(4096)
        if not d: break
        out += d
        if any(w in out for w in (b'SUBMITTED', b'REFUSED', b'FAILED', b'UNCERTAIN')): break
except socket.timeout:
    pass
print(out.decode().strip().replace('\n', ' | '))
PY
docker exec "$container" chmod 0755 /usr/local/bin/power-test-request
docker exec -i "$container" tee /usr/local/bin/power-test-operator >/dev/null <<'PY'
#!/usr/bin/python3
"""Drive an SSH session with a terminal like a person: wait for the broker's
prompt on that terminal, then type the word (argv: user, command, word)."""
import os, pty, select, sys, time
user, command, word = sys.argv[1:4]
pid, fd = pty.fork()
if pid == 0:
    os.execvp('ssh', ['ssh', '-tt', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no', '-o', 'LogLevel=ERROR', f'{user}@localhost', command])
out, typed, end = b'', False, time.time() + 60
while time.time() < end:
    if select.select([fd], [], [], 0.2)[0]:
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
        out += data
    if not typed and b'press Enter' in out:
        os.write(fd, word.encode() + b'\r'); typed = True
    if b'Shutting down' in out or b'Not done' in out or b'Refused' in out or b'not available' in out:
        if select.select([fd], [], [], 0.3)[0]:
            try:
                out += os.read(fd, 4096)
            except OSError:
                pass
        break
print(out.decode(errors='replace').replace('\r', '').strip().splitlines()[-1] if out.strip() else '(no output)')
PY
docker exec "$container" chmod 0755 /usr/local/bin/power-test-operator

phase1
docker exec -i "$container" bash -s <<'INNER'
set -euo pipefail
pass=0
ok() { echo "ok $((pass+=1)) $1"; }
fail() { echo "not ok $1: $2"; exit 1; }
active() { systemctl show -p ActiveState --value "$1.target"; }
reset() {
  systemctl stop poweroff.target reboot.target 2>/dev/null || true
  systemctl stop ceralive-power.service
  # A restarted broker recovers its last request; each check starts clean.
  rm -f /run/ceralive-power/state.json /run/ceralive-power/fence
  systemctl reset-failed ceralive-power.service 2>/dev/null || true
  systemctl start ceralive-power.service; sleep 0.5
}
lock() { systemctl stop stream-lock 2>/dev/null || true; systemctl reset-failed stream-lock 2>/dev/null || true
  systemd-run -q --unit=stream-lock systemd-inhibit --what=shutdown --who=CeraUI --why='Streaming or carrying client traffic' --mode=block sleep infinity; sleep 0.5; }
unlock() { systemctl stop stream-lock 2>/dev/null || true; }
as_unit() { local unit="$1" action="$2"; systemctl reset-failed "$unit" 2>/dev/null || true
  systemd-run -q --wait --unit="${unit%.service}" -p StandardOutput=file:/run/power-test-out /usr/local/bin/power-test-request "$action" || true
  cat /run/power-test-out; }

lock; reset
out="$(systemctl poweroff -i 2>&1 || true)"
[ "$(active poweroff)" = inactive ] || fail "raw root -i" "$out"
ok "raw root 'systemctl poweroff -i' is refused under the stream lock ($out)"

out="$(as_unit ceralive-button.service POWEROFF)"
[[ "$out" == *SUBMITTED* && "$(active poweroff)" = active ]] || fail "button" "$out"
ok "button hold (exact unit) passes the stream lock through the broker: $out"

reset
out="$(as_unit ceralive-button.service REBOOT)"
[[ "$out" == *"REFUSED the button may only power off"* ]] || fail "button reboot" "$out"
ok "the button may not reboot"

reset
out="$(as_unit ceralive-buttonx.service POWEROFF)"
[[ "$out" == *REFUSED* && "$(active poweroff)" = inactive ]] || fail "lookalike unit" "$out"
ok "a lookalike root unit is an operator without a terminal: $out"

reset
out="$(as_unit ceralive.service REBOOT)"
[[ "$out" == *SUBMITTED* && "$(active reboot)" = active ]] || fail "ceraui" "$out"
ok "CeraUI's admitted reboot (exact unit) passes the stream lock"

reset
out="$(timeout 75 /usr/local/bin/power-test-operator ceralive ceralive-poweroff poweroff)"
[[ "$out" == *"Shutting down"* && "$(active poweroff)" = active ]] || fail "operator ssh" "$out"
ok "login user over SSH with a terminal, typed word: $out"

reset
out="$(timeout 75 /usr/local/bin/power-test-operator ceralive ceralive-poweroff yes)"
[[ "$out" == *"Not done"* && "$(active poweroff)" = inactive ]] || fail "wrong word" "$out"
ok "a wrong word is refused: $out"

reset
out="$(ssh -T -o BatchMode=yes -o LogLevel=ERROR ceralive@localhost ceralive-poweroff </dev/null 2>&1 || true)"
[[ "$out" == *"needs your own terminal"* && "$(active poweroff)" = inactive ]] || fail "no pty" "$out"
ok "SSH without a terminal is refused: $(tail -1 <<<"$out")"

reset
out="$(echo poweroff | ssh -T -o BatchMode=yes -o LogLevel=ERROR ceralive@localhost ceralive-poweroff 2>&1 || true)"
[[ "$out" == *"Not done"* && "$(active poweroff)" = inactive ]] || fail "piped answer" "$out"
ok "a piped answer without a terminal is refused"

reset
out="$(timeout 75 /usr/local/bin/power-test-operator ceralive 'sudo ceralive-poweroff' poweroff)"
[[ "$out" == *"Shutting down"* && "$(active poweroff)" = active ]] || fail "sudo use_pty" "$out"
ok "root through sudo with its own pty (Debian's use_pty) prompts there; the typed word is relayed: $out"

reset
echo 'Defaults:ceralive !use_pty' > /etc/sudoers.d/test-nopty; chmod 0440 /etc/sudoers.d/test-nopty
out="$(timeout 75 /usr/local/bin/power-test-operator ceralive 'sudo ceralive-poweroff' poweroff)"
rm -f /etc/sudoers.d/test-nopty
[[ "$out" == *"owned by another account"* && "$(active poweroff)" = inactive ]] || fail "sudo on login tty" "$out"
ok "root through sudo sharing the login user's terminal is refused: $out"

reset
out="$(timeout 75 /usr/local/bin/power-test-operator root ceralive-poweroff poweroff)"
[[ "$out" == *"Shutting down"* && "$(active poweroff)" = active ]] || fail "root own tty" "$out"
ok "root on its own terminal, typed word"

reset
out="$(timeout 75 /usr/local/bin/power-test-operator guest ceralive-poweroff poweroff)"
[[ "$out" == *"not available"* && "$(active poweroff)" = inactive ]] || fail "guest" "$out"
ok "a user outside ceralive-power cannot reach the socket: $out"

reset
out="$(systemd-run -q --wait --pty -p User=ceralive ceralive-poweroff </dev/null 2>&1 || true)"
[ "$(active poweroff)" = inactive ] || fail "unattended pty job" "$out"
ok "an unattended PTY job under the login user does not power off"

reset
systemctl stop systemd-logind; systemctl mask --runtime --quiet systemd-logind
out="$(as_unit ceralive-button.service POWEROFF)"
systemctl unmask --runtime --quiet systemd-logind; systemctl start systemd-logind
[[ "$out" == *FAILED* || "$out" == *UNCERTAIN* ]] || fail "logind absent" "$out"
[ "$(active poweroff)" = inactive ] || fail "logind absent fallback" "target started"
ok "logind absent fails closed, no fallback start of the target: $out"

reset; lock
systemctl stop polkit; systemctl mask --runtime --quiet polkit
out="$(as_unit ceralive-button.service POWEROFF)"
[[ "$out" == *FAILED* && "$(active poweroff)" = inactive ]] || fail "polkit absent, locked" "$out"
ok "polkit absent under the stream lock fails closed: $out"
reset; unlock
out="$(as_unit ceralive-button.service POWEROFF)"
systemctl unmask --runtime --quiet polkit; systemctl start polkit
[[ "$out" == *SUBMITTED* && "$(active poweroff)" = active ]] || fail "polkit absent, unlocked" "$out"
ok "polkit absent without a block lock: root's ordinary authorization suffices"

# A finished update unit kept active (RemainAfterExit) is a receipt, not work.
reset; lock
systemctl reset-failed ceralive-software-update.service 2>/dev/null || true
systemd-run -q --unit=ceralive-software-update -p RemainAfterExit=yes true
sleep 0.5
[ "$(systemctl show -p SubState --value ceralive-software-update.service)" = exited ] || fail "receipt" "unit not active/exited"
out="$(as_unit ceralive-button.service POWEROFF)"
systemctl stop ceralive-software-update.service
[[ "$out" == *SUBMITTED* && "$(active poweroff)" = active ]] || fail "receipt" "$out"
ok "a finished update unit kept active does not hold the request: $out"

# While the broker waits for another writer, a direct D-Bus install is refused
# by RAUC's pre-install handler before it writes anything.
reset; lock
systemctl reset-failed ceralive-slot-sync.service 2>/dev/null || true
systemd-run -q --unit=ceralive-slot-sync sleep 12
systemd-run -q --unit=ceralive-button -p StandardOutput=file:/run/power-test-out /usr/local/bin/power-test-request POWEROFF
sleep 2
grep -q 'ceralive-slot-sync.service' /run/ceralive-power/state.json || fail "fence wait" "$(cat /run/ceralive-power/state.json)"
[ -e /run/ceralive-power/fence ] || fail "fence" "no fence file while waiting"
before="$(sha256sum /var/tmp/slot1.img | cut -d' ' -f1)"
busctl call de.pengutronix.rauc / de.pengutronix.rauc.Installer InstallBundle 'sa{sv}' /var/tmp/test.raucb 0 >/dev/null
for i in $(seq 1 40); do [ "$(busctl get-property de.pengutronix.rauc / de.pengutronix.rauc.Installer Operation)" = 's "idle"' ] && ! grep -q ' /mnt/rauc/' /proc/1/mountinfo && break; sleep 0.5; done
error="$(busctl get-property de.pengutronix.rauc / de.pengutronix.rauc.Installer LastError)"
[[ "$error" == *Pre-install* ]] || fail "fenced install" "$error"
[ "$(sha256sum /var/tmp/slot1.img | cut -d' ' -f1)" = "$before" ] || fail "fenced install" "slot written"
[ "$(active poweroff)" = inactive ] || fail "fence wait" "submitted while a writer ran"
for i in $(seq 1 30); do [ "$(active poweroff)" = active ] && break; sleep 1; done
[ "$(active poweroff)" = active ] || fail "fence wait" "not submitted after the writer finished"
ok "a direct D-Bus install during the wait is refused before writing ($error), and the request goes once the writer finished"

# RAUC worker: the client is gone, the service still installs.
reset; lock
P() { busctl get-property de.pengutronix.rauc / de.pengutronix.rauc.Installer Operation; }
systemctl reset-failed installer 2>/dev/null || true
systemd-run -q --unit=installer rauc install /var/tmp/test.raucb
for i in $(seq 1 20); do [ "$(P)" = 's "installing"' ] && break; sleep 0.5; done
systemctl kill -s KILL installer; sleep 0.5
[ "$(P)" = 's "installing"' ] || fail "worker" "install not running after the client died"
systemd-run -q --unit=ceralive-button -p StandardOutput=file:/run/power-test-out /usr/local/bin/power-test-request POWEROFF
sleep 3
grep -q '"waiting"' /run/ceralive-power/state.json || fail "worker wait" "$(cat /run/ceralive-power/state.json)"
[ "$(active poweroff)" = inactive ] || fail "worker cut" "target started while installing"
if flock -n -x /run/lock/ceralive-update.lock true; then fail "fence" "a new writer got the update lock"; fi
ok "a detached RAUC worker holds the request back and new writers are fenced: $(cat /run/ceralive-power/state.json)"
for i in $(seq 1 90); do [ "$(active poweroff)" = active ] && break; sleep 1; done
[ "$(P)" = 's "idle"' ] && [ "$(active poweroff)" = active ] || fail "worker drain" "target not started after the install"
done_at="$(journalctl -u rauc -o json --no-pager | python3 -c 'import json,sys
t=[int(e["__MONOTONIC_TIMESTAMP"]) for e in map(json.loads, sys.stdin) if "succeeded" in str(e.get("MESSAGE",""))]
print(t[-1] if t else 0)')"
target_at="$(systemctl show -p ActiveEnterTimestampMonotonic --value poweroff.target)"
[ "$done_at" -gt 0 ] && [ "$target_at" -gt "$done_at" ] || fail "worker order" "install done $done_at, target $target_at"
ok "submitted only after the install finished (install done at ${done_at} us, target at ${target_at} us): $(cat /run/power-test-out)"
unlock; reset
echo "1..$pass"
INNER

shutdown_round() { # $1 label, $2 "short" to add a 10 s forced target deadline (negative control)
  docker exec -i "$container" bash -s "$2" <<'INNER'
set -euo pipefail
rm -f /etc/systemd/system/poweroff.target /etc/systemd/system/reboot.target
rm -f /etc/systemd/system/poweroff.target.d/70-power-test-short.conf
if [ "$1" = short ]; then
  printf '[Unit]\nJobTimeoutSec=10s\nJobTimeoutAction=poweroff-force\n' > /etc/systemd/system/poweroff.target.d/70-power-test-short.conf
fi
rm -f /run/ceralive-power/fence
systemctl daemon-reload
systemctl enable --now ceralive-write-drain.service >/dev/null 2>&1
systemctl show -p JobTimeoutUSec --value poweroff.target > /var/tmp/power-test-jobtimeout
systemctl reset-failed installer 2>/dev/null || true
systemd-run -q --unit=installer rauc install /var/tmp/test.raucb
for i in $(seq 1 20); do busctl get-property de.pengutronix.rauc / de.pengutronix.rauc.Installer Operation | grep -q installing && break; sleep 0.5; done
systemctl kill -s KILL installer
busctl get-property de.pengutronix.rauc / de.pengutronix.rauc.Installer Operation | grep -q installing
date +%s > /var/tmp/power-test-shutdown-requested
# Timers default to one minute of accuracy; this one must fire on time.
systemd-run -q --on-active=1 --timer-property=AccuracySec=100ms systemctl poweroff
INNER
  start=$(date +%s)
  until [[ "$(docker inspect -f '{{.State.Running}}' "$container")" == false ]]; do
    (( $(date +%s) - start < 180 )) || { echo "not ok $1: container still running"; exit 1; }
    sleep 1
  done
  stopped=$(( $(date +%s) - start ))
  docker start "$container" >/dev/null
  for _ in $(seq 1 60); do docker exec "$container" systemctl is-active systemd-journald >/dev/null 2>&1 && break; sleep 2; done
  # A container shares the host's boot ID, so select the shutdown by time.
  since="$(docker exec "$container" cat /var/tmp/power-test-shutdown-requested)"
  echo "# $1: poweroff.target JobTimeoutUSec=$(docker exec "$container" cat /var/tmp/power-test-jobtimeout), container stopped after $stopped s"
  docker exec "$container" bash -c "journalctl --since=@$since -o short-precise --no-pager | grep -E 'Shutdown waits|All writes finished|Installation .* (succeeded|failed)|Stopped rauc|timed out|Reached target.*Power'" > /dev/stderr || true
  order="$(docker exec "$container" bash -c "journalctl --since=@$since -o cat --no-pager | grep -E 'Shutdown waits|Installation .* succeeded|Stopped rauc' | head -3 | tr '\n' '|'")"
}

if [[ "${1:-}" == --shutdown ]]; then
  # Phase 2: real shutdowns through plain logind (no broker, like logind's own
  # key handling) while a detached RAUC worker still installs (~25 s).
  # Negative control: a 10 s forced deadline on poweroff.target cuts it.
  shutdown_round control short
  [[ "$order" != *Installation*succeeded* ]] && (( stopped < 22 )) \
    || { echo "not ok control: a 10 s forced deadline did not cut the install ($stopped s, $order)"; exit 1; }
  echo "ok control: with a 10 s forced target deadline the install is cut (container gone after $stopped s, no success logged)"
  # The image's drop-ins: no forced deadline; the drain holds until the write is done.
  shutdown_round image none
  [[ "$(docker exec "$container" cat /var/tmp/power-test-jobtimeout)" == infinity ]] || { echo "not ok target deadline"; exit 1; }
  [[ "$order" == Shutdown\ waits*Installation*succeeded*Stopped*rauc* ]] || { echo "not ok shutdown order: $order"; exit 1; }
  echo "ok shutdown waited for the detached RAUC install before stopping rauc.service: $order"
fi

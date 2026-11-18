#!/usr/bin/env bats
#
# Opt-in remote access for release images: pinned Tailscale (inert until a key
# file on BOOT enrolls it), its loopback allowlist, its /data state, seeded SSH
# keys and key-only sshd. Offline: fake tarballs, stub tailscale/systemctl,
# temporary roots, and an unprivileged network namespace for the nft rule.

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PIPELINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  SRC="$PIPELINE_DIR/mkosi/runtime/remote-access"
  MODULE="$PIPELINE_DIR/mkosi/customize/postinst.d/remote-access.sh"
  HOSTLIB="$PIPELINE_DIR/lib/release-remote-access.sh"
  ENROLL="$SRC/ceralive-tailscale-enroll.sh"
  SEEDER="$SRC/ceralive-ssh-key-seed.sh"
  T="$BATS_TEST_TMPDIR"
  # Fake release tarball with the real layout and its pin.
  mkdir -p "$T/tar/tailscale_9.9.9_arm64/systemd"
  printf '#!/bin/sh\necho tailscaled\n' >"$T/tar/tailscale_9.9.9_arm64/tailscaled"
  printf '#!/bin/sh\necho tailscale\n' >"$T/tar/tailscale_9.9.9_arm64/tailscale"
  tar -czf "$T/ts.tgz" -C "$T/tar" tailscale_9.9.9_arm64
  printf 'TAILSCALE_VERSION=9.9.9\nTAILSCALE_URL_TEMPLATE=https://invalid/{ver}/{arch}\nTAILSCALE_SHA256_arm64=%s\nTAILSCALE_SHA256_amd64=%s\n' \
    "$(sha256sum "$T/ts.tgz" | cut -c1-64)" "$(printf 0%.0s {1..64})" >"$T/recipe.conf"
  ssh-keygen -q -t ed25519 -N '' -C support@example.invalid -f "$T/support" >/dev/null
}

module() { # env assignments... -> runs setup_remote_access with stubbed enable_service
  run env -i PATH="$PATH" CERALIVE_RUNTIME_SRC="$PIPELINE_DIR/mkosi/runtime" REMOTE_ACCESS_DESTROOT="$T/root" \
    TAILSCALE_RECIPE="$T/recipe.conf" TAILSCALE_ARCH=arm64 TAILSCALE_LOCAL_TARBALL="$T/ts.tgz" "$@" bash -c '
      source "$1"; enable_service() { echo "ENABLE $1"; }; setup_remote_access' _ "$MODULE"
}

@test "the committed pin is a real version with both architecture checksums" {
  run bash -c 'source "$1"; [[ $TAILSCALE_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ $TAILSCALE_SHA256_arm64 =~ ^[0-9a-f]{64}$ ]] && [[ $TAILSCALE_SHA256_amd64 =~ ^[0-9a-f]{64}$ ]] && [[ $TAILSCALE_URL_TEMPLATE == https://pkgs.tailscale.com/stable/* ]]' _ "$SRC/tailscale.recipe.conf"
  [ "$status" -eq 0 ]
}

@test "nothing is installed without remote-access options" {
  module
  [ "$status" -eq 0 ]
  [ ! -e "$T/root" ]
}

@test "Tailscale installs pinned binaries, an enabled inert unit and the enrollment timer" {
  module CERALIVE_TAILSCALE=1
  [ "$status" -eq 0 ]
  [ -x "$T/root/usr/local/sbin/tailscaled" ] && [ -x "$T/root/usr/local/bin/tailscale" ]
  [ -x "$T/root/usr/local/sbin/ceralive-tailscale-enroll" ]
  [ -f "$T/root/etc/systemd/system/ceralive-tailscale-enroll.timer" ]
  [ "$(stat -c %a "$T/root/var/lib/tailscale")" = 700 ]
  [[ "$output" == *"ENABLE tailscaled.service"* && "$output" == *"ENABLE ceralive-tailscale-enroll.timer"* ]]
  local unit="$T/root/etc/systemd/system/tailscaled.service"
  grep -q -- '--tun=userspace-networking' "$unit"
  grep -q '^ConditionPathExists=|/var/lib/tailscale/tailscaled.state$' "$unit"
  grep -q '^ConditionPathExists=|/var/lib/tailscale/pending-authkey$' "$unit"
  grep -q '^RequiresMountsFor=/var/lib/tailscale$' "$unit"
  grep -qx 'ExecStartPre=/usr/sbin/nft -f /usr/lib/ceralive/tailscaled-loopback.nft' "$unit"
  grep -q -- '--no-logs-no-support' "$unit"
  grep -qx 'ExecStartPost=-/usr/local/bin/tailscale --socket=/run/tailscale/tailscaled.sock set --auto-update=false --update-check=false' "$unit"
  grep -qx 'ReadOnlyPaths=/usr/local/bin /usr/local/sbin' "$unit"
  grep -qx 'ExecStopPost=/usr/local/sbin/tailscaled --tun=userspace-networking --cleanup' "$unit"
  cmp "$SRC/tailscaled-loopback.nft" "$T/root/usr/lib/ceralive/tailscaled-loopback.nft"
  [ ! -e "$T/root/etc/ssh/sshd_config.d/05-ceralive-key-only.conf" ]
}

@test "Tailscale is refused on images without the FAT /boot (x86)" {
  module CERALIVE_TAILSCALE=1 TAILSCALE_ARCH=amd64
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs the arm64 board layout"* ]]
  [ ! -e "$T/root/usr/local/sbin/tailscaled" ]
}

@test "the enrollment unit starts for any case of the key file name" {
  grep -qx 'ConditionPathExistsGlob=|/boot/\[oO\]\[sS\]\[bB\]-\[tT\]\[aA\]\[iI\]\[lL\]\[sS\]\[cC\]\[aA\]\[lL\]\[eE\]\*' "$SRC/ceralive-tailscale-enroll.service"
}

@test "units pass systemd-analyze verify apart from binaries absent on the build host" {
  command -v systemd-analyze >/dev/null || skip "no systemd-analyze"
  run systemd-analyze verify --man=no "$SRC"/*.service "$SRC"/*.timer
  local line
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == *"is not executable: No such file or directory"* ]] || { echo "unexpected: $line"; return 1; }
  done <<<"$output"
}

# --- loopback allowlist: real nft in an unprivileged user + network namespace ---
nft_case() { # cgroup-path level -> prints "<port> connected|refused" for tcp 1935, 18080 and 53
  local path="$1" level="$2"
  sed -e "s#level 2 \"system.slice/tailscaled.service\"#level ${level} \"${path}\"#" "$SRC/tailscaled-loopback.nft" >"$T/lo.nft"
  grep -q "level ${level} " "$T/lo.nft"
  unshare -rn bash -c 'ip link set lo up && nft -f "$1" && python3 - <<PY
import socket, threading
for p in (1935, 18080, 53):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", p)); s.listen(5)
    threading.Thread(target=lambda s=s: [s.accept() for _ in range(3)], daemon=True).start()
for p in (1935, 18080, 53):
    c = socket.socket(); c.settimeout(2)
    try:
        c.connect(("127.0.0.1", p)); print(p, "connected")
    except OSError:
        print(p, "refused")
PY' _ "$T/lo.nft"
}

@test "tailscaled's loopback re-dials reach only the CeraUI backend and DNS" {
  command -v nft >/dev/null && unshare -rn true 2>/dev/null || skip "needs nft and user namespaces"
  local cg level
  cg="$(cut -d: -f3 /proc/self/cgroup)"; cg="${cg#/}"
  level="$(awk -F/ '{print NF}' <<<"$cg")"
  # rule bound to this test's own cgroup = "we are tailscaled"
  run nft_case "$cg" "$level"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1935 refused"* && "$output" == *"18080 connected"* && "$output" == *"53 connected"* ]]
  # rule bound to another cgroup: everything else on the box is untouched
  run nft_case "system.slice" 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"1935 connected"* && "$output" == *"18080 connected"* ]]
}

@test "a checksum mismatch fails the build closed" {
  sed -i 's/^TAILSCALE_SHA256_arm64=.*/TAILSCALE_SHA256_arm64=0000000000000000000000000000000000000000000000000000000000000000/' "$T/recipe.conf"
  module CERALIVE_TAILSCALE=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"sha256 MISMATCH"* ]]
  [ ! -e "$T/root/usr/local/sbin/tailscaled" ]
}

@test "seeded keys and key-only sshd are installed when asked" {
  module CERALIVE_SSH_ROOT_KEYS_B64="$(base64 -w0 <"$T/support.pub")" CERALIVE_SSH_PASSWORD_AUTH=no
  [ "$status" -eq 0 ]
  cmp "$T/support.pub" "$T/root/usr/share/ceralive/ssh/root_authorized_keys.seed"
  [[ "$output" == *"ENABLE ceralive-ssh-key-seed.service"* ]]
  grep -qx 'PasswordAuthentication no' "$T/root/etc/ssh/sshd_config.d/05-ceralive-key-only.conf"
  grep -qx 'KbdInteractiveAuthentication no' "$T/root/etc/ssh/sshd_config.d/05-ceralive-key-only.conf"
  [ ! -e "$T/root/usr/local/sbin/tailscaled" ]
}

@test "the key-only drop-in is accepted by sshd and wins over a later drop-in" {
  command -v sshd >/dev/null || command -v /usr/sbin/sshd >/dev/null || skip "no sshd on this host"
  local sshd; sshd="$(command -v sshd || echo /usr/sbin/sshd)"
  mkdir -p "$T/sshd/sshd_config.d"
  ssh-keygen -q -t ed25519 -N '' -f "$T/sshd/host" >/dev/null
  printf 'Include %s/sshd_config.d/*.conf\nHostKey %s/host\nPasswordAuthentication yes\n' "$T/sshd" "$T/sshd" >"$T/sshd/sshd_config"
  cp "$SRC/05-ceralive-key-only.conf" "$T/sshd/sshd_config.d/"
  printf 'PasswordAuthentication yes\n' >"$T/sshd/sshd_config.d/50-later.conf"
  run "$sshd" -T -f "$T/sshd/sshd_config" -o PidFile=none
  [ "$status" -eq 0 ] || skip "sshd -T needs privileges here: $output"
  [[ "$output" == *"passwordauthentication no"* ]]
  [[ "$output" == *"kbdinteractiveauthentication no"* ]]
}

# --- BOOT key-file enrollment -------------------------------------------------
KEY=tskey-auth-kAbC123-XyZ987654321
enroll_env() {
  mkdir -p "$T/boot" "$T/bin"
  printf '#!/bin/sh\necho "systemctl $*" >>"%s/calls"\n' "$T" >"$T/bin/systemctl"
  # stub CLI: logs its arguments; `up` prints $TS_OUT and exits $TS_RC
  printf '#!/bin/sh\necho "tailscale $*" >>"%s/calls"\ncase "$*" in *" up "*) [ -n "$TS_OUT" ] && echo "$TS_OUT" >&2; exit "${TS_RC:-0}";; esac\nexit 0\n' "$T" >"$T/bin/tailscale"
  chmod +x "$T/bin/systemctl" "$T/bin/tailscale"
}
enroll() {
  run env PATH="$T/bin:$PATH" CERALIVE_TS_BOOT_DIR="$T/boot" CERALIVE_TS_STATE_DIR="$T/state" \
    CERALIVE_TS_CLI="$T/bin/tailscale" SYSTEMCTL_BIN="$T/bin/systemctl" CERALIVE_TS_SOCKET="$T/none.sock" \
    CERALIVE_TS_SOCKET_WAIT=0 "$@" bash "$ENROLL"
}
no_key_anywhere() { # the key text appears in no file on BOOT and in no output
  ! grep -rqF "$KEY" "$T/boot" && [[ "$output" != *"$KEY"* ]] && { [ ! -e "$T/calls" ] || ! grep -qF "$KEY" "$T/calls"; }
}

@test "enrollment takes the key off BOOT, joins with Tailscale SSH and the file's name, then pins auto-update off" {
  enroll_env
  printf '\xef\xbb\xbf%s\r\n' "$KEY" >"$T/boot/OSB-Tailscale-White.key.txt"
  enroll CERALIVE_TS_NOW=1000
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$T/boot")" ]
  [ ! -e "$T/state/pending-authkey" ]
  grep -q 'systemctl start tailscaled.service' "$T/calls"
  grep -q -- "up --auth-key=file:$T/state/pending-authkey --ssh --accept-risk=lose-ssh --accept-dns=false --accept-routes=false --timeout=90s --hostname=white" "$T/calls"
  [ "$(tail -n1 "$T/calls")" = "tailscale --socket=$T/none.sock set --auto-update=false --update-check=false" ]
  [ "$(cut -d' ' -f1 "$T/state/enroll-status")" = joined ]
  [ -e "$T/state/joined-once" ]
  no_key_anywhere
}

@test "a transient failure keeps the key pending on /data, backs off, then joins" {
  enroll_env
  printf '%s' "$KEY" >"$T/boot/osb-tailscale.key"
  enroll CERALIVE_TS_NOW=1000 TS_RC=1 TS_OUT="connection refused"
  [ "$status" -ne 0 ]
  [ -z "$(ls -A "$T/boot")" ]
  [ "$(cat "$T/state/pending-authkey")" = "$KEY" ]
  [ "$(stat -c %a "$T/state/pending-authkey")" = 600 ] && [ "$(stat -c %a "$T/state")" = 700 ]
  [ "$(cat "$T/state/enroll-status")" = "pending 1 1120 retry" ]
  ! grep -q -- '--hostname' "$T/calls"
  rm "$T/calls"
  enroll CERALIVE_TS_NOW=1060          # inside the back-off window: no attempt
  [ "$status" -eq 0 ] && [ ! -e "$T/calls" ]
  enroll CERALIVE_TS_NOW=1130 TS_RC=1 TS_OUT="no network"
  [ "$(cat "$T/state/enroll-status")" = "pending 2 1370 retry" ]
  enroll CERALIVE_TS_NOW=1400
  [ "$status" -eq 0 ]
  [ ! -e "$T/state/pending-authkey" ]
  no_key_anywhere
}

@test "a refused key ends enrollment at once and an unjoined box goes back to idle" {
  enroll_env
  printf '%s' "$KEY" >"$T/boot/osb-tailscale-black.key"
  mkdir -p "$T/state"; : >"$T/state/tailscaled.state"
  enroll CERALIVE_TS_NOW=1000 TS_RC=1 TS_OUT="backend error: invalid key: API key does not exist"
  [ "$status" -ne 0 ]
  [ ! -e "$T/state/pending-authkey" ] && [ ! -e "$T/state/pending-hostname" ]
  [ ! -e "$T/state/tailscaled.state" ]
  grep -q 'systemctl stop tailscaled.service' "$T/calls"
  [[ "$(cat "$T/state/enroll-status")" == "gave-up 1 0 the control server refused the key" ]]
  [[ "$output" == *"gave up Tailscale enrollment"* ]]
  rm "$T/calls"; enroll CERALIVE_TS_NOW=5000
  [ ! -e "$T/calls" ]                  # nothing left to retry
}

@test "retries are capped, and a box that joined before keeps its state" {
  enroll_env
  mkdir -p "$T/state"; : >"$T/state/tailscaled.state"; : >"$T/state/joined-once"
  printf '%s' "$KEY" >"$T/boot/osb-tailscale.key"
  enroll CERALIVE_TS_NOW=1000 CERALIVE_TS_MAX_ATTEMPTS=2 TS_RC=1 TS_OUT="timeout"
  enroll CERALIVE_TS_NOW=2000 CERALIVE_TS_MAX_ATTEMPTS=2 TS_RC=1 TS_OUT="timeout"
  [ "$status" -ne 0 ]
  [[ "$(cat "$T/state/enroll-status")" == "gave-up 2 0 no success after 2 attempts" ]]
  [ ! -e "$T/state/pending-authkey" ]
  [ -e "$T/state/tailscaled.state" ]
  ! grep -q 'systemctl stop' "$T/calls"
}

@test "a file that is not an auth key is removed from BOOT, not kept" {
  enroll_env
  printf 'tskey-client-kSECRETSECRET-0123456789' >"$T/boot/osb-tailscale-black.key"
  enroll
  [ "$status" -eq 0 ]
  [ "$(ls -A "$T/boot")" = TAILSCALE-KEY-REJECTED.txt ]
  ! grep -rq 'SECRETSECRET' "$T/boot"
  grep -q 'osb-tailscale-black.key' "$T/boot/TAILSCALE-KEY-REJECTED.txt"
  [[ "$output" != *SECRETSECRET* ]]
  [ ! -e "$T/state/pending-authkey" ] && [ ! -e "$T/calls" ]
}

@test "two key files are both removed and neither is used" {
  enroll_env
  printf '%s' "$KEY" >"$T/boot/osb-tailscale-white.key"
  printf '%s' "$KEY" >"$T/boot/osb-tailscale-white (1).key"
  enroll
  [ "$status" -eq 0 ]
  [ "$(ls -A "$T/boot")" = TAILSCALE-KEY-REJECTED.txt ]
  [ ! -e "$T/state/pending-authkey" ] && [ ! -e "$T/calls" ]
  no_key_anywhere
}

@test "no key file and nothing pending is a no-op" {
  enroll_env
  enroll
  [ "$status" -eq 0 ]
  [ ! -e "$T/calls" ]
}

# --- SSH key seed ---------------------------------------------------------------
@test "the key seed appends once, keeps existing keys and respects later removals" {
  mkdir -p "$T/ssh"
  printf 'ssh-ed25519 AAAAexisting other@host\n' >"$T/ssh/root_authorized_keys"
  run env CERALIVE_SSH_STATE_DIR="$T/ssh" CERALIVE_SSH_SEED="$T/support.pub" bash "$SEEDER"
  [ "$status" -eq 0 ]
  grep -qxF "$(cat "$T/support.pub")" "$T/ssh/root_authorized_keys"
  grep -qx 'ssh-ed25519 AAAAexisting other@host' "$T/ssh/root_authorized_keys"
  printf 'ssh-ed25519 AAAAexisting other@host\n' >"$T/ssh/root_authorized_keys"   # someone removed ours
  run env CERALIVE_SSH_STATE_DIR="$T/ssh" CERALIVE_SSH_SEED="$T/support.pub" bash "$SEEDER"
  [ "$status" -eq 0 ]
  ! grep -qF "$(cut -d' ' -f2 "$T/support.pub")" "$T/ssh/root_authorized_keys"
}

@test "the key seed waits for the store the SSH guard creates" {
  mkdir -p "$T/ssh2"
  run env CERALIVE_SSH_STATE_DIR="$T/ssh2" CERALIVE_SSH_SEED="$T/support.pub" bash "$SEEDER"
  [ "$status" -ne 0 ]
  [ ! -e "$T/ssh2/root-keys-seeded" ]
}

# --- persistence -------------------------------------------------------------------
@test "Tailscale state is bound from /data only on Tailscale images" {
  local p="$PIPELINE_DIR/mkosi/customize/postinst.d/persistence.sh"
  grep -Fq '[[ "${CERALIVE_TAILSCALE:-0}" == 1 ]] && specs+=("${data_root}/tailscale:/var/lib/tailscale")' "$p"
  # the first-boot migrate body creates /data/tailscale 0700 only when tailscaled ships
  local body
  body="$(awk '/cat >>\/usr\/local\/sbin\/ceralive-migrate-data <<.EOF./{on=1; next} on && /^EOF$/{exit} on' "$p")"
  [[ "$body" == *'if [ -x /usr/local/sbin/tailscaled ]; then'*'mkdir -p "$DATA/tailscale"'*'chmod 0700 "$DATA/tailscale"'* ]]
}

# --- host-side validation ------------------------------------------------------------
host() { run env -i PATH="$PATH" "$@" bash -c 'source "$1"; release_remote_access_resolve && printf "K=%s\n" "$CERALIVE_SSH_ROOT_KEYS_B64"' _ "$HOSTLIB"; }

@test "host check: defaults are off and a good keys file is forwarded" {
  host
  [ "$status" -eq 0 ] && [ "${lines[-1]}" = "K=" ]
  host CERALIVE_SSH_ROOT_KEYS_FILE="$T/support.pub" CERALIVE_SSH_PASSWORD_AUTH=no CERALIVE_TAILSCALE=1
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "${lines[-1]#K=}" | base64 -d)" = "$(cat "$T/support.pub")" ]
}

@test "host check refuses bad keys files and unsafe combinations" {
  cp "$T/support" "$T/private"
  host CERALIVE_SSH_ROOT_KEYS_FILE="$T/private"; [ "$status" -ne 0 ]
  printf 'command="x" %s\n' "$(cat "$T/support.pub")" >"$T/opts.pub"
  host CERALIVE_SSH_ROOT_KEYS_FILE="$T/opts.pub"; [ "$status" -ne 0 ]
  printf '%s ceralive-ci-x\n' "$(cut -d' ' -f1,2 "$T/support.pub")" >"$T/ci.pub"
  host CERALIVE_SSH_ROOT_KEYS_FILE="$T/ci.pub"; [ "$status" -ne 0 ]
  printf 'ssh-ed25519 AAAAnotbase64!!\n' >"$T/garbage.pub"
  host CERALIVE_SSH_ROOT_KEYS_FILE="$T/garbage.pub"; [ "$status" -ne 0 ]
  ssh-keygen -q -t rsa -b 2048 -N '' -f "$T/rsa" >/dev/null
  host CERALIVE_SSH_ROOT_KEYS_FILE="$T/rsa.pub"; [ "$status" -ne 0 ]
  sed 's/$/\r/' "$T/support.pub" >"$T/crlf.pub"
  host CERALIVE_SSH_ROOT_KEYS_FILE="$T/crlf.pub"; [ "$status" -ne 0 ]
  host CERALIVE_TAILSCALE=yes; [ "$status" -ne 0 ]
  host CERALIVE_SSH_PASSWORD_AUTH=off; [ "$status" -ne 0 ]
  host CERALIVE_SSH_PASSWORD_AUTH=no CERALIVE_SSH_ROOT_KEYS_FILE="$T/support.pub" CERALIVE_DEBUG_IMAGE=1; [ "$status" -ne 0 ]
  host CERALIVE_SSH_PASSWORD_AUTH=no; [ "$status" -ne 0 ]
  [[ "$output" == *"leaves no LAN way in"* ]]
  host CERALIVE_SSH_PASSWORD_AUTH=no CERALIVE_TAILSCALE=1; [ "$status" -ne 0 ]
}

@test "options reach the runtime chroot and the executor calls the writer" {
  local var
  for var in CERALIVE_TAILSCALE CERALIVE_SSH_ROOT_KEYS_B64 CERALIVE_SSH_PASSWORD_AUTH; do
    grep -Eq "^[[:space:]]+.*\\b${var}\\b" "$PIPELINE_DIR/lib/orchestrate.sh"
    grep -Fq "export ${var}=" "$PIPELINE_DIR/lib/orchestrate.sh"
    grep -Eq "^PassEnvironment=.*\\b${var}\\b" "$PIPELINE_DIR/mkosi/mkosi.conf"
  done
  grep -Fq 'release_remote_access_resolve' "$PIPELINE_DIR/lib/orchestrate.sh"
  grep -Eq '^  setup_remote_access ' "$PIPELINE_DIR/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
  grep -Eq '^  remote-access\.sh$' "$PIPELINE_DIR/mkosi/customize/postinst-lib.sh"
}

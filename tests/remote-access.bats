#!/usr/bin/env bats
#
# Opt-in remote access for release images: pinned Tailscale (inert until a key
# file on BOOT enrolls it), its /data state, seeded SSH keys and key-only sshd.
# Offline: fake tarballs, stub tailscale/systemctl, temporary roots.

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
  [ ! -e "$T/root/etc/ssh/sshd_config.d/05-ceralive-key-only.conf" ]
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
enroll_env() {
  mkdir -p "$T/boot" "$T/bin"
  printf '#!/bin/sh\necho "systemctl $*" >>"%s/calls"\n' "$T" >"$T/bin/systemctl"
  printf '#!/bin/sh\necho "tailscale $*" >>"%s/calls"\ncase "$*" in *"auth-key=file:"*) cat "${*##*auth-key=file:}" 2>/dev/null | head -c0;; esac\nexit "${TS_RC:-0}"\n' "$T" >"$T/bin/tailscale"
  chmod +x "$T/bin/systemctl" "$T/bin/tailscale"
}
enroll() {
  run env PATH="$T/bin:$PATH" CERALIVE_TS_BOOT_DIR="$T/boot" CERALIVE_TS_STATE_DIR="$T/state" \
    CERALIVE_TS_CLI="$T/bin/tailscale" SYSTEMCTL_BIN="$T/bin/systemctl" CERALIVE_TS_SOCKET="$T/none.sock" \
    CERALIVE_TS_SOCKET_WAIT=0 "$@" bash "$ENROLL"
}

@test "enrollment takes the key off BOOT, joins with Tailscale SSH and the file's name" {
  enroll_env
  printf '\xef\xbb\xbftskey-auth-kAbC123-XyZ987654321\r\n' >"$T/boot/osb-tailscale-White.key.txt"
  enroll
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$T/boot")" ]
  [ ! -e "$T/state/pending-authkey" ]
  grep -q 'systemctl start tailscaled.service' "$T/calls"
  grep -q -- "up --auth-key=file:$T/state/pending-authkey --ssh --accept-dns=false --accept-routes=false --timeout=90s --hostname=white" "$T/calls"
}

@test "a failed join keeps the key pending on /data, never on BOOT, and the retry uses it" {
  enroll_env
  printf 'tskey-auth-kAbC123-XyZ987654321' >"$T/boot/osb-tailscale.key"
  enroll TS_RC=1
  [ "$status" -ne 0 ]
  [ -z "$(ls -A "$T/boot")" ]
  [ "$(cat "$T/state/pending-authkey")" = tskey-auth-kAbC123-XyZ987654321 ]
  [ "$(stat -c %a "$T/state/pending-authkey")" = 600 ]
  [ "$(stat -c %a "$T/state")" = 700 ]
  ! grep -q -- '--hostname' "$T/calls"
  enroll
  [ "$status" -eq 0 ]
  [ ! -e "$T/state/pending-authkey" ]
}

@test "a file that is not an auth key is set aside and never used" {
  enroll_env
  printf 'hello world\n' >"$T/boot/osb-tailscale-black.key"
  enroll
  [ "$status" -eq 0 ]
  [ -e "$T/boot/osb-tailscale-black.key.rejected" ]
  [ ! -e "$T/state/pending-authkey" ]
  [ ! -e "$T/calls" ]
  enroll   # the rejected file is not picked up again
  [ ! -e "$T/calls" ]
}

@test "two key files are both set aside" {
  enroll_env
  printf 'tskey-auth-kAAAAAAAA-1111111111' >"$T/boot/osb-tailscale-white.key"
  printf 'tskey-auth-kBBBBBBBB-2222222222' >"$T/boot/osb-tailscale-black.key"
  enroll
  [ "$status" -eq 0 ]
  [ -e "$T/boot/osb-tailscale-white.key.rejected" ] && [ -e "$T/boot/osb-tailscale-black.key.rejected" ]
  [ ! -e "$T/state/pending-authkey" ]
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
  [[ "$output" == *"leaves no way in"* ]]
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

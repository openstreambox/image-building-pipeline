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
  grep -q '^ConditionPathExists=|/data/tailscale-enroll/pending-authkey$' "$unit"
  grep -q '^RequiresMountsFor=/var/lib/tailscale /data/tailscale-enroll$' "$unit"
  grep -q -- '--no-logs-no-support' "$unit"
  grep -qx 'ExecStartPost=-+/usr/local/bin/tailscale --socket=/run/tailscale/tailscaled.sock set --auto-update=false --update-check=false' "$unit"
  grep -qx 'ReadOnlyPaths=/usr/local/bin /usr/local/sbin' "$unit"
  grep -qx 'ExecStopPost=/usr/local/sbin/tailscaled --tun=userspace-networking --cleanup' "$unit"
  cmp "$SRC/tailscaled-loopback.nft" "$T/root/usr/lib/ceralive/tailscaled-loopback.nft"
  grep -qx 'User=ceralive-tailscale' "$unit"
  grep -qx 'ExecStartPre=+/usr/sbin/nft -f /usr/lib/ceralive/tailscaled-loopback.nft' "$unit"
  grep -qx 'StateDirectory=tailscale' "$unit"
  grep -q '^ceralive-tailscale:x:[0-9]*:[0-9]*:Tailscale node agent:/var/lib/tailscale:/bin/bash$' "$T/root/etc/passwd"
  [ "$(stat -c %a "$T/root/etc/sudoers.d/ceralive-tailscale")" = 440 ]
  grep -qx 'ceralive-tailscale ALL=(ALL:ALL) NOPASSWD: ALL' "$T/root/etc/sudoers.d/ceralive-tailscale"
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
nft_case() { # uid-to-match -> "<addr>:<port> connected|refused" lines
  sed -e "s#meta skuid \"ceralive-tailscale\"#meta skuid $1#" "$SRC/tailscaled-loopback.nft" >"$T/lo.nft"
  grep -q "meta skuid $1 " "$T/lo.nft"
  unshare -rn bash -c 'ip link set lo up && nft -f "$1" && python3 - <<PY
import socket, threading
targets = [("127.0.0.1", 1935), ("127.0.0.1", 18080), ("127.0.0.53", 53), ("127.0.0.1", 53), ("127.0.0.1", 4001)]
for a, p in targets:
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind((a, p)); s.listen(5)
    threading.Thread(target=lambda s=s: [s.accept() for _ in range(3)], daemon=True).start()
for a, p in targets:
    c = socket.socket(); c.settimeout(2)
    try:
        c.connect((a, p)); print(f"{a}:{p} connected")
    except OSError:
        print(f"{a}:{p} refused")
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.bind(("127.0.0.1", 4001)); u.settimeout(1)
c = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    c.sendto(b"x", ("127.0.0.1", 4001)); u.recvfrom(16); print("udp:4001 delivered")
except OSError:
    print("udp:4001 blocked")
PY' _ "$T/lo.nft"
}

@test "the loopback allowlist lets the tailscaled account reach only the backend and the DNS stub" {
  command -v nft >/dev/null && unshare -rn true 2>/dev/null || skip "needs nft and user namespaces"
  # inside the namespace this test runs as uid 0: match uid 0 = "we are tailscaled"
  run nft_case 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"127.0.0.1:1935 refused"* && "$output" == *"127.0.0.1:4001 refused"* ]]
  [[ "$output" == *"127.0.0.1:18080 connected"* && "$output" == *"127.0.0.53:53 connected"* ]]
  [[ "$output" == *"127.0.0.1:53 refused"* && "$output" == *"udp:4001 blocked"* ]]
  # another account: nothing else on the box is affected
  run nft_case 4242
  [ "$status" -eq 0 ]
  [[ "$output" == *"127.0.0.1:1935 connected"* && "$output" == *"127.0.0.1:53 connected"* && "$output" == *"udp:4001 delivered"* ]]
}

@test "the allowlist uses only expressions the shipped kernel has, and every kernel build checks them" {
  # no socket/cgroup/owner matches (NFT_SOCKET and the xt matches are not built)
  ! grep -Ev '^\s*#' "$SRC/tailscaled-loopback.nft" | grep -Eq '\b(socket|cgroupv2|fib|limit|log|quota|tproxy|osf)\b'
  local sym
  while IFS= read -r sym; do
    [[ -z "$sym" || "$sym" == \#* ]] && continue
    grep -qx -- "$sym" "$PIPELINE_DIR/manifests/kernel/required-symbols.list" \
      || { echo "$sym is not in required-symbols.list"; return 1; }
  done <"$SRC/tailscaled-loopback.kconfig"
}

@test "the kernel symbol check fails on a resolved config without them" {
  local verify="$PIPELINE_DIR/lib/verify-kernel-config.sh"
  grep -v '^#' "$SRC/tailscaled-loopback.kconfig" | grep . >"$T/good.config"
  run bash "$verify" --config "$T/good.config" --required "$SRC/tailscaled-loopback.kconfig"
  [ "$status" -eq 0 ]
  sed 's/^CONFIG_NFT_REJECT_INET=y$/# CONFIG_NFT_REJECT_INET is not set/' "$T/good.config" >"$T/bad.config"
  run bash "$verify" --config "$T/bad.config" --required "$SRC/tailscaled-loopback.kconfig"
  [ "$status" -ne 0 ]
  # A real resolved build config, when given, must carry every symbol too.
  if [ -n "${KERNEL_RESOLVED_CONFIG:-}" ]; then
    run bash "$verify" --config "$KERNEL_RESOLVED_CONFIG" --required "$SRC/tailscaled-loopback.kconfig"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  fi
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

# --- BOOT key-file and writer enrollment ------------------------------------------
KEY=tskey-auth-kAbC123-XyZ987654321
enroll_env() {
  mkdir -p "$T/boot" "$T/bin" "$T/state"
  printf '#!/bin/sh\necho "systemctl $*" >>"%s/calls"\n' "$T" >"$T/bin/systemctl"
  # stub CLI: logs arguments and the key it was given; `up` creates a state like
  # tailscaled would, prints $TS_OUT, exits $TS_RC; `status --json` reports $TS_BACKEND.
  cat >"$T/bin/tailscale" <<STUB
#!/bin/sh
echo "tailscale \$*" >>"$T/calls"
case "\$*" in
  *" up "*) f="\${*##*auth-key=file:}"; f="\${f%% *}"; echo "used \$(cut -c12-20 "\$f")" >>"$T/used"
    : >"$T/state/tailscaled.state"; [ -n "\$TS_SLEEP" ] && sleep "\$TS_SLEEP"
    [ -n "\$TS_OUT" ] && echo "\$TS_OUT" >&2; exit "\${TS_RC:-0}";;
  *"status --json"*) [ -n "\$TS_STATUS_RC" ] && exit "\$TS_STATUS_RC"; [ -n "\$TS_NODEKEY" ] && nk=', "HaveNodeKey": true' || nk=''
    echo "{\"BackendState\": \"\${TS_BACKEND:-NeedsLogin}\"\$nk}";;
  # \$TS_SET_OUT/\$TS_SET_RC model tailscaled refusing a pref change while
  # Tailscale SSH stays on; turning SSH off in the same change is accepted.
  *" set "*) case "\$*" in *"--ssh=false"*) [ -n "\$TS_SSHOFF_OUT" ] && echo "\$TS_SSHOFF_OUT" >&2; exit "\${TS_SSHOFF_RC:-0}";; esac
    [ -n "\$TS_SET_OUT" ] && echo "\$TS_SET_OUT" >&2; exit "\${TS_SET_RC:-0}";;
esac
exit 0
STUB
  chmod +x "$T/bin/systemctl" "$T/bin/tailscale"
}
enroll_cmd() {
  echo env PATH="$T/bin:$PATH" CERALIVE_TS_BOOT_DIR="$T/boot" CERALIVE_TS_STATE_DIR="$T/state" CERALIVE_TS_ENROLL_DIR="$T/enroll" \
    CERALIVE_TS_CLI="$T/bin/tailscale" SYSTEMCTL_BIN="$T/bin/systemctl" CERALIVE_TS_SOCKET="$T/none.sock" CERALIVE_TS_SOCKET_WAIT=0
}
# shellcheck disable=SC2046
enroll() { run $(enroll_cmd) "$@" bash "$ENROLL"; }
card_drop() { # key [name]: the documented writer protocol, one file via tmp + rename
  mkdir -p "$T/enroll"; chmod 700 "$T/enroll"
  ( umask 077; printf '%s\n%s\n' "$1" "${2:-}" >"$T/enroll/.in.tmp"; mv "$T/enroll/.in.tmp" "$T/enroll/incoming-authkey" )
}
pending_key() { head -n1 "$T/enroll/pending-authkey"; }
no_key_anywhere() { # the key text appears in no file on BOOT, in no output, no argv
  ! grep -rqF "$KEY" "$T/boot" && [[ "$output" != *"$KEY"* ]] && { [ ! -e "$T/calls" ] || ! grep -qF "$KEY" "$T/calls"; }
}
no_leftovers() { [ -z "$(cd "$T/enroll" && ls -A | grep -E '^\.(claimed|pending\.|status\.|up-key\.)')" ]; }
fresh() { # wipe the per-scenario state inside this test's own tmpdir
  rm -rf "${T:?}/enroll" "${T:?}/state" "${T:?}/calls" "${T:?}/used" "${T:?}/syncs" "${T:?}/bin"
}

@test "enrollment takes the key off BOOT, joins with Tailscale SSH and the file's name, then pins auto-update off" {
  enroll_env
  printf '\xef\xbb\xbf%s\r\n' "$KEY" >"$T/boot/OSB-Tailscale-White.key.txt"
  enroll CERALIVE_TS_NOW=1000
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$T/boot")" ]
  [ ! -e "$T/enroll/pending-authkey" ]
  grep -q 'systemctl start tailscaled.service' "$T/calls"
  grep -Eq -- "up --auth-key=file:$T/enroll/\.up-key\.[A-Za-z0-9]+ --ssh --accept-risk=lose-ssh --accept-dns=false --accept-routes=false --timeout=90s --hostname=white" "$T/calls"
  [ "$(tail -n1 "$T/calls")" = "tailscale --socket=$T/none.sock set --auto-update=false --update-check=false" ]
  [ "$(cut -d' ' -f1 "$T/enroll/enroll-status")" = joined ]
  [ -e "$T/enroll/joined-once" ] && [ ! -e "$T/enroll/state-ours" ]
  no_leftovers
  no_key_anywhere
}

NO_TAILNET_SSH="Unable to enable local Tailscale SSH server; not enabled on Tailnet."

@test "on a tailnet without Tailscale SSH, enrollment turns SSH off so the auto-update pin still applies" {
  enroll_env
  printf '%s' "$KEY" >"$T/boot/osb-tailscale.key"
  enroll CERALIVE_TS_NOW=1000 TS_SET_RC=1 TS_SET_OUT="$NO_TAILNET_SSH"
  [ "$status" -eq 0 ]
  # the plain pin was refused, then SSH off and both pins went in one change
  [ "$(grep -c ' set ' "$T/calls")" -eq 2 ]
  [ "$(tail -n1 "$T/calls")" = "tailscale --socket=$T/none.sock set --ssh=false --accept-risk=lose-ssh --auto-update=false --update-check=false" ]
  [ "$(cat "$T/enroll/enroll-status")" = "joined 1 0 ok-without-tailnet-ssh" ]
  [[ "$output" == *"does not allow Tailscale SSH"* ]]
  [ ! -e "$T/enroll/pending-authkey" ] && [ -e "$T/enroll/joined-once" ]
  no_leftovers
  no_key_anywhere
}

@test "a pin that still fails is reported in the status, not as a plain ok" {
  enroll_env
  printf '%s' "$KEY" >"$T/boot/osb-tailscale.key"
  enroll CERALIVE_TS_NOW=1000 TS_SET_RC=1 TS_SET_OUT="$NO_TAILNET_SSH" TS_SSHOFF_RC=1
  [ "$status" -eq 0 ]
  [ "$(cat "$T/enroll/enroll-status")" = "joined 1 0 ok-auto-update-not-pinned" ]
  fresh; enroll_env
  printf '%s' "$KEY" >"$T/boot/osb-tailscale.key"
  enroll CERALIVE_TS_NOW=1000 TS_SET_RC=1 TS_SET_OUT="some other error"
  [ "$status" -eq 0 ]
  # an unrelated refusal never turns SSH off
  ! grep -q -- '--ssh=false' "$T/calls"
  [ "$(cat "$T/enroll/enroll-status")" = "joined 1 0 ok-auto-update-not-pinned" ]
  [[ "$output" == *"could not pin auto-update off"* ]]
  no_key_anywhere
}

@test "a new key for a box already on a tailnet without Tailscale SSH ends at once, keeping its state" {
  enroll_env
  printf '%s' "$KEY" >"$T/boot/osb-tailscale.key"
  : >"$T/state/tailscaled.state"
  enroll CERALIVE_TS_NOW=1000 TS_RC=1 TS_OUT="$NO_TAILNET_SSH" TS_BACKEND=Running TS_NODEKEY=1
  [ "$status" -ne 0 ]
  [ "$(cut -d' ' -f1,4- "$T/enroll/enroll-status")" = "gave-up this tailnet does not allow Tailscale SSH; forget the box there first" ]
  [ -e "$T/state/tailscaled.state" ] && [ ! -e "$T/enroll/pending-authkey" ]
  no_key_anywhere
}

@test "a join this enrollment registered, refused on retry by a tailnet without Tailscale SSH, still finishes and pins" {
  enroll_env
  printf '%s' "$KEY" >"$T/boot/osb-tailscale.key"
  # attempt 1: no login yet; the keyed up registers but times out (approval wait)
  enroll CERALIVE_TS_NOW=1000 TS_RC=1 TS_OUT="timeout waiting for the device to be approved"
  [ "$(cat "$T/enroll/enroll-status")" = "pending 1 1120 retry" ]
  # approved meanwhile: Running with a netmap that refuses SSH, so the retry's up is refused
  enroll CERALIVE_TS_NOW=1130 TS_RC=1 TS_OUT="$NO_TAILNET_SSH" TS_BACKEND=Running TS_NODEKEY=1 \
    TS_SET_RC=1 TS_SET_OUT="$NO_TAILNET_SSH"
  [ "$status" -eq 0 ]
  [ "$(cat "$T/enroll/enroll-status")" = "joined 2 0 ok-without-tailnet-ssh" ]
  [ "$(tail -n1 "$T/calls")" = "tailscale --socket=$T/none.sock set --ssh=false --accept-risk=lose-ssh --auto-update=false --update-check=false" ]
  [ ! -e "$T/enroll/pending-authkey" ] && [ -e "$T/enroll/joined-once" ]
  no_leftovers
  no_key_anywhere
}

@test "the login check is made once per key, and an unanswered check stays open" {
  enroll_env
  printf '%s' "$KEY" >"$T/boot/osb-tailscale.key"
  enroll CERALIVE_TS_NOW=1000 TS_RC=1 TS_OUT="no network" TS_BACKEND=Running TS_NODEKEY=1
  [ "$(cat "$T/enroll/prior-login")" = yes ]
  # a later attempt sees no login but keeps the first answer
  enroll CERALIVE_TS_NOW=1130 TS_RC=1 TS_OUT="no network"
  [ "$(cat "$T/enroll/prior-login")" = yes ]
  # a new key asks again; a daemon that does not answer leaves it undetermined
  card_drop "$KEY"
  enroll CERALIVE_TS_NOW=1140 TS_RC=1 TS_OUT="no network" TS_STATUS_RC=1
  [ ! -e "$T/enroll/prior-login" ]
  # ... and undetermined is treated like a login that predates the key
  enroll CERALIVE_TS_NOW=1400 TS_RC=1 TS_OUT="$NO_TAILNET_SSH" TS_BACKEND=Running TS_NODEKEY=1 TS_STATUS_RC=1
  [ "$(cut -d' ' -f1 "$T/enroll/enroll-status")" = gave-up ]
  [ ! -e "$T/enroll/prior-login" ]
}

@test "a failed SSH-off pin keeps its own error in the log" {
  enroll_env
  printf '%s' "$KEY" >"$T/boot/osb-tailscale.key"
  enroll CERALIVE_TS_NOW=1000 TS_SET_RC=1 TS_SET_OUT="$NO_TAILNET_SSH" TS_SSHOFF_RC=1 TS_SSHOFF_OUT="dial unix: no such socket"
  [ "$(cat "$T/enroll/enroll-status")" = "joined 1 0 ok-auto-update-not-pinned" ]
  [[ "$output" == *"dial unix: no such socket"* ]]
  [[ "$output" == *"tries again"* ]]
  no_key_anywhere
}

@test "a transient failure keeps the key pending in the root-only directory, backs off, then joins" {
  enroll_env
  printf '%s' "$KEY" >"$T/boot/osb-tailscale.key"
  enroll CERALIVE_TS_NOW=1000 TS_RC=1 TS_OUT="connection refused"
  [ "$status" -ne 0 ]
  [ -z "$(ls -A "$T/boot")" ]
  [ "$(pending_key)" = "$KEY" ]
  [ "$(stat -c %a "$T/enroll/pending-authkey")" = 600 ] && [ "$(stat -c %a "$T/enroll")" = 700 ]
  [ "$(cat "$T/enroll/enroll-status")" = "pending 1 1120 retry" ]
  ! grep -q -- '--hostname' "$T/calls"
  rm "$T/calls"
  enroll CERALIVE_TS_NOW=1060          # inside the back-off window: no attempt
  [ "$status" -eq 0 ] && [ ! -e "$T/calls" ]
  enroll CERALIVE_TS_NOW=1130 TS_RC=1 TS_OUT="no network"
  [ "$(cat "$T/enroll/enroll-status")" = "pending 2 1370 retry" ]
  enroll CERALIVE_TS_NOW=1400
  [ "$status" -eq 0 ]
  [ ! -e "$T/enroll/pending-authkey" ]
  no_leftovers
  no_key_anywhere
}

@test "a daemon that cannot start still counts attempts, backs off and gives up" {
  enroll_env
  printf '#!/bin/sh\necho "systemctl $*" >>"%s/calls"\ncase "$1" in start) exit 1;; esac\nexit 0\n' "$T" >"$T/bin/systemctl"
  printf '%s' "$KEY" >"$T/boot/osb-tailscale.key"
  enroll CERALIVE_TS_NOW=1000 CERALIVE_TS_MAX_ATTEMPTS=2
  [ "$status" -ne 0 ]
  [ "$(cat "$T/enroll/enroll-status")" = "pending 1 1120 trying" ]
  enroll CERALIVE_TS_NOW=1050 CERALIVE_TS_MAX_ATTEMPTS=2
  [ "$(cat "$T/enroll/enroll-status")" = "pending 1 1120 trying" ]   # backing off, no attempt
  enroll CERALIVE_TS_NOW=1200 CERALIVE_TS_MAX_ATTEMPTS=2
  [[ "$(cat "$T/enroll/enroll-status")" == "gave-up 2 0 tailscaled did not start after 2 attempts" ]]
  [ ! -e "$T/enroll/pending-authkey" ]
  ! grep -q ' up ' "$T/calls"
}

@test "a refused key ends enrollment and removes only the state this enrollment created" {
  enroll_env
  printf '%s' "$KEY" >"$T/boot/osb-tailscale-black.key"
  enroll CERALIVE_TS_NOW=1000 TS_RC=1 TS_OUT="backend error: invalid key: API key does not exist"
  [ "$status" -ne 0 ]
  [ ! -e "$T/enroll/pending-authkey" ]
  [ ! -e "$T/state/tailscaled.state" ] && [ ! -e "$T/enroll/state-ours" ]
  grep -q 'systemctl stop tailscaled.service' "$T/calls"
  [[ "$(cat "$T/enroll/enroll-status")" == "gave-up 1 0 the control server refused the key" ]]
  [[ "$output" == *"gave up Tailscale enrollment"* ]]
  rm "$T/calls"; enroll CERALIVE_TS_NOW=5000
  [ ! -e "$T/calls" ]                  # nothing left to retry
}

@test "Tailscale and headscale refusal texts end enrollment; a transient error does not" {
  local msg
  for msg in "backend error: invalid key: API key does not exist" \
             "backend error: invalid key: unable to validate API key" \
             "backend error: invalid key: API key $KEY not valid" \
             "backend error: invalid pre auth key" \
             "backend error: auth-key not found" \
             "backend error: auth-key expired" \
             "backend error: auth-key has already been used" \
             "backend error: authkey expired" \
             "backend error: AuthKey has expired" \
             "backend error: auth key has already been used" \
             "backend error: authkey already used" \
             "backend error: pre auth key not found" \
             "backend error: key revoked"; do
    fresh; enroll_env
    card_drop "$KEY"
    enroll CERALIVE_TS_NOW=1000 TS_RC=1 TS_OUT="$msg"
    [[ "$(cat "$T/enroll/enroll-status")" == "gave-up 1 0 the control server refused the key" ]] \
      || { echo "not treated as final: $msg"; return 1; }
    no_key_anywhere
  done
  for msg in "timeout waiting for Tailscale service to enter a Running state" \
             "x509: certificate has expired or is not yet valid" \
             "backend error: tls: invalid key in server certificate" \
             "dial tcp: lookup controlplane.tailscale.com: no such host"; do
    fresh; enroll_env
    card_drop "$KEY"
    enroll CERALIVE_TS_NOW=1000 TS_RC=1 TS_OUT="$msg"
    [ "$(cat "$T/enroll/enroll-status")" = "pending 1 1120 retry" ] || { echo "treated as final: $msg"; return 1; }
  done
}

@test "R8: a state that existed before (old-layout box after an OTA) survives a refused key" {
  enroll_env
  printf '{"node":"key"}' >"$T/state/tailscaled.state"; : >"$T/state/joined-once"
  printf 'tskey-auth-pending-old-1' >"$T/state/pending-authkey"
  card_drop tskey-auth-kWRONGWRON-4444444444
  enroll CERALIVE_TS_NOW=1000 TS_RC=1 TS_OUT="backend error: invalid key" TS_BACKEND=Running
  [ -e "$T/state/tailscaled.state" ]
  [ -e "$T/enroll/joined-once" ]                          # migrated from the old layout
  [ ! -e "$T/state/pending-authkey" ]                     # old-layout key file removed, not read
  ! grep -q 'systemctl stop' "$T/calls"
  # same without the old marker: a state that existed before is still not ours
  fresh; enroll_env
  printf '{"node":"key"}' >"$T/state/tailscaled.state"
  card_drop tskey-auth-kWRONGWRON-4444444444
  enroll CERALIVE_TS_NOW=1000 TS_RC=1 TS_OUT="backend error: invalid key"
  [ -e "$T/state/tailscaled.state" ] && [ ! -e "$T/enroll/state-ours" ]
  ! grep -q 'systemctl stop' "$T/calls"
}

@test "a crash between a successful join and its marker never costs the joined state" {
  enroll_env
  mkdir -p "$T/enroll"; : >"$T/enroll/state-ours"; : >"$T/state/tailscaled.state"
  card_drop tskey-auth-kWRONGWRON-4444444444
  enroll CERALIVE_TS_NOW=1000 TS_RC=1 TS_OUT="backend error: invalid key" TS_BACKEND=Running
  [ -e "$T/state/tailscaled.state" ]
  [[ "$output" == *"kept tailscaled.state (tailscaled state 'Running')"* ]]
}

@test "give-up preserves enrollment-owned state on NoState, with a node key, or on status failure" {
  local response status_rc
  for response in \
    '{"BackendState": "NoState", "HaveNodeKey": true}' \
    '{"BackendState": "NoState"}' \
    '{"BackendState": "NeedsLogin", "HaveNodeKey": true}' \
    '{"BackendState": "NeedsLogin"}'; do
    fresh
    enroll_env
    status_rc=0
    if [[ "$response" == '{"BackendState": "NeedsLogin"}' ]]; then status_rc=1; fi
    cat >"$T/bin/tailscale" <<STUB
#!/bin/sh
case "\$*" in
  *" up "*) printf '%s' test-node-state >"$T/state/tailscaled.state"; exit 1;;
  *"status --json"*) printf '%s\n' '$response'; exit $status_rc;;
esac
STUB
    card_drop "$KEY"
    enroll CERALIVE_TS_MAX_ATTEMPTS=1
    [ "$status" -eq 1 ]
    [ "$(cat "$T/state/tailscaled.state")" = test-node-state ]
    [ -e "$T/enroll/state-ours" ]
    [ ! -e "$T/enroll/joined-once" ]
    [ ! -e "$T/enroll/pending-authkey" ]
    run grep -q 'systemctl stop tailscaled.service' "$T/calls"
    [ "$status" -eq 1 ]
    [[ "$(cat "$T/enroll/enroll-status")" == "gave-up 1 0 no success after 1 attempts" ]]
  done
}

@test "retries are capped, and a box that joined before keeps its state" {
  enroll_env
  mkdir -p "$T/enroll"; : >"$T/state/tailscaled.state"; : >"$T/enroll/joined-once"
  printf '%s' "$KEY" >"$T/boot/osb-tailscale.key"
  enroll CERALIVE_TS_NOW=1000 CERALIVE_TS_MAX_ATTEMPTS=2 TS_RC=1 TS_OUT="timeout"
  enroll CERALIVE_TS_NOW=2000 CERALIVE_TS_MAX_ATTEMPTS=2 TS_RC=1 TS_OUT="timeout"
  [ "$status" -ne 0 ]
  [[ "$(cat "$T/enroll/enroll-status")" == "gave-up 2 0 no success after 2 attempts" ]]
  [ ! -e "$T/enroll/pending-authkey" ]
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
  [ ! -e "$T/enroll/pending-authkey" ] && [ ! -e "$T/calls" ]
}

@test "two key files are both removed and neither is used" {
  enroll_env
  printf '%s' "$KEY" >"$T/boot/osb-tailscale-white.key"
  printf '%s' "$KEY" >"$T/boot/osb-tailscale-white (1).key"
  enroll
  [ "$status" -eq 0 ]
  [ "$(ls -A "$T/boot")" = TAILSCALE-KEY-REJECTED.txt ]
  [ ! -e "$T/enroll/pending-authkey" ] && [ ! -e "$T/calls" ]
  no_key_anywhere
}

@test "contract: a writer's key file (key, then optional name) is adopted and used; a bad name is ignored" {
  enroll_env
  card_drop "$KEY" black
  enroll CERALIVE_TS_NOW=1000
  [ "$status" -eq 0 ]
  grep -q -- "--hostname=black" "$T/calls"
  [ "$(cut -d' ' -f1 "$T/enroll/enroll-status")" = joined ]
  [ "$(cd "$T/enroll" && ls -A | grep -v '^\.lock$' | sort | tr '\n' ' ')" = "enroll-status joined-once " ]
  rm "$T/calls"
  card_drop "$KEY" 'Bad Name;rm'
  enroll CERALIVE_TS_NOW=2000
  [ "$status" -eq 0 ]
  ! grep -q -- '--hostname' "$T/calls"
  card_drop "$KEY" "$(printf 'a\nb')"   # three lines: refused
  rm "$T/calls"; enroll CERALIVE_TS_NOW=3000
  [ ! -e "$T/calls" ] && [ ! -e "$T/enroll/incoming-authkey" ]
  no_key_anywhere
}

@test "contract: a new key from a writer resets a backing-off key and is tried at once" {
  enroll_env
  printf '%s' "$KEY" >"$T/boot/osb-tailscale.key"
  enroll CERALIVE_TS_NOW=1000 TS_RC=1 TS_OUT="timeout"
  [ "$(cat "$T/enroll/enroll-status")" = "pending 1 1120 retry" ]
  rm "$T/calls"
  card_drop tskey-auth-kNEWNEWNEW-2222222222
  enroll CERALIVE_TS_NOW=1010          # inside the old back-off window
  [ "$status" -eq 0 ]
  grep -q ' up ' "$T/calls"
  [ "$(cut -d' ' -f1-2 "$T/enroll/enroll-status")" = "joined 1" ]
}

race() { # old-up-output -> run with an old pending key, drop the writer's key mid-attempt
  enroll_env
  mkdir -p "$T/enroll"; chmod 700 "$T/enroll"
  printf 'tskey-auth-OLDOLDOLD-1111111111\n\n' >"$T/enroll/pending-authkey"
  printf 'pending 3 0 retry\n' >"$T/enroll/enroll-status"
  cat >"$T/bin/tailscale" <<STUB
#!/bin/sh
case "\$*" in *" up "*)
  f="\${*##*auth-key=file:}"; f="\${f%% *}"; echo "used \$(cut -c12-20 "\$f")" >>"$T/used"
  [ "\$(cut -c12-14 "\$f")" = OLD ] && { sleep 2; echo "$1" >&2; exit 1; }
  exit 0;; esac
exit 0
STUB
  chmod +x "$T/bin/tailscale"
  # shellcheck disable=SC2046
  ( $(enroll_cmd) CERALIVE_TS_NOW=5000 bash "$ENROLL" >"$T/run.log" 2>&1 ) &
  local pid=$!
  sleep 1
  card_drop tskey-auth-NEWNEWNEW-2222222222 white
  wait "$pid" || true
}

@test "race: a writer's key arriving during a refused attempt is used, not shredded" {
  race "backend error: invalid key: unable to validate API key"
  [ "$(cat "$T/used")" = "$(printf 'used OLDOLDOLD\nused NEWNEWNEW')" ]
  [ "$(cut -d' ' -f1-2 "$T/enroll/enroll-status")" = "joined 1" ]
  grep -q 'for machine name white' "$T/run.log"
}

@test "race: a writer's key arriving during a transient failure starts fresh, not with old attempts" {
  race "timeout waiting for Tailscale service to enter a Running state"
  [ "$(cat "$T/used")" = "$(printf 'used OLDOLDOLD\nused NEWNEWNEW')" ]
  [ "$(cut -d' ' -f1-2 "$T/enroll/enroll-status")" = "joined 1" ]
}

@test "R7: a second writer drop during an adoption is kept and the newest key is tried" {
  enroll_env
  printf '#!/bin/sh\nsleep 2\nexit 0\n' >"$T/bin/sync"; chmod +x "$T/bin/sync"   # slow adoption
  card_drop tskey-auth-FIRSTFIRS-1111111111 first
  # shellcheck disable=SC2046
  ( $(enroll_cmd) CERALIVE_TS_NOW=5000 bash "$ENROLL" >"$T/run.log" 2>&1 ) &
  local pid=$!
  sleep 1
  card_drop tskey-auth-SECONDSEC-2222222222 second
  wait "$pid" || true
  [ "$(tail -n1 "$T/used")" = "used SECONDSEC" ]
  grep -q -- '--hostname=second' "$T/calls"
  [ ! -e "$T/enroll/incoming-authkey" ]
  no_leftovers
}

@test "R6: a crash at any point of an adoption leaves a consistent state that the next run completes" {
  local n
  for n in 1 2 3 4; do
    fresh; enroll_env
    mkdir -p "$T/enroll"; chmod 700 "$T/enroll"
    printf 'tskey-auth-OLDOLDOLD-1111111111\n\n' >"$T/enroll/pending-authkey"
    printf 'pending 57 0 retry\n' >"$T/enroll/enroll-status"
    card_drop tskey-auth-NEWNEWNEW-2222222222 white
    cat >"$T/bin/sync" <<STUB
#!/bin/sh
c=\$(cat "$T/syncs" 2>/dev/null || echo 0); c=\$((c+1)); echo \$c >"$T/syncs"
[ "\$c" -eq $n ] && kill -9 \$PPID
exit 0
STUB
    chmod +x "$T/bin/sync"
    # shellcheck disable=SC2046
    $(enroll_cmd) CERALIVE_TS_NOW=5000 bash "$ENROLL" >/dev/null 2>&1 || true
    rm "$T/bin/sync"
    # shellcheck disable=SC2046
    $(enroll_cmd) CERALIVE_TS_NOW=5000 bash "$ENROLL" >/dev/null 2>&1 || true
    [ "$(tail -n1 "$T/used")" = "used NEWNEWNEW" ] || { echo "crash point $n: $(cat "$T/used")"; return 1; }
    grep -q -- '--hostname=white' "$T/calls" || { echo "crash point $n lost the name"; return 1; }
    no_leftovers || { echo "crash point $n left $(ls -A "$T/enroll")"; return 1; }
  done
}

@test "two runs never overlap: the second waits for the lock" {
  enroll_env
  card_drop "$KEY"
  # shellcheck disable=SC2046
  ( $(enroll_cmd) CERALIVE_TS_NOW=5000 TS_SLEEP=2 TS_RC=1 TS_OUT=timeout bash "$ENROLL" >/dev/null 2>&1 ) &
  local pid=$!
  sleep 1
  enroll CERALIVE_TS_NOW=5000 CERALIVE_TS_LOCK_WAIT=0
  [ "$status" -eq 0 ]
  [[ "$output" == *"another enrollment run holds the lock"* ]]
  wait "$pid" || true
  [ "$(grep -c used "$T/used")" -eq 1 ]
}

@test "stale temporary files are removed and a leftover claim is re-adopted" {
  enroll_env
  mkdir -p "$T/enroll"; chmod 700 "$T/enroll"
  printf 'x' >"$T/enroll/.pending.AAAA"; printf 'x' >"$T/enroll/.status.BBBB"; printf 'x' >"$T/enroll/.up-key.CCCC"
  printf '%s\nwhite\n' "$KEY" >"$T/enroll/.claimed"
  enroll CERALIVE_TS_NOW=1000
  [ "$status" -eq 0 ]
  grep -q -- '--hostname=white' "$T/calls"
  no_leftovers
}

@test "links and non-regular files are never followed, read or shredded through" {
  enroll_env
  mkdir -p "$T/enroll"; chmod 700 "$T/enroll"
  printf 'secret-root-only-content\n' >"$T/victim"
  ln -s "$T/victim" "$T/enroll/pending-authkey"
  enroll CERALIVE_TS_NOW=1000 CERALIVE_TS_MAX_ATTEMPTS=1
  [ "$(cat "$T/victim")" = secret-root-only-content ]
  [ ! -e "$T/enroll/pending-authkey" ] && [ ! -L "$T/enroll/pending-authkey" ]
  ln -s "$T/victim" "$T/enroll/incoming-authkey"
  enroll CERALIVE_TS_NOW=2000
  [ "$(cat "$T/victim")" = secret-root-only-content ] && [ ! -L "$T/enroll/incoming-authkey" ]
  mkfifo "$T/enroll/incoming-authkey"
  enroll CERALIVE_TS_NOW=2500
  [ ! -e "$T/enroll/incoming-authkey" ]
  ln -s "$T/victim" "$T/boot/osb-tailscale.key"
  enroll CERALIVE_TS_NOW=3000
  [ "$(cat "$T/victim")" = secret-root-only-content ] && [ ! -L "$T/boot/osb-tailscale.key" ]
  [ ! -e "$T/used" ]
  ln -s "$T" "$T/enroll2"
  run env PATH="$T/bin:$PATH" CERALIVE_TS_BOOT_DIR="$T/boot" CERALIVE_TS_ENROLL_DIR="$T/enroll2" bash "$ENROLL"
  [ "$status" -ne 0 ] && [[ "$output" == *"not a plain directory"* ]]
}

@test "R10: a directory at incoming-authkey does not block an existing pending key" {
  enroll_env
  mkdir -p "$T/enroll/incoming-authkey"
  printf '%s\n' "$KEY" >"$T/enroll/pending-authkey"
  enroll
  [ "$status" -eq 0 ]
  [ -e "$T/enroll/joined-once" ]
  [ ! -e "$T/enroll/incoming-authkey" ]
  grep -q 'used kAbC123-X' "$T/used"
  no_leftovers
}

@test "R10: a leftover populated claim directory does not block the next real drop" {
  enroll_env
  mkdir -p "$T/enroll/.claimed"
  printf '%s\n' 'unrelated contents' >"$T/enroll/.claimed/keep"
  card_drop "$KEY" white
  enroll
  [ "$status" -eq 0 ]
  [ -e "$T/enroll/joined-once" ]
  grep -q 'used kAbC123-X' "$T/used"
  grep -q -- '--hostname=white' "$T/calls"
  grep -qx 'unrelated contents' "$T/enroll"/.rejected.*/incoming-authkey/keep
  no_leftovers
}

@test "a pending key that is not a tskey-auth key is removed without a join attempt" {
  enroll_env
  mkdir -p "$T/enroll"; chmod 700 "$T/enroll"
  printf 'tskey-client-kSECRETSECRET-0123456789\n' >"$T/enroll/pending-authkey"
  enroll CERALIVE_TS_NOW=1000
  [ ! -e "$T/enroll/pending-authkey" ]
  [ ! -e "$T/used" ]
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
  grep -Fq '[[ "${CERALIVE_TAILSCALE:-0}" == 1 ]] && specs+=("${data_root}/tailscale:/var/lib/tailscale")' \
    "$PIPELINE_DIR/mkosi/customize/postinst.d/persistence.sh"
}

# Run the real ceralive-migrate-data body against a fake root where tailscaled ships.
migrate() { # dir
  local d="$1"
  mkdir -p "$d/bin" "$d/etc/ceralive" "$d/data" "$d/varlog" "$d/nm" "$d/opt"
  printf '#!/bin/sh\nexit 1\n' >"$d/bin/mountpoint"; printf '#!/bin/sh\nexit 0\n' >"$d/bin/logger"
  printf '#!/bin/sh\nexit 0\n' >"$d/tailscaled"; chmod +x "$d/bin/"* "$d/tailscaled"
  { echo 'set -euo pipefail'; echo "DATA=$d/data"; echo "WORKDIR=$d/opt"; echo "NM_CONN=$d/nm"; echo "CERAUI_HELPERS=$d/ceraui-workdir"
    awk '/cat >>\/usr\/local\/sbin\/ceralive-migrate-data <<.EOF./{on=1; next} on && /^EOF$/{exit} on' \
      "$PIPELINE_DIR/mkosi/customize/postinst.d/persistence.sh" \
      | sed "s#/etc/ceralive#$d/etc/ceralive#g; s#/var/log#$d/varlog#g; s#/usr/local/sbin/tailscaled#$d/tailscaled#g"; } >"$d/migrate.sh"
  grep -q "$d/tailscaled" "$d/migrate.sh"
  PATH="$d/bin:$PATH" bash "$d/migrate.sh"
}

@test "migrate-data prepares both Tailscale directories root-only" {
  unshare -r true 2>/dev/null || skip "needs user namespaces (chown 0:0)"
  run unshare -r bash -c "$(declare -f migrate); PIPELINE_DIR='$PIPELINE_DIR' migrate '$T/m'"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(stat -c %a "$T/m/data/tailscale")" = 700 ] && [ "$(stat -c %a "$T/m/data/tailscale-enroll")" = 700 ]
  [ -d "$T/m/data/ceralive/certs/incoming" ]
}

@test "a Tailscale directory problem never stops the rest of migrate-data" {
  mkdir -p "$T/f/data"; printf 'not a dir' >"$T/f/data/tailscale-enroll"   # mkdir -p must fail
  run migrate "$T/f"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"WARN: could not prepare"*"tailscale-enroll"* ]]
  [ -d "$T/f/data/ceralive/certs/incoming" ]                               # later steps still ran
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

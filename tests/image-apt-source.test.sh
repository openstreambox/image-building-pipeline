#!/usr/bin/env bash
# Single signed image apt source (lib/image-apt-source.sh + mkosi/runtime/image-apt-source.sh):
# host-side resolution, the files written into a scratch root, the one-source
# assertion, and the update capabilities derived from it.
# shellcheck disable=SC2016  # the bash -c programs expand their own arguments
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"
check() { if "$@"; then ok "$*"; else bad "$*"; fi; }
refused() { # description, command...
  local what="$1"; shift
  if "$@" >"$WORK/refused.log" 2>&1; then bad "accepted: $what"; else ok "refused: $what"; fi
}
WORK=''
finish() {
  local status=$?
  [[ "$status" -eq 0 || "$FAIL" -gt 0 ]] || bad "unexpected exit: $status"
  [[ -z "$WORK" ]] || { gpgconf --homedir "$WORK/gnupg" --kill all 2>/dev/null; rm -rf "$WORK"; }
  printf ' RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]]
}
trap 'finish; exit $?' EXIT
WORK="$(mktemp -d)" || { bad 'fixture: mktemp'; exit 1; }

# --- a throwaway archive keyring --------------------------------------------------
mkdir -m 700 "$WORK/gnupg"
G=(gpg --homedir "$WORK/gnupg" --batch --quiet --pinentry-mode loopback --passphrase '')
"${G[@]}" --quick-gen-key 'Test Archive A' ed25519 sign never 2>/dev/null
"${G[@]}" --quick-gen-key 'Test Archive B' ed25519 sign never 2>/dev/null
mapfile -t FPRS < <(gpg --homedir "$WORK/gnupg" --batch --with-colons --list-keys | awk -F: '$1=="fpr"{print $10}')
gpg --homedir "$WORK/gnupg" --batch --export "${FPRS[@]}" >"$WORK/keyring.pgp"
gpg --homedir "$WORK/gnupg" --batch --export "${FPRS[0]}" >"$WORK/only-a.pgp"
"${G[@]}" --export-secret-keys "${FPRS[0]}" >"$WORK/secret.pgp"
check test "${#FPRS[@]}" -eq 2

# --- host side: lib/image-apt-source.sh -----------------------------------------------
CHANNEL_B64="$(printf '{"schema":1,"channel":"stable","channelUrl":"https://updates.example.org/abcdefghijklmnopqrstuv","allowSystemDownloadsOverCellular":false}' | base64 -w0)"
resolve() {
  env -i PATH="$PATH" HOME="$WORK" "$@" bash -c 'source "$1/lib/image-apt-source.sh"; image_apt_source_resolve && printf "%s|%s|%s\n" "$CERALIVE_IMAGE_APT_SOURCE" "$(base64 -d <<<"$CERALIVE_IMAGE_APT_URI_B64")" "${#CERALIVE_IMAGE_APT_KEYRING_B64}"' _ "$ROOT"
}
check test "$(resolve)" = '0||0'
out="$(resolve CERALIVE_IMAGE_APT_SOURCE=1 CERALIVE_FORK_RELEASE=1 CERALIVE_UPDATE_PRESET_CHANNEL_B64="$CHANNEL_B64" \
  CERALIVE_OS_RELEASE_VERSION=2026.12.1 CERALIVE_IMAGE_APT_KEYRING_FILE="$WORK/keyring.pgp" CERALIVE_EXPECT_IMAGE_APT_FPRS="${FPRS[*]}")"
check test "${out%|*}" = '1|https://updates.example.org/abcdefghijklmnopqrstuv/apt/'
check test "${out##*|}" -gt 100
refused 'keyring given without the flag' resolve CERALIVE_IMAGE_APT_KEYRING_FILE="$WORK/keyring.pgp"
refused 'no fork release' resolve CERALIVE_IMAGE_APT_SOURCE=1 CERALIVE_OS_RELEASE_VERSION=2026.12.1 \
  CERALIVE_IMAGE_APT_KEYRING_FILE="$WORK/keyring.pgp" CERALIVE_EXPECT_IMAGE_APT_FPRS="${FPRS[*]}"
refused 'no OS version' resolve CERALIVE_IMAGE_APT_SOURCE=1 CERALIVE_FORK_RELEASE=1 CERALIVE_UPDATE_PRESET_CHANNEL_B64="$CHANNEL_B64" \
  CERALIVE_IMAGE_APT_KEYRING_FILE="$WORK/keyring.pgp" CERALIVE_EXPECT_IMAGE_APT_FPRS="${FPRS[*]}"
refused 'keyring missing the standby key' resolve CERALIVE_IMAGE_APT_SOURCE=1 CERALIVE_FORK_RELEASE=1 CERALIVE_UPDATE_PRESET_CHANNEL_B64="$CHANNEL_B64" \
  CERALIVE_OS_RELEASE_VERSION=2026.12.1 CERALIVE_IMAGE_APT_KEYRING_FILE="$WORK/only-a.pgp" CERALIVE_EXPECT_IMAGE_APT_FPRS="${FPRS[*]}"
refused 'wrong fingerprint list' resolve CERALIVE_IMAGE_APT_SOURCE=1 CERALIVE_FORK_RELEASE=1 CERALIVE_UPDATE_PRESET_CHANNEL_B64="$CHANNEL_B64" \
  CERALIVE_OS_RELEASE_VERSION=2026.12.1 CERALIVE_IMAGE_APT_KEYRING_FILE="$WORK/keyring.pgp" CERALIVE_EXPECT_IMAGE_APT_FPRS="${FPRS[0]}"
refused 'secret key material' resolve CERALIVE_IMAGE_APT_SOURCE=1 CERALIVE_FORK_RELEASE=1 CERALIVE_UPDATE_PRESET_CHANNEL_B64="$CHANNEL_B64" \
  CERALIVE_OS_RELEASE_VERSION=2026.12.1 CERALIVE_IMAGE_APT_KEYRING_FILE="$WORK/secret.pgp" CERALIVE_EXPECT_IMAGE_APT_FPRS="${FPRS[0]}"

# --- chroot side: the files in a scratch root ----------------------------------------
NAMES_B64="$(grep -Ev '^[[:space:]]*(#|$)' "$ROOT/mkosi/runtime/first-party-origin-names.txt" | base64 -w0)"
new_root() {
  local r="$WORK/root.$1"
  mkdir -p "$r/etc/apt/sources.list.d" "$r/etc/apt/preferences.d" "$r/var/lib/dpkg"
  printf 'Types: deb\nURIs: https://deb.debian.org/debian\nSuites: trixie\nComponents: main\n' >"$r/etc/apt/sources.list.d/debian.sources"
  printf 'Types: deb\nURIs: https://apt.ceralive.tv/dists/stable/binary-arm64/\nSuites: ./\n' >"$r/etc/apt/sources.list.d/ceralive.sources"
  printf 'deb https://deb.debian.org/debian trixie main\n' >"$r/etc/apt/sources.list"
  printf 'Package: x\nPin: origin apt.ceralive.tv\nPin-Priority: 990\n' >"$r/etc/apt/preferences.d/ceralive-origin"
  printf 'Package: modemmanager\nPin: release a=now\nPin-Priority: 1001\n' >"$r/etc/apt/preferences.d/ceralive-local-override"
  : >"$r/var/lib/dpkg/status"
  printf '%s' "$r"
}
finalize() { # root [env...]
  local r="$1"; shift
  env -i PATH="$PATH" IMAGE_APT_ROOT="$r" IMAGE_APT_ARCH=arm64 CERALIVE_IMAGE_APT_SOURCE=1 \
    CERALIVE_IMAGE_APT_URI_B64="$(printf 'https://updates.example.org/abcdefghijklmnopqrstuv/apt/' | base64 -w0)" \
    CERALIVE_IMAGE_APT_KEYRING_B64="$(base64 -w0 <"$WORK/keyring.pgp")" \
    CERALIVE_OS_RELEASE_VERSION=2026.12.1 CERALIVE_BOARD=rock-5b-plus CERALIVE_FIRST_PARTY_NAMES_B64="$NAMES_B64" "$@" \
    bash -c 'source "$1/mkosi/runtime/image-apt-source.sh"; image_apt_source_finalize' _ "$ROOT"
}
R="$(new_root ok)"
check finalize "$R"
check test ! -e "$R/etc/apt/sources.list"
check test "$(ls "$R/etc/apt/sources.list.d")" = 'openstreambox.sources'
check grep -Fxq 'URIs: https://updates.example.org/abcdefghijklmnopqrstuv/apt/' "$R/etc/apt/sources.list.d/openstreambox.sources"
check grep -Fxq 'Suites: rock-5b-plus-2026.12.1 rock-5b-plus-2026.12.1-emergency' "$R/etc/apt/sources.list.d/openstreambox.sources"
check grep -Fxq 'Types: deb' "$R/etc/apt/sources.list.d/openstreambox.sources"
check grep -Fxq 'Signed-By: /usr/share/keyrings/openstreambox-archive-keyring.pgp' "$R/etc/apt/sources.list.d/openstreambox.sources"
if grep -q 'Check-Date' "$R/etc/apt/sources.list.d/openstreambox.sources"; then bad 'Check-Date set (it would disable Valid-Until)'; else ok 'no Check-Date override'; fi
check cmp -s "$WORK/keyring.pgp" "$R/usr/share/keyrings/openstreambox-archive-keyring.pgp"
check test "$(ls "$R/etc/apt/preferences.d")" = 'openstreambox-origin'
P="$R/etc/apt/preferences.d/openstreambox-origin"
check test "$(grep -c '^Package: ' "$P")" -eq "$(( $(printf '%s' "$NAMES_B64" | base64 -d | grep -c .) - 1 + 3 ))"
if grep -q 'ceralive-apt-credentials' "$P"; then bad 'credentials package pinned'; else ok 'credentials package not pinned'; fi
# the general stanzas are exactly the measured set, in this order, last in the file
check test "$(awk '/^(Package|Pin|Pin-Priority): /' "$P" | tail -n 9 | tr '\n' '|')" = \
  'Package: *|Pin: origin "updates.example.org"|Pin-Priority: 500|Package: *|Pin: release a=now|Pin-Priority: 100|Package: *|Pin: release *|Pin-Priority: -1|'
check grep -Fq $'Package: modemmanager\nPin: origin "updates.example.org"\nPin-Priority: 990' <(awk '/^(Package|Pin|Pin-Priority): /' "$P")
check grep -Fxq '{"schema":1,"sourcesFile":"/etc/apt/sources.list.d/openstreambox.sources","host":"updates.example.org","origin":"OpenStreamBox","label":"OpenStreamBox","suites":["rock-5b-plus-2026.12.1","rock-5b-plus-2026.12.1-emergency"]}' \
  "$R/usr/lib/ceralive/image-apt-source.json"
# off by default: nothing changes
R0="$(new_root off)"
check env -i PATH="$PATH" IMAGE_APT_ROOT="$R0" bash -c 'source "$1/mkosi/runtime/image-apt-source.sh"; image_apt_source_finalize' _ "$ROOT"
check test -e "$R0/etc/apt/sources.list.d/ceralive.sources"

# refusals
R1="$(new_root cred)"
printf 'Package: ceralive-apt-credentials\nStatus: install ok installed\nVersion: 1.0.1\nArchitecture: all\n\n' >"$R1/var/lib/dpkg/status"
refused 'credentials installed' finalize "$R1"
check grep -Fq 'must not carry the first-party archive credentials' "$WORK/refused.log"
refused 'http base' finalize "$(new_root http)" CERALIVE_IMAGE_APT_URI_B64="$(printf 'http://x.example/apt/' | base64 -w0)"
refused 'base with a query' finalize "$(new_root q)" CERALIVE_IMAGE_APT_URI_B64="$(printf 'https://x.example/apt/?a=1' | base64 -w0)"
refused 'version not CalVer' finalize "$(new_root v)" CERALIVE_OS_RELEASE_VERSION=7
refused 'empty keyring' finalize "$(new_root k)" CERALIVE_IMAGE_APT_KEYRING_B64=
refused 'names differ from the authority' finalize "$(new_root n)" CERALIVE_FIRST_PARTY_NAMES_B64="$(printf 'ceralive-device\n' | base64 -w0)"

# the assertion catches anything added afterwards
assert_root() { env -i PATH="$PATH" IMAGE_APT_ROOT="$1" CERALIVE_IMAGE_APT_SOURCE=1 bash -c 'source "$1/mkosi/runtime/image-apt-source.sh"; image_apt_source_assert' _ "$ROOT"; }
check assert_root "$R"
cp -a "$R" "$WORK/r2"; printf 'deb https://deb.debian.org/debian trixie main\n' >"$WORK/r2/etc/apt/sources.list.d/extra.list"
refused 'an extra .list' assert_root "$WORK/r2"
cp -a "$R" "$WORK/r3"; printf 'deb https://x.example/ ./\n' >"$WORK/r3/etc/apt/sources.list"
refused 'sources.list' assert_root "$WORK/r3"
cp -a "$R" "$WORK/r4"; printf 'deb https://x.example/ ./\n' >"$WORK/r4/etc/apt/sources.list.d/hidden.conf"
refused 'a one-line deb entry under another name' assert_root "$WORK/r4"
cp -a "$R" "$WORK/r5"; printf '\nTypes: deb\nURIs: https://x.example/\nSuites: ./\n' >>"$WORK/r5/etc/apt/sources.list.d/openstreambox.sources"
refused 'a second stanza in the one file' assert_root "$WORK/r5"
cp -a "$R" "$WORK/r6"; printf 'x\n' >"$WORK/r6/etc/apt/preferences.d/ceralive-origin"
refused 'a legacy pin' assert_root "$WORK/r6"

# --- update capabilities from the single-source root -------------------------------
mkdir -p "$WORK/bin"
cat >"$WORK/bin/getent" <<'EOF'
#!/bin/sh
case "$2" in
  ceralive-ota) printf 'ceralive-ota:x:657:657::/nonexistent:/usr/sbin/nologin\n';;
  _apt) printf '_apt:x:42:65534::/nonexistent:/usr/sbin/nologin\n';;
  *) exit 2;;
esac
EOF
chmod +x "$WORK/bin/getent"
caps() { env PATH="$WORK/bin:$PATH" KERNEL_STAGE_MIN_CERAUI= "$ROOT/mkosi/runtime/rauc/install-update-capabilities.sh" "$1"; }
check caps "$R"
C="$R/usr/lib/ceralive/update-capabilities.json"
check grep -Fq '"origin-protection","apt-all-packages","reprune-hook","transport-uidrange"]' "$C"
if grep -Eq 'apt-credentials|kernel-apt-stage' "$C"; then bad 'credentials or kernel stage advertised'; else ok 'no apt-credentials, no kernel-apt-stage'; fi
cp -a "$R" "$WORK/r7"
sed -i '0,/Pin-Priority: 990/s//Pin-Priority: 500/' "$WORK/r7/etc/apt/preferences.d/openstreambox-origin"
refused 'a changed single-source pin' caps "$WORK/r7"
check test ! -e "$WORK/r7/usr/lib/ceralive/update-capabilities.json"
cp -a "$R" "$WORK/r8"
sed -i 's/"host":"updates.example.org"/"host":"other.example.org"/' "$WORK/r8/usr/lib/ceralive/image-apt-source.json"
refused 'pins for another host than the policy names' caps "$WORK/r8"

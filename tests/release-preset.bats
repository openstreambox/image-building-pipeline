#!/usr/bin/env bats
#
# Release trust pin and update-channel preset (lib/release-preset.sh and
# postinst.d/update-preset.sh).
#
# Proves, offline and with throwaway certificates generated per run:
#   * an unflagged build is unchanged: no pin, no preset, empty payloads;
#   * a preset is refused outside production, without a root pin, with a
#     keyring that is not exactly the pinned root, or with a file that the
#     updater's strict schema would refuse;
#   * the host validator rejects every case CeraUI's own reader rejects
#     (independent-review differential cases, plus a live run against a CeraUI
#     checkout when CERAUI_DIR is set);
#   * the keyring pin needs exactly one canonical PEM certificate: a second root
#     under any PEM label, or trailing bytes, fails;
#   * an accepted preset reaches the runtime layer byte for byte and is written
#     to /opt/ceralive as root 0644 files;
#   * ceralive-migrate-data seeds the pair as one unit (fresh, existing settings,
#     existing sidecar, both present, interrupted seed, image without preset);
#   * the payloads are forwarded through orchestrate.sh and mkosi.conf, and the
#     runtime executor calls the writer after /opt/ceralive exists.

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PIPELINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  LIB="$PIPELINE_DIR/lib/release-preset.sh"
  MODULE="$PIPELINE_DIR/mkosi/customize/postinst.d/update-preset.sh"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/preset"
  printf '%s' '{"packagesAuto":false,"systemAuto":false,"schedule":{"mode":"any-idle","start":"03:00","end":"05:00"},"channel":"stable","allowPackagesOverCellular":true,"allowSystemOverCellular":false}' \
    >"$T/preset/update-settings.json"
  printf '%s' '{"schema":1,"channel":"stable","channelUrl":"https://updates.example.invalid/c0ffee","allowSystemDownloadsOverCellular":false}' \
    >"$T/preset/update-image-channel.json"
  # Throwaway roots (NON-PRODUCTION); never a real key.
  for n in root other; do
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
      -subj "/CN=release-preset test ${n} (NON-PRODUCTION)" \
      -keyout "$T/${n}.key" -out "$T/${n}.pem" >/dev/null 2>&1
  done
  ROOT_SHA="$(openssl x509 -in "$T/root.pem" -outform DER | sha256sum | cut -d' ' -f1)"
}

resolve() { # env assignments..., then runs release_preset_resolve and prints the payloads
  run env -i PATH="$PATH" HOME="$HOME" "$@" bash -c '
    source "$1"
    release_preset_resolve
    printf "S=%s\nC=%s\n" "$CERALIVE_UPDATE_PRESET_SETTINGS_B64" "$CERALIVE_UPDATE_PRESET_CHANNEL_B64"
  ' _ "$LIB"
}

@test "unflagged development and production builds are unchanged" {
  resolve CERALIVE_BUILD_MODE=development RAUC_KEYRING_FILE="$T/root.pem"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "S=" ] && [ "${lines[1]}" = "C=" ]
  # A production build with a multi-certificate keyring is not this module's business unless pinned.
  cat "$T/root.pem" "$T/other.pem" >"$T/two.pem"
  resolve CERALIVE_BUILD_MODE=production RAUC_KEYRING_FILE="$T/two.pem"
  [ "$status" -eq 0 ]
}

@test "accepted preset is forwarded byte for byte" {
  resolve CERALIVE_BUILD_MODE=production RAUC_KEYRING_FILE="$T/root.pem" \
    CERALIVE_EXPECT_RAUC_ROOT_SHA256="$ROOT_SHA" CERALIVE_UPDATE_PRESET_DIR="$T/preset"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "${lines[0]#S=}" | base64 -d)" = "$(cat "$T/preset/update-settings.json")" ]
  [ "$(printf '%s' "${lines[1]#C=}" | base64 -d)" = "$(cat "$T/preset/update-image-channel.json")" ]
}

@test "a preset or pin is refused outside production" {
  resolve CERALIVE_BUILD_MODE=development RAUC_KEYRING_FILE="$T/root.pem" \
    CERALIVE_EXPECT_RAUC_ROOT_SHA256="$ROOT_SHA" CERALIVE_UPDATE_PRESET_DIR="$T/preset"
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs CERALIVE_BUILD_MODE=production"* ]]
  resolve RAUC_KEYRING_FILE="$T/root.pem" CERALIVE_EXPECT_RAUC_ROOT_SHA256="$ROOT_SHA"
  [ "$status" -ne 0 ]
}

@test "a preset without a root pin is refused" {
  resolve CERALIVE_BUILD_MODE=production RAUC_KEYRING_FILE="$T/root.pem" CERALIVE_UPDATE_PRESET_DIR="$T/preset"
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs CERALIVE_EXPECT_RAUC_ROOT_SHA256"* ]]
}

@test "the keyring must be exactly the pinned root" {
  resolve CERALIVE_BUILD_MODE=production RAUC_KEYRING_FILE="$T/other.pem" CERALIVE_EXPECT_RAUC_ROOT_SHA256="$ROOT_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not the expected release root"* ]]
  cat "$T/root.pem" "$T/other.pem" >"$T/two.pem"
  resolve CERALIVE_BUILD_MODE=production RAUC_KEYRING_FILE="$T/two.pem" CERALIVE_EXPECT_RAUC_ROOT_SHA256="$ROOT_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exactly one canonical PEM certificate"* ]]
  cat "$T/root.pem" "$T/root.key" >"$T/withkey.pem"
  resolve CERALIVE_BUILD_MODE=production RAUC_KEYRING_FILE="$T/withkey.pem" CERALIVE_EXPECT_RAUC_ROOT_SHA256="$ROOT_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"contains a private key"* ]]
  resolve CERALIVE_BUILD_MODE=production RAUC_KEYRING_FILE="$T/root.pem" CERALIVE_EXPECT_RAUC_ROOT_SHA256="ABC"
  [ "$status" -ne 0 ]
}

@test "the validator accepts the reference preset" {
  run "$LIB" validate "$T/preset"
  [ "$status" -eq 0 ]
}

bad_channel() { # json for update-image-channel.json -> expect refusal
  printf '%s' "$1" >"$T/preset/update-image-channel.json"
  run "$LIB" validate "$T/preset"
  [ "$status" -ne 0 ] || { echo "accepted: $1"; return 1; }
}

@test "the validator refuses channel files the updater would refuse" {
  bad_channel '{"schema":1,"channel":"stable","channelUrl":"http://updates.example.invalid/c"}'
  bad_channel '{"schema":1,"channel":"stable","channelUrl":"https://updates.example.invalid/c/"}'
  bad_channel '{"schema":1,"channel":"stable","channelUrl":"https://u:p@updates.example.invalid/c"}'
  bad_channel '{"schema":1,"channel":"stable","channelUrl":"https://updates.example.invalid/c?x=1"}'
  bad_channel '{"schema":1,"channel":"stable","channelUrl":"https://updates.example.invalid/c#x"}'
  bad_channel '{"schema":1,"channel":"drill","channelUrl":"https://updates.example.invalid/c"}'
  bad_channel '{"schema":2,"channel":"stable","channelUrl":"https://updates.example.invalid/c"}'
  bad_channel '{"schema":true,"channel":"stable","channelUrl":"https://updates.example.invalid/c"}'
  bad_channel '{"schema":1,"channel":"stable"}'
  bad_channel '{"schema":1,"channel":"stable","channelUrl":"https://updates.example.invalid/c","extra":1}'
  bad_channel '{"schema":1,"channel":"stable","channel":"beta","channelUrl":"https://updates.example.invalid/c"}'
  bad_channel '{"schema":1,"channel":"stable","channelUrl":"https://updates.example.invalid/c","allowSystemDownloadsOverCellular":"no"}'
  bad_channel '[1]'
  bad_channel 'not json'
}

@test "the validator refuses bad settings files and stray or linked files" {
  local good; good="$(cat "$T/preset/update-settings.json")"
  for bad in '{"packagesAuto":"false"}' '{"unknown":1}' '{"channel":"drill"}' \
             '{"schedule":{"mode":"window","start":"25:00"}}' \
             '{"channelUrl":"https://elsewhere.example.invalid/x"}' \
             '{"allowSystemOverCellular":true}'; do
    printf '%s' "$bad" >"$T/preset/update-settings.json"
    run "$LIB" validate "$T/preset"
    [ "$status" -ne 0 ] || { echo "accepted settings: $bad"; return 1; }
  done
  printf '%s' "$good" >"$T/preset/update-settings.json"
  touch "$T/preset/extra.json"
  run "$LIB" validate "$T/preset"
  [ "$status" -ne 0 ]
  rm "$T/preset/extra.json"
  mv "$T/preset/update-settings.json" "$T/real.json"
  ln -s "$T/real.json" "$T/preset/update-settings.json"
  run "$LIB" validate "$T/preset"
  [ "$status" -ne 0 ]
}

@test "the runtime writer installs both files as 0644 and is a no-op without a preset" {
  run env -i PATH="$PATH" CERALIVE_UPDATE_PRESET_ROOT="$T/root-empty" bash -c 'source "$1"; setup_update_preset' _ "$MODULE"
  [ "$status" -eq 0 ]
  [ ! -e "$T/root-empty/opt/ceralive" ]
  S="$(base64 -w0 <"$T/preset/update-settings.json")"
  C="$(base64 -w0 <"$T/preset/update-image-channel.json")"
  run env -i PATH="$PATH" CERALIVE_UPDATE_PRESET_ROOT="$T/rootfs" CERALIVE_UPDATE_PRESET_SETTINGS_B64="$S" \
    CERALIVE_UPDATE_PRESET_CHANNEL_B64="$C" bash -c 'source "$1"; setup_update_preset' _ "$MODULE"
  [ "$status" -eq 0 ]
  cmp "$T/preset/update-settings.json" "$T/rootfs/opt/ceralive/update-settings.json"
  cmp "$T/preset/update-image-channel.json" "$T/rootfs/opt/ceralive/update-image-channel.json"
  [ "$(stat -c %a "$T/rootfs/opt/ceralive/update-settings.json")" = 644 ]
  [ "$(stat -c %a "$T/rootfs/opt/ceralive/update-image-channel.json")" = 644 ]
  [ -z "$(find "$T/rootfs" -name '*.tmp')" ]
}

@test "the runtime writer refuses half a preset" {
  S="$(base64 -w0 <"$T/preset/update-settings.json")"
  run env -i PATH="$PATH" CERALIVE_UPDATE_PRESET_ROOT="$T/rootfs" CERALIVE_UPDATE_PRESET_SETTINGS_B64="$S" \
    bash -c 'source "$1"; setup_update_preset' _ "$MODULE"
  [ "$status" -ne 0 ]
  [ ! -e "$T/rootfs/opt/ceralive/update-settings.json" ]
}

@test "payloads are forwarded to the runtime chroot (env_names, export, PassEnvironment)" {
  local var
  for var in CERALIVE_UPDATE_PRESET_SETTINGS_B64 CERALIVE_UPDATE_PRESET_CHANNEL_B64; do
    grep -Eq "^[[:space:]]+.*\\b${var}\\b" "$PIPELINE_DIR/lib/orchestrate.sh"
    grep -Fq "export ${var}=" "$PIPELINE_DIR/lib/orchestrate.sh"
    grep -Eq "^PassEnvironment=.*\\b${var}\\b" "$PIPELINE_DIR/mkosi/mkosi.conf"
  done
  grep -Fq 'release_preset_resolve' "$PIPELINE_DIR/lib/orchestrate.sh"
}

@test "the runtime executor writes the preset after /opt/ceralive exists" {
  local main="$PIPELINE_DIR/mkosi/mkosi.images/runtime/mkosi.postinst.chroot" a b
  a="$(grep -n '^  create_ceralive_structure' "$main" | cut -d: -f1)"
  b="$(grep -n '^  setup_update_preset' "$main" | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ]
  grep -Eq '^  update-preset\.sh$' "$PIPELINE_DIR/mkosi/customize/postinst-lib.sh"
}

@test "the validator rejects every preset CeraUI's own reader rejects" {
  local name verdict accepted=0
  while read -r name verdict; do
    run "$LIB" validate "$T/cases/$name"
    if [ "$verdict" = reject ] && [ "$status" -eq 0 ]; then
      echo "accepted a preset CeraUI rejects: $name"; return 1
    fi
    [ "$status" -ne 0 ] || accepted=$((accepted + 1))
  done < <(python3 "$TESTS_DIR/fixtures/release-preset-cases.py" "$T/cases")
  # the baseline and other plain cases still pass
  run "$LIB" validate "$T/cases/00-baseline"
  [ "$status" -eq 0 ]
  [ "$accepted" -ge 1 ]
}

@test "live differential: every preset the validator accepts loads in CeraUI (CERAUI_DIR)" {
  [ -n "${CERAUI_DIR:-}" ] || skip "set CERAUI_DIR to a CeraUI checkout with bun dependencies installed"
  local name verdict
  while read -r name verdict; do
    run "$LIB" validate "$T/cases/$name"
    [ "$status" -eq 0 ] || continue
    run env CERALIVE_UPDATE_PRESET_CERAUI_DIR="$CERAUI_DIR" "$LIB" validate "$T/cases/$name"
    [ "$status" -eq 0 ] || { echo "CeraUI refused validator-accepted case $name: $output"; return 1; }
  done < <(python3 "$TESTS_DIR/fixtures/release-preset-cases.py" "$T/cases")
  run env CERALIVE_UPDATE_PRESET_CERAUI_DIR="$CERAUI_DIR" "$LIB" validate "$T/preset"
  [ "$status" -eq 0 ]
}

@test "the keyring pin refuses a second root under any PEM label, and trailing bytes" {
  local label
  for label in "TRUSTED CERTIFICATE" "X509 CERTIFICATE" "CERTIFICATE"; do
    { cat "$T/root.pem"; sed "s/CERTIFICATE-----/${label}-----/; s/-----BEGIN CERTIFICATE/-----BEGIN ${label}/; s/-----END CERTIFICATE/-----END ${label}/" "$T/other.pem" \
      | sed "s/-----BEGIN ${label}-----/-----BEGIN ${label}-----/"; } >"$T/smuggled.pem"
    grep -q -- "-----BEGIN ${label}-----" "$T/smuggled.pem"
    resolve CERALIVE_BUILD_MODE=production RAUC_KEYRING_FILE="$T/smuggled.pem" CERALIVE_EXPECT_RAUC_ROOT_SHA256="$ROOT_SHA"
    [ "$status" -ne 0 ] || { echo "accepted a second root labelled $label"; return 1; }
  done
  { cat "$T/root.pem"; printf 'junk\n'; } >"$T/junk.pem"
  resolve CERALIVE_BUILD_MODE=production RAUC_KEYRING_FILE="$T/junk.pem" CERALIVE_EXPECT_RAUC_ROOT_SHA256="$ROOT_SHA"
  [ "$status" -ne 0 ]
  sed 's/$/\r/' "$T/root.pem" >"$T/crlf.pem"
  resolve CERALIVE_BUILD_MODE=production RAUC_KEYRING_FILE="$T/crlf.pem" CERALIVE_EXPECT_RAUC_ROOT_SHA256="$ROOT_SHA"
  [ "$status" -ne 0 ]
}

@test "the pin is re-checked on the encoded keyring payload" {
  run env -i PATH="$PATH" CERALIVE_EXPECT_RAUC_ROOT_SHA256="$ROOT_SHA" bash -c \
    'source "$1"; release_preset_check_keyring_b64 "$(base64 -w0 <"$2")"' _ "$LIB" "$T/root.pem"
  [ "$status" -eq 0 ]
  run env -i PATH="$PATH" CERALIVE_EXPECT_RAUC_ROOT_SHA256="$ROOT_SHA" bash -c \
    'source "$1"; release_preset_check_keyring_b64 "$(base64 -w0 <"$2")"' _ "$LIB" "$T/other.pem"
  [ "$status" -ne 0 ]
  run env -i PATH="$PATH" bash -c 'source "$1"; release_preset_check_keyring_b64 "$(base64 -w0 <"$2")"' _ "$LIB" "$T/other.pem"
  [ "$status" -eq 0 ]   # unpinned builds are unchanged
  grep -Fq 'release_preset_check_keyring_b64 "${RAUC_ROOT_CA_B64}"' "$PIPELINE_DIR/lib/orchestrate.sh"
}

@test "the runtime writer chowns to root when it runs as root" {
  command -v unshare >/dev/null && unshare -r true 2>/dev/null || skip "no user namespaces here"
  S="$(base64 -w0 <"$T/preset/update-settings.json")"
  C="$(base64 -w0 <"$T/preset/update-image-channel.json")"
  run unshare -r env -i PATH="$PATH" CERALIVE_UPDATE_PRESET_ROOT="$T/rootns" CERALIVE_UPDATE_PRESET_SETTINGS_B64="$S" \
    CERALIVE_UPDATE_PRESET_CHANNEL_B64="$C" bash -c 'source "$1"; setup_update_preset && stat -c "%u %a" "$2"/opt/ceralive/*.json' _ "$MODULE" "$T/rootns"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^0 644$')" -eq 2 ]
}

# Run the real ceralive-migrate-data body from persistence.sh against a fake
# rootfs: $1 = scenario dir with opt/ceralive (image) and data/ceralive (/data).
migrate() {
  local d="$1"
  mkdir -p "$d/bin" "$d/etc/ceralive" "$d/data" "$d/varlog" "$d/nm"
  printf '#!/bin/sh\nexit 1\n' >"$d/bin/mountpoint"; chmod +x "$d/bin/mountpoint"
  printf '#!/bin/sh\nexit 0\n' >"$d/bin/logger"; chmod +x "$d/bin/logger"
  { echo 'set -euo pipefail'; echo "DATA=$d/data"; echo "WORKDIR=$d/opt/ceralive"; echo "NM_CONN=$d/nm"
    awk '/cat >>\/usr\/local\/sbin\/ceralive-migrate-data <<.EOF./{on=1; next} on && /^EOF$/{exit} on' \
      "$PIPELINE_DIR/mkosi/customize/postinst.d/persistence.sh" \
      | sed "s#/etc/ceralive#$d/etc/ceralive#g; s#/var/log#$d/varlog#g"; } >"$d/migrate.sh"
  grep -q 'update preset pair' "$d/migrate.sh"
  PATH="$d/bin:$PATH" bash "$d/migrate.sh" >"$d/migrate.log" 2>&1
}
image() { mkdir -p "$1/opt/ceralive" "$1/data/ceralive"; cp "$T/preset/"*.json "$1/opt/ceralive/"; }

@test "seeding A: a fresh card gets both preset files" {
  image "$T/A"; migrate "$T/A"
  cmp "$T/preset/update-settings.json" "$T/A/data/ceralive/update-settings.json"
  cmp "$T/preset/update-image-channel.json" "$T/A/data/ceralive/update-image-channel.json"
  [ -z "$(find "$T/A/data" -name '.*.seed')" ]
}

@test "seeding B: saved settings without a sidecar get no half preset" {
  image "$T/B"; printf '{"systemAuto":true}' >"$T/B/data/ceralive/update-settings.json"
  migrate "$T/B"
  [ "$(cat "$T/B/data/ceralive/update-settings.json")" = '{"systemAuto":true}' ]
  [ ! -e "$T/B/data/ceralive/update-image-channel.json" ]
}

@test "seeding C: a box with its own sidecar keeps it and gets no settings" {
  image "$T/C"; printf '{"schema":1,"channel":"beta"}' >"$T/C/data/ceralive/update-image-channel.json"
  migrate "$T/C"
  [ "$(cat "$T/C/data/ceralive/update-image-channel.json")" = '{"schema":1,"channel":"beta"}' ]
  [ ! -e "$T/C/data/ceralive/update-settings.json" ]
}

@test "seeding D: both files present are left alone" {
  image "$T/D"; printf 'S' >"$T/D/data/ceralive/update-settings.json"; printf 'C' >"$T/D/data/ceralive/update-image-channel.json"
  migrate "$T/D"
  [ "$(cat "$T/D/data/ceralive/update-settings.json")" = S ]
  [ "$(cat "$T/D/data/ceralive/update-image-channel.json")" = C ]
}

@test "seeding: an interrupted seed is completed on the next boot" {
  image "$T/I"; cp "$T/preset/update-image-channel.json" "$T/I/data/ceralive/"
  migrate "$T/I"
  cmp "$T/preset/update-settings.json" "$T/I/data/ceralive/update-settings.json"
  cmp "$T/preset/update-image-channel.json" "$T/I/data/ceralive/update-image-channel.json"
}

@test "seeding: an image without a preset seeds nothing and other json still seeds" {
  mkdir -p "$T/N/opt/ceralive" "$T/N/data/ceralive"; printf '{}' >"$T/N/opt/ceralive/config.json"
  migrate "$T/N"
  [ -e "$T/N/data/ceralive/config.json" ]
  [ ! -e "$T/N/data/ceralive/update-settings.json" ] && [ ! -e "$T/N/data/ceralive/update-image-channel.json" ]
}

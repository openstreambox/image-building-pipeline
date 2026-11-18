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
#   * an accepted preset reaches the runtime layer byte for byte and is written
#     to /opt/ceralive as 0644 files;
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
  [[ "$output" == *"exactly one root certificate, found 2"* ]]
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

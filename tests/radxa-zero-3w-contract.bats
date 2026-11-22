#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
#
# Pin the ZERO 3W's distinct boot and gadget inputs.
#
# Run:  bats tests/radxa-zero-3w-contract.bats

load manifest-helpers

@test "zero3w: family and board manifests validate" {
  run validate_manifest "$PIPELINE_DIR/manifests/families/rk3566.yaml" "$FAMILY_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VALID"* ]]
  run validate_manifest "$PIPELINE_DIR/manifests/boards/radxa-zero-3w.yaml" "$BOARD_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VALID"* ]]
}

@test "zero3w: resolve names the RK3566 DTB and U-Boot, not the RK3588 kernel" {
  run "$RESOLVE_SH" radxa-zero-3w
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAMILY='rk3566'"* ]]
  [[ "$output" == *"BOARD_ID='radxa-zero3'"* ]]
  [[ "$output" == *"DTB_NAME='rk3566-radxa-zero-3w.dtb'"* ]]
  [[ "$output" == *"SERIAL_CONSOLE='ttyS2:1500000'"* ]]
  [[ "$output" == *"UBOOT_PACKAGES='linux-u-boot-radxa-zero3-edge'"* ]]
  [[ "$output" == *"KERNEL_PACKAGES=''"* ]]
  [[ "$output" == *"DTB_PACKAGES=''"* ]]
  [[ "$output" == *"FIRMWARE_PACKAGES=''"* ]]
  [[ "$output" == *"COMPANION_KERNEL_FRAGMENT='manifests/kernel/rk3566-companion.fragment'"* ]]
  [[ "$output" == *"PARTITION_TEMPLATE='rk3588-ab'"* ]]
  [[ "$output" == *"RAUC_BOOTLOADER_ADAPTER='custom'"* ]]
  [[ "$output" != *"ceralive-rk3588"* ]]
  [[ "$output" != *"gstreamer1.0-rockchip"* ]]
  [[ "$output" != *"KERNEL_SOURCE_GIT_URL="* ]] || [[ "$output" == *"KERNEL_SOURCE_GIT_URL=''"* ]]
}

@test "zero3w: the shared boot script renders this board's env and is not forked" {
  run grep -n 'rk3566' "$PIPELINE_DIR/mkosi/platform/boot/boot.scr.cmd"
  [ "$status" -eq 1 ]

  local dest="$BATS_TEST_TMPDIR/boot"
  mkdir -p "$dest"
  run env SERIAL_CONSOLE='ttyS2:1500000' DTB_NAME='rk3566-radxa-zero-3w.dtb' \
    BOARD_ID='radxa-zero3' SINGLE_SLOT_FALLBACK='false' \
    bash "$PIPELINE_DIR/mkosi/platform/boot/install-boot.sh" \
    boot-partition "$dest" --allow-uncompiled
  [ "$status" -eq 0 ]
  grep -q 'fdtfile=rk3566-radxa-zero-3w.dtb' "$dest/cera_board.env"
  grep -q 'console=ttyS2,1500000' "$dest/cera_board.env"
  grep -q 'board_id=radxa-zero3' "$dest/cera_board.env"
  # Compiled from the shared boot.scr.cmd. The scratch address is the same
  # value mainline calls scriptaddr on both RK3568 and RK3588.
  grep -q 'setenv loadaddr 0x00c00000' "$PIPELINE_DIR/mkosi/platform/boot/boot.scr.cmd"
  grep -a -q 'setenv loadaddr 0x00c00000' "$dest/boot.scr"
  grep -a -Fq 'part uuid ${devtype} ${devnum}:2' "$dest/boot.scr"
}

@test "zero3w: normal build selects the trimmed companion image" {
  run env DRY_RUN=1 "$PIPELINE_DIR/build" radxa-zero-3w
  [ "$status" -eq 0 ]
  [[ "$output" == *"USB NCM+ACM"* ]]
  run env DRY_RUN=1 "$PIPELINE_DIR/build" radxa-zero-3w --release
  [ "$status" -ne 0 ]
  [[ "$output" == *"companion image only"* ]]
}

@test "zero3w: U-Boot plan resolves the signed archive pin and unified offset" {
  run bash -c "source '$PIPELINE_DIR/lib/fetch-debs.sh'; bsp_download_specs linux-u-boot-radxa-zero3-edge"
  [ "$status" -eq 0 ]
  [[ "$output" == "linux-u-boot-radxa-zero3-edge=26.8.3" ]]

  run bash "$LIB_DIR/write-bootloader.sh" plan --board radxa-zero3 --variant default
  [ "$status" -eq 0 ]
  [[ "$output" == *"u-boot-rockchip.bin"* ]]
  [[ "$output" == *"64"* ]]
  [[ "$output" == *"4766bb388d9cfede79c377e25a26d0830a46ee73b0d7c48078d5816b44b4bfa7"* ]]

  run bash "$LIB_DIR/write-bootloader.sh" plan --board radxa-zero3 --variant edge-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"no RK3588 raw-gap bootloader plan"* ]]
}

@test "zero3w: the ROCK 5B+ production resolve did not move" {
  run bash -c "diff -q '$PIPELINE_DIR/tests/manifests/fixtures/production-baseline/rock-5b-plus.params' <('$RESOLVE_SH' rock-5b-plus 2>/dev/null)"
  [ "$status" -eq 0 ]
}

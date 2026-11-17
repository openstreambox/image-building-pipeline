#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
#
# radxa-zero-3w-contract.bats — the RK3566 ZERO 3W is a board record, not an
# RK3588 image with the DTB renamed.
#
# The load-bearing assertions are negative:
#   * the resolved board is family rk3566 and names its own DTB and U-Boot,
#   * it does not inherit the RK3588 source kernel or the MPP userspace,
#   * the shared boot script is still the one file, with this board's env,
#   * the bootloader writer refuses the tuple, because no blob hash is pinned,
#   * the existing ROCK 5B+ production resolve is byte-identical.
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
  [[ "$output" == *"KERNEL_PACKAGES='linux-image-edge-rockchip64'"* ]]
  [[ "$output" == *"DTB_PACKAGES='linux-dtb-edge-rockchip64'"* ]]
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
}

@test "zero3w: U-Boot is unpinned and the writer refuses the tuple" {
  # A missing pin must fail closed. Guessing a version would write somebody
  # else's idbloader into the gap.
  run bash -c "source '$PIPELINE_DIR/lib/fetch-debs.sh'; bsp_download_specs linux-u-boot-radxa-zero3-edge"
  [ "$status" -ne 0 ]
  [[ "$output" == *"linux-u-boot-radxa-zero3-edge"* ]]

  run bash "$LIB_DIR/write-bootloader.sh" plan --board radxa-zero3 --variant default
  [ "$status" -ne 0 ]
  [[ "$output" == *"no RK3588 raw-gap bootloader plan"* ]]
  [[ "$output" == *"board 'radxa-zero3' variant 'default'"* ]]
}

@test "zero3w: the ROCK 5B+ production resolve did not move" {
  run bash -c "diff -q '$PIPELINE_DIR/tests/manifests/fixtures/production-baseline/rock-5b-plus.params' <('$RESOLVE_SH' rock-5b-plus 2>/dev/null)"
  [ "$status" -eq 0 ]
}

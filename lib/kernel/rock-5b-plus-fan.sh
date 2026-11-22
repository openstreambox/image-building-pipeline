#!/usr/bin/env bash
# Include the fan profile in the board source before building the kernel DTBs.
set -euo pipefail
rockchip="$1/arch/arm64/boot/dts/rockchip"
board="$rockchip/rk3588-rock-5b-plus.dts"
include='#include "ceralive-rock-5b-plus-fan.dtsi"'
test -f "$board"
install -m 0644 "$2" "$rockchip/ceralive-rock-5b-plus-fan.dtsi"
grep -Fxq "$include" "$board" || printf '\n%s\n' "$include" >> "$board"

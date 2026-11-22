#!/usr/bin/env bash
# Exercise both fan profiles against the same source coordinates as the image.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

params="$("$repo/lib/resolve.sh" rock-5b-plus --variant edge)"
eval "$params"

git init -q "$work/patches"
git -C "$work/patches" fetch --depth 1 "$KERNEL_SOURCE_PATCHES_GIT_URL" "$KERNEL_SOURCE_PATCHES_COMMIT"
git -C "$work/patches" checkout --quiet FETCH_HEAD
test "$(git -C "$work/patches" rev-parse HEAD)" = "$KERNEL_SOURCE_PATCHES_COMMIT"
test "$KERNEL_SOURCE_PATCHES_SERIES" = patches/series

"$work/patches/scripts/apply.sh" "$work/linux"
test "$(git -C "$work/linux" rev-parse "refs/tags/$KERNEL_SOURCE_TAG^{commit}")" = "$KERNEL_SOURCE_COMMIT"
bash "$repo/lib/kernel/ramoops.sh" "$work/linux" "$repo/manifests/kernel/rk3588-ramoops.dtsi"
CERALIVE_ROCK_FAN_DTS_TREE="$work/linux" bats "$repo/tests/rock-5b-plus-fan.bats"

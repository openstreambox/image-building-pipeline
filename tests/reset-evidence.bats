#!/usr/bin/env bats
setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}
@test "kernel device tree reservation compiles and applies without base symbols" {
  { printf '/dts-v1/; /plugin/; / { fragment@0 { target-path = "/"; __overlay__ {\n'
    sed '1,2d;$d' "$REPO/manifests/kernel/rk3588-ramoops.dtsi"
    printf '}; }; };\n'
  } > "$BATS_TEST_TMPDIR/overlay.dts"
  dtc -@ -I dts -O dtb -o "$BATS_TEST_TMPDIR/overlay.dtbo" "$BATS_TEST_TMPDIR/overlay.dts"
  printf '/dts-v1/; / { #address-cells = <2>; #size-cells = <2>; reserved-memory { #address-cells = <2>; #size-cells = <2>; ranges; }; };' > "$BATS_TEST_TMPDIR/base.dts"
  dtc -I dts -O dtb -o "$BATS_TEST_TMPDIR/base.dtb" "$BATS_TEST_TMPDIR/base.dts"
  fdtoverlay -i "$BATS_TEST_TMPDIR/base.dtb" -o "$BATS_TEST_TMPDIR/result.dtb" "$BATS_TEST_TMPDIR/overlay.dtbo"
  node=/reserved-memory/ramoops@1f000000
  [ "$(fdtget -tx "$BATS_TEST_TMPDIR/result.dtb" "$node" reg)" = '0 1f000000 0 100000' ]
  [ "$(fdtget -tx "$BATS_TEST_TMPDIR/result.dtb" "$node" record-size)" = 20000 ]
  [ "$(fdtget -tx "$BATS_TEST_TMPDIR/result.dtb" "$node" console-size)" = 80000 ]
  [ "$(fdtget -tx "$BATS_TEST_TMPDIR/result.dtb" "$node" max-reason)" = 2 ]
}
@test "kernel build injects the reservation only into both Rock board sources" {
  tree="$BATS_TEST_TMPDIR/linux/arch/arm64/boot/dts/rockchip"
  mkdir -p "$tree"
  for board in rk3588-rock-5b rk3588-rock-5b-plus rk3588-orangepi-5-plus; do
    printf '/dts-v1/; / { #address-cells = <2>; #size-cells = <2>; };\n' > "$tree/$board.dts"
  done
  bash "$REPO/lib/kernel/ramoops.sh" "$BATS_TEST_TMPDIR/linux" "$REPO/manifests/kernel/rk3588-ramoops.dtsi"
  bash "$REPO/lib/kernel/ramoops.sh" "$BATS_TEST_TMPDIR/linux" "$REPO/manifests/kernel/rk3588-ramoops.dtsi"
  for board in rk3588-rock-5b rk3588-rock-5b-plus; do
    [ "$(grep -c '/include/' "$tree/$board.dts")" = 1 ]
    dtc -I dts -O dtb -o "$BATS_TEST_TMPDIR/$board.dtb" "$tree/$board.dts"
    [ "$(fdtget -ts "$BATS_TEST_TMPDIR/$board.dtb" /reserved-memory/ramoops@1f000000 compatible)" = ramoops ]
  done
  ! grep -q ramoops "$tree/rk3588-orangepi-5-plus.dts"
  grep -q 'bash /in/ramoops.sh /src/linux /in/ramoops.dtsi' "$REPO/lib/build-kernel.sh"
  grep -q 'rk3588-ramoops.dtsi' "$REPO/lib/kernel/artifact-cache.sh"
  ! grep -q ramoops "$REPO/mkosi/platform/boot/boot.scr.cmd"
}
@test "stock pstore installer provides persistent storage, config and ordering" {
  export CERALIVE_RUNTIME_SRC="$REPO/mkosi/runtime"
  export PSTORE_DESTROOT="$BATS_TEST_TMPDIR/root"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  run bash -c 'source "$1/mkosi/customize/postinst.d/services.sh"; enable_service() { echo "enable $*" >> "$CALLS"; }; mask_service() { echo "mask $*" >> "$CALLS"; }; setup_reset_evidence' _ "$REPO"
  [ "$status" -eq 0 ]
  grep -qx 'Storage=external' "$PSTORE_DESTROOT/etc/systemd/pstore.conf.d/60-ceralive.conf"
  grep -qx 'Unlink=yes' "$PSTORE_DESTROOT/etc/systemd/pstore.conf.d/60-ceralive.conf"
  grep -qx 'RequiresMountsFor=/data/ceralive/pstore /var/lib/systemd/pstore' "$PSTORE_DESTROOT/etc/systemd/system/systemd-pstore.service.d/60-ceralive.conf"
  grep -qx 'BindPaths=/data/ceralive/pstore:/var/lib/systemd/pstore' "$PSTORE_DESTROOT/etc/systemd/system/systemd-pstore.service.d/60-ceralive.conf"
  grep -qx 'd /data/ceralive/pstore 0700 root root 30d' "$PSTORE_DESTROOT/etc/tmpfiles.d/ceralive-pstore.conf"
  grep -qx 'After=data.mount' "$PSTORE_DESTROOT/etc/systemd/system/systemd-tmpfiles-setup.service.d/60-ceralive-pstore.conf"
  grep -qx 'enable systemd-pstore.service' "$CALLS"
  ! grep -q mask "$CALLS"
  [ ! -e "$REPO/mkosi/runtime/ceralive-reset-evidence.sh" ]
  [ ! -e "$REPO/mkosi/runtime/ceralive-reset-evidence.service" ]
}
@test "tmpfiles creates private persistent storage and stock unit has no ordering cycle" {
  root="$BATS_TEST_TMPDIR/root"
  mkdir -p "$root"
  sed "s/root root/$(id -u) $(id -g)/" "$REPO/mkosi/runtime/ceralive-pstore.tmpfiles.conf" > "$BATS_TEST_TMPDIR/tmpfiles.conf"
  systemd-tmpfiles --root="$root" --create "$BATS_TEST_TMPDIR/tmpfiles.conf"
  [ "$(stat -c %a "$root/data/ceralive/pstore")" = 700 ]
  mkdir -p "$root/etc/systemd/system/systemd-pstore.service.d"
  cp "$REPO/mkosi/runtime/ceralive-pstore.service.conf" "$root/etc/systemd/system/systemd-pstore.service.d/60-ceralive.conf"
  mkdir -p "$root/etc/systemd/system/systemd-tmpfiles-setup.service.d"
  cp "$REPO/mkosi/runtime/ceralive-pstore-tmpfiles.service.conf" "$root/etc/systemd/system/systemd-tmpfiles-setup.service.d/60-ceralive-pstore.conf"
  printf '[Mount]\nWhat=/dev/disk/by-label/data\nWhere=/data\nType=ext4\n' > "$root/etc/systemd/system/data.mount"
  SYSTEMD_UNIT_PATH="$root/etc/systemd/system:/usr/lib/systemd/system" systemd-analyze verify systemd-pstore.service systemd-tmpfiles-setup.service data.mount
}
@test "documented stock output reader handles empty and populated fixture trees without writes" {
  store="$BATS_TEST_TMPDIR/pstore"
  mkdir -p "$store/123"
  run find "$store" -type f -name '*ramoops*' -exec cat -- '{}' +
  [ "$status" = 0 ]; [ -z "$output" ]
  printf 'panic fixture\n' > "$store/123/dmesg-ramoops-0"
  printf 'console fixture\n' > "$store/console-ramoops-0"
  before="$(find "$store" -type f -exec sha256sum '{}' +)"
  run find "$store" -type f -name '*ramoops*' -exec cat -- '{}' +
  [ "$status" = 0 ]; [[ "$output" == *'panic fixture'* && "$output" == *'console fixture'* ]]
  [ "$before" = "$(find "$store" -type f -exec sha256sum '{}' +)" ]
  grep -Fq -- "-name '*ramoops*' -exec cat" "$REPO/docs/reset-evidence.md"
}

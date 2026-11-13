#!/usr/bin/env bats
setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TOOL="$REPO/mkosi/runtime/ceralive-reset-evidence.sh"
  export CERALIVE_EVIDENCE_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$CERALIVE_EVIDENCE_ROOT"/{sys/fs/pstore,sys/class/watchdog/watchdog2,proc/sys/kernel/random,data}
  echo 12345678-1234-1234-1234-123456789abc > "$CERALIVE_EVIDENCE_ROOT/proc/sys/kernel/random/boot_id"
}
@test "collects pstore, watchdog and exposed reset cause before clearing only pstore" {
  echo panic > "$CERALIVE_EVIDENCE_ROOT/sys/fs/pstore/dmesg-ramoops-0"
  echo console > "$CERALIVE_EVIDENCE_ROOT/sys/fs/pstore/console-ramoops-0"
  echo 32 > "$CERALIVE_EVIDENCE_ROOT/sys/class/watchdog/watchdog2/bootstatus"
  mkdir -p "$CERALIVE_EVIDENCE_ROOT/sys/kernel"
  echo watchdog > "$CERALIVE_EVIDENCE_ROOT/sys/kernel/reset_reason"
  run bash "$TOOL" collect
  [ "$status" -eq 0 ]
  run bash "$TOOL" latest
  [ "$status" -eq 0 ]
  [[ "$output" == *'"watchdog2": "32"'* ]]
  [[ "$output" == *'watchdog'* && "$output" == *'reset_reason'* ]]
  [ -z "$(ls -A "$CERALIVE_EVIDENCE_ROOT/sys/fs/pstore")" ]
  [ "$(cat "$CERALIVE_EVIDENCE_ROOT/sys/class/watchdog/watchdog2/bootstatus")" = 32 ]
  grep -rq panic "$CERALIVE_EVIDENCE_ROOT/data/log/reset-evidence"
}
@test "missing optional evidence is explicit and same boot retry is idempotent" {
  bash "$TOOL" collect
  bash "$TOOL" collect
  [ "$(find "$CERALIVE_EVIDENCE_ROOT/data/log/reset-evidence" -name evidence.json | wc -l)" -eq 1 ]
  run bash "$TOOL" latest
  [[ "$output" == *'"reset_causes": {}'* ]]
}
@test "failed persistence and oversized input leave pstore intact" {
  mkdir "$CERALIVE_EVIDENCE_ROOT/data/log"
  touch "$CERALIVE_EVIDENCE_ROOT/data/log/reset-evidence"
  echo panic > "$CERALIVE_EVIDENCE_ROOT/sys/fs/pstore/dmesg-ramoops-0"
  run bash "$TOOL" collect
  [ "$status" -ne 0 ]
  [ -f "$CERALIVE_EVIDENCE_ROOT/sys/fs/pstore/dmesg-ramoops-0" ]
  rm "$CERALIVE_EVIDENCE_ROOT/data/log/reset-evidence"
  truncate -s 17000000 "$CERALIVE_EVIDENCE_ROOT/sys/fs/pstore/dmesg-ramoops-0"
  run bash "$TOOL" collect
  [ "$status" -ne 0 ]
  [ -f "$CERALIVE_EVIDENCE_ROOT/sys/fs/pstore/dmesg-ramoops-0" ]
}
@test "retention keeps eight boot collections even with unsynchronised clocks" {
  for n in {1..10}; do
    printf '%08d-1234-1234-1234-123456789abc\n' "$n" > "$CERALIVE_EVIDENCE_ROOT/proc/sys/kernel/random/boot_id"
    bash "$TOOL" collect
  done
  [ "$(find "$CERALIVE_EVIDENCE_ROOT/data/log/reset-evidence" -name evidence.json | wc -l)" -eq 8 ]
}
@test "ramoops reference overlay compiles and applies without base symbols" {
  dtc -@ -I dts -O dtb -o "$BATS_TEST_TMPDIR/overlay.dtbo" "$REPO/mkosi/platform/boot/rk3588-ramoops.dts"
  printf '/dts-v1/; / { #address-cells = <2>; #size-cells = <2>; reserved-memory { #address-cells = <2>; #size-cells = <2>; ranges; }; };' > "$BATS_TEST_TMPDIR/base.dts"
  dtc -I dts -O dtb -o "$BATS_TEST_TMPDIR/base.dtb" "$BATS_TEST_TMPDIR/base.dts"
  fdtoverlay -i "$BATS_TEST_TMPDIR/base.dtb" -o "$BATS_TEST_TMPDIR/result.dtb" "$BATS_TEST_TMPDIR/overlay.dtbo"
  [ "$(fdtget -tx "$BATS_TEST_TMPDIR/result.dtb" /reserved-memory/ramoops@1f000000 reg)" = '0 1f000000 0 100000' ]
}
@test "boot reservation and collection are installed and ordered before other pstore consumers" {
  grep -q 'ramoops@1f000000' "$REPO/mkosi/platform/boot/boot.scr.cmd"
  grep -q 'Before=systemd-pstore.service' "$REPO/mkosi/runtime/ceralive-reset-evidence.service"
  grep -q 'After=data.mount' "$REPO/mkosi/runtime/ceralive-reset-evidence.service"
  grep -q 'setup_reset_evidence' "$REPO/mkosi/customize/postinst.d/services.sh"
}

@test "installer uses committed sources and gives collector sole pstore ownership" {
  export CERALIVE_RUNTIME_SRC="$REPO/mkosi/runtime"
  export RESET_EVIDENCE_SBIN_DIR="$BATS_TEST_TMPDIR/sbin"
  export RESET_EVIDENCE_UNIT_DIR="$BATS_TEST_TMPDIR/units"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  run bash -c 'source "$1/mkosi/customize/postinst.d/services.sh"; enable_service() { echo "enable $*" >> "$CALLS"; }; mask_service() { echo "mask $*" >> "$CALLS"; }; setup_reset_evidence' _ "$REPO"
  [ "$status" -eq 0 ]
  [ -x "$RESET_EVIDENCE_SBIN_DIR/ceralive-reset-evidence" ]
  cmp "$REPO/mkosi/runtime/ceralive-reset-evidence.sh" "$RESET_EVIDENCE_SBIN_DIR/ceralive-reset-evidence"
  grep -q 'mask systemd-pstore.service' "$CALLS"
  grep -q 'enable ceralive-reset-evidence.service' "$CALLS"
}
@test "symlinks are not copied or cleared and latest never collects" {
  echo private > "$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$CERALIVE_EVIDENCE_ROOT/sys/fs/pstore/link"
  run bash "$TOOL" latest
  [ "$status" -eq 1 ]
  bash "$TOOL" collect
  [ -L "$CERALIVE_EVIDENCE_ROOT/sys/fs/pstore/link" ]
  [ "$(cat "$BATS_TEST_TMPDIR/elsewhere")" = private ]
}
@test "bootloader properties agree with compiled overlay" {
  dtc -@ -I dts -O dtb -o "$BATS_TEST_TMPDIR/o.dtbo" "$REPO/mkosi/platform/boot/rk3588-ramoops.dts"
  for prop in reg record-size console-size max-reason; do
    value="$(fdtget -tx "$BATS_TEST_TMPDIR/o.dtbo" /fragment@0/__overlay__/ramoops@1f000000 "$prop")"
    line="$(grep "fdt set /reserved-memory/ramoops@1f000000 $prop " "$REPO/mkosi/platform/boot/boot.scr.cmd")"
    cells="$(printf '%s' "$line" | sed 's/.*<//;s/>.*//;s/0x//g')"
    [ "$cells" = "$value" ]
  done
}

@test "fsync failure cannot acknowledge pstore" {
  echo panic > "$CERALIVE_EVIDENCE_ROOT/sys/fs/pstore/dmesg-ramoops-0"
  mkdir "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/sync"
  chmod +x "$BATS_TEST_TMPDIR/bin/sync"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$TOOL" collect
  [ "$status" -ne 0 ]
  [ -f "$CERALIVE_EVIDENCE_ROOT/sys/fs/pstore/dmesg-ramoops-0" ]
}
@test "latest follows durable sequence rather than wall clock or file mtime" {
  bash "$TOOL" collect
  first="$(find "$CERALIVE_EVIDENCE_ROOT/data/log/reset-evidence" -name evidence.json)"
  echo 00000002-1234-1234-1234-123456789abc > "$CERALIVE_EVIDENCE_ROOT/proc/sys/kernel/random/boot_id"
  bash "$TOOL" collect
  second="$(find "$CERALIVE_EVIDENCE_ROOT/data/log/reset-evidence" -name '*00000002*')"
  touch -d '2038-01-01' "$(dirname "$first")"
  touch -d '1970-01-02' "$second"
  run bash "$TOOL" latest
  [ "$status" -eq 0 ]
  [[ "$output" == *'00000002-1234-1234-1234-123456789abc'* ]]
}
@test "stale partial copy is recovered and archives remain private" {
  mkdir -p "$CERALIVE_EVIDENCE_ROOT/data/log/reset-evidence/.pending-abandoned"
  echo panic > "$CERALIVE_EVIDENCE_ROOT/sys/fs/pstore/dmesg-ramoops-0"
  bash "$TOOL" collect
  [ ! -d "$CERALIVE_EVIDENCE_ROOT/data/log/reset-evidence/.pending-abandoned" ]
  file="$(find "$CERALIVE_EVIDENCE_ROOT/data/log/reset-evidence" -name evidence.json)"
  [ "$(stat -c %a "$file")" = 600 ]
  [ "$(stat -c %a "$(dirname "$file")")" = 700 ]
}

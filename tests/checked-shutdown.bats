#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  cat >"$BATS_TEST_TMPDIR/bin/systemctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$CALLS"
exit "${SYSTEMCTL_STATUS:-0}"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/systemctl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}
@test "planned reboot checks inhibitors without force or fallback" {
  run bash "$ROOT/mkosi/runtime/ceralive-power.sh" reboot
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "--check-inhibitors=yes reboot" ]
}
@test "planned shutdown checks inhibitors" {
  run bash "$ROOT/mkosi/runtime/ceralive-power.sh" poweroff
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "--check-inhibitors=yes poweroff" ]
}
@test "inhibited action is refused calmly and never retried" {
  export SYSTEMCTL_STATUS=1
  run bash "$ROOT/mkosi/runtime/ceralive-power.sh" reboot
  [ "$status" -eq 75 ]
  [[ "$output" == *"not restarted"* ]]
  [ "$(wc -l <"$CALLS")" -eq 1 ]
}
@test "unknown operation cannot submit a power action" {
  run bash "$ROOT/mkosi/runtime/ceralive-power.sh" --force
  [ "$status" -eq 64 ]
  [ ! -e "$CALLS" ]
}
@test "runtime assembly installs the checked power entrypoint" {
  export CERALIVE_RUNTIME_SRC="$ROOT/mkosi/runtime"
  export CERALIVE_RAUC_ACTIVATE_HELPER_DIR="$BATS_TEST_TMPDIR/helpers"
  export CERALIVE_RAUC_ACTIVATE_UNIT_DIR="$BATS_TEST_TMPDIR/units"
  run bash -euc 'source "$1"; enable_service() { :; }; setup_rauc_activation' _ "$ROOT/mkosi/customize/postinst.d/services.sh"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$CERALIVE_RAUC_ACTIVATE_HELPER_DIR/ceralive-power")" = 755 ]
  cmp "$ROOT/mkosi/runtime/ceralive-power.sh" "$CERALIVE_RAUC_ACTIVATE_HELPER_DIR/ceralive-power"
}
@test "disposable runner shutdown also checks inhibitors" {
  grep -Fq 'systemctl --check-inhibitors=yes poweroff' "$ROOT/ci/kernel-runner/guest-job.sh"
}
@test "updater cannot autonomously bypass planned shutdown" {
  grep -Eq '^post_update_reboot[[:space:]]*=[[:space:]]*false' "$ROOT/mkosi/runtime/hawkbit-updater/config.conf"
}

@test "extra arguments cannot disable inhibitor checks" {
  run bash "$ROOT/mkosi/runtime/ceralive-power.sh" reboot --force
  [ "$status" -eq 64 ]
  [ ! -e "$CALLS" ]
}
@test "an unavailable shutdown command fails closed without fallback" {
  export SYSTEMCTL_STATUS=127
  run bash "$ROOT/mkosi/runtime/ceralive-power.sh" poweroff
  [ "$status" -eq 75 ]
  [[ "$output" == *"not powered off"* ]]
  [ "$(wc -l <"$CALLS")" -eq 1 ]
}
@test "interrupted power submission reports an uncertain result without retry" {
  export SYSTEMCTL_STATUS=143
  run bash "$ROOT/mkosi/runtime/ceralive-power.sh" reboot
  [ "$status" -eq 70 ]
  [[ "$output" == *"could not be confirmed"* ]]
  [ "$(wc -l <"$CALLS")" -eq 1 ]
}

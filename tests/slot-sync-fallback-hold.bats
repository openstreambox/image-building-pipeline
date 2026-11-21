#!/usr/bin/env bats

setup() {
  REPO="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  WORK="${BATS_TEST_TMPDIR}"
  source "${BATS_TEST_DIRNAME}/lib/kernel-stage-fixture.sh"
  stage_fixture_init
  STAGE_FIXTURE_UNCONFIRMED=1 stage_fixture_reset
  cat >"${WORK}/mirror-rauc" <<'SH'
#!/bin/bash
case "$*" in
  'status --detailed --output-format=json') cat "${FIXTURE}/rauc.json" ;;
  'status mark-bad other'|'status mark-good other') printf '%s\n' "$*" >>"${FIXTURE}/mirror-writes" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "${WORK}/mirror-rauc"
  healthy_boot 1
}

healthy_boot() {
  local boot_id
  printf -v boot_id 'aaaaaaaa-aaaa-4aaa-8aaa-%012d' "$1"
  printf '%s\n' "${boot_id}" >"${CERALIVE_HEALTHCHECK_BOOT_ID_FILE}"
  edit_json "${CERALIVE_HEALTHY_STATE_FILE}" ".boot_id=\"$boot_id\""
}

edit_json() {
  jq -c "$2" "$1" >"${WORK}/json"
  mv "${WORK}/json" "$1"
}

mirror() {
  RAUC_BIN="${WORK}/mirror-rauc" RSYNC_BIN=/usr/bin/rsync "${CERALIVE_SLOT_SYNC_LIB}" "$1"
}

held() {
  run mirror run
  [ "$status" -eq 75 ]
  [[ "$output" == *fallback-hold* && "$output" == *"$1/3 healthy boots"* ]]
  [ ! -e "${FIXTURE}/mirror-writes" ]
}

@test "check is read-only and boots one and two hold; the third distinct healthy boot mirrors" {
  run mirror check
  [ "$status" -eq 0 ]
  jq -e '.would_refuse and .refuse_reason == "fallback-hold"' <<<"$output"
  [ ! -e "${FIXTURE}/state/healthy-boots-A" ]
  grep -Fxq 'ExecStartPost=-/usr/libexec/ceralive/ceralive-slot-sync observe'     "${REPO}/mkosi/runtime/ceralive-mark-good.service"
  run mirror observe
  [ "$status" -eq 0 ]
  [ ! -e "${FIXTURE}/mirror-writes" ]
  healthy_boot 2
  held 2
  held 2
  healthy_boot 3
  run mirror run
  [ "$status" -eq 0 ]
  [ "$(cat "${FIXTURE}/mirror-writes")" = $'status mark-bad other\nstatus mark-good other' ]
}

@test "root confirmation releases only the current generation and still requires health" {
  held 1
  run env UID_FIXTURE=1000 RAUC_BIN="${WORK}/mirror-rauc" "${CERALIVE_SLOT_SYNC_LIB}" confirm
  [ "$status" -ne 0 ]
  held 1
  run mirror confirm
  [ "$status" -eq 0 ]
  [ ! -e "${FIXTURE}/mirror-writes" ]
  printf 'stale\n' >"${CERALIVE_HEALTHCHECK_BOOT_ID_FILE}"
  run mirror run
  [ "$status" -eq 75 ]
  [[ "$output" == *healthy-state-mismatch* ]]
  healthy_boot 2
  run mirror run
  [ "$status" -eq 0 ]
  rm "${FIXTURE}/mirror-writes"
  edit_json "${FIXTURE}/rauc.json" '.slots[0]["rootfs.0"].slot_status.installed.count += 1'
  held 1
}

@test "power loss before rename leaves the previous observation intact" {
  held 1
  cp "${FIXTURE}/state/healthy-boots-A" "${WORK}/before"
  healthy_boot 2
  cat >"${WORK}/cut-power" <<'SH'
#!/bin/bash
if [[ "$1" == *healthy-boots-A.tmp.* ]]; then
  kill -KILL "$PPID"
fi
SH
  chmod +x "${WORK}/cut-power"
  run env SYNC_BIN="${WORK}/cut-power" RAUC_BIN="${WORK}/mirror-rauc" "${CERALIVE_SLOT_SYNC_LIB}" run
  [ "$status" -eq 137 ]
  cmp "${WORK}/before" "${FIXTURE}/state/healthy-boots-A"
  [ ! -e "${FIXTURE}/mirror-writes" ]
  healthy_boot 3
  held 2
  healthy_boot 4
  run mirror run
  [ "$status" -eq 0 ]
}

@test "a factory pair mirrors but the first OTA protects its factory predecessor" {
  edit_json "${FIXTURE}/rauc.json" 'del(.slots[1]["rootfs.1"].slot_status)'
  held 1
  edit_json "${FIXTURE}/rauc.json" 'del(.slots[0]["rootfs.0"].slot_status)'
  run mirror run
  [ "$status" -eq 0 ]
}

@test "rollback can boot the untouched previous slot without inheriting the newer slot count" {
  held 1
  healthy_boot 2
  held 2
  STAGE_FIXTURE_UNCONFIRMED=1 stage_fixture_boot_b
  edit_json "${FIXTURE}/rauc.json" '.slots[0]["rootfs.0"].boot_status="bad"'
  healthy_boot 3
  held 1
  [ "$(cat "${FIXTURE}/eligibility")" = good ]
}

@test "kernel staging also waits before changing eligibility or writing the target" {
  run stage_run
  [ "$status" -eq 75 ]
  [[ "$output" == *fallback-hold* ]]
  [ ! -e "${FIXTURE}/state/kernel-state.json" ]
  ! grep -q 'mark-bad\|^mirror$' "${FIXTURE}/events"
  [ "$(cat "${FIXTURE}/eligibility")" = good ]
  run mirror confirm
  [ "$status" -eq 0 ]
  run stage_run
  [ "$status" -eq 0 ]
  [ "$(jq -r .state "${FIXTURE}/state/kernel-state.json")" = staged ]
}

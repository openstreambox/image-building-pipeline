#!/usr/bin/env bash
#
# boot-script-slot-power.test.sh — the A/B selector's ROCK 5B+ B-key slot power hold.
#
# A DW5821e powered while RESET# is low waits in fastboot (413c:81d6). The selector
# switches the slot's 3.3 V (EKEY_EN, U-Boot GPIO B26) off before it loads the kernel,
# so Linux powers the card only after its RESET# hog has released reset. This drives
# boot.scr.cmd with stubbed U-Boot commands (as boot-script-sanitize.test.sh does) and
# asserts:
#   * on rock-5b-plus, `gpio clear B26` runs before the first kernel/DTB load and
#     before booti, nothing sets the line again, and the kernel learns the outcome;
#   * a failing gpio command still boots, reporting `failed`;
#   * any other board (or no board file) never touches a GPIO;
#   * the boot partition of a freshly flashed card carries the hold, and the compiled
#     boot.scr that ceralive-boot-script-sync ships to the field does NOT (nothing boots
#     boot.scr.prev if a replaced selector fails), yet still boots the board.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT_SCRIPT="${HERE}/../mkosi/platform/boot/boot.scr.cmd"
INSTALL_BOOT="${HERE}/../mkosi/platform/boot/install-boot.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
# shellcheck source=lib/assertions.sh
source "${HERE}/lib/assertions.sh"

# simulate <board_id or __none__> <gpio exit status> <trace file>
# shellcheck disable=SC1090,SC2034,SC2154
simulate() (
  local board="$1" gpio_rc="$2" trace="$3"
  devtype=mmc devnum=0 kernel_addr_r=0x2000 fdt_addr_r=0x3000 ramdisk_addr_r=0x4000
  filesize=0 loadaddr=0x1000 loaded=""
  step() { printf '%s\n' "$*" >>"${trace}"; }
  setenv() { local name="$1"; shift; printf -v "${name}" '%s' "$*"; }
  load() {
    loaded="${*: -1}"
    [[ "${loaded}" == cera_board.env && "${board}" == __none__ ]] && return 1
    filesize=128
  }
  env() {
    if [[ "$1" == import && "${loaded}" == cera_board.env ]]; then
      fdtfile=rk3588-rock-5b-plus.dtb board_id="${board}"
    fi
    filesize=128
  }
  fatwrite() { :; }
  gpio() { step "gpio $*"; return "${gpio_rc}"; }
  ext4load() { step "ext4load ${*: -1}"; filesize=1024; }
  exit() { step ABORTED; builtin exit 0; }
  reset() { step RESET; builtin exit 0; }
  booti() { step "booti ${bootargs}"; builtin exit 0; }
  set +u
  source "${BOOT_SCRIPT}" >/dev/null
)

run_case() { : >"${WORK}/$1"; simulate "$2" "$3" "${WORK}/$1"; cat "${WORK}/$1"; }

echo "== ROCK 5B+: slot power held before the kernel is loaded"
trace="$(run_case rock rock-5b-plus 0)"
[[ "$(head -1 <<<"${trace}")" == 'gpio clear B26' ]] \
  && ok "the first board action is 'gpio clear B26' (EKEY_EN low), before any kernel or DTB load" \
  || bad "first action was '$(head -1 <<<"${trace}")'"
[[ "$(grep -c '^gpio ' <<<"${trace}")" -eq 1 ]] \
  && ok "the selector issues exactly one gpio command and never raises the rail again" \
  || bad "gpio commands: $(grep '^gpio ' <<<"${trace}" | tr '\n' ';')"
grep -q '^booti .* cera_slot_power=held$' <<<"${trace}" \
  && ok "the kernel command line reports cera_slot_power=held" \
  || bad "booti line: $(grep '^booti' <<<"${trace}")"

echo "== ROCK 5B+: the gpio command fails"
trace="$(run_case rock-fail rock-5b-plus 1)"
grep -q '^booti .* cera_slot_power=failed$' <<<"${trace}" \
  && ok "a failing gpio command still boots and reports cera_slot_power=failed" \
  || bad "trace: $(tr '\n' ';' <<<"${trace}")"

echo "== other boards"
for board in orange-pi-5-plus __none__; do
  trace="$(run_case "other-${board}" "${board}" 0)"
  ! grep -q '^gpio ' <<<"${trace}" && ! grep -q 'cera_slot_power' <<<"${trace}" \
    && ok "${board}: no gpio command and no cera_slot_power argument" \
    || bad "${board}: $(tr '\n' ';' <<<"${trace}")"
done

echo "== compiled boot.scr: flashed cards get the hold, the field-sync payload does not"
if command -v mkimage >/dev/null 2>&1; then
  BOARD_ENV=(SERIAL_CONSOLE=ttyS2:1500000 DTB_NAME=rk3588-rock-5b-plus.dtb
    BOARD_ID=rock-5b-plus COMPATIBLE_STRING=ceralive-rock-5b-plus SINGLE_SLOT_FALLBACK=false)
  env "${BOARD_ENV[@]}" bash "${INSTALL_BOOT}" boot-payload "${WORK}/payload" >/dev/null 2>&1
  env "${BOARD_ENV[@]}" bash "${INSTALL_BOOT}" boot-partition "${WORK}/partition" >/dev/null 2>&1
  grep -aq 'if gpio clear B26; then setenv cera_slot_power "held"; fi' "${WORK}/partition/boot.scr" 2>/dev/null \
    && ok "the boot partition's boot.scr carries the slot power hold" \
    || bad "the boot partition's boot.scr lacks the slot power hold"
  { [[ -s "${WORK}/payload/boot.scr" ]] && ! grep -aq 'gpio\|cera_slot_power' "${WORK}/payload/boot.scr"; } \
    && ok "the payload for ceralive-boot-script-sync has no gpio command (no field delivery of the hold)" \
    || bad "the field-sync payload carries the slot power hold"
  # The field selector must still be a working selector on the ROCK 5B+.
  tail -c +73 "${WORK}/payload/boot.scr" >"${WORK}/field.cmd"
  trace="$(BOOT_SCRIPT="${WORK}/field.cmd"; run_case field rock-5b-plus 0)"
  { grep -q '^booti root=PARTLABEL=rootfs_a ' <<<"${trace}" && ! grep -q '^gpio ' <<<"${trace}"; } \
    && ok "the field selector boots slot A on the ROCK 5B+ without touching a GPIO" \
    || bad "field selector trace: $(tr '\n' ';' <<<"${trace}")"
else
  ok "mkimage not installed: compiled-script check skipped (CI installs it)"
fi

printf '\nRESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]

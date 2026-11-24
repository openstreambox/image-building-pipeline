#!/bin/bash
#
# ceralive-typec-policy — request host data role on settled sink/device attaches.
#
# Rock 5B+ exception (CeraUI#414): its kernel must start sink-first so a front
# charger cannot cut the board's only supply during probe. Only a confirmed back
# input (SARADC channel 6, two readings) permits source preference and a bounded
# source->dual cycle to make an attached camera charge. Absent/unknown back power
# leaves the connector alone. Other boards retain their existing DR_SWAP policy.
# PR_SWAP is never requested: the proven correction is a port_type cycle, always
# restoring dual, rather than writing power_role. A tmpfs marker suppresses the
# cycle's partner-add recursion; a failed-attach marker prevents charger loops.
# The FUSB302 can sit toggling as the source without ever raising an attach
# interrupt until it is reset, so the first recheck that finds the port source
# with no partner rebinds the port's FUSB302 before any cycle. If that early
# rebind finds nothing, the cycles run as before and, once they are used up, one
# more rebind follows (a device plugged in after the early one).
# A cycle that leaves the port with no partner is followed by one more cycle
# with sink preferred: a reset with source preferred restarts tcpm in
# SRC_UNATTACHED, from where the FUSB302 raises no attach for a later plug.
#
# udev starts the systemd oneshot on partner and port add events. The boot enable
# is a second coldplug path, so every run inspects CURRENT sysfs state and is safe
# when the partner was already attached before userspace started.
#
# Test seams (production uses every default):
#   CERALIVE_TYPEC_CLASS_DIR   Type-C class dir (default /sys/class/typec)
#   CERALIVE_TYPEC_PORT        connector name (default port0)
#   CERALIVE_TYPEC_WAIT        settle deadline seconds (default 10)
#   CERALIVE_TYPEC_POLL        settle poll interval seconds (default 0.25)
#   CERALIVE_TYPEC_DATA_ROLE_WRITE write target (default current data_role;
#                                  test-only rejected/readback seam)
#   CERALIVE_TYPEC_DT_ROOT     device tree (default /proc/device-tree)
#   CERALIVE_TYPEC_IIO_DIR     IIO devices (default /sys/bus/iio/devices)
#   CERALIVE_TYPEC_RUN_DIR     volatile state (default /run/ceralive-typec)
#   CERALIVE_TYPEC_ADC_RETRY   unknown ADC retry seconds (default 15)
#   CERALIVE_TYPEC_MODE        recheck skips ADC retry and the DR_SWAP loop
#   CERALIVE_TYPEC_SETTLED_POWER_ROLE post-cycle readback (default power_role)
#   CERALIVE_TYPEC_NOPARTNER_MAX      recheck cycles per boot with no partner (default 3)
#   CERALIVE_TYPEC_NOPARTNER_SPACING  seconds between those cycles (default 30)
#   CERALIVE_TYPEC_EARLY_SETTLE       seconds after a cycle before the early
#                                     FUSB302 rebind (default 5)
#   CERALIVE_TYPEC_REPROBE_SETTLE     seconds after the last cycle before the
#                                     late FUSB302 rebind (default 20)
#   CERALIVE_TYPEC_REARM_SETTLE       seconds a partner must stay gone after a
#                                     rebind before one more rebind (default 30)
#   CERALIVE_TYPEC_REARM_MAX          such re-arm rebinds per boot (default 3)
#   CERALIVE_TYPEC_REBIND_GAP         seconds between unbind and bind (default 1)
#   CERALIVE_TYPEC_BIND_WAIT          seconds to wait for each driver-link change (default 3)
#   CERALIVE_TYPEC_OTG_DEV            OTG controller (default /sys/bus/platform/devices/fc000000.usb)
#   CERALIVE_TYPEC_SINK_RESET_SETTLE  seconds the sink-first reset may take before
#                                     the source preference returns (default 2)

set -uo pipefail

CLASS_DIR="${CERALIVE_TYPEC_CLASS_DIR:-/sys/class/typec}"
PORT="${CERALIVE_TYPEC_PORT:-port0}"
WAIT_SECONDS="${CERALIVE_TYPEC_WAIT:-10}"
POLL_INTERVAL="${CERALIVE_TYPEC_POLL:-0.25}"

# Journal priority from the message's own tag: ERROR -> err, WARNING -> warning,
# everything else -> notice. The ten-second recheck unit caps its journal at
# notice (LogLevelMax) so systemd's per-tick start/finish lines are dropped; the
# lines this script prints are state changes and must stay above that cap.
log() {
  local prio=5
  case "$*" in ERROR:*) prio=3 ;; WARNING:*) prio=4 ;; esac
  printf '<%s>ceralive-typec-policy: %s\n' "${prio}" "$*"
}
die() { printf '<3>ceralive-typec-policy: %s\n' "$*" >&2; exit 1; }

[[ "${WAIT_SECONDS}" =~ ^[0-9]+$ ]] || die "CERALIVE_TYPEC_WAIT must be an unsigned integer"
NOPARTNER_MAX="${CERALIVE_TYPEC_NOPARTNER_MAX:-3}"
NOPARTNER_SPACING="${CERALIVE_TYPEC_NOPARTNER_SPACING:-30}"
[[ "${NOPARTNER_MAX}" =~ ^[0-9]+$ && "${NOPARTNER_SPACING}" =~ ^[0-9]+$ ]] \
  || die "CERALIVE_TYPEC_NOPARTNER_MAX and _SPACING must be unsigned integers"
REPROBE_SETTLE="${CERALIVE_TYPEC_REPROBE_SETTLE:-20}"
[[ "${REPROBE_SETTLE}" =~ ^[0-9]+$ ]] || die "CERALIVE_TYPEC_REPROBE_SETTLE must be an unsigned integer"
EARLY_SETTLE="${CERALIVE_TYPEC_EARLY_SETTLE:-5}"
[[ "${EARLY_SETTLE}" =~ ^[0-9]+$ ]] || die "CERALIVE_TYPEC_EARLY_SETTLE must be an unsigned integer"
REBIND_GAP="${CERALIVE_TYPEC_REBIND_GAP:-1}"
REARM_SETTLE="${CERALIVE_TYPEC_REARM_SETTLE:-30}"
REARM_MAX="${CERALIVE_TYPEC_REARM_MAX:-3}"
[[ "${REARM_SETTLE}" =~ ^[0-9]+$ && "${REARM_MAX}" =~ ^[0-9]+$ ]] \
  || die "CERALIVE_TYPEC_REARM_SETTLE and _MAX must be unsigned integers"
[[ "${REBIND_GAP}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "CERALIVE_TYPEC_REBIND_GAP must be a non-negative number"
BIND_WAIT="${CERALIVE_TYPEC_BIND_WAIT:-3}"
[[ "${BIND_WAIT}" =~ ^[0-9]+$ ]] || die "CERALIVE_TYPEC_BIND_WAIT must be an unsigned integer"
OTG_DEV="${CERALIVE_TYPEC_OTG_DEV:-/sys/bus/platform/devices/fc000000.usb}"
SINK_RESET_SETTLE="${CERALIVE_TYPEC_SINK_RESET_SETTLE:-2}"
[[ "${SINK_RESET_SETTLE}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "CERALIVE_TYPEC_SINK_RESET_SETTLE must be a non-negative number"

PORT_DIR="${CLASS_DIR}/${PORT}"
PARTNER_DIR="${PORT_DIR}-partner"
DATA_ROLE="${PORT_DIR}/data_role"
POWER_ROLE="${PORT_DIR}/power_role"
DATA_ROLE_WRITE="${CERALIVE_TYPEC_DATA_ROLE_WRITE:-${DATA_ROLE}}"
RUN_DIR="${CERALIVE_TYPEC_RUN_DIR:-/run/ceralive-typec}"
MODE="${CERALIVE_TYPEC_MODE:-normal}"
rock_settled_source=0

# active_role <file> — the entry the kernel marked active. `[dual] source sink`
# -> dual. Falls back to the raw trimmed value for a kernel that ever drops the
# brackets, so the idempotency check degrades to "compare literally" rather than
# to "always rewrite".
active_role() {
  local raw token
  raw="$(cat -- "$1")"
  token="$(printf '%s\n' "${raw}" | sed -n 's/.*\[\([a-z_]\{1,\}\)\].*/\1/p')"
  if [[ -n "${token}" ]]; then
    printf '%s\n' "${token}"
  else
    printf '%s\n' "${raw//[[:space:]]/}"
  fi
}

# Every FUSB302 rebind decision is journaled under this tag, with a syslog
# priority prefix (<3> error, <4> warning, <5> notice) that journald strips and
# applies, so `journalctl -p warning` finds the failures.
reprobe_log() {
  local prio=5
  case "$1" in ERROR) prio=3 ;; WARNING) prio=4 ;; esac
  printf '<%s>ceralive-typec-policy: %s: fusb302-reprobe: %s\n' "${prio}" "$1" "$2"
}

# reprobe_write <what> <path> <value> — one sysfs write; a failure is journaled
# at warning with the kernel's error text. Whether the write took effect is
# still judged by the driver link afterwards, never by this exit status.
reprobe_write() {
  local what="$1" path="$2" value="$3" errf="${RUN_DIR}/reprobe-write.err" rc=0 err=""
  # Never let the error capture stop the write itself.
  : >"${errf}" 2>/dev/null || errf=/dev/null
  # stderr first, so a failed open of ${path} is captured as well.
  printf '%s\n' "${value}" 2>"${errf}" >"${path}" || rc=$?
  if (( rc != 0 )); then
    [[ ! -r "${errf}" ]] || err="$(tr '\n' ' ' <"${errf}")"
    err="${err%" "}"
    if [[ -n "${err}" ]]; then
      reprobe_log WARNING "${what} write for ${value} failed: ${err}"
    else
      reprobe_log WARNING "${what} write for ${value} failed (exit status ${rc}, no error text)"
    fi
  fi
  [[ "${errf}" == /dev/null ]] || rm -f "${errf}"
}

# reprobe_record <state> — the once-per-boot marker; false when it cannot be kept.
reprobe_record() {
  printf '%s %s\n' "$1" "$(date +%s)" >"${RUN_DIR}/reprobe"
}

# reprobe_defer <reason> — a condition that may still change; journal it only
# when it differs from the last deferral so the ten-second recheck stays quiet.
reprobe_defer() {
  local previous=""
  [[ ! -r "${RUN_DIR}/reprobe-deferred" ]] || previous="$(cat "${RUN_DIR}/reprobe-deferred")"
  [[ "${previous}" != "$1" ]] || return 0
  reprobe_log INFO "deferred: $1"
  printf '%s\n' "$1" >"${RUN_DIR}/reprobe-deferred" \
    || reprobe_log ERROR "cannot record the deferral"
}

# mono_now — whole seconds since boot into MONO_NOW. The policy runs early in
# boot, where NTP may step the wall clock (a board without an RTC starts days
# behind). Bash SECONDS follows that step, and a deadline taken before it would
# expire at once, so every wait counts /proc/uptime instead. The first call
# picks the clock for the whole run: uptime, or SECONDS if /proc/uptime cannot
# be read then, so a deadline never compares across the two. On uptime, a
# later failed read advances the last good value by the SECONDS elapsed since
# it (only a clock step inside that same gap could shift it).
MONO_SRC="" MONO_UP=0 MONO_AT=0
mono_now() {
  local up=""
  if [[ "${MONO_SRC}" != seconds ]]; then
    { read -r up _ </proc/uptime; } 2>/dev/null || up=""
    up="${up%%.*}"
  fi
  if [[ "${up}" =~ ^[0-9]+$ ]]; then
    MONO_SRC=uptime MONO_UP="${up}" MONO_AT="${SECONDS}" MONO_NOW="${up}"
  elif [[ "${MONO_SRC}" == uptime ]]; then
    MONO_NOW=$((MONO_UP + SECONDS - MONO_AT))
  else
    MONO_SRC=seconds MONO_NOW="${SECONDS}"
  fi
}

# wait_bound <device dir> <want: bound|unbound> — poll the driver link, the only
# trustworthy result: a deferred probe fails the bind write yet may bind later,
# and a repeated write to a bound device fails with EBUSY.
wait_bound() {
  local deadline
  mono_now
  deadline=$((MONO_NOW + BIND_WAIT))
  while :; do
    if [[ -L "$1/driver" ]]; then
      [[ "$2" == bound ]] && return 0
    else
      [[ "$2" == unbound ]] && return 0
    fi
    mono_now
    (( MONO_NOW < deadline )) || return 1
    sleep "${POLL_INTERVAL}"
  done
}

# rock_fusb302_reprobe <last cycle epoch> <now epoch> [early | re-arm k/max] —
# returns 2 when it did nothing (marker, settle time or a deferral), 3 when it
# only recorded a driver or I2C skip, otherwise 0. Runs only from the Rock
# recheck with back power present and no partner: early, before the no-partner
# cycles; late, once they are used up; or as a re-arm (below).
# It unbinds and rebinds the one I2C device that owns ${PORT} (the J11 data
# connector; the board's supply comes from the back input), once per boot, then
# re-reads the partner. The driver directory comes from the device's own driver
# link: the kernel registers the driver as typec_fusb302 (modalias
# i2c:typec_fusb302) although the module file is fusb302.ko. Unbinding a single
# device avoids a module unload that would touch every FUSB302.
#
# On the bench only `modprobe -r fusb302; modprobe fusb302` has been shown to
# recover the stuck chip; this rebind runs the same remove/probe path but is
# unproven until a board boots with it. If the TCPM worker were wedged in I2C,
# the unbind write could block in D state: the unit then times out holding the
# lock, later runs log a lock timeout, and boot itself is not held (timer-driven).
#
# Early: on cold boots with a modem on J11 the chip was stuck in most boots
# measured, and a rebind recovered every one, while the port_type cycles helped
# once. So the first recheck that sees the port source with no partner rebinds
# right away (no cycle run yet, or EARLY_SETTLE after one), once per boot. Only a
# `no-partner` result leaves the late rebind available, after the cycles and only
# while no partner has been seen since: that keeps a modem plugged in a minute
# after power-on covered as before.
#
# An empty J11 looks exactly like a stuck one (source, no partner, no CC event in
# sysfs), so on a back-powered boot with nothing plugged in the early and the late
# rebind each run once and end in an info line. A working data path without a
# partner object (a device enumerated under the OTG controller) is left alone.
#
# Re-arm: a hot unplug and replug sticks the chip the same way, and a second
# rebind recovers it. So once a partner has been seen after this boot's rebind
# and then disappears, the recheck allows one more rebind when the port has
# stayed partnerless for CERALIVE_TYPEC_REARM_SETTLE seconds (rock_reprobe_rearm),
# at most CERALIVE_TYPEC_REARM_MAX times per boot. Its third argument labels
# that run and bypasses only the once-per-boot marker; every other guard holds.
# An empty port after an unplug costs one such rebind; it cannot loop, because
# only a partner that appears again re-arms it.
rock_fusb302_reprobe() {
  local last="$1" now="$2" rearm="${3:-}" power dev name driver bus deadline data label="" prev=""
  local early=0
  if [[ "${rearm}" == early ]]; then
    early=1 rearm=""
    [[ ! -e "${RUN_DIR}/reprobe" ]] || return 2
    (( last == 0 || now - last >= EARLY_SETTLE )) || return 2
  elif [[ -z "${rearm}" ]]; then
    [[ ! -e "${RUN_DIR}/reprobe" ]] || rock_late_reprobe_allowed || return 2
    (( now - last >= REPROBE_SETTLE )) || return 2
  fi
  [[ -z "${rearm}" || ! -r "${RUN_DIR}/reprobe" ]] || read -r prev _ <"${RUN_DIR}/reprobe"

  if [[ ! -r "${PORT_DIR}/preferred_role" ||
        "$(active_role "${PORT_DIR}/preferred_role")" != source ]]; then
    reprobe_defer "${PORT} source preference not active"
    return 2
  fi
  power=unreadable
  [[ ! -r "${POWER_ROLE}" ]] || power="$(active_role "${POWER_ROLE}")"
  if [[ "${power}" != source ]]; then
    reprobe_defer "${PORT} power_role=${power}, not source"
    return 2
  fi
  # Device ports start at 1: every root hub has its own N-0:1.0 interface, and
  # host role with nothing enumerated is not a working data path.
  if compgen -G "${OTG_DEV}/xhci-hcd.*/usb[0-9]*/[0-9]*-[1-9]*" >/dev/null; then
    reprobe_defer "a USB device is enumerated under ${OTG_DEV##*/}"
    return 2
  fi

  dev="$(readlink -f -- "${PORT_DIR}/device" 2>/dev/null)" || dev=""
  name="${dev##*/}"
  driver=""
  [[ -z "${dev}" || ! -L "${dev}/driver" ]] || driver="$(readlink -f -- "${dev}/driver")"
  if [[ -z "${dev}" || ! "${name}" =~ ^[0-9]+-[0-9a-f]{4}$ ]]; then
    reprobe_log INFO "skipped: ${PORT} is not backed by an I2C device"
    reprobe_record skipped || reprobe_log ERROR "cannot record the skip"
    rm -f "${RUN_DIR}/detached"
    return 3
  fi
  case "${driver##*/}" in
    typec_fusb302 | fusb302) ;;
    *)
      reprobe_log INFO "skipped: ${name} is bound to '${driver##*/}', not typec_fusb302"
      reprobe_record skipped || reprobe_log ERROR "cannot record the skip"
      rm -f "${RUN_DIR}/detached"
      return 3
      ;;
  esac
  bus="${driver%/drivers/*}"

  # Record before acting: a crash or kill mid-rebind must not earn another one.
  if ! reprobe_record attempted; then
    reprobe_log ERROR "cannot record the attempt — no rebind"
    return 0
  fi
  if (( early )); then
    : >"${RUN_DIR}/reprobe-early" || reprobe_log ERROR "cannot record the early rebind"
  elif [[ -z "${rearm}" && -e "${RUN_DIR}/reprobe-early" ]]; then
    # Unrecorded, the marker stays `attempted`, which allows no further rebind.
    if ! : >"${RUN_DIR}/reprobe-late"; then
      reprobe_log ERROR "cannot record the late rebind — no rebind"
      return 0
    fi
  fi
  if [[ -e "${PARTNER_DIR}" ]]; then
    reprobe_log INFO "skipped: a partner appeared on ${PORT}"
    if [[ -n "${rearm}" && -n "${prev}" ]]; then
      # The partner came back on its own: keep the earlier outcome so it re-arms
      # the next detach, and leave the count unspent.
      reprobe_record "${prev}" || reprobe_log ERROR "cannot restore the rebind outcome"
    else
      reprobe_record skipped || reprobe_log ERROR "cannot record the skip"
    fi
    return 0
  fi
  if [[ -n "${rearm}" ]]; then
    # Spend the re-arm only now that every guard and the partner check passed.
    rm -f "${RUN_DIR}/detached"
    if ! printf '%s\n' "${rearm%%/*}" >"${RUN_DIR}/rearm"; then
      reprobe_log ERROR "cannot record the re-arm count — no rebind"
      return 0
    fi
    label="re-arm ${rearm}: "
  fi
  if [[ -n "${rearm}" ]]; then
    reprobe_log INFO "${label}${PORT} lost its partner and has had none for ${REARM_SETTLE}s or more: rebinding ${name} from ${driver##*/}"
  elif (( early )); then
    label="early: "
    if (( last == 0 )); then
      reprobe_log INFO "${label}${PORT} is source with no partner before any cycle: rebinding ${name} from ${driver##*/}"
    else
      reprobe_log INFO "${label}${PORT} is source with no partner $((now - last))s after a cycle: rebinding ${name} from ${driver##*/}"
    fi
  else
    reprobe_log INFO "${PORT} is source with no partner $((now - last))s after the last cycle: rebinding ${name} from ${driver##*/}"
  fi
  reprobe_write unbind "${driver}/unbind" "${name}"
  if ! wait_bound "${dev}" unbound; then
    reprobe_log ERROR "unbind of ${name} did not take — ${name} left bound, not retrying this boot"
    reprobe_record failed-unbind || reprobe_log ERROR "cannot record the failure"
    return 0
  fi
  sleep "${REBIND_GAP}"
  reprobe_write bind "${driver}/bind" "${name}"
  if ! wait_bound "${dev}" bound; then
    reprobe_log WARNING "${name} not bound after bind — asking the bus to probe it"
    reprobe_write drivers_probe "${bus}/drivers_probe" "${name}"
  fi
  if ! wait_bound "${dev}" bound; then
    sleep 2
    reprobe_write bind "${driver}/bind" "${name}"
  fi
  if ! wait_bound "${dev}" bound; then
    reprobe_log ERROR "${name} is still unbound after bind, bus probe and a second bind — ${PORT} has no controller until reboot"
    reprobe_record failed-bind || reprobe_log ERROR "cannot record the failure"
    return 0
  fi

  mono_now
  deadline=$((MONO_NOW + WAIT_SECONDS))
  while [[ ! -e "${PARTNER_DIR}" ]]; do
    mono_now
    (( MONO_NOW < deadline )) || break
    sleep "${POLL_INTERVAL}"
  done
  if [[ ! -d "${PORT_DIR}" ]]; then
    reprobe_log WARNING "${name} is bound again but ${PORT} did not come back (present: $(cd "${CLASS_DIR}" 2>/dev/null && echo port* || echo none)) — the policy only manages ${PORT}"
    reprobe_record port-missing || reprobe_log ERROR "cannot record the result"
  elif [[ -e "${PARTNER_DIR}" ]]; then
    power=unknown data=unknown
    [[ ! -r "${POWER_ROLE}" ]] || power="$(active_role "${POWER_ROLE}")"
    [[ ! -r "${DATA_ROLE}" ]] || data="$(active_role "${DATA_ROLE}")"
    reprobe_log INFO "${label}partner found after rebinding ${name}: power_role=${power} data_role=${data}"
    reprobe_record recovered || reprobe_log ERROR "cannot record the result"
  else
    if (( early )); then
      reprobe_log INFO "${label}no partner ${WAIT_SECONDS}s after rebinding ${name}: J11 is empty or the chip is still stuck — the no-partner cycles follow, then one late rebind"
    else
      reprobe_log INFO "${label}no partner ${WAIT_SECONDS}s after rebinding ${name}: J11 is empty or the chip is still stuck — only a partner that appears again re-arms another rebind"
    fi
    reprobe_record no-partner || reprobe_log ERROR "cannot record the result"
  fi
  return 0
}

# note_partner_since_early — any partner the policy sees after the early rebind
# rules out the late one for the rest of the boot, whatever the re-arm state
# (which the re-arm clears as it goes). Called wherever a partner is observed,
# so even one that leaves before the next run counts.
note_partner_since_early() {
  [[ -e "${RUN_DIR}/reprobe-early" && ! -e "${RUN_DIR}/partner-since-early" ]] || return 0
  : >"${RUN_DIR}/partner-since-early" \
    || log "ERROR: cannot record the partner seen after the early rebind"
}

# rock_late_reprobe_allowed — the late rebind after an early one: only when the
# early rebind ended in `no-partner`, the late one has not run, and no partner
# has been seen since (`partner-since-early`, kept for the boot; the re-arm
# files are a second check). Any other recorded outcome, skipped and failed
# ones included, keeps the once-per-boot rule.
rock_late_reprobe_allowed() {
  local state=""
  [[ -e "${RUN_DIR}/reprobe-early" && ! -e "${RUN_DIR}/reprobe-late" &&
     ! -e "${RUN_DIR}/partner-since-early" ]] || return 1
  [[ ! -e "${RUN_DIR}/partner-seen" && ! -e "${RUN_DIR}/detached" &&
     ! -e "${RUN_DIR}/rearm" ]] || return 1
  [[ -r "${RUN_DIR}/reprobe" ]] && read -r state _ <"${RUN_DIR}/reprobe"
  [[ "${state}" == no-partner ]]
}

# rock_reprobe_rearm <last cycle epoch> <now epoch> — runs in the Rock recheck
# with back power present and no partner, under the policy lock. Turns a
# recorded partner (partner-seen) into a detach time, then hands one labelled
# rebind to rock_fusb302_reprobe once the port has stayed partnerless for
# REARM_SETTLE seconds and REPROBE_SETTLE seconds have passed since the last
# port_type cycle. Returns 0 when it acted (rebind attempted, skipped, or the cap
# reached), 1 to let the caller go on with the usual no-partner handling: nothing
# pending, not due yet, or the rebind deferred on a guard.
rock_reprobe_rearm() {
  local last="$1" now="$2" gone=0 count=0
  if [[ -e "${RUN_DIR}/partner-seen" ]]; then
    rm -f "${RUN_DIR}/partner-seen"
    if printf '%s\n' "${now}" >"${RUN_DIR}/detached"; then
      reprobe_log INFO "${PORT} lost its partner after this boot's rebind: one more rebind if none returns within ${REARM_SETTLE}s"
    else
      reprobe_log ERROR "cannot record the detach — no re-arm"
    fi
  fi
  [[ -r "${RUN_DIR}/detached" ]] || return 1
  read -r gone <"${RUN_DIR}/detached"
  [[ "${gone}" =~ ^[0-9]+$ ]] || { rm -f "${RUN_DIR}/detached"; return 1; }
  # Not due yet: the port_type cycles go on as before (same lock, so the two
  # never overlap, and the rebind waits REPROBE_SETTLE after any cycle).
  (( now - gone >= REARM_SETTLE && now - last >= REPROBE_SETTLE )) || return 1
  [[ ! -r "${RUN_DIR}/rearm" ]] || read -r count <"${RUN_DIR}/rearm"
  [[ "${count}" =~ ^[0-9]+$ ]] || count=0
  if (( count >= REARM_MAX )); then
    rm -f "${RUN_DIR}/detached"
    reprobe_log INFO "re-arm limit of ${REARM_MAX} per boot reached — no further rebind this boot"
    return 0
  fi
  # A deferral (return 2) leaves the re-arm pending and lets this tick's usual
  # no-partner handling run, so the port_type cycles can still make the port
  # source again (e.g. after a charger or camera left it as sink).
  rock_fusb302_reprobe "${last}" "${now}" "$((count + 1))/${REARM_MAX}"
  (( $? != 2 ))
}

rock_back_power_correction() {
  local adc first second decision=unknown previous="" retry deadline stamp=0
  local settled_power identity=unknown original_port_type rstate
  local blind=0 tries=0 last=0 now
  retry="${CERALIVE_TYPEC_ADC_RETRY:-15}"
  [[ "${MODE}" != recheck ]] || retry=0
  [[ "${retry}" =~ ^[0-9]+$ ]] || die "CERALIVE_TYPEC_ADC_RETRY must be an unsigned integer"

  # A detached partner starts a new attach, regardless of the current ADC result.
  if [[ ! -e "${PARTNER_DIR}" ]]; then
    rm -f "${RUN_DIR}/failed"
  fi
  mono_now
  deadline=$((MONO_NOW + retry))
  while :; do
    for adc in "${CERALIVE_TYPEC_IIO_DIR:-/sys/bus/iio/devices}"/iio:device*; do
      [[ -r "${adc}/name" && "$(cat "${adc}/name")" == fec10000.adc ]] || continue
      first="$(cat "${adc}/in_voltage6_raw" 2>/dev/null)"
      sleep 0.1
      second="$(cat "${adc}/in_voltage6_raw" 2>/dev/null)"
      if [[ "${first}" =~ ^[0-9]+$ && "${second}" =~ ^[0-9]+$ ]]; then
        if (( 10#${first} >= 500 && 10#${second} >= 500 )); then
          decision=present
        elif (( 10#${first} <= 100 && 10#${second} <= 100 )); then
          decision=absent
        fi
      fi
      break
    done
    mono_now
    [[ "${decision}" == unknown ]] && (( MONO_NOW < deadline )) || break
    sleep 1
  done
  [[ ! -r "${RUN_DIR}/state" ]] || previous="$(cat "${RUN_DIR}/state")"
  if [[ "${MODE}" != recheck || "${previous}" != "${decision}" ]]; then
    log "INFO: Rock back power=${decision}"
  fi
  printf '%s\n' "${decision}" >"${RUN_DIR}/state" || log "ERROR: cannot record Rock back-power state"
  [[ "${decision}" == present ]] || return 0

  # No port means nothing to write. At boot the driver may simply not have
  # registered it yet (its port-add event runs the policy again), so the boot run
  # only notes that. The recheck says so once per change instead of failing the
  # preference write on every tick (e.g. after a failed rebind).
  if [[ ! -d "${PORT_DIR}" ]]; then
    if [[ "${MODE}" != recheck ]]; then
      log "INFO: ${PORT} not registered yet — no connector writes"
    elif [[ ! -e "${RUN_DIR}/port-absent" ]]; then
      log "INFO: ${PORT} is absent — no connector writes until it returns"
      : >"${RUN_DIR}/port-absent" \
        || printf '<3>ceralive-typec-policy: ERROR: cannot record the absent %s\n' "${PORT}"
    fi
    return 0
  fi
  if [[ -e "${RUN_DIR}/port-absent" ]]; then
    rm -f "${RUN_DIR}/port-absent"
    log "INFO: ${PORT} is present again"
  fi

  # Set Try.SRC before the no-partner exit, so the next attach needs no reset.
  if [[ ! -r "${PORT_DIR}/preferred_role" ||
        "$(active_role "${PORT_DIR}/preferred_role")" != source ]]; then
    log "INFO: Rock back power present: requesting preferred_role=source"
    if ! printf '%s\n' source >"${PORT_DIR}/preferred_role"; then
      log "ERROR: cannot set Rock source preference"
      return 0
    fi
  fi
  if [[ -e "${PARTNER_DIR}" ]]; then
    # A partner seen after this boot's rebind arms one more rebind for when it
    # leaves (rock_reprobe_rearm). Only outcomes that left a working controller
    # qualify; skipped and failed rebinds never re-arm.
    rm -f "${RUN_DIR}/detached"
    note_partner_since_early
    if [[ ! -e "${RUN_DIR}/partner-seen" && -r "${RUN_DIR}/reprobe" ]]; then
      read -r rstate _ <"${RUN_DIR}/reprobe"
      case "${rstate}" in
        recovered | no-partner | port-missing)
          : >"${RUN_DIR}/partner-seen" || log "ERROR: cannot record the partner for the rebind re-arm"
          ;;
      esac
    fi
    # A partner that reappears right after our cycle (a plain charger flaps) must
    # not earn fresh tries; only one that has stayed up for a minute does.
    if [[ -r "${RUN_DIR}/nopartner" ]]; then
      read -r tries last <"${RUN_DIR}/nopartner"
      if [[ ! "${last}" =~ ^[0-9]+$ ]] || (( $(date +%s) - last >= 60 )); then
        rm -f "${RUN_DIR}/nopartner"
      fi
      tries=0 last=0
    fi
    [[ ! -e "${RUN_DIR}/failed" ]] || return 0
  else
    # A camera that advertises Rp but never drives VBUS leaves tcpm waiting in
    # SNK_DEBOUNCED and no partner is ever created. Only the ten-second recheck
    # (coldplug has settled by then) looks for it, a bounded number of times.
    [[ "${MODE}" == recheck ]] || return 0
    [[ ! -r "${RUN_DIR}/nopartner" ]] || read -r tries last <"${RUN_DIR}/nopartner"
    [[ "${tries}" =~ ^[0-9]+$ && "${last}" =~ ^[0-9]+$ ]] || { tries=0; last=0; }
    now="$(date +%s)"
    ! rock_reprobe_rearm "${last}" "${now}" || return 0
    if (( tries >= NOPARTNER_MAX )); then
      rock_fusb302_reprobe "${last}" "${now}"
      return 0
    fi
    # The early rebind goes first; a deferral, a skip that touched nothing or a
    # rebind already spent lets this tick's cycle run as before.
    rock_fusb302_reprobe "${last}" "${now}" early
    case $? in 2 | 3) ;; *) return 0 ;; esac
    (( now - last >= NOPARTNER_SPACING )) || return 0
    if ! mkdir -p "${RUN_DIR}" || ! printf '%s %s\n' "$((tries + 1))" "${now}" >"${RUN_DIR}/nopartner"; then
      log "ERROR: cannot record Rock no-partner try — no port_type write"
      return 0
    fi
    blind=1
  fi
  if (( blind == 0 )); then
    mono_now
    deadline=$((MONO_NOW + WAIT_SECONDS))
    while [[ ! -r "${POWER_ROLE}" ]]; do
      mono_now
      (( MONO_NOW < deadline )) || return 0
      sleep "${POLL_INTERVAL}"
    done
    [[ -e "${PARTNER_DIR}" && "$(active_role "${POWER_ROLE}")" == sink ]] || return 0
    if [[ -e "${RUN_DIR}/corrected" ]]; then
      stamp="$(stat -c %Y "${RUN_DIR}/corrected")" || return 0
      (( $(date +%s) - stamp >= 10 )) || return 0
    fi
  fi
  original_port_type="$(active_role "${PORT_DIR}/port_type")"
  case "${original_port_type}" in
    dual | sink | source) ;;
    *)
      log "ERROR: cannot record Rock port_type before correction — no port_type write"
      return 0
      ;;
  esac
  if ! mkdir -p "${RUN_DIR}" || ! touch "${RUN_DIR}/corrected"; then
    log "ERROR: cannot record Rock correction marker — no port_type write"
    return 0
  fi
  if (( blind )); then
    log "INFO: Rock back power present, no partner seen: cycling port_type=source then dual (try $((tries + 1))/${NOPARTNER_MAX})"
  else
    log "INFO: Rock back power present: cycling port_type=source then dual"
  fi
  if ! printf '%s\n' source >"${PORT_DIR}/port_type"; then
    log "ERROR: Rock port_type=source write was rejected"
    return 0
  fi
  if ! printf '%s\n' dual >"${PORT_DIR}/port_type"; then
    log "ERROR: Rock port_type=dual write was rejected — retrying restoration"
    if ! printf '%s\n' dual >"${PORT_DIR}/port_type"; then
      log "ERROR: Rock port_type=dual retry was rejected — restoring recorded port_type=${original_port_type}"
      if ! printf '%s\n' "${original_port_type}" >"${PORT_DIR}/port_type"; then
        log "ERROR: Rock port_type=${original_port_type} restoration was rejected — interface rejected every restoration"
      fi
      if [[ -r "${PARTNER_DIR}/identity/id_header" ]]; then
        identity="$(cat "${PARTNER_DIR}/identity/id_header")"
      fi
      printf '%s\n' "${identity}" >"${RUN_DIR}/failed" \
        || log "ERROR: cannot record failed Rock attachment"
      return 1
    fi
  fi

  # The cycle removes and re-adds the partner asynchronously. This wait and its
  # failure receipt also run under the periodic recheck, without any DR_SWAP.
  mono_now
  deadline=$((MONO_NOW + WAIT_SECONDS))
  rock_settle_deadline="${deadline}"
  settled_power="${CERALIVE_TYPEC_SETTLED_POWER_ROLE:-${POWER_ROLE}}"
  while :; do
    if [[ -e "${PARTNER_DIR}" && -r "${settled_power}" ]]; then
      note_partner_since_early
      case "$(active_role "${settled_power}")" in
        source) rock_settled_source=1; return 0 ;;
        sink)
          # A sink read immediately after the write may still be the old attach.
          mono_now
          if (( MONO_NOW >= deadline )); then
            if [[ -r "${PARTNER_DIR}/identity/id_header" ]]; then
              identity="$(cat "${PARTNER_DIR}/identity/id_header")"
            fi
            break
          fi
          ;;
      esac
    fi
    mono_now
    (( MONO_NOW < deadline )) || break
    sleep "${POLL_INTERVAL}"
  done
  # No partner after the cycle: tcpm chooses the state a port reset ends in
  # from the try role, and with source preferred it restarts in SRC_UNATTACHED,
  # from where the FUSB302 raises no attach for a device plugged in later (a
  # hub or modem stays unseen until a rebind). The same reset with sink
  # preferred restarts it in SNK_UNATTACHED, which attaches a later plug on its
  # own, so reset once more that way. The source preference returns only after
  # SINK_RESET_SETTLE seconds (tcpm picks the state about 100 ms after the
  # write, up to about 1 s when VBUS was on); a preference write by itself does
  # not reset the port. A camera this cycle made attach has a partner by now.
  if [[ ! -e "${PARTNER_DIR}" ]]; then
    if ! printf '%s\n' sink >"${PORT_DIR}/preferred_role" ||
        [[ "$(active_role "${PORT_DIR}/preferred_role")" != sink ]]; then
      log "ERROR: cannot set Rock sink preference — ${PORT} may miss a later plug until it is rebound"
    else
      log "INFO: Rock ${PORT} has no partner after the cycle: cycling port_type=source then dual with sink preferred, so a later plug is seen"
      if ! printf '%s\n' source >"${PORT_DIR}/port_type"; then
        log "ERROR: Rock port_type=source write for the sink-first reset was rejected"
      elif ! printf '%s\n' dual >"${PORT_DIR}/port_type" &&
          ! printf '%s\n' dual >"${PORT_DIR}/port_type"; then
        log "ERROR: Rock port_type=dual after the sink-first reset was rejected twice — restoring recorded port_type=${original_port_type}"
        printf '%s\n' "${original_port_type}" >"${PORT_DIR}/port_type" \
          || log "ERROR: Rock port_type=${original_port_type} restoration was rejected"
      fi
      sleep "${SINK_RESET_SETTLE}"
      printf '%s\n' source >"${PORT_DIR}/preferred_role" \
        || log "ERROR: cannot restore Rock source preference after the sink-first reset"
    fi
  fi
  printf '%s\n' "${identity}" >"${RUN_DIR}/failed" \
    || log "ERROR: cannot record failed Rock attachment"
}

# Check the board before creating state or opening a lock: non-Rock runs retain
# the original behavior, including when the state directory is unwritable.
compat="${CERALIVE_TYPEC_DT_ROOT:-/proc/device-tree}/compatible"
if [[ -r "${compat}" ]] && tr '\0' '\n' <"${compat}" | grep -Fxq 'radxa,rock-5b-plus'; then
  if ! mkdir -p "${RUN_DIR}"; then
    log "ERROR: cannot create Rock Type-C run directory"
  elif { exec {rock_lock}>"${RUN_DIR}/lock"; } 2>/dev/null; then
    if flock -w 20 "${rock_lock}"; then
      # A recorded restoration fault must not reach DR_SWAP or fail media startup.
      rock_back_power_correction || exit 0
      flock -u "${rock_lock}"
    elif [[ "${MODE}" == recheck ]]; then
      log "INFO: Rock correction lock timed out — next tick will recheck"
    else
      log "ERROR: Rock correction lock timed out"
    fi
    exec {rock_lock}>&-
  else
    log "ERROR: cannot open Rock Type-C lock"
  fi
fi
[[ "${MODE}" != recheck && "${rock_settled_source}" == 0 ]] || exit 0

if [[ ! -d "${CLASS_DIR}" ]]; then
  log "no Type-C connector class at ${CLASS_DIR} — nothing to inspect"
  exit 0
fi

# A port-add event without a partner is not an attachment. Returning immediately
# avoids imposing the settle deadline on ordinary boot while the partner-add rule
# and the enabled boot service still cover live attach and coldplug respectively.
if [[ ! -e "${PARTNER_DIR}" ]]; then
  log "${PORT} has no attached partner — no action"
  exit 0
fi

# Share the post-cycle deadline rather than adding a third settle budget.
mono_now
deadline="${rock_settle_deadline:-$((MONO_NOW + WAIT_SECONDS))}"
while :; do
  if [[ -r "${POWER_ROLE}" && -r "${DATA_ROLE}" ]]; then
    power="$(active_role "${POWER_ROLE}")"
    data="$(active_role "${DATA_ROLE}")"

    if [[ "${power}" != "sink" || "${data}" != "device" ]]; then
      log "${PORT} settled as power_role=${power:-unknown} data_role=${data:-unknown} — no data-role swap needed"
      exit 0
    fi

    break
  fi

  mono_now
  if (( MONO_NOW >= deadline )); then
    log "${PORT} role attributes did not settle within ${WAIT_SECONDS}s — no action"
    exit 0
  fi
  sleep "${POLL_INTERVAL}"
done

for attempt in 1 2; do
  log "DR_SWAP attempt ${attempt}/2: requesting ${PORT} data_role=host"
  if ! printf '%s\n' host >"${DATA_ROLE_WRITE}"; then
    log "WARNING: DR_SWAP attempt ${attempt}/2 write was rejected"
    continue
  fi

  data="$(active_role "${DATA_ROLE}")"
  if [[ "${data}" == "host" ]]; then
    log "DR_SWAP attempt ${attempt}/2 succeeded: ${PORT} data_role=host"
    exit 0
  fi
  log "WARNING: DR_SWAP attempt ${attempt}/2 readback is '${data:-unknown}', expected 'host'"
done

# A partner that cannot swap (a plain charger has no data role) is a clean stop,
# not a unit failure: the port is left unchanged and the journal keeps the warning.
log "WARNING: DR_SWAP failed after 2 attempts; leaving ${PORT} dual-role policy unchanged"
exit 0

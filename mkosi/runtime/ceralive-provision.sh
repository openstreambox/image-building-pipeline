#!/bin/bash
#
# ceralive-provision.sh — first-boot WiFi provisioning portal.
#   Part 1 (Task 11): AP-mode trigger + NM-native hotspot bring-up.
#   Part 2 (Task 14): captive-portal lifecycle, credential handoff, and the
#                     four-condition teardown (MAC6 end-state).
#
# Committed standalone artifact (single source of truth under mkosi/runtime/).
# Installed to /usr/local/sbin/ceralive-provision and run by ceralive-provision.service,
# exactly like setup_boot_healthcheck installs ceralive-healthcheck.sh (Task 6 pattern).
#
# WHY: a freshly-flashed appliance with no WiFi credentials and no wired/modem uplink
# is unreachable — there is no way to hand it network config. This brings up a
# self-hosted WPA2 hotspot AND a captive portal so an operator can join it and
# submit WiFi credentials, WITHOUT a screen/keyboard on the device.
#
# TRIGGER LOGIC (evaluated at runtime; the unit cannot express it as static Conditions):
#   1. RE-TRIGGER (factory-reset hook): if the force flag exists, start the portal
#      unconditionally — even when WiFi profiles already exist.
#   2. DEFAULT TRIGGER: start the portal IFF there are NO stored (non-AP) NM WiFi
#      profiles on /data AND no link-up connectivity appears within a boot grace
#      window (60-90s). Either a stored profile OR connectivity suppresses it.
#
#   EC4: a RAUC A/B update that PRESERVES /data keeps the stored WiFi profiles, so
#        condition (2) is false and the portal correctly does NOT start after an OTA.
#   CONFLICT SAFETY: the AP only comes up when there is ZERO connectivity, so srtla
#        bonding/streaming is impossible anyway and the AP never contends for a live
#        uplink.
#
# AP MODE: NetworkManager-NATIVE AP (802-11-wireless.mode ap + ipv4.method shared).
#   Preferred over hostapd+dnsmasq — fewer moving parts and NO extra packages: NM
#   drives wpa_supplicant in AP mode and runs its internal dnsmasq for DHCP on the
#   shared subnet. Both RK3588 boards passed the hardware AP/teardown drill on
#   2026-09-25; hostapd is no longer explicitly installed. NM-native AP is
#   supported since NM 1.0. AP mode still needs a capable wlan driver; both
#   shipped RK3588 boards passed that hardware check — see
#   docs/agents/add-on-subsystem.md and docs/wifi-provisioning.md for its limits.
#
# CAPTIVE PORTAL (Task 14): served by ceralive-portal.{socket,@.service} (systemd
#   socket activation, Accept=yes) running the bash handler /usr/local/sbin/ceralive-portal
#   on 192.168.42.1:80. The portal is NOT a CeraUI integration (SC2) — it is a plain
#   standalone HTML page. Chosen serving mechanism: systemd socket activation + bash,
#   the lightest viable option ALREADY in the image (no busybox/python3/socat/nc are
#   shipped — socat/netcat were moved to the debug add-on; see manifests/packages/removed.md).
#
#   DNS CAPTURE: an address=/#/192.168.42.1 wildcard dropped into
#   /etc/NetworkManager/dnsmasq-shared.d makes every hostname resolve to the gateway
#   while the AP is up, so the operator's device pops its captive-portal sign-in.
#
#   PORT 80 HANDOFF (the coexistence decision): CeraUI's backend (ceralive.service)
#   binds [80, 8080, 81] in production, trying 80 first (CeraUI rpc/server.ts). On a
#   clean first boot it already owns 0.0.0.0:80 long before the 60-90s grace window
#   elapses, which would shadow the portal's 192.168.42.1:80. So provisioning STOPS
#   ceralive.service before binding the portal (Restart=always does NOT re-fire on an
#   explicit stop), and teardown STARTS it again so CeraUI re-binds 80 on the new
#   uplink IP (MAC6 condition d). The portal owns port 80 only while the AP is up.
#   With the button ingress, CeraUI moves to 18080 and ceralive-button-ingress.service
#   owns :80/:443 per address, including 192.168.42.1%wlan0 once the AP is up; it is
#   stopped and started together with CeraUI for the same reason.
#
# CREDENTIAL HANDOFF (the captive-portal handoff problem): the portal POST handler
#   writes the user's WiFi profile via nmcli (credentials land ONLY in NM's own
#   /data-backed system-connections store — never a temp file or config.json), answers
#   the browser with a "connecting…" page, then triggers a DETACHED worker
#   (`ceralive-provision connect <con>` via `systemd-run`, so it survives the
#   per-connection portal service being torn down). The worker drops the AP, switches
#   wlan0 to client mode, and joins the target with a bounded timeout. On success it
#   runs the full teardown; on a wrong passphrase or timeout it deletes the bad
#   profile, writes an error marker the portal shows, and re-arms the AP for a retry —
#   the device never ends up headless-dead.
#
# TEARDOWN CONTRACT (MAC6 end-state — all four conditions):
#   (a) AP mode disabled        — ceralive-ap profile brought down AND deleted.
#   (b) device joined target    — `nmcli connection up <con>` activated + connectivity
#                                 verified (done by the `connect` worker before teardown).
#   (c) portal no longer reachable — ceralive-portal.socket stopped, port 80 freed.
#   (d) CeraUI reachable on new IP — ceralive.service (re)started, re-binds port 80.
#   Exit paths:
#     * `connect` success → teardown_ap KEEP_LINK (does NOT disconnect wlan0; it is
#       carrying the freshly-joined client connection).
#     * `ceralive-provision teardown` (out-of-band) → teardown_ap drops wlan0 too (no
#       client connection in that path).
#     * stale marker on a boot that needs no portal → teardown_ap KEEP_LINK (a saved
#       network may already be up on wlan0).
#   Plain `systemctl stop` runs ExecStop=`stop`, a link-down + portal-down clean stop
#   that RETAINS the AP profile + the factory-reset flags so the next boot re-evaluates
#   the trigger and does NOT silently disarm a pending factory reset.
#
# SETUP MARKER (portal-active): CeraUI treats this file as "the setup owns wlan0" and
#   will not start, switch, restore or arm a hotspot there while it exists. It is
#   therefore written BEFORE the AP profile is created or activated, and it exists
#   exactly while the setup AP is up or about to come up: through the station join
#   and any re-arm. CeraUI and the ingress are then stopped BEFORE the AP is created:
#   the marker stops new CeraUI activations, but one CeraUI already handed to NM just
#   before the marker appeared can still be in flight, and only issuing the setup's own
#   activation after CeraUI has exited makes it the last one on wlan0, so nothing
#   touches the AP until both units are confirmed inactive. Every path that
#   gives wlan0 back removes the marker before CeraUI starts again (failed bring-up,
#   manual stop, teardown), and only once NM shows no setup AP active and the file is
#   really gone (release_marker); otherwise the marker stays and the command fails
#   visibly. Only shutdown keeps it, so the setup keeps priority until the next boot
#   re-evaluates the trigger; that boot removes it through the stale-marker teardown
#   when no portal is needed, keeping whatever station wlan0 carries by then.
#
# This is a standalone DEVICE script: it does NOT source the repo lib/common.sh
# (not present on the device). NOT `set -e`: the trigger probes are EXPECTED to fail
# transiently (NM still settling) and are evaluated explicitly in a grace loop.
#
# shellcheck shell=bash

set -uo pipefail

PROG="ceralive-provision"

log()  { logger -t "${PROG}" -- "$*" 2>/dev/null || true; echo "${PROG}: $*"; }
die()  { log "FATAL: $*"; exit 1; }

# --- config / test seams (overridable for the offline proof harness) ----------
NMCLI="${NMCLI:-nmcli}"
IP_BIN="${IP_BIN:-ip}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
SYSTEMD_RUN="${SYSTEMD_RUN:-systemd-run}"
TIMEOUT_BIN="${TIMEOUT_BIN:-timeout}"   # set empty to skip the outer hard-timeout wrapper
MACHINE_ID_FILE="${CERALIVE_MACHINE_ID_FILE:-/etc/machine-id}"

# CeraUI control-plane service that owns port 80 in production (header §PORT 80
# HANDOFF). Stopped while the AP window is up so the portal can take 80; restarted on
# teardown. Override in tests to point at a stub.
CERAUI_SERVICE="${CERALIVE_CERAUI_SERVICE:-ceralive.service}"

# Browser front door (button-ingress). It binds :80/:443 on every eligible address,
# including the AP gateway once wlan0 takes it, so it must leave with CeraUI or the
# portal socket fails with EADDRINUSE. Absent on images without the ingress; the
# stop/start below then fail quietly.
INGRESS_SERVICE="${CERALIVE_INGRESS_SERVICE:-ceralive-button-ingress.service}"

# Captive-portal serving units. The socket is started imperatively when the AP comes
# up and stopped on teardown — installed but NOT enabled at boot.
PORTAL_SOCKET="${CERALIVE_PORTAL_SOCKET:-ceralive-portal.socket}"
PORTAL_SERVICE_GLOB="${CERALIVE_PORTAL_SERVICE_GLOB:-ceralive-portal@*.service}"

# Provisioning state lives on /data: survives reboots AND A/B OTA slot swaps, so the
# factory-reset re-trigger flag and the portal-active marker persist across updates.
STATE_DIR="${CERALIVE_PROVISION_STATE_DIR:-/data/ceralive/provision}"
FORCE_FLAG="${CERALIVE_PROVISION_FORCE_FLAG:-${STATE_DIR}/force-portal}"          # factory-reset re-trigger
ACTIVE_FLAG="${CERALIVE_PROVISION_ACTIVE_FLAG:-${STATE_DIR}/portal-active}"       # setup owns wlan0 (header §SETUP MARKER); read by the portal and CeraUI
TEARDOWN_FLAG="${CERALIVE_PROVISION_TEARDOWN_FLAG:-${STATE_DIR}/teardown-requested}"
SCAN_CACHE="${CERALIVE_PROVISION_SCAN_CACHE:-${STATE_DIR}/scan.txt}"              # SSID list (single-radio: scanned BEFORE AP up)
ERROR_MARKER="${CERALIVE_PROVISION_ERROR_MARKER:-${STATE_DIR}/last-error}"        # written on a failed join; shown by the portal
AP_UUID_FILE="${CERALIVE_PROVISION_AP_UUID_FILE:-${STATE_DIR}/ap-uuid}"           # UUID of the setup AP profile this script created
UUID_SOURCE="${CERALIVE_UUID_SOURCE:-/proc/sys/kernel/random/uuid}"               # fresh UUID for each setup AP profile

# DNS-capture drop-in: NM's shared-mode dnsmasq reads dnsmasq-shared.d at activation.
# Wildcard-resolving every name to the gateway is what pops the captive-portal sign-in.
# Provisioning-scoped: written before AP up, removed on teardown (must NOT linger and
# wildcard a later user hotspot).
DNS_CAPTURE_DIR="${CERALIVE_DNSMASQ_SHARED_DIR:-/etc/NetworkManager/dnsmasq-shared.d}"
DNS_CAPTURE_FILE="${DNS_CAPTURE_DIR}/ceralive-portal.conf"

# AP identity / addressing.
AP_CON_NAME="${CERALIVE_AP_CON_NAME:-ceralive-ap}"   # NM profile name — EXCLUDED from the stored-profile count
AP_IFACE="${CERALIVE_AP_IFACE:-wlan0}"
AP_GW="${CERALIVE_AP_GATEWAY:-192.168.42.1}"
AP_PREFIX="${CERALIVE_AP_PREFIX:-24}"
AP_PASSPHRASE="${CERALIVE_AP_PASSPHRASE:-ceralive-setup}"   # WPA2-PSK; documented default (>=8 chars)

# Target (user) WiFi profile the portal writes. A FIXED name keeps retries idempotent;
# it IS counted by stored_wifi_profile_count, so once written the portal stays down on
# the next boot (EC4).
USER_CON_NAME="${CERALIVE_USER_CON_NAME:-ceralive-wifi}"

# Boot grace window (60-90s) + connectivity poll cadence.
GRACE_SECONDS="${CERALIVE_PROVISION_GRACE:-75}"
POLL_INTERVAL="${CERALIVE_PROVISION_POLL:-5}"

# Credential-handoff timing (the `connect` worker).
CONNECT_FLUSH_DELAY="${CERALIVE_CONNECT_FLUSH_DELAY:-2}"     # let the HTTP response flush before dropping the AP
CONNECT_WAIT="${CERALIVE_CONNECT_WAIT:-45}"                  # nmcli --wait: bounds a bad-PSK auth loop
CONNECT_HARD_TIMEOUT="${CERALIVE_CONNECT_HARD_TIMEOUT:-60}"  # outer guard against a wedged nmcli

# --- SSID short-id: machine-id derived, mirroring ceralive-set-hostname --------
ap_ssid() {
  local mid
  mid="$(tr -cd 'a-f0-9' <"${MACHINE_ID_FILE}" 2>/dev/null | tail -c 4)"
  [ -n "${mid}" ] || mid="0000"
  printf 'CeraLive-Setup-%s' "${mid}"
}

# --- stored WiFi profile count (EXCLUDING our own AP profile) ------------------
# A real user WiFi profile means the device can rejoin an uplink, so the portal must
# NOT start (EC4). Our own ${AP_CON_NAME} profile is excluded — it is created by THIS
# script and must never suppress its own re-trigger.
stored_wifi_profile_count() {
  "${NMCLI}" -t -f NAME,TYPE connection show 2>/dev/null \
    | awk -F: -v ap="${AP_CON_NAME}" '
        $2 == "802-11-wireless" && $1 != ap { n++ }
        END { print n + 0 }'
}

# --- the image's own setup AP profiles -----------------------------------------
# Identity is the UUID bring_up_ap chooses for the profile and records in
# ${AP_UUID_FILE} before it creates it: every setup-only up/down/delete goes by that
# UUID, never by connection name, so a user's profile that shares the name is never
# touched, and a later change to the profile's settings doesn't hide it. Profiles from
# older runs (no record, or a record since replaced) are recognised only on positive
# NM evidence: our connection name, Wi-Fi type, AP mode, this device's machine-id SSID
# and the setup gateway address, all as bring_up_ap writes them.

# The recorded UUID, or nothing when none is recorded. Non-zero when the record exists
# but cannot be read or is not a UUID: identity is then uncertain.
recorded_ap_uuid() {
  [ -e "${AP_UUID_FILE}" ] || return 0
  local u
  u="$(cat "${AP_UUID_FILE}" 2>/dev/null)" || return 1
  [ -z "${u}" ] && return 0
  [[ "${u}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || return 1
  printf '%s\n' "${u}"
}

# Legacy setup APs in a NAME:UUID:TYPE listing ($1), by the settings fingerprint.
fingerprint_ap_uuids() {
  local name uuid type mode ssid addr
  while IFS=: read -r name uuid type; do
    [ "${name}" = "${AP_CON_NAME}" ] && [ "${type}" = 802-11-wireless ] && [ -n "${uuid}" ] || continue
    mode="$("${NMCLI}" -g 802-11-wireless.mode connection show uuid "${uuid}" 2>/dev/null)" || return 1
    ssid="$("${NMCLI}" -g 802-11-wireless.ssid connection show uuid "${uuid}" 2>/dev/null)" || return 1
    addr="$("${NMCLI}" -g ipv4.addresses connection show uuid "${uuid}" 2>/dev/null)" || return 1
    [ "${mode}" = ap ] && [ "${ssid}" = "$(ap_ssid)" ] && [ "${addr}" = "${AP_GW}/${AP_PREFIX}" ] \
      && printf '%s\n' "${uuid}"
  done <<<"$1"
  return 0
}

# Setup AP profiles NM has now: the recorded one if NM lists it, plus legacy ones.
# One UUID per line; non-zero when NM or the record cannot be read, so callers never
# mistake "could not check" for "none".
setup_ap_uuids() {
  local rec list legacy
  rec="$(recorded_ap_uuid)" || return 1
  list="$("${NMCLI}" -t -f NAME,UUID,TYPE connection show 2>/dev/null)" || return 1
  legacy="$(fingerprint_ap_uuids "${list}")" || return 1
  {
    [ -n "${rec}" ] && awk -F: -v u="${rec}" '$2 == u { print $2 }' <<<"${list}"
    printf '%s\n' "${legacy}"
  } | awk 'NF && !seen[$0]++'
}

# 0 = a setup AP is active, 1 = none is (an inactive or absent profile counts as gone),
# 2 = NM or the record could not be read. Only 1 is evidence that the setup no longer
# holds wlan0. The recorded UUID counts even if NM no longer lists its profile.
setup_ap_active() {
  local rec uuids active
  rec="$(recorded_ap_uuid)" || return 2
  uuids="$(setup_ap_uuids)" || return 2
  uuids="$(printf '%s\n%s\n' "${rec}" "${uuids}" | awk 'NF && !seen[$0]++')"
  [ -n "${uuids}" ] || return 1
  active="$("${NMCLI}" -t -f UUID connection show --active 2>/dev/null)" || return 2
  grep -qxF -f <(printf '%s\n' "${uuids}") <<<"${active}" && return 0
  return 1
}

# Bring every setup AP down by UUID. Extra args go before `connection down` (the
# shutdown path passes a bounded --wait). Best effort: release_marker checks the result.
down_setup_aps() {
  local rec uuids u
  rec="$(recorded_ap_uuid 2>/dev/null)" || rec=""
  uuids="$(setup_ap_uuids 2>/dev/null)" || uuids=""
  for u in $(printf '%s\n%s\n' "${rec}" "${uuids}" | awk 'NF && !seen[$0]++'); do
    "${NMCLI}" "$@" connection down uuid "${u}" >/dev/null 2>&1 || true
  done
}

# Delete every setup AP profile by UUID and forget the record once none is left.
# Non-zero (logged) when NM cannot be read or a delete fails.
delete_setup_aps() {
  local uuids u rc=0
  if ! uuids="$(setup_ap_uuids)"; then
    log "ERROR: could not read NetworkManager profiles or ${AP_UUID_FILE}; setup AP profiles not cleaned up"
    return 1
  fi
  for u in ${uuids}; do
    if "${NMCLI}" connection delete uuid "${u}" >/dev/null 2>&1; then
      log "deleted setup AP profile ${u}"
    else
      log "ERROR: could not delete setup AP profile ${u}"
      rc=1
    fi
  done
  [ "${rc}" -eq 0 ] && rm -f "${AP_UUID_FILE}"
  return "${rc}"
}

# Hand wlan0 back to CeraUI: remove the setup marker only once NM shows no setup AP
# active, and confirm it is gone. Otherwise keep a truthful state (an AP that is still
# up keeps its marker), log why, and return non-zero so the caller reports failure.
release_marker() {
  local st=0
  setup_ap_active || st=$?
  case "${st}" in
    0) log "ERROR: setup AP still active on ${AP_IFACE}; keeping the setup marker (CeraUI keeps off ${AP_IFACE})"; return 1 ;;
    2) log "ERROR: could not read NetworkManager to confirm the setup AP is down; keeping the setup marker"; return 1 ;;
  esac
  if ! rm -f "${ACTIVE_FLAG}" 2>/dev/null || [ -e "${ACTIVE_FLAG}" ]; then
    log "ERROR: could not remove the setup marker ${ACTIVE_FLAG}; CeraUI keeps deferring ${AP_IFACE}"
    return 1
  fi
  return 0
}

# --- connectivity probe --------------------------------------------------------
# "link-up connectivity" = NM reports a connected state (full/limited/portal) OR a
# default route exists. Either means an uplink (wired / modem / known WiFi) is
# carrying IP, so streaming is possible and the AP must not contend for wlan0.
# Errs toward NOT starting the AP (the conservative, conflict-safe choice).
have_connectivity() {
  local state
  state="$("${NMCLI}" -t -f CONNECTIVITY general status 2>/dev/null)"
  case "${state}" in
    full|limited|portal) return 0 ;;
  esac
  if "${IP_BIN}" -4 route show default 2>/dev/null | grep -q '^default '; then
    return 0
  fi
  return 1
}

# --- decision: should the provisioning portal start this boot? -----------------
should_start_portal() {
  if [ -e "${FORCE_FLAG}" ]; then
    log "force-portal flag present (${FORCE_FLAG}) → starting portal regardless of profiles/connectivity"
    return 0
  fi

  local n; n="$(stored_wifi_profile_count)"
  if [ "${n}" -gt 0 ]; then
    log "found ${n} stored WiFi profile(s) on /data → portal not needed (EC4: OTA-preserved profiles keep it down)"
    return 1
  fi

  log "no stored WiFi profiles — waiting up to ${GRACE_SECONDS}s for any link-up connectivity"
  local waited=0
  while [ "${waited}" -lt "${GRACE_SECONDS}" ]; do
    if have_connectivity; then
      log "connectivity detected after ${waited}s → portal not needed"
      return 1
    fi
    sleep "${POLL_INTERVAL}"
    waited=$(( waited + POLL_INTERVAL ))
  done

  log "grace expired (${GRACE_SECONDS}s): no profiles + no connectivity → portal required"
  return 0
}

# --- captive-portal support ----------------------------------------------------

# Single-radio devices cannot scan while in AP mode, so cache the visible SSIDs
# BEFORE switching wlan0 to AP. The portal renders these as a <datalist> AND still
# offers free-text entry. Best-effort: an empty cache just means manual entry only.
cache_scan() {
  mkdir -p "${STATE_DIR}"
  "${NMCLI}" -g SSID dev wifi list --rescan yes 2>/dev/null \
    | sed 's/\\:/:/g' \
    | awk 'NF' \
    | sort -u \
    | head -n 50 >"${SCAN_CACHE}" 2>/dev/null || : >"${SCAN_CACHE}"
  log "cached $(wc -l <"${SCAN_CACHE}" 2>/dev/null || echo 0) visible SSID(s) for the portal"
}

write_dns_capture() {
  mkdir -p "${DNS_CAPTURE_DIR}"
  printf 'address=/#/%s\n' "${AP_GW}" >"${DNS_CAPTURE_FILE}"
  log "installed DNS capture (${DNS_CAPTURE_FILE} → ${AP_GW})"
}

remove_dns_capture() { rm -f "${DNS_CAPTURE_FILE}"; }

# Stopping CeraUI and the ingress frees every :80 listener that could cover the
# portal's 192.168.42.1:80 (CeraUI's own 0.0.0.0:80 on images without the ingress,
# the ingress's device-bound 192.168.42.1%wlan0:80 with it). An explicit stop is not
# reversed by Restart=always/on-failure, and nothing socket- or path-activates the
# ingress. Its PartOf=ceralive-tls-firstboot.service only propagates try-restart,
# which leaves a stopped unit stopped. Nothing needs button confirmation while the
# AP is up: CeraUI itself is stopped.
#
# Returns non-zero (logged) unless both units are confirmed inactive afterwards. An
# image without the ingress unit reports it inactive (not loaded), which is fine.
stop_ceraui() {
  local unit state rc=0
  "${SYSTEMCTL}" stop "${INGRESS_SERVICE}" >/dev/null 2>&1 || true
  "${SYSTEMCTL}" stop "${CERAUI_SERVICE}"  >/dev/null 2>&1 || true
  for unit in "${CERAUI_SERVICE}" "${INGRESS_SERVICE}"; do
    state="$("${SYSTEMCTL}" show -p ActiveState --value "${unit}" 2>/dev/null)" || state="unknown"
    case "${state}" in
      inactive|failed) ;;
      *) log "ERROR: ${unit} did not stop (state: ${state:-unknown})"; rc=1 ;;
    esac
  done
  return "${rc}"
}
# Returns non-zero when CeraUI or a present ingress unit did not start, after logging
# which one. An image without the ingress unit is fine (nothing to restore there).
start_ceraui() {
  local rc=0
  if ! "${SYSTEMCTL}" start "${CERAUI_SERVICE}" >/dev/null 2>&1; then
    log "ERROR: could not start ${CERAUI_SERVICE}; the web UI stays down until it is started"
    rc=1
  fi
  if ! "${SYSTEMCTL}" start "${INGRESS_SERVICE}" >/dev/null 2>&1; then
    if "${SYSTEMCTL}" cat "${INGRESS_SERVICE}" >/dev/null 2>&1; then
      log "ERROR: could not start ${INGRESS_SERVICE}; ports 80/443 stay closed until it is started"
      rc=1
    fi
  fi
  return "${rc}"
}
# One word for log lines: what the restore actually achieved.
restore_result() { if [ "$1" -eq 0 ]; then printf 'CeraUI restored'; else printf 'CeraUI/ingress restore FAILED'; fi; }

start_portal_socket() {
  "${SYSTEMCTL}" start "${PORTAL_SOCKET}" >/dev/null 2>&1 && return 0
  log "ERROR: could not start ${PORTAL_SOCKET} (nothing would answer on ${AP_GW}:80)"
  return 1
}

# Undo a half-done handoff: an AP that cannot come up, or whose portal cannot listen,
# would leave the box with no control plane at all on the re-arm path (CeraUI and the
# ingress already stopped) and the DNS capture in place for every later shared link.
# Drop the AP, release its marker and bring the normal front door back. The AP
# profile, the force flag and the last-error marker stay, so the next boot (or the
# next trigger) tries again. The front door comes back even when the marker cannot be
# released: CeraUI then runs but keeps off wlan0, which is what the marker says.
abort_ap_handoff() { # sets ABORT_MARKER to what happened to the marker
  stop_portal_socket
  remove_dns_capture
  down_setup_aps
  if release_marker; then ABORT_MARKER="AP dropped"; else ABORT_MARKER="setup marker KEPT"; fi
  start_ceraui
}
# Before any AP change (marker not writable, CeraUI would not stop, no UUID): nothing
# to bring down. Release the marker on the usual proof, bring the front door back
# (on the re-arm path CeraUI is already stopped) and exit 1.
abort_before_ap() { # $1=what failed
  local ui=0 m="setup marker released"
  stop_portal_socket
  remove_dns_capture
  release_marker || m="setup marker KEPT"
  start_ceraui || ui=$?
  die "$1; no AP brought up, ${m}, $(restore_result "${ui}"), retry flags kept"
}
# abort_ap_handoff, then exit 1 with a log line that says what actually happened.
abort_and_die() { # $1=what failed
  local rc=0
  ABORT_MARKER=""
  abort_ap_handoff || rc=$?
  die "$1; ${ABORT_MARKER}, $(restore_result "${rc}"), retry flags kept"
}

# Stop the listener (frees port 80) AND any in-flight per-connection instances.
stop_portal_socket() {
  "${SYSTEMCTL}" stop "${PORTAL_SOCKET}" >/dev/null 2>&1 || true
  "${SYSTEMCTL}" stop "${PORTAL_SERVICE_GLOB}" >/dev/null 2>&1 || true
}

# --- AP bring-up (NetworkManager native AP mode) + portal -----------------------
bring_up_ap() {
  local ssid; ssid="$(ap_ssid)"
  log "starting provisioning AP '${ssid}' on ${AP_IFACE} (gateway ${AP_GW}/${AP_PREFIX}, WPA2)"

  # Scan + DNS capture must be in place BEFORE the shared connection activates: the
  # radio can't scan in AP mode, and NM's shared dnsmasq reads dnsmasq-shared.d at
  # activation time.
  cache_scan
  write_dns_capture

  # The setup marker goes first (header §SETUP MARKER): from here until it is removed,
  # CeraUI leaves wlan0 alone, whatever the AP's connection is called. No marker, no
  # AP: an unwritable marker aborts before anything touches the radio.
  mkdir -p "${STATE_DIR}"
  printf 'ssid=%s\ngateway=%s\niface=%s\ncon=%s\nuser_con=%s\n' \
      "${ssid}" "${AP_GW}" "${AP_IFACE}" "${AP_CON_NAME}" "${USER_CON_NAME}" >"${ACTIVE_FLAG}" \
    || abort_before_ap "could not write the setup marker ${ACTIVE_FLAG}"

  # Hand wlan0 and port 80 over BEFORE the AP exists (header §SETUP MARKER): once these
  # units have exited, CeraUI issues nothing more, so the activation below is the last
  # one NM sees for wlan0 and replaces any CeraUI AP still activating there. The ingress
  # never gets to bind the AP gateway either. Nothing touches the AP until both are
  # confirmed stopped. A failed bring-up below restarts both.
  stop_ceraui || abort_before_ap "CeraUI or the button ingress did not stop"

  # Fresh profile for every bring-up, so its settings always match this script: drop
  # earlier setup profiles (by UUID only), then record the new profile's UUID BEFORE
  # creating it, so no crash can leave a setup AP we cannot identify. The profile is
  # autoconnect=no — it must come up ONLY when the trigger fires, never automatically
  # on a boot where a real uplink exists.
  delete_setup_aps || log "continuing with a fresh setup AP profile; the old one is cleaned up later"
  local ap_uuid
  ap_uuid="$(tr -d '[:space:]' <"${UUID_SOURCE}" 2>/dev/null)"
  if ! [[ "${ap_uuid}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
     || ! printf '%s\n' "${ap_uuid}" >"${AP_UUID_FILE}"; then
    abort_before_ap "could not choose and record a UUID for the setup AP (${AP_UUID_FILE})"
  fi
  "${NMCLI}" connection add \
      type wifi ifname "${AP_IFACE}" con-name "${AP_CON_NAME}" connection.uuid "${ap_uuid}" \
      autoconnect no ssid "${ssid}" \
      802-11-wireless.mode ap 802-11-wireless.band bg \
      ipv4.method shared ipv4.addresses "${AP_GW}/${AP_PREFIX}" \
      wifi-sec.key-mgmt wpa-psk wifi-sec.psk "${AP_PASSPHRASE}" \
    || abort_and_die "failed to create AP connection profile '${AP_CON_NAME}'"

  "${NMCLI}" connection up uuid "${ap_uuid}" \
    || abort_and_die "failed to activate AP connection '${AP_CON_NAME}' on ${AP_IFACE}"

  # Port 80 on the AP gateway is free (CeraUI and the ingress stopped above).
  start_portal_socket || abort_and_die "captive portal could not take ${AP_GW}:80"
  log "provisioning AP active — captive portal on ${AP_GW}:80 (marker ${ACTIVE_FLAG})"
}

# --- clean link-down only (service ExecStop / shutdown) ------------------------
# The AP profile + the /data flags are RETAINED so the next boot re-evaluates the
# trigger; the factory-reset force flag is NOT cleared here. A manual `stop` (and a
# manual unit stop) removes the setup marker and then restores CeraUI and the
# ingress, so the device keeps a reachable control plane that may use wlan0 again.
# During shutdown (arg 1 = 1) nothing is started: a synchronous start from ExecStop
# would wait behind the shutdown transaction that is stopping those units. Portal
# stops are only queued then, the NM link-down is bounded, and the marker stays.
stop_ap() {
  local shutdown="${1:-0}"
  log "stopping provisioning AP link (profile + flags retained; shutdown=${shutdown})"
  if [[ "${shutdown}" == 1 ]]; then
    "${SYSTEMCTL}" --no-block stop "${PORTAL_SOCKET}" "${PORTAL_SERVICE_GLOB}" >/dev/null 2>&1 || true
  else
    stop_portal_socket
  fi
  remove_dns_capture
  if [[ "${shutdown}" == 1 ]]; then
    # Bounded, and only the recorded UUID: no profile reads while the system stops.
    local rec
    rec="$(recorded_ap_uuid 2>/dev/null)" || rec=""
    if [ -n "${rec}" ]; then
      if [ -n "${TIMEOUT_BIN}" ] && command -v "${TIMEOUT_BIN}" >/dev/null 2>&1; then
        "${TIMEOUT_BIN}" 5 "${NMCLI}" --wait 3 connection down uuid "${rec}" >/dev/null 2>&1 || true
      else
        "${NMCLI}" --wait 3 connection down uuid "${rec}" >/dev/null 2>&1 || true
      fi
    fi
    return 0
  fi
  down_setup_aps --wait 3
  # The front door comes back either way; only a released marker counts as a handback.
  local released=0 ui=0
  release_marker || released=$?
  start_ceraui || ui=$?
  if [ "${released}" -eq 0 ]; then
    log "provisioning AP link stopped; $(restore_result "${ui}")"
  else
    log "ERROR: provisioning AP stop incomplete (setup marker kept); $(restore_result "${ui}")"
  fi
  [ "${released}" -eq 0 ] && [ "${ui}" -eq 0 ]
}

# --- TEARDOWN: full provisioning-mode exit (MAC6 end-state) --------------------
# Arg 1 (KEEP_LINK): when "1", do NOT disconnect wlan0 — it is carrying the freshly
# joined client connection (the `connect` success path). Out-of-band teardown leaves
# it 0 and releases the radio.
teardown_ap() {
  local keep_link="${1:-0}"
  log "tearing down provisioning AP (exit provisioning mode; keep_link=${keep_link})"

  # (c) portal no longer reachable — stop listener + drain instances, freeing port 80.
  stop_portal_socket
  remove_dns_capture

  # (a) AP mode disabled — bring the setup AP down and DELETE its profile, by UUID
  # only (a same-named user profile stays). A failed delete is logged; the marker
  # release below still decides on whether the AP is actually down.
  down_setup_aps
  delete_setup_aps || true
  if [ "${keep_link}" != "1" ]; then
    "${NMCLI}" device disconnect "${AP_IFACE}" >/dev/null 2>&1 || true
  fi

  rm -f "${FORCE_FLAG}" "${TEARDOWN_FLAG}" "${ERROR_MARKER}"
  local released=0 ui=0
  release_marker || released=$?

  # (d) CeraUI reachable on the new IP — restart so it re-binds port 80. A failed
  # start or a kept marker is reported (non-zero), but the joined link stays.
  start_ceraui || ui=$?
  if [ "${released}" -ne 0 ]; then
    log "ERROR: provisioning teardown incomplete (setup marker kept); $(restore_result "${ui}")"
  elif [ "${ui}" -eq 0 ]; then
    log "provisioning mode cleared (AP profile deleted, flags cleared, CeraUI on port 80)"
  else
    log "ERROR: provisioning mode cleared (AP profile deleted, flags cleared) but CeraUI/ingress did not start"
  fi
  [ "${released}" -eq 0 ] && [ "${ui}" -eq 0 ]
}

# --- credential-handoff worker (detached; runs in its own transient unit) ------
# Invoked as `ceralive-provision connect <con>` by the portal via systemd-run, so it
# survives the per-connection portal service being torn down. The portal has ALREADY
# written the <con> NM profile (credentials live only in NM storage). This worker
# switches wlan0 from AP to client mode and joins, then teardown-on-success or
# re-arm-on-failure.
con_ssid() { "${NMCLI}" -g 802-11-wireless.ssid connection show "$1" 2>/dev/null; }

verify_joined() { have_connectivity; }

bounded_connect() {
  local con="$1"
  if [ -n "${TIMEOUT_BIN}" ] && command -v "${TIMEOUT_BIN}" >/dev/null 2>&1; then
    "${TIMEOUT_BIN}" "${CONNECT_HARD_TIMEOUT}" "${NMCLI}" --wait "${CONNECT_WAIT}" connection up "${con}"
  else
    "${NMCLI}" --wait "${CONNECT_WAIT}" connection up "${con}"
  fi
}

connect_target() {
  local con="${1:?connect requires a connection name}"
  local attempt_ssid; attempt_ssid="$(con_ssid "${con}")"
  log "credential handoff: attempting to join '${attempt_ssid:-${con}}' (profile ${con})"

  # Let the browser receive the "connecting…" page before we drop the AP that is
  # carrying its connection.
  sleep "${CONNECT_FLUSH_DELAY}"

  # Drop the AP connection so the radio is free to associate as a client. We do NOT
  # `device disconnect ${AP_IFACE}` here: bringing the AP connection down already frees
  # wlan0, and an explicit device-disconnect would block the very client activation
  # below (and, on success, would tear down the link we just brought up). The full
  # radio release for the FAILURE path is handled by re-arming, and for out-of-band
  # exits by teardown_ap with keep_link=0.
  stop_portal_socket
  down_setup_aps

  if bounded_connect "${con}" && verify_joined; then
    log "joined target network (${con}) — finalising provisioning teardown"
    rm -f "${ERROR_MARKER}"
    teardown_ap 1     # KEEP_LINK: wlan0 is carrying the new client connection
    exit $?
  fi

  # FAILURE / TIMEOUT — wrong passphrase, no DHCP, or a wedged join. Delete the bad
  # profile (so it neither lingers nor suppresses a re-trigger), record the reason,
  # and re-arm the AP for a retry. Never leave the device headless-dead.
  log "join FAILED for '${attempt_ssid:-${con}}' — returning to AP mode for retry"
  "${NMCLI}" connection delete "${con}" >/dev/null 2>&1 || true
  mkdir -p "${STATE_DIR}"
  printf 'ssid=%s\nreason=auth_or_timeout\n' "${attempt_ssid}" >"${ERROR_MARKER}"
  bring_up_ap
  exit 1
}

main() {
  local cmd="${1:-start}"
  case "${cmd}" in
    service-stop)
      # ExecStop. Only a manager that is stopping selects shutdown cleanup: every
      # other state, empty output or a failed query is a manual unit stop, which
      # restores the control plane. (is-system-running also exits nonzero for
      # "stopping", so the state string decides, not the exit code.)
      case "$("${SYSTEMCTL}" is-system-running 2>/dev/null || true)" in
        stopping) stop_ap 1; exit 0 ;;
        *)        stop_ap;   exit $? ;;
      esac ;;
    shutdown) stop_ap 1;     exit 0 ;;
    stop)     stop_ap;       exit $? ;;
    teardown) teardown_ap 0; exit $? ;;
    connect)  connect_target "${2:-}" ;;   # exits inside (success 0 / failure 1)
    start)    ;;
    *)        die "unknown command: ${cmd} (use: start | stop | service-stop | shutdown | teardown | connect <con>)" ;;
  esac

  # Out-of-band teardown request (alt exit path): honor it and exit.
  if [ -e "${TEARDOWN_FLAG}" ]; then
    log "teardown-requested flag present (${TEARDOWN_FLAG}) → exiting provisioning mode"
    teardown_ap 0
    exit $?
  fi

  local rc=0
  if should_start_portal; then
    bring_up_ap
  else
    if [ -e "${ACTIVE_FLAG}" ]; then
      # Left by a shutdown or power loss during setup. wlan0 may already carry a saved
      # network by now (that is often why no portal is needed): keep the link.
      log "stale portal marker but portal no longer required → tearing down (wlan0 kept)"
      teardown_ap 1 || rc=$?
    else
      # A stop keeps the AP profile for a retry but drops the marker, so the stale-
      # marker teardown above no longer finds it. Delete only setup AP profiles, by
      # UUID, and the old error once they are gone. wlan0 and CeraUI are left alone:
      # wlan0 may be carrying a real uplink, and CeraUI is already up.
      local found
      if ! found="$(setup_ap_uuids)"; then
        log "ERROR: could not read NetworkManager profiles or ${AP_UUID_FILE}; leftover setup AP check skipped"
        rc=1
      elif [ -n "${found}" ] || [ -e "${AP_UUID_FILE}" ]; then
        log "leftover setup AP profile(s) but portal no longer required → deleting them"
        if delete_setup_aps; then
          [ -n "${found}" ] && rm -f "${ERROR_MARKER}"
        else
          rc=1
        fi
      fi
    fi
    # A capture left by an older failed bring-up would send every later shared
    # connection's DNS to the AP gateway.
    [ -e "${DNS_CAPTURE_FILE}" ] && { log "removing a stale DNS capture"; remove_dns_capture; }
    log "provisioning portal not started"
  fi
  exit "${rc}"
}

main "$@"

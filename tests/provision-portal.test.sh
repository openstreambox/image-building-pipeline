#!/usr/bin/env bash
#
# provision-portal.test.sh — offline proof harness for the first-boot WiFi provisioning
# captive portal (Task 14). Pure static/offline: it stubs nmcli / ip / systemctl /
# systemd-run / timeout / logger in a throwaway PATH and drives the REAL committed
# scripts (ceralive-provision.sh + ceralive-portal.sh) through every provisioning path,
# asserting on the recorded stub calls and the on-disk state.
#
# It proves, without any radio or systemd, the four MAC6 end-state conditions and the
# failure/timeout paths the task requires:
#   (a) AP mode disabled            — ceralive-ap profile deleted
#   (b) device joined target        — nmcli connection up <user-con> attempted + verified
#   (c) portal no longer reachable  — ceralive-portal.socket stopped (port 80 freed)
#   (d) CeraUI reachable on new IP   — ceralive.service (re)started
#   + wrong-passphrase retry path returns to AP mode
#   + hard-timeout path returns to AP mode (never headless-dead)
#   + only the portal listens on 192.168.42.1:80 while the AP is up (button ingress
#     and CeraUI stopped, both restored on teardown)
#   + the setup marker exists before the AP profile is created or activated, through
#     the station join, and is gone before CeraUI starts on every way out
#   + CeraUI and the ingress are stopped after the marker and before the AP is created
#
# Run: tests/provision-portal.test.sh   (also gated via tests/postinst-wiring.bats)
#
# shellcheck shell=bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="$(cd "${HERE}/../mkosi/runtime" && pwd)"
PROVISION="${RUNTIME}/ceralive-provision.sh"
PORTAL="${RUNTIME}/ceralive-portal.sh"

FAILED=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILED=1; }

# ---- sandbox + stubs ---------------------------------------------------------
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/provision-portal.XXXXXX")"
trap 'rm -rf "${SANDBOX}"' EXIT
BIN="${SANDBOX}/bin"; STATE="${SANDBOX}/state"; DNSDIR="${SANDBOX}/dnsmasq-shared.d"
CALL_LOG="${SANDBOX}/calls.log"; SCAN_SRC="${SANDBOX}/scan-src.txt"
MACHINE_ID="${SANDBOX}/machine-id"
HOSTNAME_FILE="${SANDBOX}/hostname"; HOST_INDEX_FILE="${SANDBOX}/host-index"
HOST_BASE_FILE="${SANDBOX}/hostname-base"
mkdir -p "${BIN}" "${STATE}"
printf 'HomeNet\nCafe Wifi\nNeighbour\n' >"${SCAN_SRC}"
printf 'deadbeefcafef00d\n' >"${MACHINE_ID}"

make_stub() { local p="${BIN}/$1"; shift; printf '%s\n' '#!/usr/bin/env bash' "$@" >"${p}"; chmod +x "${p}"; }

# Every nmcli and systemctl call is also logged with whether the setup marker existed
# at that moment ("marker ..." / "nomarker ..."), so ordering is asserted directly.
MARK_CALL='[ -e "${CERALIVE_PROVISION_ACTIVE_FLAG:-$CERALIVE_PROVISION_STATE_DIR/portal-active}" ] && m=marker || m=nomarker; echo "$m $(basename "$0") $*" >>"$MARKER_LOG"'

# nmcli: records every call; returns programmed data/exit codes. The AP profile ALWAYS
# comes up (so a re-arm during the failure path succeeds) unless STUB_AP_UP_RC says
# otherwise; the USER connection's `connection up` exit code is STUB_USER_UP_RC.
# A small NM model under $NMSTATE backs the ownership and handback checks:
#   profiles  NAME:UUID:TYPE rows (`-t -f NAME,UUID,TYPE connection show`)
#   details   "<uuid> <field> <value>" rows (`-g <field> connection show uuid <uuid>`)
#   active    active UUIDs (`-t -f UUID connection show --active`)
# Adding ceralive-ap records it with the UUID the script passes (connection.uuid);
# up/down/delete by UUID and `device disconnect` update the model. Name-based
# up/down/delete of the setup AP are deliberately not modelled: the script must not
# issue them, and checks assert that. The portal's user profile is modelled too: its
# `connection add` records it (UUID STUB_USER_UUID), a delete by name removes it, and
# `-f NAME,TYPE` lists the model unless STUB_PROFILES_FILE replaces it. Faults: STUB_AP_DOWN_RC (down fails, AP stays
# up), STUB_DELETE_RC (delete fails), STUB_NM_READ_RC (profile/active reads fail),
# STUB_ACTIVE_READ_RC (only the active-connection read fails).
cat >"${BIN}/nmcli" <<'STUB'
#!/usr/bin/env bash
echo "nmcli $*" >>"$CALL_LOG"
[ -e "${CERALIVE_PROVISION_ACTIVE_FLAG:-$CERALIVE_PROVISION_STATE_DIR/portal-active}" ] && m=marker || m=nomarker
echo "$m nmcli $*" >>"$MARKER_LOG"
args="$*"
P="$NMSTATE/profiles" D="$NMSTATE/details" A="$NMSTATE/active"
drop_uuid() { for f in "$P" "$D" "$A"; do grep -v -- "$1" "$f" >"$f.tmp"; mv "$f.tmp" "$f"; done; }
# Profile rows as nmcli -t prints them: the model keeps raw names (UUID and TYPE are its
# last two fields); output escapes '\' and ':' in the name like NM does.
rows() { while IFS= read -r line; do [ -n "$line" ] || continue
           t="${line##*:}"; r="${line%:*}"; u="${r##*:}"; n="${r%:*}"; n="${n//\\/\\\\}"; n="${n//:/\\:}"
           case "$1" in nut) echo "$n:$u:$t" ;; utn) echo "$u:$t:$n" ;; nt) echo "$n:$t" ;; esac
         done <"$P"; }
case "$args" in
  *"dev wifi list"*) [ -n "${STUB_SCAN_FILE:-}" ] && cat "$STUB_SCAN_FILE"; exit 0 ;;
  *"-f CONNECTIVITY general status"*) printf "%s\n" "${STUB_CONNECTIVITY:-full}"; exit 0 ;;
  # NM 1.52.1's projections: a UUID-only request prints only active rows that still
  # have a saved profile; naming an active field (ACTIVE-PATH) prints every active or
  # activating connection, orphans included.
  *"-f UUID,ACTIVE-PATH connection show --active"*) [ -n "${STUB_NM_READ_RC:-}${STUB_ACTIVE_READ_RC:-}" ] && exit "${STUB_NM_READ_RC:-$STUB_ACTIVE_READ_RC}"
                                                    n=0; while read -r u; do n=$((n+1)); [ -n "$u" ] && echo "$u:/org/freedesktop/NetworkManager/ActiveConnection/$n"; done <"$A"; exit 0 ;;
  *"-f UUID,STATE connection show --active"*) [ -n "${STUB_NM_READ_RC:-}${STUB_ACTIVE_READ_RC:-}" ] && exit "${STUB_NM_READ_RC:-$STUB_ACTIVE_READ_RC}"
                                              while read -r u; do [ -n "$u" ] && echo "$u:${STUB_ACTIVE_STATE:-activated}"; done <"$A"; exit 0 ;;
  *"-f UUID connection show --active"*) [ -n "${STUB_NM_READ_RC:-}${STUB_ACTIVE_READ_RC:-}" ] && exit "${STUB_NM_READ_RC:-$STUB_ACTIVE_READ_RC}"
                                        while read -r u; do grep -q ":$u:" "$P" && echo "$u"; done <"$A"; exit 0 ;;
  *"-g GENERAL.STATE device show"*) [ -n "${STUB_DEV_READ_RC:-}" ] && exit "$STUB_DEV_READ_RC"
                                    if [ -n "${STUB_DEV_STATE:-}" ]; then echo "$STUB_DEV_STATE"
                                    elif [ -s "$A" ]; then echo "100 (connected)"; else echo "30 (disconnected)"; fi; exit 0 ;;
  *"-f NAME,UUID,TYPE connection show"*) [ -n "${STUB_NM_READ_RC:-}" ] && exit "$STUB_NM_READ_RC"; rows nut; exit 0 ;;
  *"-f UUID,TYPE,NAME connection show"*) [ -n "${STUB_NM_READ_RC:-}" ] && exit "$STUB_NM_READ_RC"; rows utn; exit 0 ;;
  *"-g 802-11-wireless.mode connection show uuid "*) [ -n "${STUB_MODE_READ_RC:-}" ] && exit "$STUB_MODE_READ_RC"
                             set -- $args; field="$2"; uuid="${!#}"
                             awk -v u="$uuid" -v f="$field" '$1 == u && $2 == f { sub(/^[^ ]+ [^ ]+ /, ""); print }' "$D"; exit 0 ;;
  *"connection show uuid "*) set -- $args; field="$2"; uuid="${!#}"
                             awk -v u="$uuid" -v f="$field" '$1 == u && $2 == f { sub(/^[^ ]+ [^ ]+ /, ""); print }' "$D"; exit 0 ;;
  *"802-11-wireless.ssid connection show"*) printf "%s\n" "${STUB_CON_SSID:-HomeNet}"; exit 0 ;;
  *"-f NAME,TYPE connection show"*) if [ -n "${STUB_PROFILES_FILE:-}" ]; then cat "$STUB_PROFILES_FILE"; else rows nt; fi; exit 0 ;;
  *"connection add"*ceralive-ap*)
    [ "${STUB_AP_ADD_RC:-0}" -ne 0 ] && exit "$STUB_AP_ADD_RC"
    u=""; prev=""; for a in "$@"; do [ "$prev" = connection.uuid ] && u="$a"; prev="$a"; done
    [ -n "$u" ] || u="$(cat /proc/sys/kernel/random/uuid)"   # NM picks one when none is given
    cat "$CERALIVE_PROVISION_STATE_DIR/ap-uuid" >"$NMSTATE/record-at-add" 2>/dev/null || : >"$NMSTATE/record-at-add"
    drop_uuid "$u"
    echo "ceralive-ap:$u:802-11-wireless" >>"$P"
    printf '%s 802-11-wireless.mode ap\n%s 802-11-wireless.ssid CeraLive-Setup-f00d\n%s ipv4.addresses 192.168.42.1/24\n' "$u" "$u" "$u" >>"$D"
    exit 0 ;;
  *"connection up uuid "*) u="${!#}"; rc="${STUB_AP_UP_RC:-0}"
                           grep -q ":$u:" "$P" || exit 10
                           grep -qx "$u 802-11-wireless.mode ap" "$D" || rc="${STUB_USER_UP_RC:-0}"
                           [ "$rc" -eq 0 ] && echo "$u" >>"$A"; exit "$rc" ;;
  *"connection up"*) exit "${STUB_USER_UP_RC:-0}" ;;
  *"connection down uuid "*) [ -n "${STUB_AP_DOWN_RC:-}" ] && exit "$STUB_AP_DOWN_RC"
                             grep -qx -- "${!#}" "$A" || exit 10
                             grep -vx -- "${!#}" "$A" >"$A.tmp"; mv "$A.tmp" "$A"; exit 0 ;;
  *"connection delete uuid "*) [ -n "${STUB_DELETE_RC:-}" ] && exit "$STUB_DELETE_RC"
                               grep -q ":${!#}:" "$P" || exit 10
                               drop_uuid "${!#}"; exit 0 ;;
  *"connection delete "*) [ -n "${STUB_DELETE_RC:-}" ] && exit "$STUB_DELETE_RC"
                          u="$(awk -F: -v n="${!#}" '$1 == n { print $2; exit }' "$P")"
                          [ -n "$u" ] || exit 10
                          drop_uuid "$u"; exit 0 ;;
  *"device disconnect"*) : >"$A"; exit 0 ;;
  *"connection add"*) if [ "${STUB_ADD_RC:-0}" -ne 0 ]; then echo "Error: failed to modify 802-11-wireless.ssid: invalid" >&2; exit "$STUB_ADD_RC"; fi
                      u="${STUB_USER_UUID:-0000aaaa-0000-4000-8000-0000000000d4}"; name=""; ssid=""; prev=""
                      for a in "$@"; do [ "$prev" = con-name ] && name="$a"; [ "$prev" = ssid ] && ssid="$a"; [ "$prev" = connection.uuid ] && u="$a"; prev="$a"; done
                      drop_uuid "$u"; echo "$name:$u:802-11-wireless" >>"$P"; echo "$u 802-11-wireless.ssid $ssid" >>"$D"
                      echo "Connection '$name' ($u) successfully added."; exit 0 ;;
esac
exit 0
STUB
chmod +x "${BIN}/nmcli"

# iw: the kernel's view of wlan0. By default it follows the NM model's ground truth (an
# active connection whose stored mode is ap makes wlan0 type AP); STUB_IW_TYPE overrides
# it (set but empty prints no type line), STUB_IW_RC makes it fail.
cat >"${BIN}/iw" <<'STUB'
#!/usr/bin/env bash
echo "iw $*" >>"$CALL_LOG"
[ -n "${STUB_IW_RC:-}" ] && exit "$STUB_IW_RC"
printf 'Interface %s\n\tifindex 3\n' "$2"
if [ -n "${STUB_IW_TYPE+x}" ]; then
  [ -n "$STUB_IW_TYPE" ] && printf '\ttype %s\n' "$STUB_IW_TYPE"
  exit 0
fi
t=managed
while read -r u; do
  [ -n "$u" ] && grep -qx "$u 802-11-wireless.mode ap" "$NMSTATE/details" && t=AP
done <"$NMSTATE/active"
printf '\ttype %s\n' "$t"
STUB
chmod +x "${BIN}/iw"

make_stub ip \
  'echo "ip $*" >>"$CALL_LOG"' \
  '[ -n "${STUB_DEFAULT_ROUTE:-}" ] && echo "default via 10.0.0.1"; exit 0'

make_stub systemctl 'echo "systemctl $*" >>"$CALL_LOG"' "${MARK_CALL}" '[ "$1" = show ] && [ -n "${STUB_SHOW_RC:-}" ] && exit "$STUB_SHOW_RC"' '[ "$1" = show ] && printf "%s\n" "${STUB_UNIT_STATE:-inactive}"' 'exit 0'

# systemd-run: records the transient-unit launch but does NOT execute it (--no-block).
make_stub systemd-run 'echo "systemd-run $*" >>"$CALL_LOG"; exit 0'

# timeout: records, then either simulates a hard timeout (STUB_TIMEOUT_RC) or execs the
# wrapped command (dropping the duration arg) so the nmcli stub decides success/failure.
make_stub timeout \
  'echo "timeout $*" >>"$CALL_LOG"' \
  'if [ -n "${STUB_TIMEOUT_RC:-}" ]; then exit "$STUB_TIMEOUT_RC"; fi' \
  'while [ "${1#-}" != "$1" ]; do shift; done' \
  'shift; exec "$@"'

make_stub logger 'printf "%s\n" "$*" >>"${STUB_LOG_FILE:-/dev/null}"; exit 0'
make_stub hostname 'printf "%s\n" "${STUB_RUNTIME_HOSTNAME:-factory-seed}"'
make_stub busctl \
  'case "$*" in' \
  '  *GetState) printf '"'"'i %s\n'"'"' "${STUB_AVAHI_STATE:-2}" ;;' \
  '  *GetHostName) printf '"'"'s "%s"\n'"'"' "${STUB_AVAHI_HOSTNAME:-factory-seed}" ;;' \
  '  *) exit 2 ;;' \
  'esac'

export PATH="${BIN}:${PATH}"
SYSNET="${SANDBOX}/sysnet"; mkdir -p "${SYSNET}/wlan0"
export NMCLI="${BIN}/nmcli" IP_BIN="${BIN}/ip" SYSTEMCTL="${BIN}/systemctl" IW_BIN="${BIN}/iw" CERALIVE_SYSFS_NET="${SYSNET}"
export SYSTEMD_RUN="${BIN}/systemd-run" TIMEOUT_BIN="${BIN}/timeout"
export CERALIVE_BUSCTL="${BIN}/busctl" CERALIVE_TIMEOUT="${BIN}/timeout"
export CERALIVE_MACHINE_ID_FILE="${MACHINE_ID}"
export CERALIVE_PROVISION_STATE_DIR="${STATE}"
export CERALIVE_DNSMASQ_SHARED_DIR="${DNSDIR}"
export CERALIVE_PROVISION_BIN="${PROVISION}"
export CERALIVE_HOSTNAME_FILE="${HOSTNAME_FILE}"
export CERALIVE_HOSTNAME_INDEX_FILE="${HOST_INDEX_FILE}"
export CERALIVE_HOSTNAME_BASE_FILE="${HOST_BASE_FILE}"
export CERALIVE_HOSTNAME_BIN="${BIN}/hostname"
export CERALIVE_CONNECT_FLUSH_DELAY=0
MARKER_LOG="${SANDBOX}/marker-calls.log"
export CALL_LOG MARKER_LOG STUB_SCAN_FILE="${SCAN_SRC}"

NMSTATE="${SANDBOX}/nm"; AP_UUID="5e7a1a5e-0000-4000-8000-0000000000a1"
UUID_SRC="${SANDBOX}/uuid-source"; printf '%s\n' "${AP_UUID}" >"${UUID_SRC}"
export NMSTATE AP_UUID CERALIVE_UUID_SOURCE="${UUID_SRC}"
# The portal's per-attempt profile UUID (its own source: the AP's is fixed above).
JOIN_UUID_SRC="${SANDBOX}/join-uuid-source"; printf '0000aaaa-0000-4000-8000-0000000000d4\n' >"${JOIN_UUID_SRC}"
export CERALIVE_JOIN_UUID_SOURCE="${JOIN_UUID_SRC}" CERALIVE_JOIN_LOCK_WAIT=1
AP_UP_CALL="nmcli connection up uuid ${AP_UUID}"
AP_DEL_CALL="nmcli connection delete uuid ${AP_UUID}"
# The setup AP as a previous bring-up of this script left it: profile + recorded UUID.
seed_setup_ap() {
  echo "ceralive-ap:${AP_UUID}:802-11-wireless" >>"${NMSTATE}/profiles"
  printf '%s 802-11-wireless.mode ap\n%s 802-11-wireless.ssid CeraLive-Setup-f00d\n%s ipv4.addresses 192.168.42.1/24\n' "${AP_UUID}" "${AP_UUID}" "${AP_UUID}" >>"${NMSTATE}/details"
  printf '%s\n' "${AP_UUID}" >"$(state_file ap-uuid)"
}
# No name-based up/down/delete of the setup AP anywhere in the call log.
no_name_ops() { ! grep -qE '^nmcli( --wait [0-9]+)? connection (up|down|delete) ceralive-ap( |$)' "${CALL_LOG}"; }
reset_nm() { rm -rf "${NMSTATE}"; mkdir -p "${NMSTATE}"; : >"${NMSTATE}/profiles"; : >"${NMSTATE}/details"; : >"${NMSTATE}/active"; }
reset_state() { rm -rf "${STATE}" "${DNSDIR}"; mkdir -p "${STATE}"; : >"${CALL_LOG}"; : >"${MARKER_LOG}"; reset_nm; }
called()     { grep -qF -- "$1" "${CALL_LOG}"; }
state_file() { printf '%s/%s' "${STATE}" "$1"; }

# ===========================================================================
echo "== Scenario A: portal bring-up (port-80 handoff START side) =="
reset_state
: >"$(state_file force-portal)"          # force trigger → skip the 75s grace wait
env STUB_PROFILES_FILE=/dev/null bash "${PROVISION}" start >/dev/null 2>&1
called "nmcli -g SSID dev wifi list"              && pass "scan performed before AP up" || fail "scan performed before AP up"
[ -s "$(state_file scan.txt)" ]                   && pass "scan cached for the portal"   || fail "scan cached for the portal"
[ -f "${DNSDIR}/ceralive-portal.conf" ]           && pass "DNS capture written"          || fail "DNS capture written"
grep -qF 'address=/#/192.168.42.1' "${DNSDIR}/ceralive-portal.conf" && pass "DNS wildcard to gateway" || fail "DNS wildcard to gateway"
called "${AP_UP_CALL}"                           && pass "AP profile activated by its UUID" || fail "AP profile activated by its UUID"
grep -qF "connection.uuid ${AP_UUID}" "${CALL_LOG}" && [ "$(cat "$(state_file ap-uuid)")" = "${AP_UUID}" ] \
                                                 && pass "AP created with the recorded UUID" || fail "AP created with the recorded UUID"
called "systemctl stop ceralive.service"          && pass "CeraUI stopped (frees port 80)" || fail "CeraUI stopped (frees port 80)"
called "systemctl start ceralive-portal.socket"   && pass "portal socket started on 80"  || fail "portal socket started on 80"
[ -f "$(state_file portal-active)" ]              && pass "portal-active marker written" || fail "portal-active marker written"

# ===========================================================================
echo "== Scenario B: GET serves the form with scanned SSIDs =="
reset_state
printf 'HomeNet\nCafe Wifi\nNeighbour\n' >"$(state_file scan.txt)"
printf 'ssid=CeraLive-Setup-f00d\ngateway=192.168.42.1\n' >"$(state_file portal-active)"
GET_OUT="$(printf 'GET / HTTP/1.1\r\nHost: x\r\n\r\n' | CERALIVE_PORTAL_MARK_SVG="${RUNTIME}/brand/ceralive-mark-small-dark.svg" bash "${PORTAL}" serve 2>/dev/null)"
grep -qF '<form method="POST"' <<<"${GET_OUT}"   && pass "serves an HTML form"          || fail "serves an HTML form"
grep -qF 'name="ssid"'         <<<"${GET_OUT}"   && pass "form has an SSID field"        || fail "form has an SSID field"
grep -qF 'name="psk"'          <<<"${GET_OUT}"   && pass "form has a passphrase field"   || fail "form has a passphrase field"
grep -qF '<option value="HomeNet">' <<<"${GET_OUT}" && pass "SSID list populated from scan" || fail "SSID list populated from scan"
grep -qF 'Cafe Wifi'           <<<"${GET_OUT}"   && pass "SSID with a space rendered"    || fail "SSID with a space rendered"
grep -qiF '200 OK'             <<<"${GET_OUT}"   && pass "responds 200 OK"               || fail "responds 200 OK"
grep -qF 'data:image/svg+xml;base64,' <<<"${GET_OUT}" && pass "embeds the brand mark" || fail "embeds the brand mark"
MARK_PAYLOAD="$(sed -n 's/.*src="data:image\/svg+xml;base64,\([^"]*\)".*/\1/p' <<<"${GET_OUT}")"
MARK_SHA="$(sha256sum "${RUNTIME}/brand/ceralive-mark-small-dark.svg")"
DECODED_SHA="$(printf '%s' "${MARK_PAYLOAD}" | base64 --decode | sha256sum)"
[ "${MARK_SHA%% *}" = "${DECODED_SHA%% *}" ] && pass "embedded mark matches the vendored sha256" || fail "embedded mark matches the vendored sha256"
for old_hex in '#0b1220' '#121a2b' '#243049' '#3b82f6' '#0d1526' '#2b3a57' '#9fb0c8' '#7c8aa3'; do
  ! grep -qiF "${old_hex}" <<<"${GET_OUT}" && pass "retired color ${old_hex} absent" || fail "retired color ${old_hex} absent"
done

# ===========================================================================
echo "== Scenario B2: missing artwork still serves the setup form =="
MISSING_OUT="$(printf 'GET / HTTP/1.1\r\nHost: x\r\n\r\n' | CERALIVE_PORTAL_MARK_SVG=/nonexistent bash "${PORTAL}" serve 2>/dev/null)"
grep -qF '<form method="POST"' <<<"${MISSING_OUT}" && pass "missing mark keeps the form" || fail "missing mark keeps the form"
grep -qF '200 OK' <<<"${MISSING_OUT}" && pass "missing mark keeps HTTP 200" || fail "missing mark keeps HTTP 200"
! grep -qF '<img' <<<"${MISSING_OUT}" && pass "missing mark emits no image" || fail "missing mark emits no image"

# ===========================================================================
echo "== Scenario C: POST writes the NM profile + triggers the detached handoff =="
reset_state
printf 'portal-active' >"$(state_file portal-active)"
printf '2\n' >"${HOST_INDEX_FILE}"
printf 'ceralive2\n' >"${HOSTNAME_FILE}"
export STUB_RUNTIME_HOSTNAME=ceralive2
export STUB_AVAHI_HOSTNAME=ceralive2
POST_OUT="$(printf 'POST / HTTP/1.1\r\nContent-Length: 28\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\nssid=HomeNet&psk=hunter2pass' | bash "${PORTAL}" serve 2>/dev/null)"
called "nmcli connection add type wifi con-name ceralive-wifi" && pass "writes NM profile for the user network" || fail "writes NM profile for the user network"
called "wifi-sec.psk hunter2pass"                && pass "passphrase handed to NM only (not a file)" || fail "passphrase handed to NM only"
called "systemd-run"                             && pass "detached worker launched"     || fail "detached worker launched"
called "ceralive-provision.sh connect ceralive-wifi" && pass "handoff = provision connect <con>" || fail "handoff = provision connect <con>"
grep -qiF 'Connecting' <<<"${POST_OUT}"          && pass "browser gets a connecting page" || fail "browser gets a connecting page"
grep -qF '<b>ceralive2.local</b>' <<<"${POST_OUT}" && pass "connecting page uses the committed collision name" || fail "connecting page uses the committed collision name"
! grep -qF 'address assigned by your router' <<<"${POST_OUT}" && pass "committed collision name does not fall back to router guidance" || fail "committed collision name does not fall back to router guidance"
printf 'ceralive-012345abcdef\n' >"${HOST_BASE_FILE}"
printf 'ceralive-012345abcdef2\n' >"${HOSTNAME_FILE}"
export STUB_RUNTIME_HOSTNAME=ceralive-012345abcdef2
export STUB_AVAHI_HOSTNAME=ceralive-012345abcdef2
FRESH_OUT="$(printf 'POST / HTTP/1.1\r\nContent-Length: 28\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\nssid=HomeNet&psk=hunter2pass' | bash "${PORTAL}" serve 2>/dev/null)"
grep -qF '<b>ceralive-012345abcdef2.local</b>' <<<"${FRESH_OUT}" && pass "connecting page uses the committed per-device name" || fail "connecting page uses the committed per-device name"
rm -f -- "${HOST_BASE_FILE}"
printf 'ceralive2\n' >"${HOSTNAME_FILE}"
export STUB_RUNTIME_HOSTNAME=ceralive2
export STUB_AVAHI_HOSTNAME=ceralive-2
STALE_AVAHI_OUT="$(printf 'POST / HTTP/1.1\r\nContent-Length: 28\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\nssid=HomeNet&psk=hunter2pass' | bash "${PORTAL}" serve 2>/dev/null)"
grep -qF 'address assigned by your router' <<<"${STALE_AVAHI_OUT}" && pass "stale Avahi publication gets router guidance" || fail "stale Avahi publication gets router guidance"
export STUB_AVAHI_HOSTNAME=ceralive2
export STUB_AVAHI_STATE=1
REGISTERING_AVAHI_OUT="$(printf 'POST / HTTP/1.1\r\nContent-Length: 28\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\nssid=HomeNet&psk=hunter2pass' | bash "${PORTAL}" serve 2>/dev/null)"
grep -qF 'address assigned by your router' <<<"${REGISTERING_AVAHI_OUT}" && pass "registering Avahi publication gets router guidance" || fail "registering Avahi publication gets router guidance"
export STUB_AVAHI_STATE=2
export STUB_RUNTIME_HOSTNAME=factory-seed
export STUB_AVAHI_HOSTNAME=ceralive2
UNCOMMITTED_OUT="$(printf 'POST / HTTP/1.1\r\nContent-Length: 28\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\nssid=HomeNet&psk=hunter2pass' | bash "${PORTAL}" serve 2>/dev/null)"
grep -qF 'address assigned by your router' <<<"${UNCOMMITTED_OUT}" && pass "in-flight identity gets router guidance" || fail "in-flight identity gets router guidance"
# credentials must NOT be persisted anywhere but NM (no temp/state file holds the psk)
! grep -rqF 'hunter2pass' "${STATE}" 2>/dev/null && pass "no credential written to /data state" || fail "no credential written to /data state"

# ===========================================================================
echo "== Scenario C2: nmcli output never reaches the client socket =="
# stdout is the client socket under Accept=yes; nmcli prints a success line on add.
reset_state
printf 'portal-active' >"$(state_file portal-active)"
for form in 'ssid=HomeNet&psk=hunter2pass' 'ssid=OpenCafe'; do
  OUT="$(printf 'POST / HTTP/1.1\r\nContent-Length: %s\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\n%s' "${#form}" "${form}" | bash "${PORTAL}" serve 2>/dev/null)"
  [[ "${OUT}" == HTTP/* ]]                       && pass "response starts with HTTP/ (${form%%&*})" || fail "response starts with HTTP/ (${form%%&*})"
  ! grep -qF 'successfully added' <<<"${OUT}"    && pass "nmcli stdout kept out of the response (${form%%&*})" || fail "nmcli stdout kept out of the response (${form%%&*})"
done
NM_LOG="${SANDBOX}/portal-log.txt"; : >"${NM_LOG}"; : >"${CALL_LOG}"
OUT="$(printf 'POST / HTTP/1.1\r\nContent-Length: 28\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\nssid=HomeNet&psk=hunter2pass' | env STUB_ADD_RC=2 STUB_LOG_FILE="${NM_LOG}" bash "${PORTAL}" serve 2>/dev/null)"
[[ "${OUT}" == HTTP/* ]]                         && pass "failed add still answers with HTTP/" || fail "failed add still answers with HTTP/"
grep -qF 'Could not save' <<<"${OUT}"            && pass "failed add shows the retry page" || fail "failed add shows the retry page"
! grep -qF 'Error:' <<<"${OUT}"                  && pass "nmcli error kept out of the response" || fail "nmcli error kept out of the response"
grep -qF 'Error: failed to modify' "${NM_LOG}"   && pass "nmcli error logged" || fail "nmcli error logged"
! called "systemd-run"                           && pass "no handoff after a failed add" || fail "no handoff after a failed add"

# ===========================================================================
echo "== Scenario D: connect SUCCESS -> all four MAC6 conditions =="
reset_state; seed_setup_ap
printf 'portal-active' >"$(state_file portal-active)"
: >"$(state_file force-portal)"
env STUB_USER_UP_RC=0 STUB_CONNECTIVITY=full STUB_CON_SSID=HomeNet \
    bash "${PROVISION}" connect ceralive-wifi >/dev/null 2>&1
rc=$?
[ "${rc}" -eq 0 ]                                && pass "connect worker exits 0 on success" || fail "connect worker exits 0 on success"
called "connection up ceralive-wifi"             && pass "(b) joined target network"     || fail "(b) joined target network"
called "nmcli -t -f CONNECTIVITY general status" && pass "(b) join verified by connectivity" || fail "(b) join verified by connectivity"
called "${AP_DEL_CALL}"                          && pass "(a) AP profile deleted"        || fail "(a) AP profile deleted"
called "systemctl stop ceralive-portal.socket"   && pass "(c) portal socket stopped (port 80 freed)" || fail "(c) portal socket stopped"
called "systemctl start ceralive.service"        && pass "(d) CeraUI restarted on new IP" || fail "(d) CeraUI restarted on new IP"
! called "nmcli device disconnect wlan0"         && pass "(b) wlan0 NOT dropped (keep_link)" || fail "(b) wlan0 NOT dropped (keep_link)"
[ ! -e "$(state_file portal-active)" ]           && pass "portal-active marker cleared"  || fail "portal-active marker cleared"
[ ! -e "$(state_file force-portal)" ]            && pass "factory-reset flag cleared"    || fail "factory-reset flag cleared"
[ ! -e "${DNSDIR}/ceralive-portal.conf" ]        && pass "DNS capture removed"           || fail "DNS capture removed"

# ===========================================================================
echo "== Scenario E: connect FAILURE (wrong passphrase) -> back to AP mode =="
reset_state
printf 'portal-active' >"$(state_file portal-active)"
env STUB_USER_UP_RC=4 STUB_CON_SSID=HomeNet \
    bash "${PROVISION}" connect ceralive-wifi >/dev/null 2>&1
rc=$?
[ "${rc}" -ne 0 ]                                && pass "connect worker exits non-zero on failure" || fail "connect worker exits non-zero on failure"
called "nmcli connection delete ceralive-wifi"   && pass "bad profile deleted"           || fail "bad profile deleted"
[ -f "$(state_file last-error)" ]                && pass "error marker written for the portal" || fail "error marker written for the portal"
grep -qF 'reason=auth_or_timeout' "$(state_file last-error)" && pass "error reason recorded" || fail "error reason recorded"
called "${AP_UP_CALL}"                          && pass "AP re-armed for retry"         || fail "AP re-armed for retry"
called "systemctl start ceralive-portal.socket"  && pass "portal restarted for retry"    || fail "portal restarted for retry"
[ -f "${DNSDIR}/ceralive-portal.conf" ]          && pass "DNS capture re-installed"      || fail "DNS capture re-installed"

# ===========================================================================
echo "== Scenario F: form shows the error banner after a failed attempt =="
# (state from Scenario E is intentionally preserved: last-error present)
printf 'HomeNet\n' >"$(state_file scan.txt)"
ERR_OUT="$(printf 'GET / HTTP/1.1\r\n\r\n' | bash "${PORTAL}" serve 2>/dev/null)"
grep -qiF 'Could not join' <<<"${ERR_OUT}"       && pass "error banner shown on retry"   || fail "error banner shown on retry"
grep -qF 'HomeNet'         <<<"${ERR_OUT}"       && pass "failed SSID named in the banner" || fail "failed SSID named in the banner"

# ===========================================================================
echo "== Scenario G: hard timeout during join -> back to AP mode (not headless-dead) =="
reset_state
printf 'portal-active' >"$(state_file portal-active)"
env STUB_TIMEOUT_RC=124 STUB_CON_SSID=HomeNet \
    bash "${PROVISION}" connect ceralive-wifi >/dev/null 2>&1
rc=$?
[ "${rc}" -ne 0 ]                                && pass "timeout -> connect worker fails closed" || fail "timeout -> connect worker fails closed"
called "timeout"                                 && pass "outer hard-timeout guard engaged" || fail "outer hard-timeout guard engaged"
called "${AP_UP_CALL}"                          && pass "AP re-armed after timeout"     || fail "AP re-armed after timeout"
called "systemctl start ceralive-portal.socket"  && pass "portal restarted after timeout" || fail "portal restarted after timeout"

# ===========================================================================
echo "== Scenario H: out-of-band teardown verb releases everything =="
reset_state; seed_setup_ap
printf 'portal-active' >"$(state_file portal-active)"
: >"$(state_file teardown-requested)"
bash "${PROVISION}" teardown >/dev/null 2>&1
called "${AP_DEL_CALL}"                          && pass "(a) AP profile deleted"        || fail "(a) AP profile deleted"
called "nmcli device disconnect wlan0"           && pass "wlan0 released (no client link)" || fail "wlan0 released (no client link)"
called "systemctl stop ceralive-portal.socket"   && pass "(c) portal stopped"            || fail "(c) portal stopped"
called "systemctl start ceralive.service"        && pass "(d) CeraUI restored"           || fail "(d) CeraUI restored"
[ ! -e "$(state_file portal-active)" ]           && pass "portal-active cleared"         || fail "portal-active cleared"
[ ! -e "$(state_file teardown-requested)" ]      && pass "teardown-requested flag cleared" || fail "teardown-requested flag cleared"

# ===========================================================================
echo "== Scenario I: nothing but the portal listens on 192.168.42.1:80 after bring-up =="
# A stateful systemctl models which units are active and who holds the AP gateway's
# port 80: the button ingress binds :80 on every eligible address, so once the AP
# gives wlan0 192.168.42.1 it holds 192.168.42.1%wlan0:80 while it runs. Starting the
# portal socket then fails with EADDRINUSE, as on hardware.
UNITS="${SANDBOX}/units"
cat >"${BIN}/systemctl-stateful" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >>"$CALL_LOG"
[ -e "${CERALIVE_PROVISION_ACTIVE_FLAG:-$CERALIVE_PROVISION_STATE_DIR/portal-active}" ] && m=marker || m=nomarker
echo "$m systemctl $*" >>"$MARKER_LOG"
[ "$1" = --no-block ] && shift
verb="$1"; shift; unit="${1:-}"
ap_up() {
  awk '/^nmcli connection up uuid /{u=1} /connection (down|delete) uuid /{u=0} END{exit !u}' "$CALL_LOG"
}
case "$verb" in
  is-system-running) printf '%s\n' "${STUB_SYSTEM_STATE-running}"; [ "${STUB_SYSTEM_STATE-running}" = running ]; exit ;;
  cat)   [ -n "${STUB_NO_INGRESS:-}" ] && [ "$unit" = ceralive-button-ingress.service ] && exit 1; exit 0 ;;
  stop)  rc=0
         for u in "$@"; do
           case " ${STUB_STOP_FAIL:-} " in *" $u "*) echo "Job for $u failed." >&2; rc=1; continue ;; esac
           rm -f "$UNITS/$u"
         done
         exit "$rc" ;;
  show)  for u in "$@"; do :; done
         [ -e "$UNITS/$u" ] && echo active || echo inactive ;;
  start)
    case " ${STUB_START_FAIL:-} " in *" $unit "*) echo "Job for $unit failed." >&2; exit 1 ;; esac
    if [ -n "${STUB_NO_INGRESS:-}" ] && [ "$unit" = ceralive-button-ingress.service ]; then
      echo "Unit $unit not found." >&2; exit 5
    fi
    if [ "$unit" = ceralive-portal.socket ] && [ -n "${STUB_PORTAL_FAIL:-}" ]; then
      if [ -n "${STUB_JAM_MARKER:-}" ]; then
        mk="${CERALIVE_PROVISION_STATE_DIR}/portal-active"; rm -f "$mk"; mkdir -p "$mk/held"
      fi
      echo "Failed to listen on 192.168.42.1:80: Address already in use" >&2; exit 1
    fi
    if [ "$unit" = ceralive-portal.socket ] && [ -e "$UNITS/ceralive-button-ingress.service" ] && ap_up; then
      echo "Failed to listen on 192.168.42.1:80: Address already in use" >&2; exit 1
    fi
    : >"$UNITS/$unit" ;;
esac
exit 0
STUB
chmod +x "${BIN}/systemctl-stateful"
# Who holds 192.168.42.1:80 right now, one unit per line.
ap80_owners() {
  awk '/^nmcli connection up uuid /{u=1} /connection (down|delete) uuid /{u=0} END{exit !u}' "${CALL_LOG}" || return 0
  [ -e "${UNITS}/ceralive-button-ingress.service" ] && echo ceralive-button-ingress.service
  [ -e "${UNITS}/ceralive-portal.socket" ] && echo ceralive-portal.socket
  return 0
}
boot_units() { rm -rf "${UNITS}"; mkdir -p "${UNITS}"; : >"${UNITS}/ceralive.service"; : >"${UNITS}/ceralive-button-ingress.service"; }

reset_state; boot_units
: >"$(state_file force-portal)"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_PROFILES_FILE=/dev/null \
    bash "${PROVISION}" start >/dev/null 2>&1
OWNERS="$(ap80_owners)"
[ "${OWNERS}" = "ceralive-portal.socket" ]       && pass "portal is the only listener on 192.168.42.1:80" || fail "portal is the only listener on 192.168.42.1:80 (got: ${OWNERS//$'\n'/, })"
[ ! -e "${UNITS}/ceralive-button-ingress.service" ] && pass "button ingress stopped while the AP is up" || fail "button ingress stopped while the AP is up"
[ ! -e "${UNITS}/ceralive.service" ]             && pass "CeraUI stopped while the AP is up" || fail "CeraUI stopped while the AP is up"

# Failed join re-arms the AP: the ingress stays down and the portal comes back alone.
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_USER_UP_RC=4 STUB_CON_SSID=HomeNet \
    bash "${PROVISION}" connect ceralive-wifi >/dev/null 2>&1
OWNERS="$(ap80_owners)"
[ "${OWNERS}" = "ceralive-portal.socket" ]       && pass "re-armed portal is the only listener on 192.168.42.1:80" || fail "re-armed portal is the only listener on 192.168.42.1:80 (got: ${OWNERS//$'\n'/, })"

# Successful join tears down: the portal is gone, CeraUI and the ingress are back.
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_USER_UP_RC=0 STUB_CONNECTIVITY=full STUB_CON_SSID=HomeNet \
    bash "${PROVISION}" connect ceralive-wifi >/dev/null 2>&1
[ ! -e "${UNITS}/ceralive-portal.socket" ]       && pass "portal socket stopped after the join" || fail "portal socket stopped after the join"
[ -e "${UNITS}/ceralive-button-ingress.service" ] && pass "button ingress restarted after the join" || fail "button ingress restarted after the join"
[ -e "${UNITS}/ceralive.service" ]               && pass "CeraUI restarted after the join" || fail "CeraUI restarted after the join"

# A plain service stop (shutdown or manual) also hands the front door back.
reset_state; boot_units
: >"$(state_file force-portal)"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_PROFILES_FILE=/dev/null \
    bash "${PROVISION}" start >/dev/null 2>&1
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" bash "${PROVISION}" stop >/dev/null 2>&1
[ -e "${UNITS}/ceralive-button-ingress.service" ] && pass "button ingress restored by stop" || fail "button ingress restored by stop"
[ ! -e "${UNITS}/ceralive-portal.socket" ]       && pass "portal socket stopped by stop" || fail "portal socket stopped by stop"

# ===========================================================================
echo "== Scenario J: a portal that cannot listen never leaves the box without a front door =="
reset_state; boot_units
: >"$(state_file force-portal)"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_PROFILES_FILE=/dev/null STUB_PORTAL_FAIL=1 \
    bash "${PROVISION}" start >/dev/null 2>&1
rc=$?
[ "${rc}" -ne 0 ]                                && pass "start fails when the portal cannot listen" || fail "start fails when the portal cannot listen (rc=${rc})"
[ -z "$(ap80_owners)" ] && ! awk '/^nmcli connection up uuid /{u=1} /connection (down|delete) uuid /{u=0} END{exit !u}' "${CALL_LOG}" \
                                                 && pass "AP brought down again" || fail "AP brought down again"
[ ! -e "$(state_file portal-active)" ]           && pass "portal-active marker removed" || fail "portal-active marker removed"
[ -e "$(state_file force-portal)" ]              && pass "force flag kept for the next try" || fail "force flag kept for the next try"
[ -e "${UNITS}/ceralive.service" ]               && pass "CeraUI restored" || fail "CeraUI restored"
[ -e "${UNITS}/ceralive-button-ingress.service" ] && pass "button ingress restored" || fail "button ingress restored"
[ -z "$(ls -A "${DNSDIR}" 2>/dev/null)" ]        && pass "DNS capture removed" || fail "DNS capture removed"

# The re-arm after a failed join takes the same way out, and keeps last-error.
reset_state; boot_units
: >"$(state_file force-portal)"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_PROFILES_FILE=/dev/null \
    bash "${PROVISION}" start >/dev/null 2>&1
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_USER_UP_RC=4 STUB_CON_SSID=HomeNet STUB_PORTAL_FAIL=1 \
    bash "${PROVISION}" connect ceralive-wifi >/dev/null 2>&1
[ ! -e "$(state_file portal-active)" ]           && pass "re-arm: portal-active marker removed" || fail "re-arm: portal-active marker removed"
[ -e "$(state_file last-error)" ]                && pass "re-arm: last-error kept" || fail "re-arm: last-error kept"
[ -e "${UNITS}/ceralive.service" ] && [ -e "${UNITS}/ceralive-button-ingress.service" ] \
                                                 && pass "re-arm: CeraUI and ingress restored" || fail "re-arm: CeraUI and ingress restored"

# The AP itself cannot be re-activated after a failed join: same way out.
reset_state; boot_units
: >"$(state_file force-portal)"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_PROFILES_FILE=/dev/null \
    bash "${PROVISION}" start >/dev/null 2>&1
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_USER_UP_RC=4 STUB_CON_SSID=HomeNet STUB_AP_UP_RC=10 \
    bash "${PROVISION}" connect ceralive-wifi >/dev/null 2>&1
[ ! -e "$(state_file portal-active)" ]           && pass "AP re-activation fails: marker removed" || fail "AP re-activation fails: marker removed"
[ -e "${UNITS}/ceralive.service" ] && [ -e "${UNITS}/ceralive-button-ingress.service" ] \
                                                 && pass "AP re-activation fails: CeraUI and ingress restored" || fail "AP re-activation fails: CeraUI and ingress restored"
[ -z "$(ls -A "${DNSDIR}" 2>/dev/null)" ]        && pass "AP re-activation fails: DNS capture removed" || fail "AP re-activation fails: DNS capture removed"
[ -e "$(state_file force-portal)" ] && [ -e "$(state_file last-error)" ] \
                                                 && pass "AP re-activation fails: retry flags kept" || fail "AP re-activation fails: retry flags kept"

# A DNS capture left behind by an older failed bring-up goes on the next boot that
# needs no portal.
reset_state; boot_units
mkdir -p "${DNSDIR}"; printf 'address=/#/192.168.42.1\n' >"${DNSDIR}/ceralive-portal.conf"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_PROFILES_FILE=/dev/null STUB_CONNECTIVITY=full \
    bash "${PROVISION}" start >/dev/null 2>&1
[ ! -e "${DNSDIR}/ceralive-portal.conf" ]        && pass "stale DNS capture removed when no portal is needed" || fail "stale DNS capture removed when no portal is needed"

# ===========================================================================
echo "== Scenario K: ExecStop restores the front door on a manual stop, starts nothing at shutdown =="
grep -qx 'ExecStop=/usr/local/sbin/ceralive-provision service-stop' "${PROVISION%.sh}.service" \
                                                 && pass "unit uses service-stop" || fail "unit uses service-stop"
grep -qx 'TimeoutStopSec=10' "${PROVISION%.sh}.service" && pass "unit has a 10 s stop budget" || fail "unit has a 10 s stop budget"
reset_state; boot_units
: >"$(state_file force-portal)"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_PROFILES_FILE=/dev/null bash "${PROVISION}" start >/dev/null 2>&1
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_SYSTEM_STATE=stopping bash "${PROVISION}" service-stop >/dev/null 2>&1
[ ! -e "${UNITS}/ceralive.service" ] && [ ! -e "${UNITS}/ceralive-button-ingress.service" ] \
                                                 && pass "shutdown starts neither CeraUI nor the ingress" || fail "shutdown starts neither CeraUI nor the ingress"
[ ! -e "${UNITS}/ceralive-portal.socket" ]       && pass "shutdown stops the portal (queued)" || fail "shutdown stops the portal (queued)"
[ -e "$(state_file portal-active)" ] && [ -e "$(state_file force-portal)" ] \
                                                 && pass "shutdown keeps marker and force flag" || fail "shutdown keeps marker and force flag"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_PROFILES_FILE=/dev/null bash "${PROVISION}" start >/dev/null 2>&1
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_SYSTEM_STATE=running bash "${PROVISION}" service-stop >/dev/null 2>&1
[ -e "${UNITS}/ceralive.service" ] && [ -e "${UNITS}/ceralive-button-ingress.service" ] \
                                                 && pass "manual unit stop restores CeraUI and the ingress" || fail "manual unit stop restores CeraUI and the ingress"
[ ! -e "${UNITS}/ceralive-portal.socket" ]       && pass "manual unit stop stops the portal" || fail "manual unit stop stops the portal"

# ===========================================================================
echo "== Scenario L: a front door that does not come back is reported, never claimed =="
BOTH="ceralive.service ceralive-button-ingress.service"
up_ap() { # fresh box with the portal up
  reset_state; boot_units; : >"$(state_file force-portal)"
  env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_PROFILES_FILE=/dev/null bash "${PROVISION}" start >/dev/null 2>&1
}
OUTF="${SANDBOX}/provision.out"

# Join succeeds, both restores fail: non-zero, logged, the joined link stays, no false claim.
up_ap; : >"${CALL_LOG}"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_USER_UP_RC=0 STUB_CONNECTIVITY=full STUB_CON_SSID=HomeNet \
    STUB_START_FAIL="${BOTH}" bash "${PROVISION}" connect ceralive-wifi >"${OUTF}" 2>&1
rc=$?
[ "${rc}" -ne 0 ]                                && pass "join: failed restore exits non-zero" || fail "join: failed restore exits non-zero"
grep -q "ERROR: could not start ceralive.service" "${OUTF}" && grep -q "ERROR: could not start ceralive-button-ingress.service" "${OUTF}" \
                                                 && pass "join: both failed starts logged" || fail "join: both failed starts logged"
! grep -q "CeraUI on port 80" "${OUTF}"          && pass "join: no claim that CeraUI is on port 80" || fail "join: no claim that CeraUI is on port 80"
! called "nmcli device disconnect"               && pass "join: the joined Wi-Fi link is kept" || fail "join: the joined Wi-Fi link is kept"
[ ! -e "$(state_file portal-active)" ]           && pass "join: provisioning state still cleared" || fail "join: provisioning state still cleared"

# Join succeeds on an image without the ingress unit: that is a full restore.
up_ap
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_USER_UP_RC=0 STUB_CONNECTIVITY=full STUB_CON_SSID=HomeNet \
    STUB_NO_INGRESS=1 bash "${PROVISION}" connect ceralive-wifi >"${OUTF}" 2>&1
rc=$?
[ "${rc}" -eq 0 ] && grep -q "CeraUI on port 80" "${OUTF}" \
                                                 && pass "join: an absent ingress unit is not a failure" || fail "join: an absent ingress unit is not a failure (rc=${rc})"
! grep -q "ERROR" "${OUTF}"                      && pass "join: no error logged for an absent ingress" || fail "join: no error logged for an absent ingress"

# Only the ingress fails (present unit): still a failure.
up_ap
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_USER_UP_RC=0 STUB_CONNECTIVITY=full STUB_CON_SSID=HomeNet \
    STUB_START_FAIL=ceralive-button-ingress.service bash "${PROVISION}" connect ceralive-wifi >"${OUTF}" 2>&1
[ $? -ne 0 ]                                     && pass "join: a present ingress that fails to start is reported" || fail "join: a present ingress that fails to start is reported"

# Manual stop (verb and unit stop), both restores fail.
for verb in stop service-stop; do
  up_ap
  env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_SYSTEM_STATE=running STUB_START_FAIL="${BOTH}" \
      bash "${PROVISION}" "${verb}" >"${OUTF}" 2>&1
  rc=$?
  [ "${rc}" -ne 0 ] && grep -q "restore FAILED" "${OUTF}" \
                                                 && pass "${verb}: failed restore exits non-zero and says so" || fail "${verb}: failed restore exits non-zero and says so (rc=${rc})"
done
# Manual stop without the ingress unit restores fully.
up_ap
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_SYSTEM_STATE=running STUB_NO_INGRESS=1 \
    bash "${PROVISION}" service-stop >"${OUTF}" 2>&1
[ $? -eq 0 ] && grep -q "; CeraUI restored" "${OUTF}" \
                                                 && pass "service-stop: an absent ingress unit is not a failure" || fail "service-stop: an absent ingress unit is not a failure"
# Shutdown starts nothing, so it has nothing to fail.
up_ap
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_SYSTEM_STATE=stopping STUB_START_FAIL="${BOTH}" \
    bash "${PROVISION}" service-stop >"${OUTF}" 2>&1
[ $? -eq 0 ]                                     && pass "shutdown: exits 0 (starts nothing)" || fail "shutdown: exits 0 (starts nothing)"

# Abort path: the log says what the restore achieved.
reset_state; boot_units; : >"$(state_file force-portal)"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_PROFILES_FILE=/dev/null STUB_PORTAL_FAIL=1 \
    STUB_START_FAIL=ceralive.service bash "${PROVISION}" start >"${OUTF}" 2>&1
rc=$?
[ "${rc}" -ne 0 ] && grep -q "restore FAILED" "${OUTF}" && ! grep -q "CeraUI restored" "${OUTF}" \
                                                 && pass "abort: a failed restore is logged as failed" || fail "abort: a failed restore is logged as failed"
reset_state; boot_units; : >"$(state_file force-portal)"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_PROFILES_FILE=/dev/null STUB_PORTAL_FAIL=1 STUB_NO_INGRESS=1 \
    bash "${PROVISION}" start >"${OUTF}" 2>&1
rc=$?
[ "${rc}" -ne 0 ] && grep -q "CeraUI restored" "${OUTF}" && ! grep -q "restore FAILED" "${OUTF}" \
                                                 && pass "abort: a full restore without the ingress unit is logged as restored" || fail "abort: a full restore without the ingress unit is logged as restored"

# ===========================================================================
echo "== Scenario M: the setup marker covers the whole AP lifetime and nothing more =="
# with_marker / without_marker: some call matching the ERE ran with / without the marker.
with_marker()    { grep -qE -- "^marker $1" "${MARKER_LOG}"; }
without_marker() { grep -qE -- "^nomarker $1" "${MARKER_LOG}"; }
AP_ADD='nmcli connection add .*con-name ceralive-ap '
AP_UP="nmcli connection up uuid ${AP_UUID}\$"
CERAUI_START='systemctl start ceralive.service$'
SC=(env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_PROFILES_FILE=/dev/null)

# Bring-up: the marker exists before the profile is created and before it is activated,
# and it carries what the portal reads.
reset_state; boot_units; : >"$(state_file force-portal)"
"${SC[@]}" bash "${PROVISION}" start >/dev/null 2>&1
with_marker "${AP_ADD}" && ! without_marker "${AP_ADD}" \
                                                 && pass "marker exists before the AP profile is created" || fail "marker exists before the AP profile is created"
with_marker "${AP_UP}" && ! without_marker "${AP_UP}" \
                                                 && pass "marker exists before the AP is activated" || fail "marker exists before the AP is activated"
grep -qx 'ssid=CeraLive-Setup-f00d' "$(state_file portal-active)" && grep -qx 'iface=wlan0' "$(state_file portal-active)" \
                                                 && pass "marker carries ssid and iface" || fail "marker carries ssid and iface"

# Station join: the marker stays through the attempt (CeraUI is told the radio is
# still the setup's) and is gone before CeraUI starts on the joined link.
: >"${MARKER_LOG}"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_USER_UP_RC=0 STUB_CONNECTIVITY=full STUB_CON_SSID=HomeNet \
    bash "${PROVISION}" connect ceralive-wifi >/dev/null 2>&1
with_marker 'nmcli --wait [0-9]+ connection up ceralive-wifi$' \
                                                 && pass "marker held through the station join" || fail "marker held through the station join"
without_marker "${CERAUI_START}" && ! with_marker "${CERAUI_START}" \
                                                 && pass "join: marker gone before CeraUI starts" || fail "join: marker gone before CeraUI starts"

# CeraUI and the ingress have exited (marker already present) before the AP profile is
# created or activated, on bring-up and on re-arm: a CeraUI AP request already in NM
# must not be the last activation on wlan0.
first_line() { grep -nE -- "$1" "${CALL_LOG}" | head -n1 | cut -d: -f1; }
stops_before_ap() { # $1=label
  local s_ui s_in add up
  s_ui="$(first_line '^systemctl stop ceralive.service$')"; s_in="$(first_line '^systemctl stop ceralive-button-ingress.service$')"
  add="$(first_line "^${AP_ADD}")"; up="$(first_line "^${AP_UP}")"
  [ -n "${s_ui}" ] && [ -n "${s_in}" ] && [ -n "${add}" ] && [ -n "${up}" ] \
    && [ "${s_ui}" -lt "${add}" ] && [ "${s_in}" -lt "${add}" ] && [ "${add}" -lt "${up}" ] \
                                                 && pass "${1}: CeraUI and ingress stopped before the AP is created" || fail "${1}: CeraUI and ingress stopped before the AP is created (${s_ui:-none}/${s_in:-none} vs ${add:-none})"
  with_marker 'systemctl stop ceralive.service$' && ! without_marker 'systemctl stop ceralive.service$' \
                                                 && pass "${1}: marker already present when CeraUI is stopped" || fail "${1}: marker already present when CeraUI is stopped"
}
reset_state; boot_units; : >"$(state_file force-portal)"
"${SC[@]}" bash "${PROVISION}" start >/dev/null 2>&1
stops_before_ap "bring-up"
: >"${CALL_LOG}"; : >"${MARKER_LOG}"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_USER_UP_RC=4 STUB_CON_SSID=HomeNet \
    bash "${PROVISION}" connect ceralive-wifi >/dev/null 2>&1
stops_before_ap "re-arm"

# A failed join re-arms with the marker in place the whole time.
reset_state; boot_units; : >"$(state_file force-portal)"
"${SC[@]}" bash "${PROVISION}" start >/dev/null 2>&1
: >"${MARKER_LOG}"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_USER_UP_RC=4 STUB_CON_SSID=HomeNet \
    bash "${PROVISION}" connect ceralive-wifi >/dev/null 2>&1
! grep -q '^nomarker' "${MARKER_LOG}" && [ -e "$(state_file portal-active)" ] \
                                                 && pass "failed join: marker never dropped while re-arming" || fail "failed join: marker never dropped while re-arming"

# Every failed bring-up, first or re-arm, leaves no marker, and CeraUI only starts
# after it is gone.
fail_case() { # $1=label $2=verb (start|rearm), rest=env for the failing call
  local label="$1" verb="$2"; shift 2
  reset_state; boot_units; : >"$(state_file force-portal)"
  if [ "${verb}" = rearm ]; then
    "${SC[@]}" bash "${PROVISION}" start >/dev/null 2>&1
    : >"${MARKER_LOG}"
    env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_USER_UP_RC=4 STUB_CON_SSID=HomeNet "$@" \
        bash "${PROVISION}" connect ceralive-wifi >/dev/null 2>&1
  else
    "${SC[@]}" "$@" bash "${PROVISION}" start >/dev/null 2>&1
  fi
  local rc=$?
  [ "${rc}" -ne 0 ] && [ ! -e "$(state_file portal-active)" ] \
                                                 && pass "${label}: fails and leaves no marker" || fail "${label}: fails and leaves no marker (rc=${rc})"
  without_marker "${CERAUI_START}" && ! with_marker "${CERAUI_START}" && [ -e "${UNITS}/ceralive.service" ] \
                                                 && pass "${label}: CeraUI starts only after the marker is gone" || fail "${label}: CeraUI starts only after the marker is gone"
}
fail_case "profile cannot be created"            start STUB_AP_ADD_RC=2
fail_case "AP cannot be activated"               start STUB_AP_UP_RC=10
fail_case "portal cannot listen"                 start STUB_PORTAL_FAIL=1
fail_case "re-arm: profile cannot be created"    rearm STUB_AP_ADD_RC=2
fail_case "re-arm: AP cannot be activated"       rearm STUB_AP_UP_RC=10
fail_case "re-arm: portal cannot listen"         rearm STUB_PORTAL_FAIL=1

# A marker that cannot be written means no AP at all.
reset_state; boot_units; : >"$(state_file force-portal)"
"${SC[@]}" CERALIVE_PROVISION_ACTIVE_FLAG="${SANDBOX}/missing-dir/portal-active" bash "${PROVISION}" start >/dev/null 2>&1
rc=$?
[ "${rc}" -ne 0 ] && ! called "nmcli connection add type wifi ifname wlan0 con-name ceralive-ap" && ! called "connection up uuid" && ! called "connection down" \
                                                 && pass "unwritable marker: no AP profile created or activated" || fail "unwritable marker: no AP profile created or activated (rc=${rc})"
[ -e "${UNITS}/ceralive.service" ] && [ -e "${UNITS}/ceralive-button-ingress.service" ] \
                                                 && pass "unwritable marker: CeraUI and ingress keep running" || fail "unwritable marker: CeraUI and ingress keep running"

# Manual stop (verb and unit stop) clears the marker before CeraUI starts and keeps
# the retry state; the next trigger brings the setup back with a fresh marker.
for verb in stop service-stop; do
  reset_state; boot_units; : >"$(state_file force-portal)"
  "${SC[@]}" bash "${PROVISION}" start >/dev/null 2>&1
  : >"${MARKER_LOG}"
  env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_SYSTEM_STATE=running bash "${PROVISION}" "${verb}" >/dev/null 2>&1
  [ ! -e "$(state_file portal-active)" ] && [ -e "$(state_file force-portal)" ] \
                                                 && pass "${verb}: marker cleared, force flag kept" || fail "${verb}: marker cleared, force flag kept"
  with_marker "nmcli --wait 3 connection down uuid ${AP_UUID}\$" && without_marker "${CERAUI_START}" && ! with_marker "${CERAUI_START}" \
                                                 && pass "${verb}: marker held until the AP is down, gone before CeraUI starts" || fail "${verb}: marker held until the AP is down, gone before CeraUI starts"
done
"${SC[@]}" bash "${PROVISION}" start >/dev/null 2>&1
[ -e "$(state_file portal-active)" ]             && pass "next trigger after a stop writes the marker again" || fail "next trigger after a stop writes the marker again"

# ===========================================================================
echo "== Scenario N: the leftover cleanup deletes only the image's own setup AP =="
STATION_UUID="0000beef-0000-4000-8000-0000000000b2"
FOREIGN_UUID="0000f0e1-0000-4000-8000-0000000000c3"
owned_ap()   { echo "ceralive-ap:${AP_UUID}:802-11-wireless" >>"${NMSTATE}/profiles"
               printf '%s 802-11-wireless.mode ap\n%s 802-11-wireless.ssid CeraLive-Setup-f00d\n%s ipv4.addresses 192.168.42.1/24\n' "${AP_UUID}" "${AP_UUID}" "${AP_UUID}" >>"${NMSTATE}/details"; }
station_named_ap() { echo "ceralive-ap:${STATION_UUID}:802-11-wireless" >>"${NMSTATE}/profiles"
               printf '%s 802-11-wireless.mode infrastructure\n%s 802-11-wireless.ssid HomeNet\n%s ipv4.addresses \n' "${STATION_UUID}" "${STATION_UUID}" "${STATION_UUID}" >>"${NMSTATE}/details"; }
foreign_ap() { echo "ceralive-ap:${FOREIGN_UUID}:802-11-wireless" >>"${NMSTATE}/profiles"
               printf '%s 802-11-wireless.mode ap\n%s 802-11-wireless.ssid SomeoneElse\n%s ipv4.addresses 192.168.42.1/24\n' "${FOREIGN_UUID}" "${FOREIGN_UUID}" "${FOREIGN_UUID}" >>"${NMSTATE}/details"; }
HOME_UUID="0000a0a0-0000-4000-8000-0000000000e5"
# A boot with a saved user network (HomeNet) next to whatever the case seeded.
no_portal_boot() { # extra env for the run
  grep -q '^HomeNet:' "${NMSTATE}/profiles" || echo "HomeNet:${HOME_UUID}:802-11-wireless" >>"${NMSTATE}/profiles"
  env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" "$@" \
      bash "${PROVISION}" start >"${OUTF}" 2>&1
}
# A boot with no uplink and a short grace window: only stored profiles keep setup down.
offline_boot() { # extra env for the run
  env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_CONNECTIVITY=none CERALIVE_PROVISION_GRACE=2 CERALIVE_PROVISION_POLL=1 "$@" \
      bash "${PROVISION}" start >"${OUTF}" 2>&1
}
OUTF="${SANDBOX}/provision.out"

# After a stop: the image's AP profile goes, by UUID, and the old error with it.
reset_state; boot_units; owned_ap
printf 'ssid=HomeNet\nreason=auth_or_timeout\n' >"$(state_file last-error)"
no_portal_boot; rc=$?
[ "${rc}" -eq 0 ] && called "nmcli connection delete uuid ${AP_UUID}" && [ ! -e "$(state_file last-error)" ] \
                                                 && pass "leftover setup AP deleted by UUID when no portal is needed" || fail "leftover setup AP deleted by UUID when no portal is needed (rc=${rc})"
! called "nmcli connection delete ceralive-ap"   && pass "leftover cleanup never deletes by name" || fail "leftover cleanup never deletes by name"
! called "nmcli device disconnect" && ! called "systemctl start" && ! called "nmcli connection up" \
                                                 && pass "leftover cleanup leaves wlan0 and CeraUI alone" || fail "leftover cleanup leaves wlan0 and CeraUI alone"

# A user's station that happens to be called ceralive-ap, and an AP with someone else's
# SSID, are not the image's: nothing is deleted on an ordinary boot.
reset_state; boot_units; station_named_ap; foreign_ap
printf 'ssid=HomeNet\nreason=auth_or_timeout\n' >"$(state_file last-error)"
no_portal_boot; rc=$?
[ "${rc}" -eq 0 ] && ! called "nmcli connection delete" \
                                                 && pass "station or foreign AP named ceralive-ap is never deleted" || fail "station or foreign AP named ceralive-ap is never deleted (rc=${rc})"
[ -e "$(state_file last-error)" ]                && pass "no setup AP deleted, last-error kept" || fail "no setup AP deleted, last-error kept"

# Each ownership witness counts on its own: right SSID and address but station mode,
# or AP mode and SSID but another address, is not the image's setup AP.
reset_state; boot_units
echo "ceralive-ap:${STATION_UUID}:802-11-wireless" >>"${NMSTATE}/profiles"
printf '%s 802-11-wireless.mode infrastructure\n%s 802-11-wireless.ssid CeraLive-Setup-f00d\n%s ipv4.addresses 192.168.42.1/24\n' "${STATION_UUID}" "${STATION_UUID}" "${STATION_UUID}" >>"${NMSTATE}/details"
echo "ceralive-ap:${FOREIGN_UUID}:802-11-wireless" >>"${NMSTATE}/profiles"
printf '%s 802-11-wireless.mode ap\n%s 802-11-wireless.ssid CeraLive-Setup-f00d\n%s ipv4.addresses 10.42.0.1/24\n' "${FOREIGN_UUID}" "${FOREIGN_UUID}" "${FOREIGN_UUID}" >>"${NMSTATE}/details"
no_portal_boot
! called "nmcli connection delete"               && pass "station mode or another address is not the setup AP" || fail "station mode or another address is not the setup AP"

# Both present: only the verified UUID goes.
reset_state; boot_units; station_named_ap; owned_ap
no_portal_boot
called "nmcli connection delete uuid ${AP_UUID}" && ! called "nmcli connection delete uuid ${STATION_UUID}" \
                                                 && pass "only the verified setup AP UUID is deleted" || fail "only the verified setup AP UUID is deleted"

# A delete that fails is reported and keeps last-error; so does an unreadable NM.
reset_state; boot_units; owned_ap
printf 'ssid=HomeNet\nreason=auth_or_timeout\n' >"$(state_file last-error)"
no_portal_boot STUB_DELETE_RC=1; rc=$?
[ "${rc}" -ne 0 ] && [ -e "$(state_file last-error)" ] && grep -q "ERROR: could not delete setup AP profile" "${OUTF}" \
                                                 && pass "failed leftover delete: non-zero, logged, last-error kept" || fail "failed leftover delete: non-zero, logged, last-error kept (rc=${rc})"
reset_state; boot_units; owned_ap
printf 'ssid=HomeNet\nreason=auth_or_timeout\n' >"$(state_file last-error)"
no_portal_boot STUB_NM_READ_RC=8; rc=$?
[ "${rc}" -ne 0 ] && [ -e "$(state_file last-error)" ] && ! called "nmcli connection delete" \
                                                 && pass "unreadable NM: non-zero, nothing deleted, last-error kept" || fail "unreadable NM: non-zero, nothing deleted, last-error kept (rc=${rc})"

# The stored-profile count tells the two apart the same way: a user's station called
# ceralive-ap is a saved network and keeps setup down at once; the image's setup AP,
# whether recognised by its settings or by the recorded UUID (even renamed), is not.
reset_state; boot_units; station_named_ap
offline_boot; rc=$?
[ "${rc}" -eq 0 ] && ! called "${AP_UP_CALL}" && grep -q "found 1 stored WiFi profile" "${OUTF}" \
                                                 && pass "station profile named ceralive-ap alone suppresses the portal" || fail "station profile named ceralive-ap alone suppresses the portal (rc=${rc})"
reset_state; boot_units; owned_ap
offline_boot; rc=$?
[ "${rc}" -eq 0 ] && called "${AP_UP_CALL}"      && pass "setup AP alone (by its settings) does not suppress the portal" || fail "setup AP alone (by its settings) does not suppress the portal (rc=${rc})"
reset_state; boot_units
echo "setup-renamed:${AP_UUID}:802-11-wireless" >>"${NMSTATE}/profiles"
printf '%s\n' "${AP_UUID}" >"$(state_file ap-uuid)"
offline_boot; rc=$?
[ "${rc}" -eq 0 ] && called "${AP_UP_CALL}"      && pass "recorded setup AP under another name does not suppress the portal" || fail "recorded setup AP under another name does not suppress the portal (rc=${rc})"
# Setup AP identity unreadable (malformed record): the count falls back to leaving out
# every profile called ceralive-ap, as before.
reset_state; boot_units; station_named_ap
printf 'not-a-uuid\n' >"$(state_file ap-uuid)"
offline_boot
grep -q "leaving out every profile called ceralive-ap" "${OUTF}" && grep -q "no stored WiFi profiles" "${OUTF}" \
                                                 && pass "unreadable setup AP identity: count falls back to the name" || fail "unreadable setup AP identity: count falls back to the name"

# Names with ':' come escaped from nmcli -t (`\:`). The recorded setup AP renamed to
# such a name is still the setup AP: not counted offline, and on a boot that needs no
# portal it is deleted by UUID; its record never goes while the profile is saved.
reset_state; boot_units
echo "setup:old:${AP_UUID}:802-11-wireless" >>"${NMSTATE}/profiles"
printf '%s\n' "${AP_UUID}" >"$(state_file ap-uuid)"
offline_boot; rc=$?
[ "${rc}" -eq 0 ] && called "${AP_UP_CALL}"      && pass "recorded setup AP renamed with ':' is not counted" || fail "recorded setup AP renamed with ':' is not counted (rc=${rc})"
reset_state; boot_units
echo "setup:old:${AP_UUID}:802-11-wireless" >>"${NMSTATE}/profiles"
printf '%s\n' "${AP_UUID}" >"$(state_file ap-uuid)"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_CONNECTIVITY=full bash "${PROVISION}" start >"${OUTF}" 2>&1
called "nmcli connection delete uuid ${AP_UUID}" && ! grep -q ":${AP_UUID}:" "${NMSTATE}/profiles" \
  && { grep -q ":${AP_UUID}:" "${NMSTATE}/profiles" || [ ! -s "$(state_file ap-uuid)" ]; } \
                                                 && pass "renamed setup AP with ':' deleted by UUID, record kept until it is gone" || fail "renamed setup AP with ':' deleted by UUID, record kept until it is gone"
# A station called a:b is one saved network, also when the count falls back to names.
reset_state; boot_units
echo "a:b:${STATION_UUID}:802-11-wireless" >>"${NMSTATE}/profiles"
offline_boot
grep -q "found 1 stored WiFi profile" "${OUTF}"  && pass "station named a:b counts once" || fail "station named a:b counts once"
reset_state; boot_units
echo "a:b:${STATION_UUID}:802-11-wireless" >>"${NMSTATE}/profiles"
printf 'not-a-uuid\n' >"$(state_file ap-uuid)"
offline_boot
grep -q "found 1 stored WiFi profile" "${OUTF}"  && pass "station named a:b counts once in the name fallback" || fail "station named a:b counts once in the name fallback"
# The user profile is found by its unescaped name too (here a name with ':').
reset_state; boot_units; seed_setup_ap
printf 'ssid=CeraLive-Setup-f00d\ncon=ceralive-ap\n' >"$(state_file portal-active)"
echo "cera:wifi:${STATION_UUID}:802-11-wireless" >>"${NMSTATE}/profiles"
offline_boot CERALIVE_USER_CON_NAME='cera:wifi'; rc=$?
called "${AP_UP_CALL}" && ! grep -q ":${STATION_UUID}:" "${NMSTATE}/profiles" \
                                                 && pass "user profile named with ':' is found (earlier image's handoff)" || fail "user profile named with ':' is found (earlier image's handoff) (rc=${rc})"

# No setup AP at all: nothing deleted, exit 0.
reset_state; boot_units
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_CONNECTIVITY=full STUB_PROFILES_FILE=/dev/null \
    bash "${PROVISION}" start >/dev/null 2>&1
rc=$?
[ "${rc}" -eq 0 ] && ! called "nmcli connection delete" && pass "no AP profile, nothing deleted" || fail "no AP profile, nothing deleted (rc=${rc})"

# ===========================================================================
echo "== Scenario O: a stale marker from a shutdown keeps the saved uplink on wlan0 =="
reset_state; boot_units; owned_ap
printf 'ssid=CeraLive-Setup-f00d\n' >"$(state_file portal-active)"
echo "${STATION_UUID}" >>"${NMSTATE}/active"     # a saved network already up on wlan0
no_portal_boot; rc=$?
[ "${rc}" -eq 0 ] && [ ! -e "$(state_file portal-active)" ] \
                                                 && pass "stale marker cleared when no portal is needed" || fail "stale marker cleared when no portal is needed (rc=${rc})"
! called "nmcli device disconnect"               && pass "stale cleanup does not disconnect wlan0" || fail "stale cleanup does not disconnect wlan0"
grep -qx "${STATION_UUID}" "${NMSTATE}/active"   && pass "saved uplink still active after stale cleanup" || fail "saved uplink still active after stale cleanup"
# The explicit teardown verb still releases the radio (Scenario H semantics unchanged).
reset_state; boot_units
printf 'portal-active' >"$(state_file portal-active)"
bash "${PROVISION}" teardown >/dev/null 2>&1
called "nmcli device disconnect wlan0"           && pass "teardown verb still releases wlan0" || fail "teardown verb still releases wlan0"

# ===========================================================================
echo "== Scenario P: the marker is released only on proof, and a failed handback says so =="
up_ap_model() { reset_state; boot_units; : >"$(state_file force-portal)"
  env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_PROFILES_FILE=/dev/null bash "${PROVISION}" start >/dev/null 2>&1; }
# Unremovable marker: a non-empty directory in its place (rm -f fails, as for EROFS/EACCES).
jam_marker() { rm -f "$(state_file portal-active)"; mkdir -p "$(state_file portal-active)/held"; }

for verb in stop service-stop; do
  # NM cannot take the AP down: it stays active, so the marker stays with it.
  up_ap_model
  env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_SYSTEM_STATE=running STUB_AP_DOWN_RC=10 \
      bash "${PROVISION}" "${verb}" >"${OUTF}" 2>&1
  rc=$?
  [ "${rc}" -ne 0 ] && [ -e "$(state_file portal-active)" ] && grep -q "ERROR: setup AP still active" "${OUTF}" \
                                                 && pass "${verb}: AP still up → marker kept, non-zero, logged" || fail "${verb}: AP still up → marker kept, non-zero, logged (rc=${rc})"
  ! grep -q "provisioning AP link stopped" "${OUTF}" && [ -e "${UNITS}/ceralive.service" ] \
                                                 && pass "${verb}: AP still up → no handback claimed, front door back" || fail "${verb}: AP still up → no handback claimed, front door back"
  # NM unreadable after the down: no evidence, marker kept.
  up_ap_model
  env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_SYSTEM_STATE=running STUB_NM_READ_RC=8 \
      bash "${PROVISION}" "${verb}" >"${OUTF}" 2>&1
  rc=$?
  [ "${rc}" -ne 0 ] && [ -e "$(state_file portal-active)" ] && grep -q "ERROR: could not confirm the setup AP is down" "${OUTF}" \
                                                 && pass "${verb}: NM unreadable → marker kept, non-zero, logged" || fail "${verb}: NM unreadable → marker kept, non-zero, logged (rc=${rc})"
  # Only the active-connection read fails: still no evidence, marker kept.
  up_ap_model
  env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_SYSTEM_STATE=running STUB_ACTIVE_READ_RC=8 \
      bash "${PROVISION}" "${verb}" >"${OUTF}" 2>&1
  rc=$?
  [ "${rc}" -ne 0 ] && [ -e "$(state_file portal-active)" ] \
                                                 && pass "${verb}: active list unreadable → marker kept, non-zero" || fail "${verb}: active list unreadable → marker kept, non-zero (rc=${rc})"
  # The marker cannot be removed: reported, never claimed.
  up_ap_model; jam_marker
  env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_SYSTEM_STATE=running \
      bash "${PROVISION}" "${verb}" >"${OUTF}" 2>&1
  rc=$?
  [ "${rc}" -ne 0 ] && grep -q "ERROR: could not remove the setup marker" "${OUTF}" && ! grep -q "provisioning AP link stopped" "${OUTF}" \
                                                 && pass "${verb}: unremovable marker → non-zero, logged, no handback claimed" || fail "${verb}: unremovable marker → non-zero, logged, no handback claimed (rc=${rc})"
done
# Ordinary stop: profile inactive counts as gone.
up_ap_model
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_SYSTEM_STATE=running bash "${PROVISION}" stop >"${OUTF}" 2>&1
rc=$?
[ "${rc}" -eq 0 ] && [ ! -e "$(state_file portal-active)" ] && grep -q "provisioning AP link stopped; CeraUI restored" "${OUTF}" \
                                                 && pass "stop: AP down → marker released, handback reported" || fail "stop: AP down → marker released, handback reported (rc=${rc})"

# Abort with an AP that will not go down: marker kept and said so.
reset_state; boot_units; : >"$(state_file force-portal)"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_PROFILES_FILE=/dev/null STUB_PORTAL_FAIL=1 STUB_AP_DOWN_RC=10 \
    bash "${PROVISION}" start >"${OUTF}" 2>&1
rc=$?
[ "${rc}" -ne 0 ] && [ -e "$(state_file portal-active)" ] && grep -q "setup marker KEPT" "${OUTF}" && ! grep -q "AP dropped" "${OUTF}" \
                                                 && pass "abort: AP still up → marker kept and reported" || fail "abort: AP still up → marker kept and reported (rc=${rc})"
[ -e "${UNITS}/ceralive.service" ]               && pass "abort: front door back even with the marker kept" || fail "abort: front door back even with the marker kept"
# Abort with a marker that cannot be removed (jammed when the portal fails to listen).
reset_state; boot_units; : >"$(state_file force-portal)"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_PROFILES_FILE=/dev/null STUB_PORTAL_FAIL=1 STUB_JAM_MARKER=1 \
    bash "${PROVISION}" start >"${OUTF}" 2>&1
rc=$?
[ "${rc}" -ne 0 ] && grep -q "ERROR: could not remove the setup marker" "${OUTF}" && grep -q "setup marker KEPT" "${OUTF}" \
                                                 && pass "abort: unremovable marker → reported, not claimed dropped" || fail "abort: unremovable marker → reported, not claimed dropped (rc=${rc})"

# Teardown after a join with an unremovable marker: non-zero, logged, link kept.
up_ap_model; jam_marker
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_USER_UP_RC=0 STUB_CONNECTIVITY=full STUB_CON_SSID=HomeNet \
    bash "${PROVISION}" connect ceralive-wifi >"${OUTF}" 2>&1
rc=$?
[ "${rc}" -ne 0 ] && grep -q "ERROR: provisioning teardown incomplete (setup marker kept)" "${OUTF}" && ! grep -q "provisioning mode cleared" "${OUTF}" \
                                                 && pass "join teardown: unremovable marker → non-zero, logged, no clear claimed" || fail "join teardown: unremovable marker → non-zero, logged, no clear claimed (rc=${rc})"
! called "nmcli device disconnect"               && pass "join teardown: joined link kept on failure" || fail "join teardown: joined link kept on failure"


# ===========================================================================
echo "== Scenario Q: no AP change until CeraUI and the ingress are confirmed stopped =="
for unit in ceralive.service ceralive-button-ingress.service; do
  reset_state; boot_units; : >"$(state_file force-portal)"
  "${SC[@]}" STUB_STOP_FAIL="${unit}" bash "${PROVISION}" start >"${OUTF}" 2>&1
  rc=$?
  [ "${rc}" -ne 0 ] && grep -q "ERROR: ${unit} did not stop" "${OUTF}" \
                                                 && pass "${unit} will not stop: bring-up fails and says so" || fail "${unit} will not stop: bring-up fails and says so (rc=${rc})"
  ! called "connection add" && ! called "connection up uuid" && ! called "connection delete" && ! called "connection down" \
                                                 && pass "${unit} will not stop: no AP profile touched" || fail "${unit} will not stop: no AP profile touched"
  [ ! -e "$(state_file portal-active)" ] && [ -e "${UNITS}/ceralive.service" ] && [ -e "${UNITS}/ceralive-button-ingress.service" ] \
                                                 && pass "${unit} will not stop: marker released, front door running" || fail "${unit} will not stop: marker released, front door running"
  [ -e "$(state_file force-portal)" ]            && pass "${unit} will not stop: force flag kept for a retry" || fail "${unit} will not stop: force flag kept for a retry"
done
# Without the ingress unit on the image, a stopped CeraUI is enough.
reset_state; boot_units; rm -f "${UNITS}/ceralive-button-ingress.service"; : >"$(state_file force-portal)"
"${SC[@]}" STUB_NO_INGRESS=1 bash "${PROVISION}" start >/dev/null 2>&1
rc=$?
[ "${rc}" -eq 0 ] && called "${AP_UP_CALL}"      && pass "absent ingress unit does not block bring-up" || fail "absent ingress unit does not block bring-up (rc=${rc})"
# The plain stub reports a unit still active: same refusal.
reset_state; : >"$(state_file force-portal)"
env STUB_PROFILES_FILE=/dev/null STUB_UNIT_STATE=deactivating bash "${PROVISION}" start >/dev/null 2>&1
rc=$?
[ "${rc}" -ne 0 ] && ! called "connection add"   && pass "a unit still deactivating blocks bring-up" || fail "a unit still deactivating blocks bring-up (rc=${rc})"
reset_state; : >"$(state_file force-portal)"
env STUB_PROFILES_FILE=/dev/null STUB_SHOW_RC=1 bash "${PROVISION}" start >/dev/null 2>&1
rc=$?
[ "${rc}" -ne 0 ] && ! called "connection add"   && pass "unit state unreadable blocks bring-up" || fail "unit state unreadable blocks bring-up (rc=${rc})"

# ===========================================================================
echo "== Scenario R: setup-only NM operations go by the setup AP's UUID =="
# A user's station named ceralive-ap, active on wlan0, survives every setup path.
add_station_named_ap() { echo "ceralive-ap:${STATION_UUID}:802-11-wireless" >>"${NMSTATE}/profiles"
  printf '%s 802-11-wireless.mode infrastructure\n%s 802-11-wireless.ssid HomeNet\n%s ipv4.addresses \n' "${STATION_UUID}" "${STATION_UUID}" "${STATION_UUID}" >>"${NMSTATE}/details"; }
station_untouched() { # $1=label
  ! grep -qE "connection (up|down|delete) uuid ${STATION_UUID}" "${CALL_LOG}" && no_name_ops && grep -q ":${STATION_UUID}:" "${NMSTATE}/profiles" \
                                                 && pass "${1}: same-named station never touched" || fail "${1}: same-named station never touched"
}
# Stale marker on a no-portal boot, station active.
reset_state; boot_units; seed_setup_ap; add_station_named_ap; echo "${STATION_UUID}" >>"${NMSTATE}/active"
printf 'ssid=CeraLive-Setup-f00d\n' >"$(state_file portal-active)"
no_portal_boot; rc=$?
[ "${rc}" -eq 0 ] && called "${AP_DEL_CALL}" && [ ! -e "$(state_file portal-active)" ] && grep -qx "${STATION_UUID}" "${NMSTATE}/active" \
                                                 && pass "stale teardown: setup AP deleted by UUID, station still active" || fail "stale teardown: setup AP deleted by UUID, station still active (rc=${rc})"
station_untouched "stale teardown"
# Bring-up, failed join + re-arm, successful join, stop, teardown verb.
reset_state; boot_units; seed_setup_ap; add_station_named_ap; : >"$(state_file force-portal)"
"${SC[@]}" bash "${PROVISION}" start >/dev/null 2>&1
called "${AP_DEL_CALL}" && called "${AP_UP_CALL}" && pass "bring-up: old setup AP replaced by UUID" || fail "bring-up: old setup AP replaced by UUID"
station_untouched "bring-up"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_USER_UP_RC=4 STUB_CON_SSID=HomeNet bash "${PROVISION}" connect ceralive-wifi >/dev/null 2>&1
station_untouched "failed join and re-arm"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_SYSTEM_STATE=running bash "${PROVISION}" stop >/dev/null 2>&1
station_untouched "stop"
"${SC[@]}" bash "${PROVISION}" start >/dev/null 2>&1
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_USER_UP_RC=0 STUB_CONNECTIVITY=full STUB_CON_SSID=HomeNet bash "${PROVISION}" connect ceralive-wifi >/dev/null 2>&1
station_untouched "successful join"
[ ! -e "$(state_file ap-uuid)" ] && ! grep -q ":${AP_UUID}:" "${NMSTATE}/profiles" \
                                                 && pass "successful join: setup AP and its record gone" || fail "successful join: setup AP and its record gone"
reset_state; seed_setup_ap; add_station_named_ap
printf 'portal-active' >"$(state_file portal-active)"
bash "${PROVISION}" teardown >/dev/null 2>&1
station_untouched "teardown verb"

# ===========================================================================
echo "== Scenario S: the recorded UUID decides, whatever the profile's settings say now =="
# Settings changed after activation, then the down fails: the AP is still ours and up.
for verb in stop service-stop; do
  up_ap_model
  printf '%s 802-11-wireless.ssid SomethingElse\n' "${AP_UUID}" >"${NMSTATE}/details.new"
  grep -v "^${AP_UUID} 802-11-wireless.ssid " "${NMSTATE}/details" >>"${NMSTATE}/details.new"; mv "${NMSTATE}/details.new" "${NMSTATE}/details"
  env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_SYSTEM_STATE=running STUB_AP_DOWN_RC=10 \
      bash "${PROVISION}" "${verb}" >"${OUTF}" 2>&1
  rc=$?
  [ "${rc}" -ne 0 ] && [ -e "$(state_file portal-active)" ] && grep -q "ERROR: setup AP still active" "${OUTF}" \
                                                 && pass "${verb}: changed settings + failed down → marker kept, non-zero" || fail "${verb}: changed settings + failed down → marker kept, non-zero (rc=${rc})"
done
# The same changed profile is still cleaned up by its recorded UUID.
up_ap_model
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_SYSTEM_STATE=running bash "${PROVISION}" stop >/dev/null 2>&1
printf '%s 802-11-wireless.ssid SomethingElse\n' "${AP_UUID}" >>"${NMSTATE}/details"
sed -i "/^${AP_UUID} 802-11-wireless.ssid CeraLive/d" "${NMSTATE}/details"
rm -f "$(state_file force-portal)"; : >"${CALL_LOG}"
no_portal_boot; rc=$?
[ "${rc}" -eq 0 ] && called "${AP_DEL_CALL}" && [ ! -e "$(state_file ap-uuid)" ] \
                                                 && pass "recorded setup AP deleted even with changed settings" || fail "recorded setup AP deleted even with changed settings (rc=${rc})"
# The recorded UUID still active but no longer listed as a profile: still the setup's.
up_ap_model
grep -v ":${AP_UUID}:" "${NMSTATE}/profiles" >"${NMSTATE}/p.new"; mv "${NMSTATE}/p.new" "${NMSTATE}/profiles"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_SYSTEM_STATE=running STUB_AP_DOWN_RC=10 bash "${PROVISION}" stop >"${OUTF}" 2>&1
rc=$?
[ "${rc}" -ne 0 ] && [ -e "$(state_file portal-active)" ] \
                                                 && pass "recorded UUID active without a listed profile → marker kept" || fail "recorded UUID active without a listed profile → marker kept (rc=${rc})"
# ===========================================================================
echo "== Scenario T: a recorded UUID is never dropped before NM shows it gone =="
NEW_UUID="aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
unlist_ap() { grep -v ":${AP_UUID}:" "${NMSTATE}/profiles" >"${NMSTATE}/p.new"; mv "${NMSTATE}/p.new" "${NMSTATE}/profiles"; }

# 1) Stale marker on a no-portal boot: the recorded AP is active but no longer saved,
#    and its down fails. The record and the marker stay; the boot reports it.
reset_state; boot_units; seed_setup_ap; echo "${AP_UUID}" >>"${NMSTATE}/active"; unlist_ap
printf 'ssid=CeraLive-Setup-f00d\n' >"$(state_file portal-active)"
no_portal_boot STUB_AP_DOWN_RC=10; rc=$?
[ "${rc}" -ne 0 ] && [ -e "$(state_file portal-active)" ] && grep -qx "${AP_UUID}" "$(state_file ap-uuid)" \
                                                 && pass "stale boot, unlisted active AP: record and marker kept, non-zero" || fail "stale boot, unlisted active AP: record and marker kept, non-zero (rc=${rc})"
# ...and once NM shows it gone, the next boot clears both.
: >"${NMSTATE}/active"
no_portal_boot; rc=$?
[ "${rc}" -eq 0 ] && [ ! -e "$(state_file portal-active)" ] && [ ! -e "$(state_file ap-uuid)" ] \
                                                 && pass "stale boot after the AP is gone: record and marker cleared" || fail "stale boot after the AP is gone: record and marker cleared (rc=${rc})"

# 2) Fresh bring-up while the previous setup AP is still active and unsaved, and the
#    new profile cannot be created: both UUIDs stay recorded and the marker stays.
reset_state; boot_units; seed_setup_ap; echo "${AP_UUID}" >>"${NMSTATE}/active"; unlist_ap
printf '%s\n' "${NEW_UUID}" >"${SANDBOX}/uuid-new"; : >"$(state_file force-portal)"
"${SC[@]}" CERALIVE_UUID_SOURCE="${SANDBOX}/uuid-new" STUB_AP_ADD_RC=2 STUB_AP_DOWN_RC=10 bash "${PROVISION}" start >"${OUTF}" 2>&1
rc=$?
[ "${rc}" -ne 0 ] && grep -qx "${AP_UUID}" "$(state_file ap-uuid)" && grep -qx "${NEW_UUID}" "$(state_file ap-uuid)" \
                                                 && pass "failed bring-up keeps the old active UUID next to the new one" || fail "failed bring-up keeps the old active UUID next to the new one (rc=${rc})"
[ -e "$(state_file portal-active)" ] && grep -q "setup marker KEPT" "${OUTF}" \
                                                 && pass "failed bring-up with the old AP still up keeps the marker" || fail "failed bring-up with the old AP still up keeps the marker"
# Successful bring-up over an old AP that is already gone: only the new UUID is recorded.
reset_state; boot_units; seed_setup_ap; : >"$(state_file force-portal)"
"${SC[@]}" CERALIVE_UUID_SOURCE="${SANDBOX}/uuid-new" bash "${PROVISION}" start >/dev/null 2>&1
[ "$(cat "$(state_file ap-uuid)")" = "${NEW_UUID}" ] && called "nmcli connection up uuid ${NEW_UUID}" \
                                                 && pass "bring-up over a gone AP records only the new UUID" || fail "bring-up over a gone AP records only the new UUID"
! ls "$(state_file ap-uuid).tmp."* >/dev/null 2>&1 && pass "record replaced without leftover temp files" || fail "record replaced without leftover temp files"

# 3) Empty, unreadable or malformed record while the setup AP is still active: the
#    marker stays.
for rec in empty garbage; do
  up_ap_model
  if [ "${rec}" = empty ]; then : >"$(state_file ap-uuid)"; else printf 'not-a-uuid\n' >"$(state_file ap-uuid)"; fi
  unlist_ap
  env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_SYSTEM_STATE=running STUB_AP_DOWN_RC=10 bash "${PROVISION}" stop >"${OUTF}" 2>&1
  rc=$?
  [ "${rc}" -ne 0 ] && [ -e "$(state_file portal-active)" ] && [ -e "$(state_file ap-uuid)" ] \
                                                 && pass "${rec} record, setup AP still up: marker and record kept, non-zero" || fail "${rec} record, setup AP still up: marker and record kept, non-zero (rc=${rc})"
done
# ...and when the active connection's mode cannot be read.
up_ap_model; : >"$(state_file ap-uuid)"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_SYSTEM_STATE=running STUB_MODE_READ_RC=1 bash "${PROVISION}" stop >/dev/null 2>&1
rc=$?
[ "${rc}" -ne 0 ] && [ -e "$(state_file portal-active)" ] \
                                                 && pass "empty record, mode of an active connection unreadable: marker kept" || fail "empty record, mode of an active connection unreadable: marker kept (rc=${rc})"
# A recorded profile that is saved but cannot be deleted stays recorded.
reset_state; boot_units; seed_setup_ap
no_portal_boot STUB_DELETE_RC=1; rc=$?
[ "${rc}" -ne 0 ] && grep -qx "${AP_UUID}" "$(state_file ap-uuid)" \
                                                 && pass "undeletable saved setup AP stays recorded" || fail "undeletable saved setup AP stays recorded (rc=${rc})"
# ...and with NM unreadable, too.
up_ap_model; : >"$(state_file ap-uuid)"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_SYSTEM_STATE=running STUB_DEV_READ_RC=8 bash "${PROVISION}" stop >/dev/null 2>&1
rc=$?
[ "${rc}" -ne 0 ] && [ -e "$(state_file portal-active)" ] \
                                                 && pass "empty record, wlan0 device state unreadable: marker kept, non-zero" || fail "empty record, wlan0 device state unreadable: marker kept, non-zero (rc=${rc})"
# An uncertain record is released only when no AP at all is active on wlan0; it is set
# aside, not deleted, and a station on wlan0 does not count as an AP.
up_ap_model; : >"$(state_file ap-uuid)"; echo "${STATION_UUID}" >>"${NMSTATE}/active"
printf '%s 802-11-wireless.mode infrastructure\n' "${STATION_UUID}" >>"${NMSTATE}/details"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_SYSTEM_STATE=running bash "${PROVISION}" stop >/dev/null 2>&1
rc=$?
[ "${rc}" -eq 0 ] && [ ! -e "$(state_file portal-active)" ] \
                                                 && pass "empty record, no AP on wlan0 (station only): marker released" || fail "empty record, no AP on wlan0 (station only): marker released (rc=${rc})"
reset_state; boot_units; : >"$(state_file ap-uuid)"; : >"$(state_file force-portal)"
"${SC[@]}" bash "${PROVISION}" start >/dev/null 2>&1
rc=$?
[ "${rc}" -eq 0 ] && [ "$(cat "$(state_file ap-uuid)")" = "${AP_UUID}" ] && [ -e "$(state_file ap-uuid).unreadable" ] \
                                                 && pass "bring-up sets an uncertain record aside once wlan0 has no AP" || fail "bring-up sets an uncertain record aside once wlan0 has no AP (rc=${rc})"
reset_state; boot_units; : >"$(state_file ap-uuid)"; : >"$(state_file force-portal)"; echo "${FOREIGN_UUID}" >>"${NMSTATE}/active"
printf '%s 802-11-wireless.mode ap\n' "${FOREIGN_UUID}" >>"${NMSTATE}/details"
"${SC[@]}" bash "${PROVISION}" start >"${OUTF}" 2>&1
rc=$?
[ "${rc}" -ne 0 ] && ! called "connection add" && [ -e "$(state_file ap-uuid)" ] && [ -e "$(state_file portal-active)" ] && [ -e "${UNITS}/ceralive.service" ] \
                                                 && pass "bring-up refuses an uncertain record while an AP is up on wlan0 (marker kept, front door back)" || fail "bring-up refuses an uncertain record while an AP is up on wlan0 (rc=${rc})"
# The UUID is recorded before the profile exists, and a missing UUID source means no AP.
reset_state; boot_units; : >"$(state_file force-portal)"
"${SC[@]}" bash "${PROVISION}" start >/dev/null 2>&1
[ "$(cat "${NMSTATE}/record-at-add" 2>/dev/null)" = "${AP_UUID}" ] && pass "UUID already recorded when the profile is created" || fail "UUID already recorded when the profile is created"
reset_state; boot_units; : >"$(state_file force-portal)"
"${SC[@]}" CERALIVE_UUID_SOURCE=/nonexistent bash "${PROVISION}" start >"${OUTF}" 2>&1
rc=$?
[ "${rc}" -ne 0 ] && ! called "connection add" && [ ! -e "$(state_file portal-active)" ] && [ -e "${UNITS}/ceralive.service" ] \
                                                 && pass "no UUID available: no AP, marker released, front door back" || fail "no UUID available: no AP, marker released, front door back (rc=${rc})"


# ===========================================================================
echo "== Scenario U: activity comes from NM's active objects and wlan0's live state =="
# An active setup AP whose profile is gone appears only when an active field is named.
reset_state; boot_units; seed_setup_ap; echo "${AP_UUID}" >>"${NMSTATE}/active"; unlist_ap
"${NMCLI}" -t -f UUID connection show --active >"${SANDBOX}/proj-uuid" 2>/dev/null
"${NMCLI}" -t -f UUID,ACTIVE-PATH connection show --active >"${SANDBOX}/proj-path" 2>/dev/null
[ ! -s "${SANDBOX}/proj-uuid" ] && grep -q "^${AP_UUID}:" "${SANDBOX}/proj-path" \
                                                 && pass "stub models NM 1.52.1: orphan only in the active-field projection" || fail "stub models NM 1.52.1: orphan only in the active-field projection"
: >"${CALL_LOG}"
printf 'ssid=CeraLive-Setup-f00d\n' >"$(state_file portal-active)"
no_portal_boot STUB_AP_DOWN_RC=10; rc=$?
[ "${rc}" -ne 0 ] && [ -e "$(state_file portal-active)" ] && grep -qx "${AP_UUID}" "$(state_file ap-uuid)" \
                                                 && pass "orphaned active setup AP: stale boot keeps marker and record" || fail "orphaned active setup AP: stale boot keeps marker and record (rc=${rc})"
grep -q "connection show --active" "${CALL_LOG}" && ! grep -qE -- "-f UUID connection show --active" "${CALL_LOG}" \
                                                 && pass "active checks always name an active field" || fail "active checks always name an active field"

# Uncertain record: only positive live evidence of "no AP on wlan0" releases.
uncertain_stop() { # extra env; empty record, setup AP left up by a failed down unless said otherwise
  up_ap_model; : >"$(state_file ap-uuid)"
  env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_SYSTEM_STATE=running "$@" bash "${PROVISION}" stop >"${OUTF}" 2>&1
}
# The probe: the active connection's mode reads blank, but wlan0 is an AP.
up_ap_model; : >"$(state_file ap-uuid)"
grep -v "^${AP_UUID} 802-11-wireless.mode " "${NMSTATE}/details" >"${NMSTATE}/d.new"; mv "${NMSTATE}/d.new" "${NMSTATE}/details"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_SYSTEM_STATE=running STUB_AP_DOWN_RC=10 STUB_IW_TYPE=AP bash "${PROVISION}" stop >/dev/null 2>&1
rc=$?
[ "${rc}" -ne 0 ] && [ -e "$(state_file portal-active)" ] \
                                                 && pass "blank profile mode but wlan0 is an AP: marker kept" || fail "blank profile mode but wlan0 is an AP: marker kept (rc=${rc})"
uncertain_stop STUB_IW_TYPE=""; rc=$?
[ "${rc}" -ne 0 ] && [ -e "$(state_file portal-active)" ] && grep -q "could not confirm the setup AP is down" "${OUTF}" \
                                                 && pass "blank kernel type: marker kept as ambiguous" || fail "blank kernel type: marker kept as ambiguous (rc=${rc})"
uncertain_stop STUB_IW_TYPE=AP; rc=$?
[ "${rc}" -ne 0 ] && grep -q "ERROR: setup AP still active" "${OUTF}" \
                                                 && pass "kernel type AP: reported as an active AP" || fail "kernel type AP: reported as an active AP (rc=${rc})"
uncertain_stop STUB_IW_TYPE="mesh point"; rc=$?
[ "${rc}" -ne 0 ] && [ -e "$(state_file portal-active)" ] && pass "unclassified kernel type: marker kept" || fail "unclassified kernel type: marker kept (rc=${rc})"
uncertain_stop STUB_IW_RC=237; rc=$?
[ "${rc}" -ne 0 ] && [ -e "$(state_file portal-active)" ] && pass "iw unreadable: marker kept" || fail "iw unreadable: marker kept (rc=${rc})"
uncertain_stop STUB_DEV_STATE="70 (ip-config)" STUB_IW_TYPE=managed; rc=$?
[ "${rc}" -ne 0 ] && [ -e "$(state_file portal-active)" ] && pass "wlan0 still activating: marker kept" || fail "wlan0 still activating: marker kept (rc=${rc})"
uncertain_stop STUB_DEV_STATE="110 (deactivating)" STUB_IW_TYPE=managed; rc=$?
[ "${rc}" -ne 0 ] && [ -e "$(state_file portal-active)" ] && pass "wlan0 deactivating: marker kept" || fail "wlan0 deactivating: marker kept (rc=${rc})"
uncertain_stop STUB_IW_TYPE=P2P-GO; rc=$?
[ "${rc}" -ne 0 ] && [ -e "$(state_file portal-active)" ] && grep -q "ERROR: setup AP still active" "${OUTF}" && pass "wlan0 a P2P group owner: marker kept" || fail "wlan0 a P2P group owner: marker kept (rc=${rc})"
# Positive evidence: settled device, station-side type, or no wlan0 at all.
uncertain_stop; rc=$?
[ "${rc}" -eq 0 ] && [ ! -e "$(state_file portal-active)" ] && pass "AP down, wlan0 disconnected and managed: marker released" || fail "AP down, wlan0 disconnected and managed: marker released (rc=${rc})"
rmdir "${SYSNET}/wlan0"
uncertain_stop STUB_IW_RC=237 STUB_DEV_READ_RC=8; rc=$?
mkdir -p "${SYSNET}/wlan0"
[ "${rc}" -eq 0 ] && [ ! -e "$(state_file portal-active)" ] && pass "no wlan0 at all: marker released" || fail "no wlan0 at all: marker released (rc=${rc})"

# Upstream's shutdown cases (12056fa, 07c1820): a blocking start during ExecStop
# waits behind the shutdown transaction; model that by refusing every blocking call.
reset_state; seed_setup_ap
printf 'portal-active' >"$(state_file portal-active)"
: >"$(state_file force-portal)"
make_stub systemctl 'echo "systemctl $*" >>"$CALL_LOG"' '[ "$1" = --no-block ] || exit 99'
bash "${PROVISION}" shutdown >/dev/null 2>&1
called "systemctl --no-block stop ceralive-portal.socket" && pass "shutdown enqueues portal stop" || fail "shutdown enqueues portal stop"
! called "systemctl start" && pass "shutdown never starts CeraUI" || fail "shutdown never starts CeraUI"
! called "systemctl stop" && pass "shutdown has no blocking stop" || fail "shutdown has no blocking stop"
called "timeout 5" && called "connection down uuid ${AP_UUID}" && no_name_ops && pass "shutdown bounds NM cleanup, by UUID" || fail "shutdown bounds NM cleanup, by UUID"
[ -e "$(state_file portal-active)" ] && pass "shutdown retains portal marker" || fail "shutdown retains portal marker"
[ -e "$(state_file force-portal)" ] && pass "shutdown retains force flag" || fail "shutdown retains force flag"

make_stub systemctl \
  'echo "systemctl $*" >>"$CALL_LOG"' \
  'if [ "$1" = is-system-running ]; then printf "%s\n" "${STUB_SYSTEM_STATE-running}"; exit "${STUB_SYSTEM_RC:-0}"; fi' \
  'exit 0'
reset_state
STUB_SYSTEM_STATE=stopping bash "${PROVISION}" service-stop >/dev/null 2>&1
! called "systemctl start" && pass "service shutdown never restarts CeraUI" || fail "service shutdown never restarts CeraUI"
called "systemctl --no-block stop" && pass "service shutdown queues portal stop" || fail "service shutdown queues portal stop"
for system_state in running degraded starting initializing maintenance offline unknown ''; do
  reset_state
  STUB_SYSTEM_STATE="${system_state}" bash "${PROVISION}" service-stop >/dev/null 2>&1
  called "systemctl start ceralive.service" && called "systemctl start ceralive-button-ingress.service" \
    && pass "unit stop restores CeraUI and ingress (state=${system_state:-empty})" || fail "unit stop restores CeraUI and ingress (state=${system_state:-empty})"
done
reset_state
STUB_SYSTEM_STATE='' STUB_SYSTEM_RC=1 bash "${PROVISION}" service-stop >/dev/null 2>&1
called "systemctl start ceralive.service" && pass "unit stop restores CeraUI when manager query fails" || fail "unit stop restores CeraUI when manager query fails"
# is-system-running also returns nonzero for a valid stopping state.
reset_state
STUB_SYSTEM_STATE=stopping STUB_SYSTEM_RC=1 bash "${PROVISION}" service-stop >/dev/null 2>&1
! called "systemctl start" && pass "nonzero stopping state never restarts CeraUI" || fail "nonzero stopping state never restarts CeraUI"
called "systemctl --no-block stop ceralive-portal.socket ceralive-portal@*.service" && pass "nonzero stopping state queues listener and instances" || fail "nonzero stopping state queues listener and instances"

# ===========================================================================
echo "== Scenario V: a network the portal saved but no join verified never strands the box =="
USER_UUID="0000aaaa-0000-4000-8000-0000000000d4"
PENDING="$(state_file pending-join)"
post_join() {
  printf 'POST / HTTP/1.1\r\nContent-Length: 28\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\nssid=HomeNet&psk=hunter2pass' \
    | bash "${PORTAL}" serve 2>/dev/null
}
# Boot with a short grace window; extra env for the run.
grace_boot() {
  env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" CERALIVE_PROVISION_GRACE=2 CERALIVE_PROVISION_POLL=1 "$@" \
      bash "${PROVISION}" start >"${OUTF}" 2>&1
}
# The setup AP up on a fresh card, the operator's POST saved the profile, and the box
# lost power before the worker ran (the systemd-run stub never runs it): the next boot
# starts with nothing active, CeraUI and the ingress running, and the marker in place.
saved_then_power_lost() {
  reset_state; boot_units
  env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_CONNECTIVITY=none CERALIVE_PROVISION_GRACE=0 \
      bash "${PROVISION}" start >/dev/null 2>&1
  post_join >/dev/null
  : >"${NMSTATE}/active"; boot_units; : >"${CALL_LOG}"
}
user_saved() { grep -q "^ceralive-wifi:${USER_UUID}:" "${NMSTATE}/profiles"; }

saved_then_power_lost
[ -e "$(state_file portal-active)" ] && user_saved && [ -e "${PENDING}" ] && grep -qx 'ssid=HomeNet' "${PENDING}" \
                                                 && pass "POST marks the join pending next to the saved profile" || fail "POST marks the join pending next to the saved profile"
grace_boot STUB_CONNECTIVITY=none; rc=$?
[ "${rc}" -eq 0 ] && called "${AP_UP_CALL}" && [ -e "${UNITS}/ceralive-portal.socket" ] \
                                                 && pass "unverified join + no uplink: setup AP and portal come back" || fail "unverified join + no uplink: setup AP and portal come back (rc=${rc})"
! user_saved && called "nmcli connection delete uuid ${USER_UUID}" \
                                                 && pass "unverified profile deleted by UUID when the grace window expires" || fail "unverified profile deleted by UUID when the grace window expires"
[ ! -e "${PENDING}" ] && grep -qx 'ssid=HomeNet' "$(state_file last-error)" 2>/dev/null && grep -qx 'reason=not_verified' "$(state_file last-error)" \
                                                 && pass "last-error says not_verified, pending-join cleared" || fail "last-error says not_verified, pending-join cleared"
ERR_OUT="$(printf 'GET / HTTP/1.1\r\n\r\n' | bash "${PORTAL}" serve 2>/dev/null)"
grep -qF 'Could not join <b>HomeNet</b>' <<<"${ERR_OUT}" && pass "portal shows the unverified network in its banner" || fail "portal shows the unverified network in its banner"

# The same interruption, but NM brings the saved network up within the grace window.
saved_then_power_lost
echo "${USER_UUID}" >>"${NMSTATE}/active"
grace_boot STUB_CONNECTIVITY=full; rc=$?
[ "${rc}" -eq 0 ] && ! called "${AP_UP_CALL}" && user_saved && [ -e "${UNITS}/ceralive.service" ] && [ ! -e "$(state_file portal-active)" ] \
                                                 && pass "pending join that comes up: no AP, profile kept, CeraUI back" || fail "pending join that comes up: no AP, profile kept, CeraUI back (rc=${rc})"
[ ! -e "${PENDING}" ] && grep -q "join verified" "${OUTF}" \
                                                 && pass "pending join verified at boot clears pending-join" || fail "pending join verified at boot clears pending-join"
# Connectivity from another uplink proves nothing about the saved network.
saved_then_power_lost
grace_boot STUB_CONNECTIVITY=full; rc=$?
[ "${rc}" -eq 0 ] && ! called "${AP_UP_CALL}" && user_saved && [ -e "${PENDING}" ] \
                                                 && pass "uplink without the saved network: no AP, join stays pending" || fail "uplink without the saved network: no AP, join stays pending (rc=${rc})"

# A setup marker from an image without pending-join, next to a saved profile: that
# image deleted the profile before every re-arm, so the pair means a cut-short handoff.
reset_state; boot_units; seed_setup_ap
printf 'ssid=CeraLive-Setup-f00d\ngateway=192.168.42.1\niface=wlan0\ncon=ceralive-ap\nuser_con=ceralive-wifi\n' >"$(state_file portal-active)"
echo "ceralive-wifi:${USER_UUID}:802-11-wireless" >>"${NMSTATE}/profiles"
echo "${USER_UUID} 802-11-wireless.ssid HomeNet" >>"${NMSTATE}/details"
grace_boot STUB_CONNECTIVITY=none; rc=$?
[ "${rc}" -eq 0 ] && called "${AP_UP_CALL}" && ! user_saved && [ ! -e "${PENDING}" ] && grep -qx 'reason=not_verified' "$(state_file last-error)" 2>/dev/null \
  && grep -qx 'ssid=HomeNet' "$(state_file last-error)" \
                                                 && pass "earlier image's marker + saved profile is treated as pending" || fail "earlier image's marker + saved profile is treated as pending (rc=${rc})"
# This image's marker says it tracks pending-join: without the file the profile is verified.
reset_state; boot_units; seed_setup_ap
printf 'ssid=CeraLive-Setup-f00d\ngateway=192.168.42.1\niface=wlan0\ncon=ceralive-ap\nuser_con=ceralive-wifi\npending_join=1\n' >"$(state_file portal-active)"
echo "ceralive-wifi:${USER_UUID}:802-11-wireless" >>"${NMSTATE}/profiles"
grace_boot STUB_CONNECTIVITY=none; rc=$?
[ "${rc}" -eq 0 ] && ! called "${AP_UP_CALL}" && user_saved && [ ! -e "$(state_file portal-active)" ] \
                                                 && pass "this image's marker without pending-join: profile counts as verified" || fail "this image's marker without pending-join: profile counts as verified (rc=${rc})"

# A verified box (profile, no pending-join, no marker) still skips setup at once.
reset_state; boot_units
echo "ceralive-wifi:${USER_UUID}:802-11-wireless" >>"${NMSTATE}/profiles"
grace_boot STUB_CONNECTIVITY=none CERALIVE_PROVISION_GRACE=600; rc=$?
[ "${rc}" -eq 0 ] && ! called "${AP_UP_CALL}" && user_saved && grep -q "found 1 stored WiFi profile" "${OUTF}" \
  && ! called "systemctl stop ceralive.service" \
                                                 && pass "verified profile suppresses setup at once (unchanged)" || fail "verified profile suppresses setup at once (unchanged) (rc=${rc})"

# The worker clears pending-join once the join is verified, and after deleting the
# profile on a failed join; a profile it could not delete stays pending.
for outcome in joined failed gone; do
  reset_state; boot_units; seed_setup_ap
  printf 'ssid=CeraLive-Setup-f00d\npending_join=1\n' >"$(state_file portal-active)"
  printf 'ssid=HomeNet\ncon=ceralive-wifi\nuuid=%s\n' "${USER_UUID}" >"${PENDING}"
  [ "${outcome}" = gone ] || echo "ceralive-wifi:${USER_UUID}:802-11-wireless" >>"${NMSTATE}/profiles"
  up_rc=4; [ "${outcome}" = joined ] && up_rc=0
  env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_USER_UP_RC="${up_rc}" STUB_CONNECTIVITY=full STUB_CON_SSID=HomeNet \
      bash "${PROVISION}" connect ceralive-wifi >/dev/null 2>&1
  case "${outcome}" in
    joined) [ ! -e "${PENDING}" ] && user_saved && pass "worker clears pending-join after a verified join" || fail "worker clears pending-join after a verified join" ;;
    failed) [ ! -e "${PENDING}" ] && ! user_saved && called "${AP_UP_CALL}" \
              && pass "worker clears pending-join after deleting a failed profile" || fail "worker clears pending-join after deleting a failed profile" ;;
    gone)   [ -e "${PENDING}" ] && pass "worker keeps pending-join when the delete fails" || fail "worker keeps pending-join when the delete fails" ;;
  esac
done

# pending-join cannot be written: the portal refuses to save the profile and says so.
reset_state
printf 'portal-active' >"$(state_file portal-active)"
mkdir -p "${PENDING}/held"                       # rename onto a non-empty directory fails
OUT="$(post_join)"
grep -qF 'Could not save' <<<"${OUT}" && ! called "connection add" && ! called "systemd-run" \
                                                 && pass "pending-join not writable: profile not saved, browser told" || fail "pending-join not writable: profile not saved, browser told"
# A failed profile write leaves no pending-join behind.
reset_state
printf 'portal-active' >"$(state_file portal-active)"
OUT="$(printf 'POST / HTTP/1.1\r\nContent-Length: 28\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\nssid=HomeNet&psk=hunter2pass' | env STUB_ADD_RC=2 bash "${PORTAL}" serve 2>/dev/null)"
grep -qF 'Could not save' <<<"${OUT}" && [ ! -e "${PENDING}" ] && ! ls "${STATE}"/pending-join.tmp.* >/dev/null 2>&1 \
                                                 && pass "failed profile write leaves no pending-join" || fail "failed profile write leaves no pending-join"

# ===========================================================================
echo "== Scenario W: each save is one attempt with its own UUID, settled only by that attempt =="
OTHER_UUID="0000bbbb-0000-4000-8000-0000000000f6"
A_UUID="0000cccc-0000-4000-8000-0000000000a7"
names() { grep -qx "uuid=$1" "${PENDING}" 2>/dev/null; }
saved() { grep -q ":$1:" "${NMSTATE}/profiles"; }
seed_user() { echo "ceralive-wifi:$1:802-11-wireless" >>"${NMSTATE}/profiles"; echo "$1 802-11-wireless.ssid HomeNet" >>"${NMSTATE}/details"; }

# The profile is created with exactly the UUID the record names, recorded first.
reset_state
printf 'portal-active' >"$(state_file portal-active)"
post_join >/dev/null
names "${USER_UUID}" && called "connection.uuid ${USER_UUID}" && saved "${USER_UUID}" \
  && called "ceralive-provision.sh connect ceralive-wifi ${USER_UUID}" \
                                                 && pass "profile saved with the UUID pending-join names; worker gets it" || fail "profile saved with the UUID pending-join names; worker gets it"

# (a) A record that cannot be flushed means no profile and no success page.
reset_state
printf 'portal-active' >"$(state_file portal-active)"
mkdir -p "${SANDBOX}/failsync"; printf '#!/usr/bin/env bash\nexit 1\n' >"${SANDBOX}/failsync/sync"; chmod +x "${SANDBOX}/failsync/sync"
OUT="$(PATH="${SANDBOX}/failsync:${PATH}" post_join)"
grep -qF 'Could not save' <<<"${OUT}" && ! grep -qiF 'Connecting' <<<"${OUT}" && ! called "connection add" \
  && ! called "systemd-run" && [ ! -e "${PENDING}" ] && ! ls "${STATE}"/pending-join.tmp.* >/dev/null 2>&1 \
                                                 && pass "flush failure: no record, no profile, no success page" || fail "flush failure: no record, no profile, no success page"

# (c) Another save holds the join lock (attempt A between its record and its profile):
# a second POST whose profile write fails neither saves nor touches A's record.
reset_state
printf 'portal-active' >"$(state_file portal-active)"
printf 'ssid=HomeNet\ncon=ceralive-wifi\nuuid=%s\n' "${A_UUID}" >"${PENDING}"
exec 9>>"$(state_file pending-join.lock)"; flock 9
OUT="$(printf 'POST / HTTP/1.1\r\nContent-Length: 28\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\nssid=HomeNet&psk=hunter2pass' | env STUB_ADD_RC=2 bash "${PORTAL}" serve 2>/dev/null)"
exec 9>&-
names "${A_UUID}" && grep -qF 'Could not save' <<<"${OUT}" \
                                                 && pass "overlapping POST with a failing add leaves the other attempt's record" || fail "overlapping POST with a failing add leaves the other attempt's record"

# (e) An earlier profile that cannot be deleted stops the save: it stays saved and the
# record that named it stays.
reset_state
printf 'portal-active' >"$(state_file portal-active)"
printf 'ssid=HomeNet\ncon=ceralive-wifi\nuuid=%s\n' "${A_UUID}" >"${PENDING}"
seed_user "${A_UUID}"
OUT="$(printf 'POST / HTTP/1.1\r\nContent-Length: 28\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\nssid=HomeNet&psk=hunter2pass' | env STUB_DELETE_RC=1 bash "${PORTAL}" serve 2>/dev/null)"
saved "${A_UUID}" && names "${A_UUID}" && ! saved "${USER_UUID}" && grep -qF 'Could not save' <<<"${OUT}" \
                                                 && pass "failed delete of the earlier profile: it stays saved and named" || fail "failed delete of the earlier profile: it stays saved and named"
# A replace that works deletes the earlier profile by UUID and names only the new one.
reset_state
printf 'portal-active' >"$(state_file portal-active)"
printf 'ssid=HomeNet\ncon=ceralive-wifi\nuuid=%s\n' "${A_UUID}" >"${PENDING}"
seed_user "${A_UUID}"
post_join >/dev/null
! saved "${A_UUID}" && saved "${USER_UUID}" && names "${USER_UUID}" && ! names "${A_UUID}" && called "connection delete uuid ${A_UUID}" \
                                                 && pass "retry replaces the earlier profile by UUID and names the new one" || fail "retry replaces the earlier profile by UUID and names the new one"

# (d) The boot acts only on the recorded UUID: another profile called ceralive-wifi is
# a saved network of its own, so it keeps setup down and nothing is deleted.
reset_state; boot_units
printf 'ssid=HomeNet\ncon=ceralive-wifi\nuuid=%s\n' "${USER_UUID}" >"${PENDING}"
seed_user "${USER_UUID}"; seed_user "${OTHER_UUID}"
grace_boot STUB_CONNECTIVITY=none; rc=$?
saved "${OTHER_UUID}" && ! called "${AP_UP_CALL}" \
                                                 && pass "a ceralive-wifi the record does not name is kept and counts" || fail "a ceralive-wifi the record does not name is kept and counts (rc=${rc})"
# Only the recorded one is deleted when the window expires; a stale UUID is ignored.
reset_state; boot_units
printf 'ssid=HomeNet\ncon=ceralive-wifi\nuuid=%s\n' "${USER_UUID}" >"${PENDING}"
seed_user "${USER_UUID}"
grace_boot STUB_CONNECTIVITY=none; rc=$?
! saved "${USER_UUID}" && called "${AP_UP_CALL}" && [ ! -e "${PENDING}" ] \
                                                 && pass "expired window deletes the recorded profile and retires its record" || fail "expired window deletes the recorded profile and retires its record (rc=${rc})"
# Verification needs the recorded profile itself to be activated.
reset_state; boot_units
printf 'ssid=HomeNet\ncon=ceralive-wifi\nuuid=%s\n' "${USER_UUID}" >"${PENDING}"
seed_user "${USER_UUID}"; echo "${OTHER_UUID}" >>"${NMSTATE}/active"
grace_boot STUB_CONNECTIVITY=full
names "${USER_UUID}"                             && pass "another active connection does not verify the recorded attempt" || fail "another active connection does not verify the recorded attempt"
# An earlier image's handoff: the record names the UUIDs seen at detection.
reset_state; boot_units; seed_setup_ap
printf 'ssid=CeraLive-Setup-f00d\ncon=ceralive-ap\n' >"$(state_file portal-active)"
seed_user "${USER_UUID}"
grace_boot STUB_CONNECTIVITY=full
names "${USER_UUID}"                             && pass "earlier image's handoff records the profile UUID it found" || fail "earlier image's handoff records the profile UUID it found"

# (c) The worker settles only its own attempt: a record naming another attempt stays.
for up_rc in 0 4; do
  reset_state; boot_units; seed_setup_ap
  printf 'ssid=CeraLive-Setup-f00d\npending_join=1\n' >"$(state_file portal-active)"
  printf 'ssid=HomeNet\ncon=ceralive-wifi\nuuid=%s\n' "${OTHER_UUID}" >"${PENDING}"
  seed_user "${USER_UUID}"
  env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_USER_UP_RC="${up_rc}" STUB_CONNECTIVITY=full \
      bash "${PROVISION}" connect ceralive-wifi "${USER_UUID}" >/dev/null 2>&1
  names "${OTHER_UUID}"                          && pass "worker (up rc=${up_rc}) leaves another attempt's record" || fail "worker (up rc=${up_rc}) leaves another attempt's record"
done

# Two saves in a row (A, then B) both succeed; A's worker wakes after B replaced it. It
# must leave the portal, the AP, B's profile and record and last-error alone, and the
# two dispatches must not share a unit name.
reset_state; boot_units; seed_setup_ap
echo "${AP_UUID}" >>"${NMSTATE}/active"; : >"${UNITS}/ceralive-portal.socket"
printf 'ssid=CeraLive-Setup-f00d\npending_join=1\n' >"$(state_file portal-active)"
printf '%s\n' "${A_UUID}" >"${SANDBOX}/join-uuid-a"
CERALIVE_JOIN_UUID_SOURCE="${SANDBOX}/join-uuid-a" post_join >/dev/null
post_join >/dev/null
UNITS_USED="$(grep -o -- '--unit=[^ ]*' "${CALL_LOG}" | sort -u | wc -l)"
[ "${UNITS_USED}" = 2 ] && called "--unit=ceralive-provision-connect-${A_UUID}" && called "--unit=ceralive-provision-connect-${USER_UUID}" \
                                                 && pass "each save dispatches its worker under its own unit name" || fail "each save dispatches its worker under its own unit name"
: >"${CALL_LOG}"
env SYSTEMCTL="${BIN}/systemctl-stateful" UNITS="${UNITS}" STUB_USER_UP_RC=0 STUB_CONNECTIVITY=full \
    bash "${PROVISION}" connect ceralive-wifi "${A_UUID}" >/dev/null 2>&1
! called "systemctl stop ceralive-portal.socket" && ! called "connection down" && ! called "connection up" \
  && [ -e "${UNITS}/ceralive-portal.socket" ] && grep -qx "${AP_UUID}" "${NMSTATE}/active" \
                                                 && pass "superseded worker leaves the portal and the AP alone" || fail "superseded worker leaves the portal and the AP alone"
! called "connection delete" && [ ! -e "$(state_file last-error)" ] && names "${USER_UUID}" && saved "${USER_UUID}" \
                                                 && pass "superseded worker deletes nothing, writes no error, B intact" || fail "superseded worker deletes nothing, writes no error, B intact"

echo
if [ "${FAILED}" -eq 0 ]; then
  echo "RESULT: ALL PASS — captive portal + handoff + 4-condition teardown verified offline"
  exit 0
fi
echo "RESULT: FAILURES above"
exit 1

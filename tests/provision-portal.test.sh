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
mkdir -p "${BIN}" "${STATE}"
printf 'HomeNet\nCafe Wifi\nNeighbour\n' >"${SCAN_SRC}"
printf 'deadbeefcafef00d\n' >"${MACHINE_ID}"

make_stub() { local p="${BIN}/$1"; shift; printf '%s\n' '#!/usr/bin/env bash' "$@" >"${p}"; chmod +x "${p}"; }

# nmcli: records every call; returns programmed data/exit codes. The AP profile ALWAYS
# comes up (so a re-arm during the failure path succeeds); only the USER connection's
# `connection up` exit code is programmable (STUB_USER_UP_RC).
make_stub nmcli \
  'echo "nmcli $*" >>"$CALL_LOG"' \
  'args="$*"' \
  'case "$args" in' \
  '  *"dev wifi list"*) [ -n "${STUB_SCAN_FILE:-}" ] && cat "$STUB_SCAN_FILE"; exit 0 ;;' \
  '  *"-f CONNECTIVITY general status"*) printf "%s\n" "${STUB_CONNECTIVITY:-full}"; exit 0 ;;' \
  '  *"802-11-wireless.ssid connection show"*) printf "%s\n" "${STUB_CON_SSID:-HomeNet}"; exit 0 ;;' \
  '  *"-f NAME,TYPE connection show"*) [ -n "${STUB_PROFILES_FILE:-}" ] && cat "$STUB_PROFILES_FILE"; exit 0 ;;' \
  '  *"connection up"*) case "$args" in *ceralive-ap*) exit "${STUB_AP_UP_RC:-0}" ;; *) exit "${STUB_USER_UP_RC:-0}" ;; esac ;;' \
  '  *"connection add"*) if [ "${STUB_ADD_RC:-0}" -ne 0 ]; then echo "Error: failed to modify 802-11-wireless.ssid: invalid" >&2; exit "$STUB_ADD_RC"; fi' \
  '                      echo "Connection '"'"'ceralive-wifi'"'"' (00000000-0000-0000-0000-000000000000) successfully added."; exit 0 ;;' \
  'esac' \
  'exit 0'

make_stub ip \
  'echo "ip $*" >>"$CALL_LOG"' \
  '[ -n "${STUB_DEFAULT_ROUTE:-}" ] && echo "default via 10.0.0.1"; exit 0'

make_stub systemctl 'echo "systemctl $*" >>"$CALL_LOG"; exit 0'

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
export NMCLI="${BIN}/nmcli" IP_BIN="${BIN}/ip" SYSTEMCTL="${BIN}/systemctl"
export SYSTEMD_RUN="${BIN}/systemd-run" TIMEOUT_BIN="${BIN}/timeout"
export CERALIVE_BUSCTL="${BIN}/busctl" CERALIVE_TIMEOUT="${BIN}/timeout"
export CERALIVE_MACHINE_ID_FILE="${MACHINE_ID}"
export CERALIVE_PROVISION_STATE_DIR="${STATE}"
export CERALIVE_DNSMASQ_SHARED_DIR="${DNSDIR}"
export CERALIVE_PROVISION_BIN="${PROVISION}"
export CERALIVE_HOSTNAME_FILE="${HOSTNAME_FILE}"
export CERALIVE_HOSTNAME_INDEX_FILE="${HOST_INDEX_FILE}"
export CERALIVE_HOSTNAME_BIN="${BIN}/hostname"
export CERALIVE_CONNECT_FLUSH_DELAY=0
export CALL_LOG STUB_SCAN_FILE="${SCAN_SRC}"

reset_state() { rm -rf "${STATE}" "${DNSDIR}"; mkdir -p "${STATE}"; : >"${CALL_LOG}"; }
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
called "nmcli connection up ceralive-ap"          && pass "AP profile activated"         || fail "AP profile activated"
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
! grep -qF 'selected deterministic address' <<<"${POST_OUT}" && pass "committed collision name does not fall back to deterministic guidance" || fail "committed collision name does not fall back to deterministic guidance"
export STUB_RUNTIME_HOSTNAME=ceralive2
export STUB_AVAHI_HOSTNAME=ceralive-2
STALE_AVAHI_OUT="$(printf 'POST / HTTP/1.1\r\nContent-Length: 28\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\nssid=HomeNet&psk=hunter2pass' | bash "${PORTAL}" serve 2>/dev/null)"
grep -qF 'selected deterministic address' <<<"${STALE_AVAHI_OUT}" && pass "stale Avahi publication gets deterministic fallback guidance" || fail "stale Avahi publication gets deterministic fallback guidance"
export STUB_AVAHI_HOSTNAME=ceralive2
export STUB_AVAHI_STATE=1
REGISTERING_AVAHI_OUT="$(printf 'POST / HTTP/1.1\r\nContent-Length: 28\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\nssid=HomeNet&psk=hunter2pass' | bash "${PORTAL}" serve 2>/dev/null)"
grep -qF 'selected deterministic address' <<<"${REGISTERING_AVAHI_OUT}" && pass "registering Avahi publication gets deterministic fallback guidance" || fail "registering Avahi publication gets deterministic fallback guidance"
export STUB_AVAHI_STATE=2
export STUB_RUNTIME_HOSTNAME=factory-seed
export STUB_AVAHI_HOSTNAME=ceralive2
UNCOMMITTED_OUT="$(printf 'POST / HTTP/1.1\r\nContent-Length: 28\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\nssid=HomeNet&psk=hunter2pass' | bash "${PORTAL}" serve 2>/dev/null)"
grep -qF 'selected deterministic address' <<<"${UNCOMMITTED_OUT}" && pass "in-flight identity gets deterministic fallback guidance" || fail "in-flight identity gets deterministic fallback guidance"
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
reset_state
printf 'portal-active' >"$(state_file portal-active)"
: >"$(state_file force-portal)"
env STUB_USER_UP_RC=0 STUB_CONNECTIVITY=full STUB_CON_SSID=HomeNet \
    bash "${PROVISION}" connect ceralive-wifi >/dev/null 2>&1
rc=$?
[ "${rc}" -eq 0 ]                                && pass "connect worker exits 0 on success" || fail "connect worker exits 0 on success"
called "connection up ceralive-wifi"             && pass "(b) joined target network"     || fail "(b) joined target network"
called "nmcli -t -f CONNECTIVITY general status" && pass "(b) join verified by connectivity" || fail "(b) join verified by connectivity"
called "nmcli connection delete ceralive-ap"     && pass "(a) AP profile deleted"        || fail "(a) AP profile deleted"
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
called "nmcli connection up ceralive-ap"         && pass "AP re-armed for retry"         || fail "AP re-armed for retry"
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
called "nmcli connection up ceralive-ap"         && pass "AP re-armed after timeout"     || fail "AP re-armed after timeout"
called "systemctl start ceralive-portal.socket"  && pass "portal restarted after timeout" || fail "portal restarted after timeout"

# ===========================================================================
echo "== Scenario H: out-of-band teardown verb releases everything =="
reset_state
printf 'portal-active' >"$(state_file portal-active)"
: >"$(state_file teardown-requested)"
bash "${PROVISION}" teardown >/dev/null 2>&1
called "nmcli connection delete ceralive-ap"     && pass "(a) AP profile deleted"        || fail "(a) AP profile deleted"
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
[ "$1" = --no-block ] && shift
verb="$1"; shift; unit="${1:-}"
ap_up() {
  awk '/^nmcli connection up ceralive-ap/{u=1} /^nmcli connection down ceralive-ap/{u=0} END{exit !u}' "$CALL_LOG"
}
case "$verb" in
  is-system-running) printf '%s\n' "${STUB_SYSTEM_STATE-running}"; [ "${STUB_SYSTEM_STATE-running}" = running ]; exit ;;
  cat)   [ -n "${STUB_NO_INGRESS:-}" ] && [ "$unit" = ceralive-button-ingress.service ] && exit 1; exit 0 ;;
  stop)  for u in "$@"; do rm -f "$UNITS/$u"; done ;;
  start)
    case " ${STUB_START_FAIL:-} " in *" $unit "*) echo "Job for $unit failed." >&2; exit 1 ;; esac
    if [ -n "${STUB_NO_INGRESS:-}" ] && [ "$unit" = ceralive-button-ingress.service ]; then
      echo "Unit $unit not found." >&2; exit 5
    fi
    if [ "$unit" = ceralive-portal.socket ] && [ -n "${STUB_PORTAL_FAIL:-}" ]; then
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
  awk '/^nmcli connection up ceralive-ap/{u=1} /^nmcli connection down ceralive-ap/{u=0} END{exit !u}' "${CALL_LOG}" || return 0
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
[ -z "$(ap80_owners)" ] && ! awk '/^nmcli connection up ceralive-ap/{u=1} /^nmcli connection down ceralive-ap/{u=0} END{exit !u}' "${CALL_LOG}" \
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

# Upstream's shutdown cases (12056fa, 07c1820): a blocking start during ExecStop
# waits behind the shutdown transaction; model that by refusing every blocking call.
reset_state
printf 'portal-active' >"$(state_file portal-active)"
: >"$(state_file force-portal)"
make_stub systemctl 'echo "systemctl $*" >>"$CALL_LOG"' '[ "$1" = --no-block ] || exit 99'
bash "${PROVISION}" shutdown >/dev/null 2>&1
called "systemctl --no-block stop ceralive-portal.socket" && pass "shutdown enqueues portal stop" || fail "shutdown enqueues portal stop"
! called "systemctl start" && pass "shutdown never starts CeraUI" || fail "shutdown never starts CeraUI"
! called "systemctl stop" && pass "shutdown has no blocking stop" || fail "shutdown has no blocking stop"
called "timeout 5" && pass "shutdown bounds NM cleanup" || fail "shutdown bounds NM cleanup"
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

echo
if [ "${FAILED}" -eq 0 ]; then
  echo "RESULT: ALL PASS — captive portal + handoff + 4-condition teardown verified offline"
  exit 0
fi
echo "RESULT: FAILURES above"
exit 1

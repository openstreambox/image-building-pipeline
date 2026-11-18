#!/usr/bin/env bash
# lib/release-preset.sh — release trust pin and update-channel preset for a
# production build.
#
# Two optional inputs, both checked on the build host before mkosi runs:
#
#   CERALIVE_EXPECT_RAUC_ROOT_SHA256
#       SHA-256 of the DER root certificate this release must trust. The device
#       keyring (RAUC_KEYRING_FILE) must then hold exactly that one certificate
#       and nothing else: no second root, no private key.
#
#   CERALIVE_UPDATE_PRESET_DIR
#       A directory holding update-settings.json and update-image-channel.json.
#       Both are validated against the updater's strict schemas, then forwarded
#       base64 (like RAUC_ROOT_CA_B64) and written to /opt/ceralive in the
#       runtime layer. ceralive-migrate-data seeds them onto /data as one pair,
#       only when /data has neither file, and never overwrites them: a box that
#       already saved update settings keeps all of its own choices.
#       The checks accept a strict ASCII subset of what CeraUI's reader accepts
#       (zod + WHATWG URL), so a preset that passes here always loads on a box.
#       Set CERALIVE_UPDATE_PRESET_CERAUI_DIR to a CeraUI checkout (with bun and
#       its dependencies installed) to also run CeraUI's own loader on the preset.
#
# The orchestrator is the supported path: a standalone `mkosi build` with the
# payload variables set by hand skips every host-side check here.
#
# A preset points boxes at an update channel, so it is accepted only in
# production mode and only together with the root pin: an image can never
# carry a channel preset while trusting a development or unexpected root.
#
# Usage (sourced by orchestrate.sh after rauc_pki_resolve):
#   release_preset_resolve   # exports CERALIVE_UPDATE_PRESET_{SETTINGS,CHANNEL}_B64
# Standalone check of a preset directory:
#   lib/release-preset.sh validate <dir>

set -euo pipefail

release_preset_die() { printf 'release preset: %s\n' "$*" >&2; return 1; }

# Validate the two preset files. The schemas mirror CeraUI's
# packages/rpc update-settings.schema.ts and update-settings.ts (strict objects,
# HTTPS base without credentials, query, fragment or trailing slash).
release_preset_validate() {
  local dir="$1"
  [[ -d "${dir}" ]] || { release_preset_die "not a directory: ${dir}"; return 1; }
  python3 -I - "${dir}" <<'PY'
import json, os, re, sys
from urllib.parse import urlsplit

d = sys.argv[1]
expected = {"update-settings.json", "update-image-channel.json"}
present = set(os.listdir(d))
if present != expected:
    sys.exit(f"release preset: {d} must hold exactly {sorted(expected)}, found {sorted(present)}")

def load(name):
    path = os.path.join(d, name)
    if os.path.islink(path) or not os.path.isfile(path):
        sys.exit(f"release preset: {name} must be a regular file")
    raw = open(path, "rb").read()
    if len(raw) > 4096:
        sys.exit(f"release preset: {name} is larger than 4 KiB")
    if not raw.startswith(b"{") or any(b > 0x7e or (b < 0x20 and b not in (0x0a,)) for b in raw):
        sys.exit(f"release preset: {name} must be printable ASCII JSON starting with '{{'")
    def no_dupes(pairs):
        keys = [k for k, _ in pairs]
        if len(keys) != len(set(keys)):
            sys.exit(f"release preset: duplicate key in {name}")
        return dict(pairs)
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=no_dupes)
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        sys.exit(f"release preset: {name} is not JSON: {e}")
    if not isinstance(value, dict):
        sys.exit(f"release preset: {name} must be an object")
    return value

# A strict ASCII subset of what CeraUI accepts (zod z.url() + WHATWG URL + the
# update-channel refine): lower-case https, a DNS name whose last label starts
# with a letter (so never an IPv4 literal) and no xn-- labels, no port,
# userinfo, query, fragment, percent-escapes or dot segments, no trailing slash.
LABEL = r"(?!xn--)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
URL_RE = re.compile(
    r"https://(?:" + LABEL + r"\.)+(?!xn--)[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?"
    r"(?:/[A-Za-z0-9_~-][A-Za-z0-9._~-]*)*", re.ASCII)

def channel_url(value, where):
    if not isinstance(value, str) or len(value) > 2048 or not URL_RE.fullmatch(value):
        sys.exit(f"release preset: {where} must be a plain https://host[/path] base: lower-case DNS name, "
                 "no port, credentials, query, fragment, escapes, dot segments or trailing slash")

def boolean(obj, key, where):
    if key in obj and not isinstance(obj[key], bool):
        sys.exit(f"release preset: {where}.{key} must be true or false")

side = load("update-image-channel.json")
allowed = {"schema", "channelUrl", "channel", "allowSystemDownloadsOverCellular"}
if set(side) - allowed or side.get("schema") != 1 or isinstance(side.get("schema"), bool):
    sys.exit("release preset: update-image-channel.json needs schema 1 and only known keys")
if side.get("channel") not in ("stable", "beta"):
    sys.exit("release preset: update-image-channel.json channel must be stable or beta")
if "channelUrl" not in side:
    sys.exit("release preset: update-image-channel.json must set channelUrl (otherwise boxes follow the default host)")
channel_url(side["channelUrl"], "update-image-channel.json channelUrl")
boolean(side, "allowSystemDownloadsOverCellular", "update-image-channel.json")

settings = load("update-settings.json")
allowed = {"channelUrl", "packagesAuto", "systemAuto", "schedule", "channel",
           "allowPackagesOverCellular", "allowSystemOverCellular"}
if set(settings) - allowed:
    sys.exit(f"release preset: update-settings.json has unknown keys {sorted(set(settings) - allowed)}")
if "channelUrl" in settings:
    # CeraUI never writes it there (the six-key file stays readable by older and
    # official readers); the sidecar carries the URL.
    sys.exit("release preset: put channelUrl only in update-image-channel.json, not in update-settings.json")
for key in ("packagesAuto", "systemAuto", "allowPackagesOverCellular", "allowSystemOverCellular"):
    boolean(settings, key, "update-settings.json")
if "channel" in settings and settings["channel"] not in ("stable", "beta"):
    sys.exit("release preset: update-settings.json channel must be stable or beta")
if "schedule" in settings:
    s = settings["schedule"]
    tod = re.compile(r"(?:[01][0-9]|2[0-3]):[0-5][0-9]", re.ASCII)
    if (not isinstance(s, dict) or set(s) - {"mode", "start", "end"}
            or s.get("mode", "any-idle") not in ("any-idle", "window")
            or any(k in s and not (isinstance(s[k], str) and tod.fullmatch(s[k])) for k in ("start", "end"))):
        sys.exit("release preset: update-settings.json schedule is invalid")
# The sidecar wins on the device; disagreeing copies only confuse a reader.
if "allowSystemOverCellular" in settings and \
        settings["allowSystemOverCellular"] != side.get("allowSystemDownloadsOverCellular", False):
    sys.exit("release preset: update-settings.json allowSystemOverCellular disagrees with update-image-channel.json")
PY
}

# The keyring must be exactly one certificate in canonical PEM (byte-identical to
# `openssl x509 -outform PEM` of itself) and its DER SHA-256 must equal $2. OpenSSL
# and RAUC also load "TRUSTED CERTIFICATE" and "X509 CERTIFICATE" blocks, so a
# label count is not enough; byte identity rules out any second block or junk.
release_preset_check_keyring() {
  local keyring="$1" expected="$2" canonical actual
  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] \
    || { release_preset_die "CERALIVE_EXPECT_RAUC_ROOT_SHA256 must be 64 lowercase hex"; return 1; }
  [[ -s "${keyring}" ]] || { release_preset_die "device keyring missing: ${keyring}"; return 1; }
  if grep -q 'PRIVATE KEY' "${keyring}"; then
    release_preset_die "device keyring contains a private key: ${keyring}"; return 1
  fi
  canonical="$(openssl x509 -in "${keyring}" -outform PEM 2>/dev/null)" \
    || { release_preset_die "device keyring is not a PEM certificate: ${keyring}"; return 1; }
  if [[ "$(cat "${keyring}"; printf x)" != "${canonical}"$'\n'x ]]; then
    release_preset_die "release keyring must be exactly one canonical PEM certificate and nothing else: ${keyring}"
    return 1
  fi
  actual="$(openssl x509 -in "${keyring}" -outform DER | sha256sum | cut -d' ' -f1)"
  [[ "${actual}" == "${expected}" ]] \
    || { release_preset_die "device keyring root ${actual} is not the expected release root ${expected}"; return 1; }
}

# Re-check the exact bytes that will be baked (orchestrate.sh calls this on
# RAUC_ROOT_CA_B64 right after encoding it), so the pin covers the payload and
# not only the file as it was when the build started.
release_preset_check_keyring_b64() {
  local b64="$1" expected="${CERALIVE_EXPECT_RAUC_ROOT_SHA256:-}" tmp rc=0
  [[ -n "${expected}" ]] || return 0
  tmp="$(mktemp)"
  printf '%s' "${b64}" | base64 -d >"${tmp}" || rc=1
  (( rc == 0 )) && { release_preset_check_keyring "${tmp}" "${expected}" || rc=1; }
  rm -f "${tmp}"
  return "${rc}"
}

# Optional reference check with CeraUI's own loader (bun + a CeraUI checkout).
release_preset_ceraui_check() {
  local dir="$1" ceraui="${CERALIVE_UPDATE_PRESET_CERAUI_DIR:-}" here
  [[ -n "${ceraui}" ]] || return 0
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [[ -f "${ceraui}/apps/backend/src/modules/system/update-settings.ts" ]] \
    || { release_preset_die "CERALIVE_UPDATE_PRESET_CERAUI_DIR is not a CeraUI checkout: ${ceraui}"; return 1; }
  (cd "${ceraui}/apps/backend" && bun run "${here}/release-preset-ceraui-check.ts" "${ceraui}" "${dir}") \
    || { release_preset_die "CeraUI's own loader refuses this preset"; return 1; }
}

release_preset_resolve() {
  local mode="${CERALIVE_BUILD_MODE:-development}" dir="${CERALIVE_UPDATE_PRESET_DIR:-}"
  local expected="${CERALIVE_EXPECT_RAUC_ROOT_SHA256:-}"
  CERALIVE_UPDATE_PRESET_SETTINGS_B64=""
  CERALIVE_UPDATE_PRESET_CHANNEL_B64=""
  if [[ -n "${dir}" || -n "${expected}" ]]; then
    [[ "${mode}" == production ]] \
      || { release_preset_die "a release root pin or update preset needs CERALIVE_BUILD_MODE=production"; return 1; }
  fi
  if [[ -n "${dir}" && -z "${expected}" ]]; then
    release_preset_die "an update preset needs CERALIVE_EXPECT_RAUC_ROOT_SHA256 (pin the root the channel is signed under)"
    return 1
  fi
  if [[ -n "${expected}" ]]; then
    release_preset_check_keyring "${RAUC_KEYRING_FILE:?RAUC_KEYRING_FILE unset}" "${expected}" || return 1
  fi
  if [[ -n "${dir}" ]]; then
    release_preset_validate "${dir}" || return 1
    release_preset_ceraui_check "${dir}" || return 1
    CERALIVE_UPDATE_PRESET_SETTINGS_B64="$(base64 -w0 <"${dir}/update-settings.json")"
    CERALIVE_UPDATE_PRESET_CHANNEL_B64="$(base64 -w0 <"${dir}/update-image-channel.json")"
  fi
  export CERALIVE_UPDATE_PRESET_SETTINGS_B64 CERALIVE_UPDATE_PRESET_CHANNEL_B64
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    validate) [[ $# -eq 2 ]] || { echo 'usage: release-preset.sh validate <dir>' >&2; exit 2; }
              release_preset_validate "$2" && release_preset_ceraui_check "$2" && echo "release preset OK: $2" ;;
    *) echo 'usage: release-preset.sh validate <dir>' >&2; exit 2 ;;
  esac
fi

#!/usr/bin/env bash
set -euo pipefail

root="${1:-}"
[[ "${root}" == /* ]] || { printf 'absolute root path required\n' >&2; exit 1; }

uid_for() {
  local account="$1" entry uid
  entry="$(getent passwd "$account")" || { printf 'missing account: %s\n' "$account" >&2; exit 1; }
  IFS=: read -r _ _ uid _ _ _ _ <<<"$entry"
  [[ "$uid" =~ ^[1-9][0-9]*$ ]] || { printf 'invalid non-root UID: %s\n' "$account" >&2; exit 1; }
  printf '%s' "$uid"
}

ota_uid="$(uid_for ceralive-ota)"
apt_uid="$(uid_for _apt)"
dest="$root/usr/lib/ceralive/update-capabilities.json"
authority="${BASH_SOURCE[0]%/*}/../first-party-origin-names.txt"
# A single-source image (runtime/image-apt-source.sh) replaces the apt.ceralive.tv
# origin pin with openstreambox-origin; its policy file names the one host.
image_source="$root/usr/lib/ceralive/image-apt-source.json"
if [[ -e "$image_source" ]]; then
  pin_file="$root/etc/apt/preferences.d/openstreambox-origin"
  host="$(sed -n 's/.*"host":"\([A-Za-z0-9.-]*\)".*/\1/p' "$image_source")"
  [[ -n "$host" ]] || { rm -f "$dest"; printf 'image apt source policy names no host\n' >&2; exit 1; }
  expected_pins() {
    awk -v host="$host" '!/^[[:space:]]*(#|$)/ && $0 != "ceralive-apt-credentials" {
      print "Package: " $0 "\nPin: origin \"" host "\"\nPin-Priority: 990"
    }' "$authority"
    printf 'Package: *\nPin: origin "%s"\nPin-Priority: 500\n' "$host"
    printf 'Package: *\nPin: release a=now\nPin-Priority: 100\n'
    printf 'Package: *\nPin: release *\nPin-Priority: -1\n'
  }
else
  pin_file="$root/etc/apt/preferences.d/ceralive-origin"
  expected_pins() {
    awk '!/^[[:space:]]*(#|$)/ {
      print "Package: " $0 "\nPin: origin apt.ceralive.tv\nPin-Priority: 990"
      print "Package: " $0 "\nPin: origin *\nPin-Priority: -1"
    }' "$authority"
  }
fi
[[ -s "$pin_file" && -s "$authority" ]] || { rm -f "$dest"; printf 'origin protection pin or independent name authority missing\n' >&2; exit 1; }
[[ "$(grep -c '^Package: ' "$pin_file")" -gt 0 ]] || { rm -f "$dest"; printf 'origin protection pin has no package stanzas\n' >&2; exit 1; }
if ! cmp -s <(awk '/^(Package|Pin|Pin-Priority): / {print}' "$pin_file") <(expected_pins); then
  rm -f "$dest"
  printf 'origin protection pin file is incomplete or differs from the independent name authority\n' >&2
  exit 1
fi
mkdir -p "${dest%/*}"
# Default: the first released CeraUI that contains the kernel lane (v2026.10.1). An explicitly
# empty value turns the feature OFF.
KERNEL_STAGE_MIN_CERAUI="${KERNEL_STAGE_MIN_CERAUI-2026.10.1}"
kernel_feature=""
kernel_pins="${CERALIVE_KERNEL_STAGE_PIN_FILE:-${BASH_SOURCE[0]%/*}/../first-party-deb-versions.txt}"
if [[ -n "${KERNEL_STAGE_MIN_CERAUI}" && -r "${kernel_pins}" &&
      -x "$root/usr/lib/ceralive/ceralive-kernel-stage" &&
      -r "$root/usr/lib/ceralive/ceralive-kernel-state-lib.sh" &&
      -r "$root/usr/lib/ceralive/ceralive-slot-mirror-lib.sh" &&
      -x "$root/usr/libexec/ceralive/ceralive-slot-sync" &&
      -x "$root/usr/lib/ceralive/ceralive-kernel-boot-staging" &&
      -x "$root/usr/lib/ceralive/verify-boot-artifacts.sh" ]]; then
  arch="$(dpkg --print-architecture)"
  pinned="$(awk -F= -v package="ceralive-device[${arch}]" '$1 == package {version=$2; count++} END {if (count == 1) print version}' "${kernel_pins}")"
  if [[ -n "${pinned}" ]] &&
    dpkg --validate-version "${pinned}" >/dev/null 2>&1 &&
    dpkg --validate-version "${KERNEL_STAGE_MIN_CERAUI}" >/dev/null 2>&1 &&
    dpkg --compare-versions "${pinned}" ge "${KERNEL_STAGE_MIN_CERAUI}"; then
    kernel_feature=',"kernel-apt-stage"'
  fi
fi
credentials_feature=',"apt-credentials"'
if [[ -e "$image_source" ]]; then
  # Kernels arrive only in images, and nothing on the image talks to the first-party archive.
  kernel_feature="" credentials_feature=""
fi
printf '{"schema":1,"features":["rauc-verity-streaming","rauc-activate-on-shutdown","slot-sync","origin-protection","apt-all-packages","reprune-hook"%s,"transport-uidrange"%s],"ota_uid":%s,"apt_uid":%s}\n' \
  "$credentials_feature" "$kernel_feature" "$ota_uid" "$apt_uid" >"$dest"
chmod 0644 "$dest"

#!/usr/bin/env bash
# Sample once, or repeat every INTERVAL seconds. Temperatures are in m°C.
# Usage: bash tools/read-rock-5b-plus-fan.sh [INTERVAL]
set -euo pipefail
shopt -s nullglob

sys_class="${FAN_SYS_CLASS:-/sys/class}"
interval="${1:-}"
zone=
for candidate in "$sys_class"/thermal/thermal_zone*; do
  if [[ "$(<"$candidate/type")" == package-thermal ]]; then
    zone="$candidate"
    break
  fi
done
[[ -n "$zone" ]] || { echo 'package-thermal zone missing' >&2; exit 1; }

cdev=
for link in "$zone"/cdev[0-9]*; do
  [[ -L "$link" ]] || continue
  case "$(<"$link/type")" in
    gpio-fan) cdev="$link"; hwmon_name=gpio_fan; break ;;
    pwm-fan) cdev="$link"; hwmon_name=pwmfan; break ;;
  esac
done
[[ -n "$cdev" ]] || { echo 'Fan is not bound to package-thermal' >&2; exit 1; }

if ! identity="$(readlink -e "$cdev/of_node")"; then
  echo 'Cooling device has no device-tree identity' >&2
  exit 1
fi
hwmon=
for candidate in "$sys_class"/hwmon/hwmon*; do
  [[ "$candidate/device/of_node" -ef "$identity" ]] || continue
  [[ "$(<"$candidate/name")" == "$hwmon_name" ]] || continue
  [[ -z "$hwmon" ]] || { echo 'Multiple hwmon devices match the cooling device' >&2; exit 1; }
  hwmon="$candidate"
done
[[ -n "$hwmon" ]] || { echo "Missing hwmon device $hwmon_name" >&2; exit 1; }

printf '%s\n' 'utc,package_mC,fan_driver,cooling_state,pwm1,pwm1_enable,tach_rpm'
while true; do
  temp="$(<"$zone/temp")"
  state="$(<"$cdev/cur_state")"
  pwm="$(<"$hwmon/pwm1")"
  mode="$(<"$hwmon/pwm1_enable")"
  tach=
  # gpio_fan exposes a nominal RPM from its table. Only pwmfan has a tach here.
  if [[ "$hwmon_name" == pwmfan && -r "$hwmon/fan1_input" ]]; then
    tach="$(<"$hwmon/fan1_input")"
  fi
  if ! [[ "$cdev/of_node" -ef "$identity" && "$hwmon/device/of_node" -ef "$identity" ]]; then
    echo 'Fan device changed during sampling' >&2
    exit 1
  fi
  printf '%s,%s,%s,%s,%s,%s,%s\n' "$(date -u +%FT%T.%3NZ)" "$temp" \
    "$hwmon_name" "$state" "$pwm" "$mode" "$tach"
  [[ -n "$interval" ]] || break
  sleep "$interval"
done

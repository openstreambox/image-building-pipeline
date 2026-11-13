#!/usr/bin/env bash
# Boot-scoped reset evidence writer and read-only JSON reader (schema 1).
set -euo pipefail
umask 077
root="${CERALIVE_EVIDENCE_ROOT:-/}"
store="${root%/}/data/log/reset-evidence"
pending=''

archives() {
  local dir
  for dir in "$store"/*_*; do
    [[ -d "$dir" && ! -L "$dir" && -f "$dir/evidence.json" ]] || continue
    printf '%s\t%s\n' "$(jq -er '.sequence' "$dir/evidence.json")" "$dir"
  done | sort -n
}

collect() {
  if [[ "$root" == / ]] && ! mountpoint -q /data; then
    echo 'reset evidence: /data is not mounted; preserving pstore' >&2
    return 1
  fi
  local boot stamp sequence final path value total=0 size count=0 dir
  local -a saved=() old=()
  boot="$(cat "${root%/}/proc/sys/kernel/random/boot_id")"
  [[ "$boot" =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ ]] || return 1
  mkdir -p "$store"
  exec 9>"$store/.lock"
  flock -x 9
  for dir in "$store"/*_"$boot"; do
    [[ -f "$dir/evidence.json" ]] && return 0
  done
  sequence="$(archives | tail -1 | cut -f1)"
  sequence=$((${sequence:-0} + 1))
  for dir in "$store"/.pending-*; do
    [[ ! -d "$dir" || -L "$dir" ]] || rm -r -- "$dir"
  done
  stamp="$(date -u +%Y%m%dT%H%M%S.%NZ)"
  pending="$(mktemp -d "$store/.pending-XXXXXXXX")"
  # Before publication the original pstore records remain the recovery source.
  trap '[[ -z "${pending:-}" || ! -d "$pending" ]] || rm -r -- "$pending"' EXIT
  mkdir "$pending/pstore"
  jq -n --arg boot "$boot" --arg stamp "$stamp" --argjson seq "$sequence" \
    '{schema:1,sequence:$seq,boot_id:$boot,collected_at:$stamp,watchdog_bootstatus:{},reset_causes:{},pstore:[]}' > "$pending/evidence.json"
  for path in "${root%/}"/sys/class/watchdog/watchdog*/bootstatus; do
    [[ -f "$path" ]] || continue
    value="$(head -c 4096 -- "$path")"
    dir="$(basename "$(dirname "$path")")"
    jq --arg key "$dir" --arg value "$value" '.watchdog_bootstatus[$key]=$value' \
      "$pending/evidence.json" > "$pending/next.json"
    mv "$pending/next.json" "$pending/evidence.json"
  done
  # No generic SoC ABI: read exposed text only, never MMIO or /dev/watchdog.
  for path in "${root%/}"/sys/kernel/reset_reason \
      "${root%/}"/sys/devices/platform/*/reset_reason \
      "${root%/}"/sys/devices/platform/*/reset_cause; do
    [[ -f "$path" ]] || continue
    value="$(head -c 4096 -- "$path")"
    jq --arg key "${path#"${root%/}"}" --arg value "$value" '.reset_causes[$key]=$value' \
      "$pending/evidence.json" > "$pending/next.json"
    mv "$pending/next.json" "$pending/evidence.json"
  done
  for path in "${root%/}"/sys/fs/pstore/*; do
    [[ -f "$path" && ! -L "$path" ]] || continue
    count=$((count + 1))
    [[ "$count" -le 128 ]] || return 1
    value="$(basename "$path")"
    head -c "$((16777216 - total + 1))" -- "$path" > "$pending/pstore/$value"
    size="$(stat -c %s "$pending/pstore/$value")"
    total=$((total + size))
    [[ "$total" -le 16777216 ]] || return 1
    jq --arg name "$value" '.pstore += [$name]' "$pending/evidence.json" > "$pending/next.json"
    mv "$pending/next.json" "$pending/evidence.json"
    sync -- "$pending/pstore/$value"
    saved+=("$path")
  done
  sync -- "$pending/evidence.json" "$pending/pstore" "$pending"
  final="$store/${stamp}_${boot}"
  mv -- "$pending" "$final"
  pending=''
  sync -- "$store" "$(dirname "$store")" "${root%/}/data"
  # Unlink acknowledges pstore only after publication is durable. Other sysfs
  # evidence is read-only and must never be written or cleared.
  for path in "${saved[@]}"; do rm -- "$path"; done
  mapfile -t old < <(archives | head -n -8 | cut -f2-)
  for dir in "${old[@]}"; do rm -r -- "$dir"; done
  sync -- "$store"
}

case "${1:-}" in
  collect) [[ $# -eq 1 ]] || exit 2; collect ;;
  latest)
    [[ $# -eq 1 ]] || exit 2
    latest="$(archives | tail -1 | cut -f2-)"
    [[ -n "$latest" ]] || exit 1
    cat -- "$latest/evidence.json"
    ;;
  *) echo 'usage: ceralive-reset-evidence collect|latest' >&2; exit 2 ;;
esac

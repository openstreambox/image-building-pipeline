#!/bin/bash
# Preserve flat ramoops records before stock systemd-pstore replaces their names.
set -euo pipefail
export LC_ALL=C
store="${1:-/var/lib/systemd/pstore}"
cd "$store"
shopt -s nullglob
records=(*ramoops*)
if ((${#records[@]})); then
  mkdir -p history
  archive="$(mktemp -d "history/$(date -u +%Y%m%dT%H%M%S.%N)-XXXXXX")"
  mv -- "${records[@]}" "$archive/"
fi
# Keep 31 previous collections plus the current one. Each collection from the
# configured 1 MiB ramoops reservation is at most 1 MiB (plus filesystem overhead).
# Also trim oversized historical inputs, e.g. after a reservation change.
archives=(history/*)
while ((${#archives[@]})) && { ((${#archives[@]} > 31)) ||
  (( $(du -sb history | cut -f1) > 31 * 1024 * 1024 )); }; do
  rm -rf -- "${archives[0]}"
  archives=("${archives[@]:1}")
done

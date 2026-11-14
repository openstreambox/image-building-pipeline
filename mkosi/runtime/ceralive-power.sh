#!/usr/bin/env bash
# Planned update, recovery and maintenance power actions share this entrypoint.
set -euo pipefail
case "${1:-}" in
  reboot|poweroff) action="$1" ;;
  *) echo 'Usage: ceralive-power reboot|poweroff' >&2; exit 64 ;;
esac
[[ $# -eq 1 ]] || { echo 'Only one power action is accepted.' >&2; exit 64; }
if systemctl --check-inhibitors=yes "$action"; then
  exit 0
else
  status=$?
fi
if (( status >= 128 )); then
  echo 'The power request could not be confirmed. Please check the box before trying again.' >&2
  exit 70
fi
if [[ "$action" == reboot ]]; then
  echo 'The box was not restarted. It may be streaming or carrying traffic, or shutdown may be unavailable. Please try again when it is idle.' >&2
else
  echo 'The box was not powered off. It may be streaming or carrying traffic, or shutdown may be unavailable. Please try again when it is idle.' >&2
fi
exit 75

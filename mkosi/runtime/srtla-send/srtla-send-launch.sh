#!/bin/bash
# srtla-send-launch: start srtla_send with the arguments CeraUI wrote.
#
# srtla-send.service runs this as root. It reads the argument vector from
# /run/ceralive/srtla-send.argv (NUL-separated, without the program name) and
# replaces itself with the sender, so the sender is the unit's main process
# and systemd sees its exit status. Because root runs what the file says, the
# file must be a regular file owned by root and writable by nobody else.
#
# Exit 2: the file is missing or refused (the unit does not retry that).
#
# Test overrides: CERALIVE_SRTLA_SEND_ARGV, CERALIVE_SRTLA_SEND_BIN and
# CERALIVE_SRTLA_SEND_OWNER_UID.
set -euo pipefail

argv_file="${CERALIVE_SRTLA_SEND_ARGV:-/run/ceralive/srtla-send.argv}"
sender="${CERALIVE_SRTLA_SEND_BIN:-/usr/bin/srtla_send}"
owner_uid="${CERALIVE_SRTLA_SEND_OWNER_UID:-0}"
max_bytes=8192

refuse() {
  printf 'srtla-send-launch: %s\n' "$*" >&2
  exit 2
}

[[ -f "$argv_file" && ! -L "$argv_file" ]] || refuse "no argument file at $argv_file"
read -r uid mode size < <(stat -c '%u %a %s' -- "$argv_file") \
  || refuse "cannot stat $argv_file"
[[ "$uid" == "$owner_uid" ]] || refuse "$argv_file is owned by uid $uid, not $owner_uid"
(( (8#$mode & 8#022) == 0 )) || refuse "$argv_file is writable by group or others (mode $mode)"
(( size > 0 && size <= max_bytes )) || refuse "$argv_file has $size bytes (1 to $max_bytes allowed)"

mapfile -d '' -t args <"$argv_file"
(( ${#args[@]} >= 4 )) || refuse "$argv_file has ${#args[@]} arguments; the sender needs at least 4"
# The sender's first positional is its local listen port.
[[ "${args[0]}" =~ ^[0-9]{1,5}$ ]] && (( 10#${args[0]} >= 1 && 10#${args[0]} <= 65535 )) \
  || refuse "first argument is not a port: ${args[0]}"

exec "$sender" "${args[@]}"

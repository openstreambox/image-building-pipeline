#!/bin/bash
# ceralive-ssh-key-seed — add the image's support public keys to root's
# persistent authorized_keys store once per device.
#
# The image carries /usr/share/ceralive/ssh/root_authorized_keys.seed (public keys
# only, validated at build time). ceralive-ssh-firstboot owns the store on /data;
# this runs after it, appends seed lines that are not already present, and sets a
# flag so a key someone later removes is not added back.
set -euo pipefail
SEED="${CERALIVE_SSH_SEED:-/usr/share/ceralive/ssh/root_authorized_keys.seed}"
if [[ -n "${CERALIVE_SSH_STATE_DIR:-}" ]]; then STATE="${CERALIVE_SSH_STATE_DIR}"
elif mountpoint -q /data 2>/dev/null; then STATE="/data/ceralive/ssh"
else STATE="/etc/ceralive"; fi
STORE="${STATE}/root_authorized_keys"
FLAG="${STATE}/root-keys-seeded"

log() { logger -t ceralive-ssh-key-seed -- "$*" 2>/dev/null || true; echo "ceralive-ssh-key-seed: $*"; }

[[ -s "${SEED}" ]] || exit 0
[[ -e "${FLAG}" ]] && exit 0
[[ -f "${STORE}" && ! -L "${STORE}" ]] || { log "root key store ${STORE} missing; ceralive-ssh-firstboot has not run"; exit 1; }
added=0
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "$line" ]] || continue
  grep -qxF -- "$line" "${STORE}" && continue
  printf '%s\n' "$line" >>"${STORE}"
  added=$((added + 1))
done <"${SEED}"
sync "${STORE}"
: >"${FLAG}"
log "seeded ${added} support key(s) into ${STORE}"

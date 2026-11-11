#!/bin/bash
# HDMI-RX profile policy: publish a capture node only with confirmed HDMI audio.
# Do not reinstate an unconditional pro-audio floor: an idle errored node can
# trigger repeated failed meter opens. Never persist these signal-driven choices.
set -eu -o pipefail
export PIPEWIRE_RUNTIME_DIR="${PIPEWIRE_RUNTIME_DIR:-/run/pipewire}"

reconcile() {
  local controls present=0 snapshot rows id current desired
  if controls=$(timeout 2 v4l2-ctl -d /dev/hdmirx --get-ctrl=audio_present,audio_sampling_rate 2>/dev/null); then
    if grep -Eq '^[[:space:]]*audio_present: 1$' <<<"$controls" &&
       grep -Eq '^[[:space:]]*audio_sampling_rate: [1-9][0-9]*$' <<<"$controls"; then
      present=1
    fi
  fi
  # A missing/unsupported control is unknown, never evidence to activate audio.
  snapshot=$(timeout 2 pw-dump 2>/dev/null) || return 0
  rows=$(jq -r --argjson present "$present" '
    .[] | select(.type == "PipeWire:Interface:Device") |
    select(.info.props["alsa.id"] == "HDMIIN" or
           .info.props["device.name"] == "alsa_card.platform-hdmi-receiver-sound" or
           .info.props["device.name"] == "alsa_card.platform-hdmirx-sound") |
    . as $d | (.info.params.EnumProfile // []) as $profiles |
    (if $present == 1 then
       ([$profiles[] | select(.name == "input:stereo-fallback" and .available != "no")][0] //
        [$profiles[] | select(.name == "pro-audio" and .available != "no")][0])
     else [$profiles[] | select(.name == "off")][0] end) as $target |
    select($target != null) |
    [$d.id, ($d.info.params.Profile[0].index // -1), $target.index] | @tsv
  ' <<<"$snapshot") || return 0
  while IFS=$'\t' read -r id current desired; do
    [[ -n "$id" && "$current" != "$desired" ]] || continue
    if timeout 2 pw-cli set-param "$id" Profile "{ index: $desired, save: false }" >/dev/null; then
      echo "HDMI audio present=$present: selected runtime profile $desired"
    else
      echo "HDMI audio profile update failed; retrying on next sample" >&2
    fi
  done <<<"$rows"
}

if [[ "${1:-}" == --once ]]; then
  reconcile
else
  while :; do
    reconcile
    sleep 1
  done
fi

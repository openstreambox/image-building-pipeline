# HDMI receiver audio profile default

The image's WirePlumber rule selects Pro Audio, including when ACP probed
HDMI-RX before a source arrived. This
publishes the capture node without requiring a manual profile command. Analog,
USB and HDMI transmitter cards keep their existing automatic policy.

Keep the current cerastream pin and its bounded meter teardown behavior. Older
engines leaked resources against errored idle nodes; an unconditional floor
must be requalified for descriptor/thread growth when changing engine versions.
The image policy requires no extra daemon, polling loop or kernel change.

A capture node does not prove source audio. With this receiver kernel, a
video-only source may stream silence. Check the source's HDMI PCM audio setting
or choose another audio input. Silence is valid media and is never an amplitude
failure. No-signal errors use DV timings; missing-card errors use the audio roster.

Validation: the PipeWire runtime-service contracts include cold-probe fallback,
source-present enumeration, card scope and installed configuration. Hardware acceptance
also measures idle cost and resources, product audio startup, missing signal,
received flash/beep sync and sustained media before release.

The preference belongs under `actions.update-props.priorities`; a bare
`priorities` member is an unknown match key and WirePlumber ignores it.

A no-signal engine start can leave cleanup pending even after a typed
`no_signal` refusal. Capture admission should reject an explicit DV-timing
no-link or no-lock verdict before starting the engine. The profile rule does
not repair that separate engine cleanup defect.

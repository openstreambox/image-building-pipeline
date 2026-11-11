# HDMI receiver audio profile policy

The image owns PipeWire card profile initialization. CeraUI checks capture
availability and cerastream owns capture; neither can capture from a PipeWire
card that publishes no source node. Upstream WirePlumber excludes Pro Audio
from its automatic best-profile chooser. When ACP probes HDMI-RX before an
audio source arrives, it can enumerate only Off and Pro Audio and remain Off.

`ceralive-hdmirx-audio.service` samples the receiver's read-only V4L2
`audio_present` and `audio_sampling_rate` controls every second. Only confirmed
audio selects an enumerated usable stereo input profile, or Pro Audio when
stereo is absent. Missing audio, zero rate, absent device or unsupported controls
select Off. Only HDMI receiver identities are managed; analog, USB and HDMI
transmitter cards retain their existing policy. Profiles are never saved.
Commands have two-second bounds; PipeWire reconnection discovers fresh object
and profile indices rather than retaining them across daemon restarts.

The static WirePlumber rule remains unchanged. An unconditional Pro Audio floor
previously exposed an errored node while idle and triggered repeated failed
meter opens. Signal-driven removal avoids leaving that node exposed indefinitely;
this is not a claim that capture teardown on abrupt signal loss is qualified.

On drivers without both controls the helper leaves receiver audio Off. Supporting
such drivers requires another reliable audio-presence interface, not video lock
or a guessed profile. Silence carried as valid PCM counts as audio; this policy
does not implement an amplitude gate.

## Operator guidance

If HDMI audio is unavailable, reconnect the HDMI cable, enable HDMI PCM audio
on the source, or select another audio source before retrying. Video lock alone
does not prove audio. See the application System Logs if it remains unavailable.

## Validation

The PipeWire section of `tests/runtime-services.bats` runs the installer and the
signal-transition policy tests in `tests/test_hdmirx_audio.py`. Run it with:

```sh
bats tests/runtime-services.bats --filter 'pipewire:'
```

Hardware acceptance still requires cold boot without a source, late audio
arrival, video-only input, unplug/replug, received flash/beep offset and drift,
and a sustained stream with frame, CPU, temperature and descriptor observations.
Host fixtures are not evidence of hardware or full-image qualification.

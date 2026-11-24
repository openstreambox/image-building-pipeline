# srtla-send.service

The SRTLA bonding sender can run as its own systemd unit, so restarting CeraUI
(`ceralive.service`) does not end a live stream. Today CeraUI spawns
`srtla_send` as a child process; `ceralive.service` uses `KillMode=mixed`, so
every CeraUI stop or restart kills the sender with it.

## What the image ships

| Path | What it is |
| --- | --- |
| `/etc/systemd/system/srtla-send.service` | The unit. Installed, never enabled: nothing starts the sender at boot. |
| `/usr/libexec/ceralive/srtla-send-launch` | Python launcher: checks the argument file and replaces itself with `/usr/bin/srtla_send`. |
| `/usr/lib/tmpfiles.d/srtla-send.conf` | Creates `/run/srtla-send` (root, 0700) at every boot, independent of CeraUI's own runtime directory. |

Source: `mkosi/runtime/srtla-send/`, installed by `setup_srtla_send_unit` in
`mkosi/customize/postinst.d/services.sh`, tested by `tests/srtla-send-unit.bats`.

## What the launcher accepts

`/run/srtla-send/argv` holds the sender's arguments without the program name,
each one followed by a NUL byte. The launcher opens it once, without following
a symlink and without blocking on a FIFO, and checks the open file: a regular
file owned by root, not writable by group or others, 1 to 8192 bytes, ending
in a NUL (so a truncated write is refused), with at least the four positionals
(`<listen_port> <srtla_host> <srtla_port> <ips_file>`), the first a port
number. `/run/srtla-send` itself must be owned by root and writable by nobody
else. The caller publishes a fresh 0600 file in that directory and renames it
over `argv`, so the launcher never sees a half-written file.

Exit statuses: 78 when the launcher refuses or cannot read the file, 2 when
the sender rejects its arguments (its own usage error). Both are permanent
configuration errors, and the unit does not retry them
(`RestartPreventExitStatus=2 78`). Any other failure of the sender is
restarted after a second. At most ten starts are allowed in 60 seconds,
counting automatic restarts, manual starts and restarts for reconfiguration;
after that the unit is in `start-limit-hit` and stays down until the caller
runs `systemctl reset-failed srtla-send.service` and starts it again. This
matches ADR-0005: systemd is the only restart authority and CeraUI only
observes and reports. A `systemctl stop` is final.

## Before CeraUI uses the unit

The unit is dormant until CeraUI follows a contract that settles these
points. They come from the review of this unit and are gates for the CeraUI
change, not for shipping the dormant unit:

1. **Readiness.** `Type=exec` reports the unit started once the launcher has
   been executed, before the argument check, the sender's exec and its socket
   bind. The caller must confirm readiness with a bounded probe of the
   sender's control socket and the same `InvocationID` before and after the
   probe, both after a start and after an automatic restart.
2. **Adoption.** Where the active configuration and the session identity are
   stored, so a restarted CeraUI adopts the running sender instead of
   starting a second one. Configuration publication and unit transitions are
   serialized; a crash between publishing and restarting has a defined
   recovery; launch state is removed after a confirmed intentional stop.
3. **Private paths.** The IPs file, bind map, stats file and control socket
   move from shared `/tmp` to `/run/srtla-send` (or another root-only
   directory), writer and reader together, with stale-file handling across
   stop, forced kill and restart. All paths in `argv` are absolute; the
   unit's working directory is not CeraUI's.
4. **Updates.** Mutual exclusion between starting the sender and the legacy
   `ceralive-update` operation (its `is-active` snapshot misses `activating`
   and `auto-restart`), and ownership of the `/run/ceralive/streaming`
   activation marker through adoption, restart, stop and sender failure.

## What already depends on the name

- cerastream's packaged unit reportedly has `After=srtla-send.service`
  (ordering only; it neither starts the sender nor waits for readiness).
- The legacy `ceralive-update` OTA guard refuses to install while
  `srtla-send.service` is active.
- `ceralive-modem-usbspeed` holds back while a process named `srtla_send`
  runs; the launcher's exec keeps that name.

Until CeraUI follows this contract the image behaves exactly as before: the
unit stays inactive and CeraUI keeps spawning the sender itself.

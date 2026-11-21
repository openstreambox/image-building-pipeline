# srtla-send.service

The SRTLA bonding sender runs as its own systemd unit, so restarting CeraUI
(`ceralive.service`) does not end a live stream. Until now CeraUI spawned
`srtla_send` as a child process; `ceralive.service` uses `KillMode=mixed`, so
every CeraUI stop or restart killed the sender with it.

## What the image ships

| Path | What it is |
| --- | --- |
| `/etc/systemd/system/srtla-send.service` | The unit. Installed, never enabled: nothing starts the sender at boot. |
| `/usr/libexec/ceralive/srtla-send-launch` | Reads the argument file and replaces itself with `/usr/bin/srtla_send`. |

Source: `mkosi/runtime/srtla-send/`, installed by `setup_srtla_send_unit` in
`mkosi/customize/postinst.d/services.sh`, tested by `tests/srtla-send-unit.bats`.

## Contract for the caller (CeraUI)

1. Write the sender's arguments, without the program name, to
   `/run/ceralive/srtla-send.argv`, each one terminated by a NUL byte. The file
   must be a regular file owned by root and not writable by group or others,
   1 to 8192 bytes, with at least the four positionals
   (`<listen_port> <srtla_host> <srtla_port> <ips_file>`); the first must be a
   port number. `/run/ceralive` is `ceralive.service`'s preserved runtime
   directory (root, 0700).
2. `systemctl start srtla-send.service` to start a stream,
   `systemctl restart srtla-send.service` after rewriting the file to
   reconfigure, `systemctl stop srtla-send.service` to end it.
3. After its own restart, CeraUI finds a running sender through
   `systemctl show -p ActiveState,MainPID,InvocationID srtla-send.service`
   and its control socket, instead of assuming it has none.

The launcher exits 2 for a missing or refused argument file; the unit does
not retry that (`RestartPreventExitStatus=2`). Any other failure of the
sender is restarted by systemd after a second, at most ten times a minute,
which matches ADR-0005: systemd is the only restart authority and CeraUI only
observes and reports. A `systemctl stop` is final.

## What already depends on the name

- cerastream's packaged unit has `After=srtla-send.service`.
- The legacy `ceralive-update` OTA guard refuses to install while
  `srtla-send.service` is active.
- `ceralive-modem-usbspeed` holds back while a process named `srtla_send`
  runs; the unit keeps that name.

## Not covered yet

CeraUI does not use the unit yet. Until it follows the contract above, the
image behaves exactly as before: the unit stays inactive and CeraUI keeps
spawning the sender itself.

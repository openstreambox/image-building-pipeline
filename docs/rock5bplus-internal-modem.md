# ROCK 5B+ internal DW5821e candidate

A DW5821e in the ROCK 5B+ B-key slot can enumerate as fastboot
`413c:81d6` when the bootloader enables it before RESET# is driven high.
The candidate image cold-starts the card after Linux releases reset. This is
host-validated source behavior; physical qualification is still required.

## Kernel sequence and radio release

The existing kernel-source builder applies the immutable fork series at
`c65b7ddc5fee14abc0f9de54a104fb5f8db087f2` (annotated fork tag
`rock5bplus-wwan-cold-start-v1`), including patch 0052, to the pinned
v7.2 kernel. No overlay or bootloader rebuild is involved. Both production and
edge-test inherit that series; the candidate package revision is 9.

0052 removes `regulator-boot-on` from `vcc3v3_wwan_pwr` and adds
`off-on-delay-us = <4000000>`. The fixed regulator requests GPIO2_B1 low,
asserting FULL_CARD_POWER_OFF# (pin 6), while 3.3 V stays applied. The
always-on regulator releases the line after the core's delay from boot;
the intended off interval is at least two seconds, after RESET# (pin 67,
GPIO2_B3) is driven high. A delayed regulator probe can shorten that interval:
only a board timing measurement qualifies it. RESET# remains high while the
card is off; qualify that combination too.

W_DISABLE1# (pin 8, GPIO3_A6) is owned by `rfkill-gpio`, whose active-high
shutdown output is `!blocked`. The final kernel config requires both rfkill
modules and MBIM. `options rfkill default_state=1` sets the module's initial
unblocked state (also the kernel default). The late
`99-zz-ceralive-internal-wwan.rules` gives only `rfkill-m2-wwan` the stable
rfkill state key `platform-ceralive-internal-wwan:wwan`, deletes that saved
state with a udev **add** RUN action, and clears its software block on **add**.
[Systemd v257](https://github.com/systemd/systemd/blob/v257/src/rfkill/rfkill.c)
waits for udev initialization, including RUN completion, before
loading saved state; a saved block therefore cannot override the release.
Its [completion check](https://github.com/systemd/systemd/blob/v257/src/shared/udev-util.c)
waits while `ID_PROCESSING=1`, which covers pending RUN commands.
`SYSTEMD_RFKILL` is only a udev database marker, not a restore opt-out.
The dedicated state key avoids depending on an unmeasured path_id and changes
neither the modem's USB ID_PATH nor its ModemManager position identity.
Old state under the original rfkill path is no longer read. Wi-Fi/Bluetooth
and external WWAN persistence keep their own keys. Later deliberate WWAN
blocks work during this boot, but are intentionally cleared on the next add
(including driver reload or reboot). The line may
remain low until rfkill-gpio probes; this does not promise a high level in
U-Boot or before driver load. Check that it ends high once Linux is running.

## Position identity and normal modem ownership

The board's fixed USB2 hub port 4 is `platform-fc800000.usb-usb-0:1.4`.
Bus numbers and `wwanN` are not identities. The existing slot-map generator
now runs in both runtime installation paths, imports `path_id` for USB-device
events, and assigns the ModemManager physical UID **internal 4G** to that
position. The schema's `internal_4g` key is translated to that UID by the
shared generator. Other boards remain fail-closed without verified maps.
This map describes the physical slot, not a modem serial number.

An external USB Dell keeps its existing physical-path/serial identity and
normal Dell plugin/MBIM handling. No vendor-wide UID, interface rename, extra
ModemManager object, FCC unlock, USB mode switch or firmware command is added.
The UI's display-name policy remains with its consumer; the image supplies the
position UID and must not infer a display name from `wwanN`. Check that the
consumer uses the position label during qualification.

## Recovery boundary

GPIO1_D2 controls the shared 3.3 V buck enable for the B-key slot and onboard
Wi-Fi. **Never cycle that buck to recover this modem.** A slot recovery cycle
must use FULL_CARD_POWER_OFF# (GPIO2_B1), keeping 3.3 V applied for at least
two seconds while asserted. The regulator owns that line; do not export it or
use a raw GPIO command against a live board.

This image has no modem-service slot power-cycle implementation and grants no
such hook. `uhubctl` remains a manual external-USB tool, not an internal-slot
recovery mechanism. `ci/check-internal-modem-power.py` guards the absence of
GPIO, regulator and hub power-control commands in every text file under
`mkosi/`, including application/platform layers and extensionless payloads.
Negative fixtures exercise each forbidden mechanism across those file types.
A future recovery owner must replace that absence guard with a
reviewed FULL_CARD_POWER_OFF# implementation and behavioral tests; adding a
shared-rail or internal-hub cycle is not an acceptable workaround.

## SIM and seating

The nano-SIM holder is on the underside. Check board revision and fully seat
the SIM before interpreting `sim-missing`; pressure on an incompletely seated
SIM can change detection. Power down before touching the holder or module.

On v1.2 boards the SIM-detect signal is inverted. The physical workaround is
tape over the holder's **detect contact**, preserving all SIM data contacts.
An alternative is disabling SIM detection in the module, which is a persistent
modem setting and requires separate owner approval. The DW5821e command has
not been established; do not guess or send a command. Neither workaround is
applied by this image.

## Host checks and hardware qualification

`tests/rock5bplus-internal-modem.bats` covers the pin, final Kconfig closure,
position rules, live-installer wiring, rfkill defaults and power-control guard.
For the real DTB test, apply the complete pinned series with the builder's
`git am --keep-non-patch` mechanism to a fresh checkout of the manifest's kernel
commit, then set `CERALIVE_WWAN_KERNEL_TREE` and
`CERALIVE_WWAN_PATCHES_TREE` when running Bats. The test reapplies every original patch in a disposable index and checks its tree,
base and series length, compiles the DTB and reads the regulator,
reset-hog and rfkill properties back. No full image build is necessary.

Before enabling this candidate for use:

- Five cold boots after at least ten seconds fully unpowered: all enumerate
  `413c:81d7`, none `81d6`, bind `cdc_mbim`, and create exactly one
  ModemManager object for the internal card.
- SIM visible, registration succeeds, and the normal modem owner manages the
  link alongside an external USB Dell, with distinct position identities.
- On **each** of the five cold boots, enable
  `trace_event=gpio:gpio_direction,gpio:gpio_value,regulator:regulator_enable,regulator:regulator_enable_delay,regulator:regulator_enable_complete tp_printk`
  on the kernel command line, or collect `/sys/kernel/tracing/trace` with those
  tracepoints enabled from boot. Confirm GPIO2_B1's global number with
  `/sys/kernel/debug/gpio` (expected 73). Record `t_off`, the first direction/value
  event driving that line low, and `t_on`, `regulator_enable_complete` for
  `vcc3v3_wwan_pwr`. Require **t_on − t_off ≥ 2 s and probe (t_off) ≤ 1 s**
  on every boot. Require the first `usb 1-1.4: new high-speed USB device` in
  `dmesg` only after `t_on`, and no regulator entry in
  `/sys/kernel/debug/devices_deferred`. Save timestamps, interval and USB time
  beside any scope trace. A missing event or failed bound is not a pass.
- Block WWAN with `rfkill block wwan`, allow systemd-rfkill to persist it
  (wait for the service to exit), then cold boot. Verify this device's software
  block is zero and W_DISABLE1# ends high; Wi-Fi/Bluetooth saved-state restore
  still works. A later deliberate block must remain effective during that boot.
- Read `udevadm info -q property -p /sys/bus/usb/devices/1-1.4` for the internal
  Dell's physical USB device: require
  `ID_PATH=platform-fc800000.usb-usb-0:1.4` and
  `ID_MM_PHYSDEV_UID=internal 4G`. `mmcli -m N` must show Device `internal 4G`
  for it and a different Device for the external USB Dell.
- Passive meter check, fine tip and grounded reference, without bridging pins:
  at **both vendor and 7.2 U-Boot prompts**, record 3V3_4G, RESET# pin 67,
  FULL_CARD_POWER_OFF# pin 6 and W_DISABLE1# pin 8. The diagnosis predicts
  slot supply about 0 V at the vendor prompt and about 3.3 V at the 7.2 prompt.
  RESET# below 0.6 V at 7.2 supports the reset-ordering diagnosis; about 1.8 V
  refutes it. In that latter branch, expect W_DISABLE1# about 0 V at the 7.2
  prompt and investigate radio release separately. Record both lines together.
  Under Linux expect RESET# about 1.8 V and pins 6 and 8 high. With a scope,
  confirm pin 6 stays low for at least two seconds after kernel probe while
  3V3_4G remains about 3.3 V, before being released.
- Confirm onboard Wi-Fi stays powered and usable, SIM seating/detect workaround,
  and actual board revision. Record voltage readings and boot results; a host
  test or successful build cannot substitute for these measurements.

The kernel patch semantics are unchanged: the four-second delay is still
anchored to boottime, so the trace gate is mandatory. A small follow-up could
initialize the regulator's `last_off` when the fixed-regulator driver requests
its enable GPIO low, so enable waits from the actual switch-off. That needs a
reviewed regulator-core/driver change, including deferred-probe tests; simply
raising the constant does not remove the dependency on probe time. No such
kernel change is included in this candidate.

English and Spanish (es-419) external user guidance is a release follow-up;
this engineering candidate is not a released or hardware-qualified image.

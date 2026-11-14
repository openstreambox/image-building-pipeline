# ROCK 5B+ internal DW5821e candidate

A DW5821e in the ROCK 5B+ B-key slot can enumerate as fastboot
`413c:81d6` when the bootloader enables it before RESET# is driven high.
The candidate image cold-starts the card after Linux releases reset. This is
host-validated source behavior; physical qualification is still required.

## Kernel sequence and radio release

The existing kernel-source builder applies the immutable fork series at
`c65b7ddc5fee14abc0f9de54a104fb5f8db087f2`, including patch 0052, to the pinned
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
unblocked state. The late `99-zz-ceralive-internal-wwan.rules` rule opts only
`rfkill-m2-wwan` out of systemd's saved rfkill restore and clears its software
block on **add**. It runs after `99-systemd.rules`; Wi-Fi/Bluetooth restore
and subsequent deliberate WWAN block requests are unchanged. The line may
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
runtime GPIO, regulator and hub power-control commands, with a negative
fixture. A future recovery owner must replace that absence guard with a
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
- Passive meter check, fine tip and grounded reference, without bridging pins:
  at the 7.2 U-Boot prompt record 3V3_4G, RESET#, FULL_CARD_POWER_OFF# and
  W_DISABLE1#. RESET# below 0.6 V supports the ordering diagnosis; about 1.8 V
  refutes it. Under Linux expect RESET# about 1.8 V and pins 6 and 8 high.
  With a scope, confirm pin 6 stays low for at least two seconds after kernel
  probe while 3V3_4G remains about 3.3 V, before being released.
- Confirm onboard Wi-Fi stays powered and usable, SIM seating/detect workaround,
  and actual board revision. Record voltage readings and boot results; a host
  test or successful build cannot substitute for these measurements.

English and Spanish (es-419) external user guidance is a release follow-up;
this engineering candidate is not a released or hardware-qualified image.

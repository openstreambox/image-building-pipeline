# ROCK 5B+ internal DW5821e

A Dell DW5821e in the ROCK 5B+ B-key slot enumerates as its bootloader's fastboot
mode, `413c:81d6`, and stays there when the slot gets power while the card's RESET#
is still low. U-Boot 2026.04 does exactly that: it enables the slot's 3.3 V from
the board device tree at start, seconds before Linux drives RESET# high. The same
card in the same slot starts normally as a modem (`413c:81d7`) when power arrives
after RESET# is released. This image sets that order and keeps a logged safety net.

## What was measured

On a ROCK 5B+ with a DW5821e in the slot:

- **Cause.** Holding the slot unpowered in the boot script until Linux restores
  it: 3 of 3 cold and 2 of 2 warm boots came up `81d7`, no fastboot stage, modem
  on USB 10.4 s after kernel start, registered 32–35 s after kernel start. Without
  the hold, every boot came up `81d6`. W_DISABLE1# was low during the card's whole
  start in the passing boots, so it is not involved.
- **Escape.** A card waiting in `81d6` answers the fastboot protocol (Qualcomm LK,
  `getvar` works). One fastboot `continue` restarts it as `81d7` about 8.5 s later:
  7 of 7 runs (5 cold boots) with one clean ModemManager object each. The single
  `reboot` run produced two ModemManager objects for the card.
- **Do not touch the port.** After the host de-configured the `81d6` device once
  (`authorized` 0 then 1), its fastboot endpoint stopped answering; a USB reset did
  not revive it, only a board reboot did.
- **0052 refuted.** The earlier candidate kernel patch 0052 asserted
  FULL_CARD_POWER_OFF# (pin 6) with a 4 s, later 8 s, off-on delay. With 5.5 s off
  the card never left the bus: pin 6 does not reset a card that sits in fastboot.
  It is not in the kernel series any more (revision 11 = revision 9 plus the rfkill
  configuration below).

## Fix 1: the boot script holds the slot unpowered

The A/B selector (`mkosi/platform/boot/boot.scr.cmd`), on `board_id=rock-5b-plus`
only, runs `gpio clear B26` right after it imports `cera_board.env`. B26 is U-Boot's
name for GPIO1_D2, EKEY_EN, the enable of `vcc3v3_4g`/`vcc3v3_pcie2x1l0`. The card
stays off while U-Boot loads the kernel. Linux then drives RESET# high through its
GPIO hog (about 0.15 s after kernel start) and its always-on, boot-on fixed
regulators bring the rail back (about 0.37 s), so the card powers up with reset
released. The kernel command line gets `cera_slot_power=held`, or `failed` if the
`gpio` command failed (the board still boots).

- The script line is the only reviewed GPIO command in the image;
  `ci/check-internal-modem-power.py` rejects any other.
- **Freshly flashed cards only.** The hold sits in `flashed-images-only` regions of
  the selector. `install-boot.sh boot-payload` strips those regions from the copy
  shipped in the rootfs for `ceralive-boot-script-sync` (the *field selector*), so a
  board updated over RAUC keeps a selector without the hold and relies on fix 2 on
  every boot. Reason: the sync keeps `boot.scr.prev`, but nothing boots it when a
  replaced selector fails, so a change in boot behaviour does not go to the field
  until a tested fallback exists. The payload also carries `boot.scr.keep`, the body
  hash of the flashed selector; the sync leaves a `boot.scr` with that body in place,
  so it never downgrades a flashed card. Limit: after a later image changes the
  selector again, an updated flashed card gets that image's field selector and falls
  back to fix 2.
- The check keys on `board_id` in the script, the one board specific it reads from
  `cera_board.env`.
- The onboard Wi-Fi shares EKEY_EN and is unpowered for the same few seconds before
  Linux. It came up normally on every measured boot.
- RESET# sits at 1.8 V on an unpowered card for about 0.23 s; the vendor kernel's
  order has the same kind of overlap.
- This is a pre-Linux power order. **Never toggle GPIO1_D2 on a running board** to
  recover the modem: it is the shared Wi-Fi/WWAN supply.

A lasting form needs an image-built U-Boot: without `regulator-boot-on` and
`regulator-always-on` on the slot supplies in U-Boot's device tree, U-Boot would not
power the slot at all and the script line could go.

## Fix 2: the boot-time fastboot release (safety net)

If the card appears as `81d6` at the B-key position, the image sends it one fastboot
`continue`. On a freshly flashed card it should never run and logs a warning if it
does. On a board updated over RAUC (no hold in its boot script) it runs on every boot
and logs a notice.

- `79-ceralive-slot-dell-fastboot-release.rules` matches the **add** event of the
  card's fastboot **interface** (`ff/42/03` of `413c:81d6`) by `ID_PATH`
  (`platform-fc800000.usb-usb-0:1.4:1.0`, from the board's verified
  `modem_ports.slots.internal_4g`). Not the USB device's event: the kernel announces
  the device before it configures it, when it has no interface yet. The USB bus number
  is not fixed (`3-1.4` on most boots, `2-1.4` on one), so there is no kernel-name
  match. It starts `ceralive-slot-dell-fastboot-release@<interface name>.service`.
- `/usr/libexec/ceralive/ceralive-slot-dell-fastboot-release` re-checks the parent
  device (`413c:81d6`, the expected `ID_PATH`, exactly one unbound `ff/42/03`
  interface), creates `/run/ceralive/slot-dell-fastboot-release` and only then sends
  `continue` over usbfs. At most one command per boot; never `reboot`; never a
  de-authorize, unbind or reset; no flash, erase or download command exists in it.
- Success is an `OKAY` reply or a confirmed disconnect (`ENODEV`). A timeout, stall
  or other USB error is logged as an error, written to the marker, and fails the unit;
  it is not retried in that boot.
- To keep the card in fastboot for a deliberate firmware update, create
  `/etc/ceralive/keep-slot-dell-fastboot`.
- Other boards, or a board without a verified `internal_4g` position, get no rule
  and no `/etc/ceralive/slot-dell-fastboot-release.env`; the unit is inert.

Check a boot with
`journalctl -b -u 'ceralive-slot-dell-fastboot-release@*'` (empty is the normal
case) and `grep -o 'cera_slot_power=[a-z]*' /proc/cmdline`.

## Kernel sequence and radio release

The kernel uses the base series at `bc7e44fa35d3eded23567dd48e65f6dc799f4b34`
(CERALIVE/rk3588-kernel-patches PR #28) with no B-key patch: `vcc3v3_wwan_pwr`
(FULL_CARD_POWER_OFF#, GPIO2_B1) keeps `regulator-boot-on` and is never toggled at
probe, and the RESET# hog in `&gpio2` drives GPIO2_B3 high at bank probe.
`ci/check-internal-modem-dtb.py <dtb>` checks a built board DTB for this (no
off-on delay, both supplies always-on, the hog, the rfkill node).

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
Old state under the original rfkill path is no longer read. Wi-Fi/Bluetooth
and external WWAN persistence keep their own keys. Later deliberate WWAN
blocks work during this boot, but are intentionally cleared on the next add
(including driver reload or reboot).

## Position identity and normal modem ownership

The board's fixed USB2 hub port 4 is `platform-fc800000.usb-usb-0:1.4`.
Bus numbers and `wwanN` are not identities. The slot-map generator runs in both
runtime installation paths, imports `path_id` for USB-device events, and assigns
the ModemManager physical UID **internal 4G** to that position. Other boards
remain fail-closed without verified maps. This map describes the physical slot,
not a modem serial number.

An external USB Dell keeps its existing physical-path/serial identity and
normal Dell plugin/MBIM handling. No vendor-wide UID, interface rename, FCC
unlock, USB mode switch or firmware command is added. The UI's display-name
policy remains with its consumer.

## Recovery boundary

This image has no modem-service slot power-cycle implementation and grants no
such hook. `uhubctl` remains a manual external-USB tool. `ci/check-internal-modem-power.py`
guards the absence of GPIO, regulator, hub power-control, USB de-authorize and
USB reset commands in every text file under `mkosi/`, except the one boot-script
line above. Pin 6 does not take a card out of fastboot, so a future recovery owner
needs measured evidence before using it.

## SIM and seating

The nano-SIM holder is on the underside. Check board revision and fully seat
the SIM before interpreting `sim-missing`. Power down before touching the holder
or module. On v1.2 boards the SIM-detect signal is inverted; the physical
workaround is tape over the holder's **detect contact**, preserving all SIM data
contacts. Disabling SIM detection in the module is a persistent modem setting
that needs separate owner approval; no command for it is sent by this image.

## Checks

Host: `tests/boot-script-slot-power.test.sh` (the selector's order; hold in the boot
partition's copy, none in the field copy), `tests/boot-script-sync.test.sh` (field
selector, `boot.scr.keep`) and `tests/rock5bplus-internal-modem.bats` (kernel pin, rfkill, position
rules, the release rule/unit and `tests/slot-dell-fastboot-release.test.py`, the
power guard; set `CERALIVE_WWAN_DTB` to check a built DTB).

Hardware, per image, on a freshly flashed card: five cold boots, at least ten seconds
unpowered each: all `81d7`, `cera_slot_power=held`, the release unit silent, the sync
logging that it kept the flashed selector, one ModemManager object with Device
`internal 4G`, SIM read and registered. And on a card updated over RAUC from an image
without the hold: the boot script stays as it was, the release unit fires once per
boot, logs it, and the card registers.

English and Spanish (es-419) external user guidance is a release follow-up.

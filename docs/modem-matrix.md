# Supported-Modem Matrix

This document describes the **existing** cellular (LTE/5G) modem stack baked into
the CeraLive device image, and the build-time check that verifies the kernel
ships the WWAN modules that stack depends on. It is a description of what the
image does today — not a roadmap.

The modem runtime stack is complete and production-grade. Nothing here changes
it; this page documents it and pairs it with the module-presence check
(`lib/check-wwan-modules.sh`), which is **fail-closed on the nine required USB
modules and advisory on the four MHI/RNDIS ones** — see §6.

---

## 1. Userspace cellular stack

The image ships a ModemManager-based cellular stack. The **core ModemManager
1.24 closure** — the nine ELF-shipping packages below — is a CeraLive fork
(`~ceralive.3`) published by modem-stack v1.4.0, staged as
first-party `.deb`s (`FIRST_PARTY_APT_PKGS` in `lib/fetch-debs.sh`, pinned in
`manifests/first-party-deb-versions.txt`) and installed by the **app layer**
(`RUNTIME_APP_PKGS`). It **upgrades** the Debian modem packages the runtime layer
pulls transitively via `shared.list`, in the same local dpkg transaction. The
`apt.ceralive.tv` origin pin (`Package: *`, Pin-Priority 990) keeps the fork
winning for on-device `apt-get upgrade`.

| Fork closure package | Role |
|----------------------|------|
| `modemmanager` | Cellular modem management daemon (NetworkManager drives it) |
| `libmm-glib0` | ModemManager GLib client library |
| `libqmi-glib5` / `libqmi-utils` / `libqmi-proxy` | QMI (Qualcomm) transport lib + `qmicli` + shared control-port proxy |
| `libmbim-glib4` / `libmbim-utils` / `libmbim-proxy` | MBIM transport lib + `mbimcli` + shared control-port proxy |
| `libqrtr-glib0` | QRTR (Qualcomm IPC router) GLib library |

These nine form a **self-contained dependency closure** (`modemmanager` →
`libmm-glib0`; the glib libs bind to the qmi/mbim/qrtr transports). External deps
(GLib, `libgudev`, `polkit`, systemd) come from Debian.

`ceralive-modem-support=1.4.0` is a separate, `Architecture: all` first-party
companion staged through that same app-layer route. It owns generic modem system
assets, including `60-ceralive-modem.rules`; the image-owned
`99-ceralive-hardware.rules` and generated `78-mm-ceralive-slot-uid.rules` have
distinct basenames, so udev cannot shadow the packaged companion rules.
The `[7/9]` parity gate enforces both that basename separation and exactly one
package owner for every path in `manifests/modem-support-ownership.txt`; the
offline negative suites inject a basename collision, an orphan, and duplicate
ownership so these checks cannot pass vacuously.

Supporting packages that stay **Debian** (`manifests/packages/shared.list`):

| Package | Role | Source |
|---------|------|--------|
| `mobile-broadband-provider-info` | Mobile-provider / APN database ModemManager reads to auto-resolve connection settings from the SIM's MCCMNC | `shared.list` §"Modems" (explicit — a `Recommends:` `--no-install-recommends` drops) |
| `usb-modeswitch` | Flips USB modems out of mass-storage mode into modem mode so they enumerate | `shared.list` §"USB modem bring-up" |
| `uhubctl` | Manual per-port power-cycle tool for a physically wedged USB modem; no service, timer, or udev rule invokes it automatically | `shared.list` §"USB modem bring-up" |
| `network-manager` | Primary connection manager (WiFi/Ethernet/modem); CeraUI drives it | `shared.list` §"Network management" |

`ModemManager` is enabled as a system service in
`mkosi/customize/postinst-lib.sh` (`configure_services` enables `ModemManager`
alongside `NetworkManager`, `systemd-resolved`, etc.).

USB device access for modems is granted by udev in
`mkosi/customize/udev.sh` ("USB Modem Devices (4G/5G)"): the common modem
vendor USB IDs are group-tagged `dialout` so the daemon can talk to the control
ports.

---

## 2. Known-good modems

The image group-tags these modem vendor USB IDs in `udev.sh` — they are the
validated vendor set the device enumerates and grants control-port access to.
Protocol is the control protocol ModemManager uses; the **Modules** column is the
kernel-driver path each protocol relies on (see §4).

| Vendor | USB ID | Typical protocol | Kernel modules used |
|--------|--------|------------------|---------------------|
| Quectel | `2c7c` | QMI (also MBIM on RM-series) | `qmi_wwan` + `cdc_wdm` (QMI); `cdc_mbim` + `cdc_wdm` (MBIM); `option` (AT/serial ports) |
| Sierra Wireless | `1199` | MBIM / QMI | `cdc_mbim` + `cdc_wdm`, or `qmi_wwan` + `cdc_wdm`; `option` |
| Huawei | `12d1` | NCM / MBIM | `cdc_ncm` or `cdc_mbim` + `cdc_wdm`; `option` |
| ZTE | `19d2` | QMI / NCM | `qmi_wwan` + `cdc_wdm`, or `cdc_ncm`; `option` |
| Telit | `1bc7` | QMI / ECM | `qmi_wwan` + `cdc_wdm`, or `cdc_ether`; `option` |

These are USB modems. M.2 B-key modems (Quectel `2c7c`, Sierra `1199`) enumerate
over USB internally and additionally need the SIM-detection quirk in §3.

---

## 3. M.2 SIM-detection quirk

M.2 B-key modems need ModemManager forced to probe and treat the port as a modem
candidate so SIM detection works. The live build resolves the board manifest's
`quirks.m2_modem_sim_workaround` value into `CERALIVE_BOARD_QUIRKS`, passes it
through the mkosi subimage environment, and
`mkosi/customize/postinst.d/hardware.sh::apply_board_quirks` adds
`ENV{ID_MM_DEVICE_PROCESS}="1"` and
`ENV{ID_MM_CANDIDATE}="1"` udev properties for the Quectel (`2c7c`) and Sierra
(`1199`) vendor IDs already group-tagged in `udev.sh`. Boards that do not declare
the quirk emit no rows. The older `customize/quirks.sh` handler remains covered
as a hermetic helper but is not the live image writer.

### 3a. RM520N USB 2 quirk (`ceralive-modem-usbspeed`)

A Quectel RM520N's own USB 3 link raises its receiver's noise floor. Measured at
unchanged RSRP: about 5 dB of S/N on LTE B1 and on the 5G leg at strong signal,
about 14 dB on one weak cell. The module keeps `AT+QCFG="usbspeed"` in its own
memory, so it runs at whatever it carries in (`"312"` from the factory, 5 or
10 Gbit/s) on any SuperSpeed port. A bonded uplink never needs more than
480 Mbit/s.

`99-ceralive-modem-usbspeed.rules` starts `ceralive-modem-usbspeed@<usb device>.service`
for every added `2c7c:0801` device. The script
(`mkosi/runtime/ceralive-modem-usbspeed.py`, installed as
`/usr/local/sbin/ceralive-modem-usbspeed`):

- does nothing while the link is at 480 Mbit/s or slower;
- holds back while `srtla_send` runs (CeraLive's stream process; `cerastream`
  runs while idle too) or `/data/ceralive/modem-usbspeed.disabled` exists, and
  checks both again right before asking ModemManager for the modem, before the
  write and before the reset. A stream that starts in between ends the attempt
  with the modem released; after the write it means no reset, and `"20"` applies
  at the module's next power-up;
- acts once per USB port and once per unit per boot (markers in
  `/run/ceralive/modem-usbspeed/`, written before ModemManager is asked and
  before the reset);
- accepts only ModemManager models `RM520N-GL` and `RM520N-EU` (the RM530N-GL
  shares the USB ID and is left alone); the modem is matched by ModemManager's
  `physdev`, so slot names from `ID_MM_PHYSDEV_UID` don't hide it;
- holds the modem with `mmcli --inhibit-device` (ModemManager then closes all
  its ports, the secondary AT port included), talks to an AT port that
  ModemManager had typed `(at)` for that device and nobody holds open, reads
  `usbspeed`, records a value other than `"20"`, writes `"20"`, reads it back
  and only then sends `AT+CFUN=1,1`;
- watches the module leave and return. At 480 Mbit/s it comes back on the
  controller's High Speed bus under another kernel name (`10-1` → `9-1` on the
  Rock 5B+ USB-C port), so it is recognised by the USB port's `peer` link. A
  socket whose USB 2 lines go to another controller (the Rock 5B+ upper blue
  port: `8-1` on xHCI `fcd00000`, back as `5-1` on EHCI) has no such relation,
  so there it is matched as the only new `2c7c:0801` that no other run claims,
  and only while no other reset is in flight. `verified`, `failed` (still fast),
  `not-reset` (never left), `not-back` or `unattributed` (two resets at once and
  a return on no known socket; not a failure) is logged and stored.

The per-unit record is `/data/ceralive/modem-usbspeed/<unit>.json`, where `<unit>`
is HMAC-SHA256(`/etc/machine-id`, IMEI) cut to 16 hex digits; it holds the
original value and the last outcome. A unit that ended `failed` or `not-back`
is left alone on later boots; `touch /data/ceralive/modem-usbspeed.retry`
clears every unit's last outcome once, keeping the original values. The whole run has a
270 s budget that also bounds every `mmcli` call.

Every decision is one journal line (`journalctl -u 'ceralive-modem-usbspeed@*'`).
To put a unit back: create the `.disabled` file, then with ModemManager held
send `AT+QCFG="usbspeed","<original>"` and `AT+CFUN=1,1`.

Notes: CeraUI takes its own `mmcli --inhibit-device` for modem mutations. If
both want the same modem at once, the second hold is refused; here that ends
as `inhibit-failed` with nothing sent. On a box that autostarts a stream, a
modem that appears late (the USB-C port's about 95 s) usually finds the stream
running and is left for the next boot. A carrier with no USB 2 wiring would
lose the module at `"20"`; every measured SuperSpeed socket on the Rock 5B+
and Orange Pi 5 Plus has a USB 2 path.

### 3b. ModemManager port hints (`78-ceralive-modem-port-hints.rules`)

`mkosi/runtime/78-ceralive-modem-port-hints.rules`, installed into
`/etc/udev/rules.d` by `networking.sh::setup_modem_port_hints`, sets
`ID_MM_PORT_IGNORE=1` on one tty, matched by exact USB vendor/product and
interface number. ModemManager then lists the port as `(ignored)` and never opens
or probes it. ModemManager's own port-type hints stay in place.

| Device | Interface | Why |
|---|---|---|
| Quectel RM520N-GL / RM530N-GL `2c7c:0801` (QMI) | 3 (secondary AT) | CeraUI reads `AT+QTEMP` and `AT+QENG="servingcell"` read-only on this port, and only when the udev database shows this release. ModemManager keeps the primary AT, QMI and data ports, and the USB 2 quirk above still talks to the `(at)` port while it holds the modem. |

Without the release CeraUI refuses both reads, as `owned-by-modemmanager` while
ModemManager lists the tty as an AT port, otherwise as `not-released`.

The match uses the USB ID and interface number only, not the USB configuration or
the retail model. `2c7c:0801` is shared by the RM520N-GL and the RM530N-GL, and
the interface layout above is the recorded QMI composition (configuration 1);
other compositions of this ID, such as MBIM, are outside that evidence.

The hints take effect for a modem probed after installation (boot, replug, or a
re-probe of that modem). `tests/modem-port-hints.bats` checks the file and proves the
matches with `udevadm test` against a generated sysfs.

---

## 4. SRTLA modem source-routing — RETIRED

**There is no per-modem source-routing layer any more.** Bonded streaming pins
each uplink's egress in the socket instead: `srtla_send` binds every link with
`SO_BINDTODEVICE` plus a source-address bind, so the interface is named by the
socket rather than inferred from a routing rule.

The retired assets — the NM dispatcher `90-srtla-wifi-routing`, the dhclient hook
`dhclient-exit-hooks.d/srtla-source-routing`, the `rt_tables` reservations
(`100-107 modem0..7`, `120-124 wlan0..4`), and the `networking-srtla.sh` module —
are removed from the image, and both `ci/postinst-drift-check.sh` (CHECK 2) and
`lib/parity-check.sh` (§D) now fail if any of them reappears.

Why it was retired rather than guarded, in one line each, all measured on a live
`7.1.7-ceralive-rk3588` board: `ip rule` was unsupported there
(`# CONFIG_IP_ADVANCED_ROUTER is not set` — the current `v7.2` edge fragment
declares it `=y`, which changes the capability but not the retirement), an `ip route add … table N` silently
lands in the **MAIN** table on that kernel (so the dispatcher could install a
metric-0 default that outranks every DHCP route), it logged a success line after
both of its mutations had failed, and its dhclient half could never run because
`dhclient` is not installed. On the vendor kernel — where `ip rule` does work —
its `from <source-ip>` rules cannot tell this fleet's two HiLink twins apart,
because both lease `192.168.8.100`.

Full decision record with verbatim traces:
`.omo/notepads/modem-phase-c-quality/evidence/todo38.md`; summary in
[`docs/agents/known-issues-deferred.md`](agents/known-issues-deferred.md) → "SRTLA source-policy routing is RETIRED".

`rp_filter` is a SEPARATE, RETAINED asset and is unaffected:
`/etc/sysctl.d/60-ceralive-rp-filter.conf` still sets
`net.ipv4.conf.{all,default}.rp_filter = 2` (loose reverse-path), written at image
build by `postinst.d/networking.sh::install_interface_naming`. Loose RPF is what
lets a multi-WAN board accept return traffic that arrives on a different interface
than the route table would pick; it is required by the device-bound bond, not by
policy routing. No runtime service writes it — CeraUI and `srtla_send` only READ
route/rp_filter health and report it.

---

## 5. Required WWAN kernel modules

The userspace stack above is inert unless the kernel exposes the WWAN network and
serial drivers the modems bind to. Nine modules are **required** — a missing one
fails the §6 check — and four more are checked **advisory**:

| Module | Class | Purpose |
|--------|-------|---------|
| `qmi_wwan` | required | QMI WWAN network device (Qualcomm modems) |
| `cdc_mbim` | required | MBIM WWAN network device (USB CDC MBIM) |
| `cdc_wdm` | required | USB CDC WDM character device — the QMI/MBIM control channel (`/dev/cdc-wdm*`); the on-disk file is `cdc-wdm.ko` |
| `option` | required | USB serial driver for modem AT/diagnostic ports |
| `cdc_ether` | required | USB CDC Ethernet (ECM) network device |
| `cdc_ncm` | required | USB CDC NCM network device |
| `cdc_acm` | required | the `/dev/ttyACM*` AT control port a large share of modems expose; on-disk file `cdc-acm.ko` |
| `qcserial` | required | control ports for Qualcomm modems that do NOT present the `option` interface layout — without it ModemManager sees a data interface and nothing to drive it with |
| `usb_wwan` | required | the promptless USB-serial helper BOTH `option` and `qcserial` select; losing it takes both control-port drivers while their own symbols still look satisfied |
| `mhi` | advisory | the PCIe/M.2 MHI bus itself |
| `mhi_wwan_ctrl` | advisory | MHI AT/MBIM/QMI/DIAG control channels |
| `mhi_wwan_mbim` | advisory | MHI data netdev |
| `rndis_host` | advisory | host-side RNDIS, for a modem or tethered peripheral whose only mode is RNDIS |

The three MHI rows are the PCIe/M.2 attach path rather than the USB one, and no
CeraLive board has qualified a PCIe modem — hence advisory. `rndis_host` is
advisory because QMI and MBIM already cover every modem in §4's table.

A module may ship either way and both satisfy the stack:

- **Loadable (`=m`)** — a `<module>.ko` file (optionally `.ko.xz`/`.ko.gz`/`.ko.zst`)
  under `lib/modules/<kver>/kernel/…`, loaded on demand by modprobe.
- **Built-in (`=y`)** — compiled into the kernel image and listed in
  `lib/modules/<kver>/modules.builtin` (no `.ko` file ships).

As measured on the Armbian vendor BSP kernel this image used to ship (that track
is now retired — production builds the mainline kernel from pinned source),
`qmi_wwan`, `cdc_mbim`, `cdc_wdm` and `option` shipped loadable (`=m`), while
`cdc_ether` and `cdc_ncm` were built-in (`=y`). Both forms are accepted, and the
check makes no assumption about which a given kernel chooses — see
`manifests/kernel/rk3588-edge.fragment` for what the production kernel declares.

---

## 6. Build-time module-presence check

`lib/verify-kernel-config.sh` proves a kernel SYMBOL resolved in the built
`.config`. That is not the same claim as a `.ko` having shipped in the built
package, and a config gate can be green while the `.deb` is missing the module.
`lib/check-wwan-modules.sh` is the second claim, and it is what makes a dropped
module observable.

```bash
lib/check-wwan-modules.sh <kernel.deb | module-tree-dir>
lib/check-wwan-modules.sh --help
```

### Severity: nine required, four advisory

| Class | Modules | On a miss |
|---|---|---|
| **REQUIRED** | `qmi_wwan` `cdc_mbim` `cdc_wdm` `option` `cdc_ether` `cdc_ncm` `cdc_acm` `qcserial` `usb_wwan` | the module is NAMED and the check **exits non-zero** |
| **ADVISORY** | `mhi` `mhi_wwan_ctrl` `mhi_wwan_mbim` `rndis_host` | an `ADVISORY` line; the check still exits 0 |

The required nine are the USB datapath the modems in §4's known-good table
actually bind through — the two vendor protocols (QMI, MBIM), their shared
`/dev/cdc-wdm` control device, the generic CDC data interfaces, and the serial
control ports ModemManager drives (`option` and `qcserial` between them cover the
two USB interface layouts, `usb_wwan` is the promptless helper both select, and
`cdc_acm` is the `/dev/ttyACM*` AT port). Losing any one of them is a
fleet-visible "no modem", so it fails closed.

The advisory four are advisory for stated reasons, not caution. The three MHI
modules are the PCIe/M.2 transport and **no CeraLive board has qualified a PCIe
modem**; `rndis_host` is the RNDIS fallback that QMI and MBIM already cover for
every modem in §4. Their symbols are still pinned, so the capability cannot
vanish unnoticed — but a build must not fail over hardware nobody has proven on a
bench. Promoting one needs a board that proves it.

`CERALIVE_WWAN_CHECK_ADVISORY=1` reports **every** module ADVISORY and always
exits 0 — the behaviour the whole check had before the split. It is for bisecting
a kernel change or probing a deliberately narrow tree, never a release build; it
logs that it is active, and any value other than `0`/`1` is refused rather than
guessed at.

### The list lives in ONE place, and that is enforced

`WWAN_MODULE_TABLE` carries `<CONFIG symbol>|<module>|<severity>` rows and the
required/advisory arrays are derived from it. The module name cannot be derived
from the symbol (`CONFIG_USB_WDM` → `cdc-wdm.ko`, `CONFIG_USB_ACM` →
`cdc-acm.ko`, `CONFIG_USB_SERIAL_QUALCOMM` → `qcserial.ko`), so keeping the
symbol beside the name is what lets `tests/package-contract.bats` §17 check the
table against `manifests/kernel/required-symbols.list` in **both** directions —
no symbol the checker names may go unpinned, and no valued modem/WWAN leaf in the
manifest may fail to reach the checker. The second direction is a real
regression, not a hypothetical: `CONFIG_USB_NET_RNDIS_HOST` reached the kernel
fragment and never reached this checker, so the module went uninspected for three
releases.

What it does:

- Inspects a kernel `.deb` (extracted via `dpkg-deb`, or the `ar`+`tar` fallback)
  or an already-extracted module tree, and reports, per module, whether it ships
  as loadable (`=m`), built-in (`modules.builtin`, `=y`), or via a `modules.alias`
  entry.
- Hyphen/underscore aware: the `cdc_wdm` module ships on disk as `cdc-wdm.ko`;
  the check normalises `-`↔`_` (as modprobe does) so the file satisfies the
  module name.
- Matches the `option` module by an exact `option.ko` basename, a
  `…/option.ko` `modules.builtin` entry, or a `modules.alias` line whose module
  token is `option` — **never** a bare occurrence of the word "option" in some
  other filename or file body (a known false-positive trap).
- Asserts a `.deb` extractor (`dpkg-deb`, or `ar`+`tar`) is available before it
  tries to open a `.deb`.
- Additionally reports, on **every** tree, whether the native FM350 PCIe driver
  `mtk_t7xx` is present. That probe used to be scoped to a `*-vendor-rk35xx`
  tree; the prebuilt vendor track is retired and a source-built module set is
  just as inspectable, so it now runs everywhere and says an absence out loud
  instead of skipping it. It is advisory in every case, and separate from the
  table above because `CONFIG_MTK_T7XX` is declared in neither the fragment nor
  `required-symbols.list` — there is no manifest row to hold it to. The USB
  `0e8d:7127` bench personality is never treated as evidence for native PCIe
  `14c3:4d75` support.

A missing **advisory** module prints a `WARNING` and the check still exits 0; it
never edits `shared.list` or the kernel config, and reacting to it (sourcing a
kernel that ships the module, or declaring it) stays a human decision. A missing
**required** module exits non-zero, because a warning nobody has to act on is not
a gate — which is exactly how the `rndis_host` omission above survived.

Proof: `run-tests` section 17.

---

## 7. Modem slot-UID naming (`modem_ports`) — fail-closed generator + discovery runbook

The board manifest carries an optional `modem_ports` block that drives
deterministic ModemManager slot-UID naming. It is **fail-closed**: while
`status: unverified` (the default without a verified map) the udev generator
`mkosi/customize/postinst.d/hardware.sh::generate_modem_slot_uid_rules` emits **NO** generated
`78-mm-ceralive-slot-uid.rules` — there is no permissive fallback. The permanent
generic modem rules (§"USB Modem Devices" in `setup_hardware_access`) always ship
and govern access on their own until a slot map is verified.

```yaml
# manifests/boards/rock-5b-plus.yaml — shipped default
modem_ports:
  status: unverified
```

### Why unverified until hardware

The slot map pins each physical modem slot to its `ID_PATH`, and `ID_PATH` can
only be read reliably from a modem plugged into that exact board model. Guessing
it would risk emitting a rule that binds the wrong device to a UID — worse than no
rule. So the generator refuses to emit anything until a human records the real
values and flips `status` to `verified`.

### Discovery runbook (run on the board with a modem attached)

```bash
# 1. Find the modem's USB device (control port or net device):
mmcli -L                                   # lists modems once ModemManager sees one
ip link show | grep -E 'wwan|usb[0-9]|enx' # the modem's net iface, if any

# 2. Read the stable ID_PATH of the physical slot (the USB device, not ttyUSBn):
udevadm info /sys/class/net/<modem-iface> | grep -E 'ID_PATH='
#   or, for the control-port USB device:
udevadm info /dev/<cdc-wdm-or-ttyUSB> | grep -E 'ID_PATH='
```

### Flip to verified (a separate, hardware-gated change)

Once you have the real `ID_PATH` for each slot, populate `slots` and set
`status: verified`:

```yaml
modem_ports:
  status: verified
  slots:
    modem0: platform-fc000000.usb-usb-0:1:1.0   # ← the ID_PATH you read
    # modem1: …                                  # add per additional slot
```

The generator then emits one rule per slot:

```
ACTION=="add|bind", SUBSYSTEM=="usb", ENV{ID_PATH}=="<id_path>", ENV{ID_MM_PHYSDEV_UID}="modem0"
```

`ID_MM_PHYSDEV_UID` gives ModemManager a stable per-slot identity regardless of
ttyUSB enumeration order. The ROCK 5B+ map names its fixed B-key port "internal 4G"; other maps
require the same physical discovery before enabling them.

Proof: `run-tests` — the generator matrix (unverified ⇒ zero generated rules;
verified fixture ⇒ rules emitted) in `postinst-wiring.bats`.

The ROCK 5B+ has a position map for its internal B-key port and a separate
[DW5821e candidate and qualification guide](rock5bplus-internal-modem.md).
The live runtime installer and decomposed installer now share the generator.

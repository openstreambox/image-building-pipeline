# Status screen (renderer only)

A plain page for a monitor plugged into the box, written to be photographed
and sent to support when the box has no network. This change ships the
renderer, `/usr/libexec/ceralive/ceralive-status-screen`, and the `qrencode`
package it uses; nothing starts it yet. The console wiring below is the
proposed next step.

## What the page shows

| Line | Source |
|---|---|
| Support code | Last four hex digits of `/etc/machine-id`, upper case: the same suffix the setup hotspot (`CeraLive-Setup-<id>`) and the hostname already show |
| Ready | Snapshot: yes/no and a reason code, shown as fixed wording; an unknown code shows "another reason (see the support log)", never the code |
| Image | `IMAGE_VERSION`, else `VERSION_ID`, from `/etc/os-release` |
| CeraUI | Snapshot release version (dotted numbers, short suffixes); `not reporting` without a snapshot |
| Up for | `/proc/uptime` |
| Uplinks | Snapshot: role labels (`Cellular 1`, `Ethernet 1`, `Wi-Fi 1`) and `up`/`degraded`/`down` |
| SIMs | Snapshot: `Modem N` and `present`/`absent`/`locked`/`unknown` |
| Last err | Snapshot: a code, shown as fixed wording, unknown codes generically |
| Attention | The highest shared attention condition's `line`, cleaned like all text |
| Address, Open, QR | Global IPv4 addresses from `ip -j -4 addr`, client-facing interfaces (`ap`, `wlan`, `br`, `eth`) before uplinks; the QR always encodes the image's TLS front, `https://<address>/`: the snapshot `url` may only choose which of these addresses, its scheme, port and path are ignored |

Without a snapshot the page says that the application has not reported and
shows the box facts only. The last line is always "Photograph this screen for
support. Alt+F1 to log in." (or "Alt+F1 to log in." on a narrow console).

The snapshot carries no free text, so names a writer might leak (Wi-Fi
networks, destinations, modem identifiers) have no field to arrive in. Never on
the page: credentials, stream keys or IDs, destination addresses, Wi-Fi names
or passwords, IMEI, ICCID, IMSI or phone numbers, logs.

## Snapshot contract

CeraUI writes `/run/ceralive/status-screen/snapshot.json` atomically (rename),
mode 0644, in a directory only CeraUI may write, at most 16 KiB, and refreshes
it at least every minute:

```json
{"schema":2,"expires":1800000060,"ceraui":"2026.11.21",
 "url":"https://192.168.42.1/",
 "uplinks":[{"kind":"cellular","state":"up"},{"kind":"ethernet","state":"down"}],
 "modems":[{"sim":"present"},{"sim":"absent"}],
 "ready":{"ready":false,"code":"no_uplink_passes"},
 "last_error":{"code":"receiver_refused","at":1800000000}}
```

The renderer opens the file once without following a symlink and without
blocking, requires a regular file, and reads at most 16 KiB plus one byte. It
ignores the file when that fails, when the JSON is invalid, too deep or holds
`NaN`/`Infinity`, when `schema` is not the integer 2, or when `expires` is not
an integer in the next hour. `kind`, `state` and `sim` must be one of the
listed strings; codes must match `[A-Za-z0-9_]{1,48}` and unknown codes get
fixed generic wording; `ceraui` must be a release version (one to four dotted
number groups after the first, at most two short suffixes). At most eight
uplinks and eight modems are read.

## Drawing

The page is printable ASCII only. Every text field is folded to ASCII, and
control, format, separator and surrogate characters are removed. The QR code
comes from Debian's `qrencode` (level M, 8-bit mode) and is drawn with
reverse-video spaces: two cells per module, one row per module, and four light
modules of quiet zone on every side. With the console's light foreground on a
dark background it reads dark on light. No glyph beyond ASCII is needed, so the
`Lat15` Terminus fonts the image ships draw it.

Checked by rasterizing the full page with `Lat15-TerminusBold16` and
`Lat15-TerminusBold32x16` from `console-setup-linux` at 128x37 and 240x67
characters, for `https://192.168.42.1/` and `https://192.168.123.234/`: no
missing glyph, and every raster decodes with jsQR with inversion disabled.

## Layout

The login line is reserved first and is always the last row. The code sits
beside a text block of at most 60 columns when the console has its width plus
32 columns and its height plus one row (a local address needs 66x33 cells),
else below the text when it fits, else it is left out. The `Open` and
`Address` lines come right after the header, so on a crowded page the
uplink, SIM and attention detail is cut first. On a 1024x600 panel the 8x16 font gives 128x37 and shows the code; the
attention owner's 16x32 font gives 64x18 and does not. When printing to a
terminal the renderer emits no trailing newline, so the first row does not
scroll away.

## Proposed console wiring (not in this change)

- The attention owner (`ceralive-attention watch`) already owns VT8 and
  repaints it every two seconds. When no critical or fatal condition holds VT8,
  it would paint this page there instead of clearing it, with the 8x16 font and
  the default palette (light foreground on black).
- It would switch to VT8 once at boot and when an HDMI connector changes from
  disconnected to connected (`/sys/class/drm/card*-HDMI-A-*/status`), never
  while an operator is on another VT, as it does today.
- Critical and fatal conditions keep precedence and keep their current text.

HDMI output, the real palette and a phone reading the code off a monitor at an
angle still need a board and a monitor before this is enabled.

# Power supervisor link v1

Version 1.1.0 (draft). Text licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
Decoder code and vectors use the repository license. Initial version: framing,
core vocabulary and two-input/reserve profile; no wire changes.

## 1. Framing

`OSB1` is the historical wire identifier, retained byte-for-byte for firmware
compatibility; it is not a vendor check or a requirement to use a named board.
Implementers may emit these ASCII frames from any USB serial microcontroller.
No host commands, handshake or command responses are required. Emit status
at least once per second for the five-second freshness window. This is an open
specification, not a USB class or an Internet standard. Emitters use a new boot
identifier on each restart and a shared increasing sequence across frame kinds.
`up` is elapsed whole seconds. Keep it non-decreasing within each frame kind,
except for a documented clock rollover; status and event clock origins can differ.
The reader preserves the tty baud setting and configures raw input; USB CDC
implementations must not require a host baud-rate handshake. A physical UART
bridge needs its baud setting configured separately. Unsupported measurements
should be omitted or use the documented unavailable values, never fabricated as healthy.

ASCII lines end in LF; the whole line including LF is at most 512 bytes.
Non-OSB1 text is ignored and counted. As an ESP32-family ROM heuristic,
`waiting for download` on non-OSB text marks bootloader mode (best effort:
opening after the one-shot ROM banner can show silent).
Only a different `OSB<digits> ` version prefix marks unknown_version. Overlong
input is discarded through the next LF, using bounded memory. Disconnect drops
any partial line. Embedded NUL/control bytes are rejected.

CRC is the final ` crc=HHHH` field: CRC-16/CCITT-FALSE (polynomial 0x1021,
initial 0xffff, no reflection or final XOR) over all preceding bytes, excluding
the separator before crc and LF. `123456789` produces `29B1`.

Status uses `OSB1 key=value ...`; events use `OSB1 EVT up=... human text ...`.
EVT has `up=<uint32>` followed by optional opaque printable text and the fixed trailing
fields `seq boot rst alive hot shutdowns fw`, in that order, then CRC. Parse
these seven fields from the right; key-like tokens and ` crc=` in the human
text have no field meaning. Event trailer fields cannot be reordered.

`seq` is uint32 decimal and `boot` is eight hex digits. Both are required.
Status also requires uint32 decimal `up`. Missing other fields stay unknown;
no zero/healthy defaults are synthesized. Status field order is immaterial and new
bounded key/value fields are preserved without assigning meaning. Duplicate
keys, invalid counters and malformed fields are rejected. Bounds are 48 keys,
31 bytes/key and 159 bytes/value, within the 512-byte frame limit.

Sequence spans status and events. Boot ids compare by numeric value
(case-insensitive hex), with lowercase canonical output. A changed boot id
immediately establishes a restart, even when first observed in an event.
Within a repeated boot id, a decrease in `up` against the last accepted frame
of the same kind establishes a restart before sequence ordering is checked.
Consequently a stale lower-uptime frame can become the current status; receivers
assume an ordered serial stream, not a replay-resistant transport.

With no same-kind history, a backward/half-range sequence delta plus an `up`
more than two seconds below the other kind's last accepted uptime establishes
a restart. This fallback retains the first boot EVT after status-only history
(and the first status after EVT-only history). The two-second tolerance allows
small clock-origin offsets; larger offsets combined with backward sequence
numbers are indistinguishable from a restart. Emitters should use distinct boot
ids. A first frame of a kind otherwise cannot prove an uptime decrease.

A known rollover is exempt from the decrease rule: previous same-kind `up`
in 4294965..4294967, new `up` in 0..2, and a strictly forward sequence delta
less than 2^31. These are the seconds around a uint32 millisecond-clock wrap
at 4294967.296 seconds (about 49.7 days). Each kind wraps independently,
without clearing the other history or incrementing restarts. Other emitter
clock widths/rollover points are not inferred; a 64-bit clock need not wrap.

Forward modulo-2^32 sequence deltas count missing lines; sequence wrap is
continuous. Duplicates and backwards/half-range deltas are rejected without
refreshing status. Three consecutive otherwise-valid backward frames with
sequence numbers increasing by one establish a restart even if boot repeats.
Duplicates or a forward frame reset that candidate; the first two backward
frames remain rejected. Recovery increments restarts, invalidates old status
and adds no giant missed-lines gap. Every detected restart clears both uptime
histories. Only accepted frames update history.

Only a valid status refreshes `rx_mono_ms` and replaces fields. Events never
patch status fields. Restart invalidates status but preserves diagnostic fields
and event history, retaining even the first boot event under the rules above.
Unknown protection-gap bits never mean full protection.

### Receiver processing order

Each rejected complete line contributes to exactly one counter, in this order:

1. Buffer bytes through LF. At most 511 bytes precede LF. At offset 511
   (zero-based), any non-LF byte, including NUL, increments `oversize`.
   Before that offset, NUL increments `malformed`, even in non-protocol text.
   After either error discard through LF without another count.
2. Check the prefix before CRC. Exact `OSB1 ` proceeds. Other `OSB<digits> `
   prefixes increment `unknown_version`; other text increments `ignored`.
   Bare `OSB1` and `OSB1x` are ignored. Non-OSB text may set the bootloader
   heuristic above. These special link states persist through ignored or
   rejected lines until another special indication or an accepted frame;
   an accepted frame clears them. Disconnect also clears them.
3. Validate the final CRC field and checksum before checking printable bytes.
   Missing/invalid checksum increments `crc`. CRLF therefore fails CRC; a
   bad-CRC control byte counts as `crc`, but a good-CRC TAB is `malformed`.
4. Validate printable ASCII and field grammar/bounds; failures increment
   `malformed`. Parse boot ids by numeric value, not textual spelling.
5. Apply boot/uptime restart rules, then sequence ordering. Rejected sequence
   candidates increment `out_of_order`; no rejected frame refreshes status.

ABNF (case-sensitive literals; RFC 7405 `%s` notation):

```abnf
line       = (status / event) SP %s"crc=" 4HEXDIG LF
status     = %s"OSB1" 1*SP pair *(1*SP pair)
event      = %s"OSB1 EVT up=" uint [SP *PRINT] SP trailer
trailer    = %s"seq=" uint SP %s"boot=" 8HEXDIG SP
             %s"rst=" value SP %s"alive=" value SP %s"hot=" value SP
             %s"shutdowns=" value SP %s"fw=" value
pair       = key %s"=" value
key        = 1*31(ALPHA / DIGIT / %s"_")
value      = 1*159VCHAR
uint       = 1*DIGIT
PRINT      = %x20-7E
VCHAR      = %x21-7E
SP         = %x20
LF         = %x0A
DIGIT      = %x30-39
ALPHA      = %x41-5A / %x61-7A
HEXDIG     = DIGIT / %x41-46 / %x61-66
```

Semantic constraints override the grammar: whole line <=512 bytes including LF;
status <=48 unique keys; `seq` and `up` <=4294967295; status `up`, `seq`, `boot`
required. Split a pair at its first `=` (later `=` bytes belong to its value).
EVT parsing starts at the rightmost seven space-delimited pairs; text may itself
contain `seq=`, `boot=` or ` crc=`. Only `up`, `seq`, `boot` are numeric framing
fields; EVT `up` has at most 31 decimal digits (including leading zeros);
trailer diagnostics are bounded strings. The final CRC separator is a
single space. Receivers also tolerate repeated/trailing spaces around status pairs; emitters
should use single spaces. CRLF is not valid. Blank/non-protocol lines are ignored.
A truncated line is not decoded until LF; discard it on disconnect.

## 2. Core vocabulary

The framing layer requires only `up`, `seq` and `boot` in a status. Meaningful
power warnings also require the corresponding status fields below; a valid
minimal frame alone does not establish healthy power or complete protection.
There is no battery percentage or runtime estimate in version 1.

| Field | Meaning |
| --- | --- |
| `power` | `ok`: healthy input reported; `low`: weak input; `holdup`: reserve supplies the host; `none`: no usable supply reported (`power=none` is never healthy). Missing or unrecognized values are unknown, never healthy. Only `ok` establishes healthy input. |
| `redundant` | `0`: no confirmed backup input; `1`: confirmed backup. Omit when unknown. |
| `thermal` | `normal`, `warm`, `hot`, `critical`, `shutdown`: the board's warning level, not a host temperature threshold. |
| `hot` | Comma-separated sensor identifiers affected by that level, or `none`; the profile defines their locations. |
| `sbc` | Host power state, including `run` and `shutdown_requested[:cause]`; descriptive only, never a host command. |
| `rst`, `alive`, `shutdowns`, `fw` | Reset reason, observed host-alive flag, shutdown counter and firmware label; retained diagnostic strings. Required in event trailers, optional in status. |

Unknown enum values in every core field are unknown, never healthy.

A board should map only conditions it actually measures into this vocabulary.
For example, a single-input UPS can report `power=holdup` while its battery is
supporting the host and omit the unused input and unsupported thermal fields.
Its firmware remains responsible for protection and shutdown policy. Extending
this vocabulary or adapting a different UPS protocol needs separate consumer
support; the reader does not infer electrical behavior from arbitrary keys.

### Alignment with existing power-device names

The semantic names below follow NUT and USB HID Power Device terminology where
the quantities mean the same thing. The wire aliases stay unchanged: dotted
NUT names are not new wire keys. This table defines vocabulary and possible
adapter mappings, not automatic NUT status flags or a HID descriptor.

| Semantic name | Wire representation | Meaning and mapping limits |
| --- | --- | --- |
| `device.uptime` | `up` | Elapsed seconds; status and event clock origins may differ. |
| `ups.firmware` | `fw` | Firmware label; opaque text. |
| `input.voltage`, `input.current` | profile bank V/A components | Per-input voltage/current in V/A, matching HID Voltage/Current quantities. Mapping two inputs to one NUT input loses information. |
| `battery.temperature` | profile reserve temperature | Degrees C, matching HID Temperature after unit conversion. `na`, `uncal`, missing or invalid is unknown. |
| `ups.realpower` | profile `load` in W | Real power only; do not map to NUT `ups.load` (percent) or apparent power. |
| input supplying / reserve discharging | `power=ok` / `holdup` | Similar to OL / OB only when the board's source topology supports that interpretation. A DC input is not necessarily utility mains. |
| weak input | `power=low` | Not NUT LB or HID BelowRemainingCapacityLimit: no remaining charge measurement is implied. |
| shutdown requested | `sbc=shutdown_requested[:cause]` | Related to HID ShutdownImminent; not a command, and not by itself NUT FSD (forced shutdown policy). |

There is no charge percentage or estimated runtime. Unknowns must never become
zero charge, full charge or a healthy state. Bank temperatures describe inputs,
not necessarily battery cells. Linux `power_supply` adapters would convert V/A
to microvolts/microamps and C to tenths of a degree; no kernel device or adapter
is defined here.

References: [NUT variable vocabulary](https://networkupstools.org/docs/developer-guide.chunked/apas02.html),
[USB HID Power Device usages](https://www.usb.org/sites/default/files/pdcv11.pdf),
[Linux power supply units](https://docs.kernel.org/power/power_supply_class.html).

## 3. Two-input/reserve board profile

Profile identifier: `dual-input-reserve-v1`. Emitters should include
`profile=dual-input-reserve-v1` in status. For legacy emitters without this key,
the profile keys below are globally reserved in wire v1 with exactly these
meanings; other boards must not reuse them for different meanings. An unknown
explicit profile remains unknown and must not imply this board's protection.
Receivers preserve all bounded unknown keys as strings without interpreting
or rejecting the frame. Consumers must not infer healthy protection from them.

Core keys and the profile keys documented here are reserved globally. New
vendor/board-specific keys use `x_<owner>_<name>`, with a stable owner token
and the existing ASCII key grammar and 31-byte bound; for example
`x_example_input`. Do not repurpose another owner's keys. New standardized
keys require a documented meaning and must not collide with reserved keys.

| Profile field | Meaning |
| --- | --- |
| `armed` | `0`: protection is not armed (development mode); `1`: armed. This is a board report, not host qualification. |
| `pack_cal` | `none`: uncalibrated; `datasheet`: estimated from datasheet constants. Other values are retained without a calibration guarantee. |
| `gaps`, `gaps2` | Protection limitations, using the bit grammar in the board profile below. Missing/unknown protection information must not imply full protection. |

The sensor identifiers `a`, `b` and `pack` refer to input A, input B and the reserve pack.
All values remain strings. Unknown enum values/flag bits mean unknown, not
healthy. Decimal measurements carry suffixes V, A and C; `na` is unavailable,
`uncal` is an uncalibrated temperature. Negative currents/temperatures are
valid. Decimal measurements use an optional minus sign, decimal digits, an optional
fraction (`.` followed by digits), then the unit suffix. Bank/pack flags use
two hex digits; unknown set bits provide no protection assurance. Hex flags
are bit sets, not decimal counters.

- `a`, `b`: `state[:cause]/voltage/current/temperature/flags-hex`.
  States: absent, present, healthy, sagging, standing_down, stood_down,
  recovering, fault. Causes: none, thermal, sag, holdup, pack_overtemp.
  Bank flag bits 0..7: sink, overvolt, reverse, overload, probe, latched,
  command, sense.
- `pack`: `state/temperature/flags-hex`; states filling, ready, discharging,
  fault. Pack flag bits 0..6: probe, uncal, blind, overtemp, assumed,
  untrusted (supply not proven), jump.
- `sbc`: `state[:cause]`; states run, shutdown_requested, rock_off,
  wait_power, main_off; same causes as banks. `rock_off` means the host
  computer is powered off; it is a historical wire spelling.
- `gaps` and `gaps2`: four hex digits each; combined mask is
  `gaps | (gaps2 << 16)`, after decoding both as unsigned hexadecimal.
  Combined bits 0..17: unarmed, pack_uncal, pack_est, pack_probe, a_probe,
  b_probe, blind, no_alive, shdn, nvs, wdt, skip, loop, blind_start,
  pack_flaky, sink, supply_unproven, pack_jump. Each set bit denotes missing
  or weaker protection; zero is not a qualification claim.

The board firmware monitors electrical/thermal limits and controls its own
protective actions independently of the host reader. This table defines the
public meanings; consumers need no firmware source. Unknown flags remain
unknown. Consumers must tolerate future additions.


`load` is real power with a W suffix. `last_shutdown`, `pack_charge`, `fan`
and `start` are diagnostic strings; their absence or unfamiliar values imply
no assurance. The profile defines no battery charge gauge. A simpler board
can omit the entire profile and still emit core/framing fields.

## Versioning

Document versions use semantic versioning independently of the `OSB1` wire
prefix. Corrections/clarifications are patch releases; compatible optional
keys, new profiles and enum/flag additions are minor releases. Receivers must
preserve bounded unknown keys and treat unfamiliar enum values/flag bits as
unknown, so these additions never silently establish health. Changing an
existing key's meaning, unit or field format, required fields, framing, CRC,
bounds or ordering rules requires a new wire major prefix (`OSB2` for v2).
A profile with incompatible meanings needs a new profile identifier and new
keys wherever globally reserved v1 keys would otherwise change meaning.

## Conformance vectors and reference decoder

[Vectors](../mkosi/runtime/power-link/fixtures/vectors/README.md) contain exact
wire lines with expected decoded state after each line. They include the
same-kind and first-kind restart rules, plus uptime rollover. Separate
semantic cases cover core power/thermal vocabulary and profile protection
and temperature quality. A zero gap mask means only no reported gaps, never
hardware qualification. The C test adapter invokes the production
parser; the independent Python reference decoder uses only the standard library
and runs with `python3 -I`. Both run under `make -C mkosi/runtime/power-link check`.
Python is host-only and is not installed on the device.

## Security and discovery

There is no authentication or confidentiality. CRC detects corruption, not a
malicious peer. USB identity is a discovery preset, not protocol identification.
The common `303a:1001`, interface `00` preset is shared by unrelated devices;
use a dedicated connection or an explicitly configured identity/path. Never
probe arbitrary serial ports. Opening a tty can assert DTR/RTS, echo received
bytes before raw mode, or trigger bootloader behavior even through a read-only
file descriptor. A reader must never send bytes or modem-control commands;
USB control transfers and electrical silence still need qualification.

Unknown protection-gap bits mean reduced/unknown protection. Host software
must not turn telemetry into power commands. Firmware retains protection and
shutdown policy independently of the reader. Bound input, discard malformed
frames, and calculate freshness on the host's monotonic clock.

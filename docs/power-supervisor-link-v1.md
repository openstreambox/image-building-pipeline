# Power supervisor link v1

Version 1.0.0. Text licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
Decoder code and vectors use the repository license. Initial version: framing,
core vocabulary and two-input/reserve profile; no wire changes.

## 1. Framing

`OSB1` is the historical wire identifier, retained byte-for-byte for firmware
compatibility; it is not a vendor check or a requirement to use a named board.
Implementers may emit these ASCII frames from any USB serial microcontroller.
No host commands, handshake or command responses are required. Emit status
at least once per second for the five-second freshness window. This is an open specification, not a USB class or an Internet standard. Use a new boot
identifier on each restart and a shared increasing sequence across frame kinds.
The reader preserves the tty baud setting and configures raw input; USB CDC
implementations must not require a host baud-rate handshake. A physical UART
bridge needs its baud setting configured separately. Unsupported measurements
should be omitted or use the documented unavailable values, never fabricated as healthy.

ASCII lines end in LF; the whole line including LF is at most 512 bytes.
Non-OSB1 text is ignored and counted. `waiting for download` on non-OSB text marks bootloader
mode (best effort: opening after the one-shot ROM banner can show silent).
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

Sequence spans status and events. A decrease in validated `up` compared with the previous accepted frame of the
same kind (status with status, EVT with EVT) within a repeated boot id immediately establishes a restart, retaining even the first boot event. Forward modulo-2^32 deltas count missing
lines; wrap is continuous. Duplicates and backwards/half-range deltas are
rejected without refreshing status. Three consecutive CRC-valid backward
frames with sequence numbers increasing by one establish a restart even if
boot repeats. Duplicates or a forward frame reset that candidate; the first
two backward frames remain rejected. Recovery increments restarts, invalidates
old status and does not add a giant missed-lines gap. A changed boot increments restarts and
invalidates current status immediately, even if first observed in an event.
Only a valid status refreshes `rx_mono_ms` and replaces fields. Events never
patch status fields. Profile fields are retained; unknown protection-gap bits must never be
interpreted as full protection.

The two uptime histories are cleared together on any detected restart. A first
frame of a kind has no previous same-kind uptime and cannot prove a decrease.
Only accepted frames update that history. Firmware millisecond clocks may wrap
after 49.7 days, yielding a benign restart indication. A repeated boot id with
no observable same-kind decrease and no recoverable sequence regression cannot
be distinguished from the same life; use distinct boot ids.

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
| `power` | `low`: input power is weak; `holdup`: reserve supplies the box. Other values do not trigger those warnings. |
| `redundant` | `0`: no confirmed backup input; `1`: confirmed backup. Omit when unknown. |
| `thermal` | `normal`, `warm`, `hot`, `critical`, `shutdown`: the board's warning level, not a host temperature threshold. |
| `hot` | Comma-separated sensor identifiers affected by that level, or `none`; the profile defines their locations. |
| `sbc` | Host power state, including `run` and `shutdown_requested[:cause]`; descriptive only, never a host command. |
| `rst`, `alive`, `shutdowns`, `fw` | Reset reason, observed host-alive flag, shutdown counter and firmware label; retained diagnostic strings. Required in event trailers, optional in status. |

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
| `device.uptime` | `up` | Seconds, with separate status and event origins as above. |
| `ups.firmware` | `fw` | Firmware label; opaque text. |
| `input.voltage`, `input.current` | profile bank V/A components | Per-input voltage/current in V/A, matching HID Voltage/Current quantities. |
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

| Profile field | Meaning |
| --- | --- |
| `armed` | `0`: protection is not armed (development mode); `1`: armed. This is a board report, not host qualification. |
| `pack_cal` | `none`: uncalibrated; `datasheet`: estimated from datasheet constants. Other values are retained without a calibration guarantee. |
| `gaps`, `gaps2` | Protection limitations, using the bit grammar in the board profile below. Missing/unknown protection information must not imply full protection. |

The sensor identifiers `a`, `b` and `pack` refer to input A, input B and the reserve pack.
All values remain strings. Unknown enum values/flag bits mean unknown, not
healthy. Decimal measurements carry suffixes V, A and C; `na` is unavailable,
`uncal` is an uncalibrated temperature. Negative currents/temperatures are
valid. Hex flags are bit sets, not decimal counters.

- `a`, `b`: `state[:cause]/voltage/current/temperature/flags-hex`.
  States: absent, present, healthy, sagging, standing_down, stood_down,
  recovering, fault. Causes: none, thermal, sag, holdup, pack_overtemp.
  Bank flag bits 0..7: sink, overvolt, reverse, overload, probe, latched,
  command, sense.
- `pack`: `state/temperature/flags-hex`; states filling, ready, discharging,
  fault. Pack flag bits 0..6: probe, uncal, blind, overtemp, assumed,
  untrusted (supply not proven), jump.
- `sbc`: `state[:cause]`; states run, shutdown_requested, rock_off,
  wait_power, main_off; same causes as banks.
- `gaps` and `gaps2`: four hex digits each; combined mask is
  `parseInt(gaps,16) + 65536 * parseInt(gaps2,16)`.
  Combined bits 0..17: unarmed, pack_uncal, pack_est, pack_probe, a_probe,
  b_probe, blind, no_alive, shdn, nvs, wdt, skip, loop, blind_start,
  pack_flaky, sink, supply_unproven, pack_jump. Each set bit denotes missing
  or weaker protection; zero is not a qualification claim.

These names mirror the protective firmware's status formatter, enum names,
Flag/PackFlag and Gap definitions. Consumers must tolerate future additions.


`load` is real power with a W suffix. `last_shutdown`, `pack_charge`, `fan`
and `start` are diagnostic strings; their absence or unfamiliar values imply
no assurance. The profile defines no battery charge gauge. A simpler board
can omit the entire profile and still emit core/framing fields.

## Conformance vectors and reference decoder

[Vectors](../mkosi/runtime/power-link/fixtures/vectors/README.md) contain exact
wire lines with expected decoded state after each line. They include the
corrected same-kind restart rule. The C test adapter invokes the production
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

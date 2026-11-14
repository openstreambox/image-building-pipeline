# Read-only supervisor telemetry

`mkosi/runtime/power-link/` provides `supervisor-power-link`, a libc-only Linux service.
It reads an external power supervisor over USB serial. It has no command channel,
never opens the serial port for writing, and issues no modem-control ioctls. It does not
handle shutdown GPIOs or control power. CeraUI reads its files independently.

Any power board or UPS HAT can implement this documented interface without
using a particular board design. The OpenStreamBox power board is one example
implementation. This is a protocol adapter, not a driver for arbitrary existing
UPS protocols; I2C-only HATs need a firmware/serial bridge. Missing measurements
remain unknown, so a one-input board need not invent a second battery bank.
With the matching [CeraUI change](https://github.com/openstreambox/CeraUI/pull/72),
a CeraLive box can show power/battery warnings and reported temperatures.
Without matching hardware the reader stays idle (apart from publishing its
availability heartbeat); it does not alter streaming or power policy.

## Build and installation

Run the focused host tests (a C compiler and Python 3 are host-only requirements):

```sh
nice -n 10 make -C mkosi/runtime/power-link check
```

Build with the target's libc/compiler, then stage into the target rootfs before
sealing an image. `CC`, `CPPFLAGS`, `CFLAGS`, and `LDFLAGS` can select a cross
toolchain and sysroot. Never install a host-architecture binary into another
architecture's rootfs.

```sh
make -C mkosi/runtime/power-link CC=aarch64-linux-gnu-gcc
make -C mkosi/runtime/power-link DESTDIR=/path/to/target-rootfs install
```

Installation stages the executable, unit, sysusers definition, udev rule and
boot enablement through `systemctl --root enable`. With DESTDIR set it does
not start a host service; without DESTDIR, install enables the unit on the
build host. This is an explicit staging target; existing image builds do not automatically include it. No
compiler or Python runtime is needed on the target. Before a live start the
`supervisor-power` account must exist (`systemd-sysusers` processes its definition at
boot), and udev must have applied the rule. No service is deployed by the tests.

The unit runs as `supervisor-power`, without capabilities, network access, or writable
system paths. It can write only its runtime and persistent directories. Device
cgroup access is read-only for the ttyACM class; DAC restricts that account to
matching supervisor interfaces, without granting membership in `dialout`.
CPU, memory, tasks and descriptors are bounded. PrivateDevices is deliberately
not used because it hides the USB serial device.

Discovery scans sysfs for native USB identity `303a:1001`, interface `00`.
No match means absent; two or more matches close the reader and publish
`ambiguous:true`, without choosing by enumeration order. The udev rule also
prevents ModemManager probing that interface. USB identity is not authentication:
only valid OSB1 status frames establish telemetry. This identity is shared by
other boards; use a dedicated connection.

For a different USB identity, install a local udev rule granting only the
`supervisor-power` group read access (`MODE="0440"`) and excluding ModemManager
for that exact interface. Give it a stable `/dev/power-supervisor` symlink and
use a systemd drop-in:

```ini
[Service]
ExecStart=
ExecStart=/usr/libexec/supervisor-power-link --device /dev/power-supervisor
```

The shipped device cgroup permits ttyACM only. A ttyUSB adapter additionally
needs `DeviceAllow=char-ttyUSB r` in that drop-in. Never match all serial ports
or add the account to dialout. The default identity is a transport preset, not
proof that the attached device speaks this protocol. Other USB devices sharing
it can be opened, so review the rule before enabling on a general-purpose host.

A single matched device with an initial open/setup failure publishes silent
while pending; only a second consecutive failed attempt publishes error. A
successful attempt or disappearance clears this debounce. Post-open setup
failures retry after 1, 2, 4, 8, 16, then 30 seconds (capped), reducing repeated
open-time driver side effects; success or a changed/disappeared device resets
backoff. Ordinary pre-open failures retry each second.

The port stays open with `O_RDONLY|O_NOCTTY|O_NONBLOCK|O_CLOEXEC`, `TIOCEXCL`, raw
input, no HUPCL and no hardware flow control. There are no modem-control ioctls
or device writes by this process. Linux nevertheless asserts DTR/RTS when opening
a nonzero-baud tty; cdc-acm can send SET_LINE_CODING at tcsetattr. There is an
ECHO/ICANON window between open and raw configuration: arriving bytes may be
transmitted back by n_tty. O_RDONLY and DeviceAllow do not prevent these driver
side effects. Clearing HUPCL reduces close-time transitions; O_NOCTTY prevents
acquiring a controlling terminal. Neither removes the first-open window.
Before qualification, capture the first open after host boot and after enumeration with usbmon and
check control transfers, echoed bytes, and reset/download behavior on open and
close. Field firmware ignores RX; that is not proof of electrical silence.
Kernel/USB-driver behavior on open/close still requires bench
verification; a PTY cannot prove that a board will not reset or enter download
mode. Enumeration, reset behavior, power isolation and thermal protection are
not qualified by host tests.

## Open USB serial power-supervisor interface (version 1)

`OSB1` is the historical wire identifier, retained byte-for-byte for firmware
compatibility; it is not a vendor check or a requirement to use a named board.
Implementers may emit these ASCII frames from any USB serial microcontroller.
No host commands, handshake or command responses are required. Emit status
at least once per second for the five-second freshness window. Use a new boot
identifier on each restart and a shared increasing sequence across frame kinds.
The reader preserves the tty baud setting and configures raw input; USB CDC
implementations must not require a host baud-rate handshake. A physical UART
bridge needs its baud setting configured separately. Unsupported measurements
should be omitted or use the documented unavailable values, never fabricated as healthy.

ASCII lines end in LF; the whole line including LF is at most 512 bytes.
Non-OSB1 text is ignored and counted. `waiting for download` on non-OSB text marks bootloader
mode (best effort: opening after the one-shot ROM banner can show silent).
Only an `OSB<digits> ` version prefix marks unknown_version. Overlong
input is discarded through the next LF, using bounded memory. Disconnect drops
any partial line. Embedded NUL/control bytes are rejected.

CRC is the final ` crc=HHHH` field: CRC-16/CCITT-FALSE (polynomial 0x1021,
initial 0xffff, no reflection or final XOR) over all preceding bytes, excluding
the separator before crc and LF. `123456789` produces `29B1`.

Status uses `OSB1 key=value ...`; events use `OSB1 EVT up=... human text ...`.
EVT has `up=<uint32>` followed by opaque printable text and the fixed trailing
fields `seq boot rst alive hot shutdowns fw`, in that order, then CRC. Parse
these seven fields from the right; key-like tokens and ` crc=` in the human
text have no field meaning. Event trailer fields cannot be reordered.

`seq` is uint32 decimal and `boot` is eight hex digits. Both are required.
Status also requires uint32 decimal `up`. Missing other fields stay unknown;
no zero/healthy defaults are synthesized. Status field order is immaterial and new
bounded key/value fields are preserved without assigning meaning. Duplicate
keys, invalid counters and malformed fields are rejected. Bounds are 48 keys,
31 bytes/key and 159 bytes/value, within the 512-byte frame limit.

Sequence spans status and events. A decrease in validated `up` within a repeated
boot id immediately establishes a restart, retaining even the first boot event. Forward modulo-2^32 deltas count missing
lines; wrap is continuous. Duplicates and backwards/half-range deltas are
rejected without refreshing status. Three consecutive CRC-valid backward
frames with sequence numbers increasing by one establish a restart even if
boot repeats. Duplicates or a forward frame reset that candidate; the first
two backward frames remain rejected. Recovery increments restarts, invalidates
old status and does not add a giant missed-lines gap. A changed boot increments restarts and
invalidates current status immediately, even if first observed in an event.
Only a valid status refreshes `rx_mono_ms` and replaces fields. Events never
patch status fields. Current firmware fields including `pack_cal`, `start`,
`gaps` and `gaps2` are retained; unknown protection-gap bits must never be
interpreted as full protection.

## CeraUI file contract: schema version 1

All paths are local to the device. Directories are 0755; published files are
0644, readable by an ordinary CeraUI account. Each file is written to a private
temporary file, flushed and renamed atomically. Readers see either the old or
new complete file. The two files are independently atomic, not a transaction.
Publication is at most once per second, including during a flood. A graceful
stop publishes `stopped`, retaining the last open_error for diagnosis. RuntimeDirectoryPreserve=yes keeps that snapshot across
stop/restart (not host reboot). Do not give another unit ownership of the
parent `/run/ceralive` via RuntimeDirectory: its cleanup could remove these
files. A runtime publication error exits and systemd restarts the writer.
Marker persistence errors instead set persist_error, log once on entry to
each failure episode and retry once per second while telemetry continues. Events are rewritten only when the ring
changes, with an empty ring published at process startup.

`/run/ceralive/power/supervisor.json` contains:

| Key | Type and meaning |
| --- | --- |
| `schema_version` | Integer `1`; consumers reject unsupported schemas. |
| `link` | `absent`, `silent`, `bootloader`, `unknown_version`, `error`, `stopped`, `ok`. Stopped means the writer has exited gracefully. Error means a matched device could not be opened/configured; it is not evidence of an unfitted board. |
| `open_error` | Linux errno integer for open/configuration failure (e.g. EACCES=13, EBUSY=16), zero otherwise. |
| `persist_error` | Boolean; expected marker could not be saved; retries continue. |
| `ambiguous` | Boolean; multiple devices matched, so none was opened. |
| `expected` | Boolean learned after the first accepted status or event, retained across reader restarts and host reboots. An absent board need not warn until expected. |
| `stale` | Boolean calculated at publication; anything except `ok` is stale. |
| `published_mono_ms` | Integer CLOCK_MONOTONIC milliseconds at each snapshot publication, including startup and stop. Heartbeat advances every second while running, even with no board. |
| `rx_mono_ms` | Integer CLOCK_MONOTONIC milliseconds of the last accepted **status**, or null before one. It is never refreshed by events or rejected input. |
| `fields` | Object of original string key/value pairs from the last accepted status, including seq/boot and all available measurements. Empty before one; fields can remain present while stale. CRC is validated, then omitted. Missing fields mean unknown. |
| `temperatures` | Object with `a`, `b`, `pack`; each has `celsius` (number or null) and `quality` (`reported`, `na`, `uncal`, `unknown`). Pack calibration provenance remains in `fields.pack_cal`. Reported does not mean calibrated or present: gate bank temperatures on bank state (absent banks may report 25 C). |
| `restarts` | Boot changes and recovered sequence regressions observed during this reader process. |
| `missed_lines` | Sum of forward sequence gaps in the same boot, across events and status. |
| `accepted_lines` | Valid, forward status and event count. |
| `rejected` | Counters: `crc`, `malformed`, `oversize`, `ignored`, `unknown_version`, `out_of_order`. All counters reset on reader restart. Normal firmware CSV rows increment ignored about once per second; do not alarm on that counter. |

**Consumers must independently calculate freshness**, even if `stale:false` is
saved in the file. First require a valid `published_mono_ms` and
`0 <= CLOCK_MONOTONIC_ms - published_mono_ms < 3000`. At exactly three seconds,
a missing/invalid heartbeat, or `link:stopped`, show unknown/unavailable even
when expected is false and the retained link is absent. A live absent snapshot
with expected false alone means no board fitted. Only then evaluate status
freshness. Current data requires all of: schema 1, link ok, stale false,
non-null rx_mono_ms, and `0 <= CLOCK_MONOTONIC_ms - rx_mono_ms < 5000`.
Missing/unreadable/invalid files mean unknown. At exactly five seconds show
unknown; never present retained fields as current. Use wall time only for
labels. This rule makes a killed or wedged writer go stale without another
write. `/run` is volatile and must not be restored across host boots.

`/run/ceralive/power/events.jsonl` holds at most the last 1000 accepted EVT
lines in this reader process, oldest first. Each JSON object has a `line`
string containing the CRC-validated wire line without LF. This is a diagnostic
ring, not a durable/auditable timeline; events can be missed across shutdowns
or reader restarts. File size is bounded by the wire limit and JSON escaping.
Do not derive current state or shutdown actions from it.

`/data/supervisor-power/expected` contains `1\n` after the first accepted frame;
absence means not yet learned. `/data` survives A/B OTA slot changes.
The service has ordering-only `After=data.mount`, with no hard mount requirement.
A privileged, failure-tolerant ExecStartPre checks mountpoint and creates the
0755 supervisor-power-owned directory only when /data is mounted. The main writer
stays sandboxed. Without /data it still publishes runtime state and skips the
persistent marker (persist_error after a frame teaches expected). Nothing
creates this directory through unordered tmpfiles on the root slot.
To intentionally forget a removed board: stop the reader, remove this marker,
then restart the reader. A live attached board will immediately teach it again.
When migrating an earlier installation, stop and disable its reader first,
copy its learned expected marker to `/data/supervisor-power/expected` with
owner supervisor-power and mode 0644, then enable the renamed reader. Never
run two readers against the same port. It is not a consumer acknowledgment store. No
last-shutdown notification acknowledgments are written by this reader; a
consumer must own its own deduplication/acknowledgment contract. No command or
control file is consumed by this service.

For host-only PTY tests, the executable accepts `--device`, `--state-dir` and
`--persistent-dir` (and `--sysfs-dir` for synthetic discovery). Production uses discovery and the paths above. Output
directories must already exist and belong to the service user (systemd creates
the runtime directory; the mount-checked prestart creates the persistent directory). No hardware is opened by `make check`.

## Bun CLOCK_MONOTONIC recipe

On Linux glibc aarch64/amd64, use Bun FFI to read the same clock as the writer
(CLOCK_MONOTONIC=1). This recipe was compared with Python clock_gettime_ns on
the host. Keep the library open for the lifetime of the consumer. Neither
performance.now() nor an assumed process.hrtime epoch is this contract.

```ts
import { dlopen, FFIType, ptr } from 'bun:ffi';
const { symbols } = dlopen('libc.so.6', {
  clock_gettime: { args: [FFIType.i32, FFIType.ptr], returns: FFIType.i32 },
});
function monotonicMs(): number {
  const ts = new BigInt64Array(2); // glibc 64-bit timespec: seconds, nanoseconds
  if (symbols.clock_gettime(1, ptr(ts)) !== 0) throw new Error('clock_gettime');
  return Number(ts[0] * 1000n + ts[1] / 1_000_000n);
}
```

A host-only PTY run of the actual C writer produced `rx_mono_ms: 213574345`.
Calling the function above in a separate Bun process returned `213575366`:
`age_ms = 213575366 - 213574345 = 1021`, so the sample was fresh (below 5000 ms).
These are observed CLOCK_MONOTONIC timestamps, not process-start-relative
values. Read a new timestamp on each check; do not reuse these example numbers.
The executable used a fake serial source; no hardware was involved.

If the clock call is unavailable, show unknown; do not substitute wall time.

## Measurement field grammar

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


## Warning fields for compatible consumers

The framing layer requires only `up`, `seq` and `boot` in a status. Meaningful
power warnings also require the corresponding status fields below; a valid
minimal frame alone does not establish healthy power or complete protection.
There is no battery percentage or runtime estimate in version 1.

| Field | Meaning |
| --- | --- |
| `power` | `low`: input power is weak; `holdup`: reserve supplies the box. Other values do not trigger those warnings. |
| `redundant` | `0`: no confirmed backup input; `1`: confirmed backup. Omit when unknown. |
| `thermal` | `normal`, `warm`, `hot`, `critical`, `shutdown`: the board's warning level, not a host temperature threshold. |
| `hot` | Comma-separated `a`, `b`, `pack` affected by that level, or `none`. |
| `armed` | `0`: protection is not armed (development mode); `1`: armed. This is a board report, not host qualification. |
| `sbc` | Host power state, including `run` and `shutdown_requested[:cause]`; descriptive only, never a host command. |
| `pack_cal` | `none`: uncalibrated; `datasheet`: estimated from datasheet constants. Other values are retained without a calibration guarantee. |
| `gaps`, `gaps2` | Protection limitations, using the bit grammar above. Missing/unknown protection information must not imply full protection. |
| `rst`, `alive`, `shutdowns`, `fw` | Reset reason, observed host-alive flag, shutdown counter and firmware label; retained diagnostic strings. Required in event trailers, optional in status. |

A board should map only conditions it actually measures into this vocabulary.
For example, a single-input UPS can report `power=holdup` while its battery is
supporting the host and omit the unused input and unsupported thermal fields.
Its firmware remains responsible for protection and shutdown policy. Extending
this vocabulary or adapting a different UPS protocol needs separate consumer
support; the reader does not infer electrical behavior from arbitrary keys.

For a synthetic minimal status, this host-side example generates a complete
frame (including CRC); it requires no board or command channel:

```python
import binascii
body = b"OSB1 up=1 power=holdup seq=0 boot=12345678"
print(body.decode() + f" crc={binascii.crc_hqx(body, 0xffff):04X}")
```

The existing firmware fixtures exercise a richer two-input/reserve-pack profile.
They are interoperability examples, not required board topology.

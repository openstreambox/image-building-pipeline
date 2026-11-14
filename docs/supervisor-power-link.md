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
backoff. Discovery continues every second during backoff; only opening is delayed. Ordinary pre-open failures retry each second.

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

## Wire interface

The versioned [Power supervisor link v1](power-supervisor-link-v1.md) defines
framing, core vocabulary and the two-input/reserve board profile. Shared
[conformance vectors](../mkosi/runtime/power-link/fixtures/vectors/README.md)
are checked by the C reader and an independent host-only Python decoder.

## CeraUI file contract: schema version 1

All paths are local to the device. Directories are 0755; published files are
0644, readable by an ordinary CeraUI account. Each file is written to a private
temporary file, flushed and renamed atomically. Readers see either the old or
new complete file. The two files are independently atomic, not a transaction.
Publication is once per second (heartbeat), plus once at stop, including during a flood. A graceful
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
| `persist_error` | Boolean; expected marker is unavailable at startup or could not be saved; retries continue. |
| `ambiguous` | Boolean; multiple devices matched, so none was opened. |
| `expected` | Boolean learned after the first accepted status or event, retained across reader restarts and host reboots. An absent board need not warn until expected. |
| `stale` | Boolean calculated at publication; anything except `ok` is stale. |
| `published_mono_ms` | Integer CLOCK_MONOTONIC milliseconds at each snapshot publication, including startup and stop. Heartbeat advances every second while running, even with no board. |
| `rx_mono_ms` | Integer CLOCK_MONOTONIC milliseconds of the last accepted **status**, or null before one. It is never refreshed by events or rejected input. |
| `fields` | Object of original string key/value pairs from the last accepted status, including seq/boot and all available measurements. Empty before one; fields can remain present while stale. CRC is validated, then omitted. Missing fields mean unknown. |
| `temperatures` | Object with `a`, `b`, `pack`; each has `celsius` (number or null) and `quality` (`reported`, `na`, `uncal`, `unknown`). Pack calibration provenance remains in `fields.pack_cal`. Reported does not mean calibrated or present: gate bank temperatures on bank state (absent banks may report 25 C). |
| `restarts` | Boot changes, same-kind uptime decreases and recovered sequence regressions observed during this reader process. The uint32 millisecond firmware clocks wrap after 49.7 days and can cause a benign restart count. |
| `missed_lines` | Sum of forward sequence gaps in the same boot, across events and status. |
| `accepted_lines` | Valid, forward status and event count. |
| `rejected` | Counters: `crc`, `malformed`, `oversize`, `ignored`, `unknown_version`, `out_of_order`. All counters reset on reader restart. Normal firmware CSV rows increment ignored about once per second; do not alarm on that counter. |

Link state detail:

| State | Meaning |
| --- | --- |
| `silent` | The device is open with no fresh status, or an open is pending retry. |

**Consumers must independently calculate freshness**, even if `stale:false` is
saved in the file. Check `schema_version` first; require schema 1. Then require a valid `published_mono_ms` and
`0 <= CLOCK_MONOTONIC_ms - published_mono_ms < 3000`. If the heartbeat is missing or invalid,
its age is 3000 ms or more, or `link` is `stopped`, show unknown/unavailable even
when expected is false and the retained link is absent. A live absent snapshot
with expected false and persist_error false means no board fitted. Only then evaluate status
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
persistent marker (persist_error from startup). Nothing
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

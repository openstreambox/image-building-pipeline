# Read-only supervisor telemetry

`mkosi/runtime/power-link/` provides `osb-power-link`, a libc-only Linux service.
It reads the supervisor's native USB serial stream. It has no command channel,
never opens the serial port for writing, and never sets DTR/RTS. It does not
handle shutdown GPIOs or control power. CeraUI reads its files independently.

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
boot enablement symlink. It does not start a host service. This is an explicit
staging target; existing image builds do not automatically include it. No
compiler or Python runtime is needed on the target. Before a live start the
`osb-power` account must exist (`systemd-sysusers` processes its definition at
boot), and udev must have applied the rule. No service is deployed by the tests.

The unit runs as `osb-power`, without capabilities, network access, or writable
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

The port stays open with `O_RDONLY|O_NOCTTY|O_NONBLOCK|O_CLOEXEC`, `TIOCEXCL`, raw
input, no HUPCL and no hardware flow control. There are no modem-control ioctls
or device writes. Kernel/USB-driver behavior on open/close still requires bench
verification; a PTY cannot prove that a board will not reset or enter download
mode. Enumeration, reset behavior, power isolation and thermal protection are
not qualified by host tests.

## OSB1 wire contract

ASCII lines end in LF; the whole line including LF is at most 512 bytes.
Non-OSB1 text is ignored and counted. `waiting for download` marks bootloader
mode; an `OSB` prefix with another version marks unknown_version. Overlong
input is discarded through the next LF, using bounded memory. Disconnect drops
any partial line. Embedded NUL/control bytes are rejected.

CRC is the final ` crc=HHHH` field: CRC-16/CCITT-FALSE (polynomial 0x1021,
initial 0xffff, no reflection or final XOR) over all preceding bytes, excluding
the separator before crc and LF. `123456789` produces `29B1`.

Status uses `OSB1 key=value ...`; events use `OSB1 EVT up=... human text ...`.
`seq` is uint32 decimal and `boot` is eight hex digits. Both are required.
Status also requires uint32 decimal `up`. Missing other fields stay unknown;
no zero/healthy defaults are synthesized. Field order is immaterial and new
bounded key/value fields are preserved without assigning meaning. Duplicate
keys, invalid counters and malformed fields are rejected. Bounds are 48 keys,
31 bytes/key and 159 bytes/value, within the 512-byte frame limit.

Sequence spans status and events. Forward modulo-2^32 deltas count missing
lines; wrap is continuous. Duplicates and backwards/half-range deltas are
rejected without refreshing status. A changed boot increments restarts and
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
stop publishes absent. An I/O error exits and systemd restarts the writer.

`/run/ceralive/power/supervisor.json` contains:

| Key | Type and meaning |
| --- | --- |
| `schema_version` | Integer `1`; consumers reject unsupported schemas. |
| `link` | `absent`, `silent`, `bootloader`, `unknown_version`, `ok`. |
| `ambiguous` | Boolean; multiple devices matched, so none was opened. |
| `expected` | Boolean learned after the first accepted status or event, retained across reader restarts and host reboots. An absent board need not warn until expected. |
| `stale` | Boolean calculated at publication; anything except `ok` is stale. |
| `rx_mono_ms` | Integer CLOCK_MONOTONIC milliseconds of the last accepted **status**, or null before one. It is never refreshed by events or rejected input. |
| `fields` | Object of original string key/value pairs from the last accepted status, including seq/boot and all available measurements. Empty before one; fields can remain present while stale. CRC is validated, then omitted. Missing fields mean unknown. |
| `temperatures` | Object with `a`, `b`, `pack`; each has `celsius` (number or null) and `quality` (`reported`, `na`, `uncal`, `unknown`). Pack calibration provenance remains in `fields.pack_cal`. Reported does not mean calibrated. |
| `restarts` | Boot changes observed during this reader process. |
| `missed_lines` | Sum of forward sequence gaps in the same boot, across events and status. |
| `accepted_lines` | Valid, forward status and event count. |
| `rejected` | Counters: `crc`, `malformed`, `oversize`, `ignored`, `unknown_version`, `out_of_order`. All counters reset on reader restart. |

**Consumers must independently calculate freshness**, even if `stale:false` is
saved in the file. Current data requires all of: schema 1, link ok, stale false,
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

`/var/lib/osb-power/expected` contains `1\n` after the first accepted frame;
absence means not yet learned. It is not a consumer acknowledgment store. No
last-shutdown notification acknowledgments are written by this reader; a
consumer must own its own deduplication/acknowledgment contract. No command or
control file is consumed by this service.

For host-only PTY tests, the executable accepts `--device`, `--state-dir` and
`--persistent-dir` (and `--sysfs-dir` for synthetic discovery). Production uses discovery and the paths above. Output
directories must already exist and belong to the service user (systemd creates
them). No hardware is opened by `make check`.

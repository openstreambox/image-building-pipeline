# Power supervisor link v1 conformance vectors

Each `.txt` is an exact byte stream (including LF); its same-named `.json`
contains the expected decoded state after each line, in order. Start each
stream with a fresh decoder. Do not regenerate expected results from a decoder.
The fixtures use synthetic data and include deliberate NUL/control bytes.

The host-only C adapter feeds the production parser and serializes its state.
`reference_decoder.py` independently implements framing and ordering in Python
using only the standard library. `test_vectors.py` runs both against every
expectation, using `python3 -I` for the reference implementation. Run through
`make -C mkosi/runtime/power-link check`; no hardware or serial access is used.
The Python decoder can also read a `.txt` on stdin and print JSON snapshots.

Expected keys:

- `accepted`, `restarts`, `missed`: cumulative accepted frames, detected
  restarts and forward sequence gaps.
- `crc`, `malformed`, `oversize`, `ignored`, `unknown_version`, `out_of_order`:
  cumulative rejection counters.
- `seq`, `boot`: last accepted sequence and canonical lowercase boot id;
  initially zero/empty, distinguished by `accepted == 0`.
- `have_status`, `rx_ms`, `fields`: status validity, last status receive time
  and original string fields. Receive time advances by 1000 ms per input line,
  starting at 1000. Rejected frames/events do not refresh it. A restart
  invalidates status but retains its diagnostic fields/time until replacement.
- `events`: accepted raw event lines without LF, oldest first (1000 maximum).
- `link`: parser availability with the source treated as connected. This does
  not test discovery, persistence or the service heartbeat.

Coverage includes minimal/rich status, original string spelling and field
order, opaque EVT text containing ` crc=`, bad CRC, duplicate/missing/bounded
fields, counter overflow, malformed trailers, NUL/control/CRLF rejection,
ROM text, unsupported versions, maximum/overlong lines and recovery. Stateful
streams cover offset uptime clocks, same-kind decreases and clock reset,
changed boot in an event, modulo sequence wrap/gaps, duplicate/half-range
rejection and three-frame sequence recovery. The separate firmware simulation
fixture and service tests remain in the same gate.

`../semantics.json` defines fixed vocabulary/profile cases (status fields to
interpretation). The adapters' `--semantics` mode checks these separately from
framing counters, using the same C interpretation published by the service.
Only `power=ok` yields `power_healthy:true`; `none`, missing and unfamiliar
values never do. Unknown gap bits mean reduced protection, missing/invalid
masks mean unknown, and a zero mask means only no reported gaps. Explicit
unknown profiles have unknown profile interpretation; legacy omitted profiles
use the globally reserved v1 meanings. Temperature quality is tested for
reported, unavailable, uncalibrated and invalid values; absent banks stay unknown.

Run `python3 -I test_fuzz.py` after building `test-vectors` for a reproducible,
single-worker C/Python comparison: three fixed seeds, 400 streams each. It
compares every framing snapshot and semantic interpretation, with mutations
covering CRC, byte rejection, prefix classification, boot/uptime and sequence
boundaries. It is a differential check, separate from the fixed expectations.

`../published-semantics.txt` and its expected JSON check that a boot event
invalidates a previously healthy status in `--published-semantics` mode.
The pure `--semantics` mapping remains available independently of freshness.
The sparse-event rollover stream checks that a status rollover clears old
event uptime history without invalidating status or counting a restart.

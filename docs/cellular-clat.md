# IPv4 service on IPv6-only cellular links

Some SIMs, including T-Mobile US, provide no native IPv4 address. IPv4-only
stream receivers and IPv4 hotspot clients then need translation on the box.
`ceralive-clat.service` supplies this using Debian's packaged tayga. It does not
change modem profiles, reconnect a modem, or use NetworkManager dispatchers.

The image service reads NetworkManager D-Bus device state (activated modem
interfaces only). A native global IPv4 address excludes the link. A stable,
non-temporary IPv6 source, a known IPv6 router and per-link DNS servers are
required. The router is, in order: the `IP6Config.Gateway` NetworkManager
publishes; the link's default route in the main table (its gateway, or none);
the RA sender the kernel recorded with the router flag in the link's neighbour
table (an entry whose reachability has not failed wins, then link-local, then
the lowest address); or no next hop on an ARP-less (raw-IP) link. A profile
with `ipv6.never-default` gets neither a gateway on D-Bus nor a main-table
default, but its RAs still reach the neighbour table, also with `accept_ra=0`
as NetworkManager sets it. An Ethernet-like link with no router known yet is
not used. The service never adds an IPv6 route to the main table.
IPv6 DNS comes from `IP6Config.Nameservers` (`aay`),
as specified by the [NM 1.52 introspection XML](https://github.com/NetworkManager/NetworkManager/blob/1.52.0/introspection/org.freedesktop.NetworkManager.IP6Config.xml)
and [NM 1.58 XML](https://github.com/NetworkManager/NetworkManager/blob/1.58.0/introspection/org.freedesktop.NetworkManager.IP6Config.xml).
Link-local resolver scope stays bound to that interface. D-Bus changes
trigger reconciliation, with a ten-second retry for failed discovery or a dead
translator. Manager disappearance withdraws all grants.

The service sends an interface/source-bound AAAA query for `ipv4only.arpa` to
that link's IPv6 DNS servers. Before the first query it installs the link's
IPv6 default (via that router) in the link's own table `46000 + ifindex`, and
the rule `from <source> oif <link> lookup <table>` at priority
`46000 + ifindex`. That rule comes after the main and default tables, so it
only applies when the main table has no route for the query through that link,
as on a never-default link with an off-link resolver. Both are journalled like
every other owned resource, stay for the 60-second revalidation while
translating and are withdrawn when discovery fails, so a link without DNS64
keeps only the snapshot. Both RFC 7050 sentinel addresses must confirm one
RFC 6052 prefix (/32, /40, /48, /56, /64 or /96). Missing, truncated, ambiguous
or inconsistent responses fail closed. `64:ff9b::/96` is used only when that
same discovery confirms it; there is no guessed fallback. DNS64 is evidence
from the network, not authenticated proof of an operator's identity. Prefixes
are revalidated every 60 seconds and when the address/gateway/DNS grant
changes. A changed prefix withdraws translation until the next retry; existing
flows are not migrated. A failed refresh retains the current translation; three
consecutive failures, spaced 60 seconds apart, withdraw it. A successful refresh
resets the failure count. Each reconciliation repairs owned routes, including
after an interface down/up with an unchanged grant. A route repair error withdraws
only that link and leaves other links reconciling. Unexpected synchronization
errors are logged and the ten-second retry remains scheduled. Status-write
faults are logged without withdrawing a working translator. Teardown first
atomically publishes `unavailable`, before signalling tayga or
removing any resource. If that invalidation cannot be written, teardown is
deferred and retried; the last snapshot still expires. Teardown continues after
cleanup command timeouts and keeps the recovery journal. Nonzero undo exits
are failures too: only a successful, resource-specific kernel query proving
absence makes a failed delete safe to forget. An unreadable/failed query keeps
the inverse. Failed inverses retain their original order and are replayed on
subsequent reconciliations, even if the modem's grant never returns. The
snapshot remains `error` and forwarding restoration is deferred until cleanup
settles. A failure to stop the child retains all resource inverses. Before
retrying a
still-wanted link, startup replays that journal ahead of discovery and ownership
checks. An interrupted replay keeps the journal for the next retry; only a
completed replay removes it.
Reconciliation is scheduled every ten seconds, but synchronous discovery and
route work can delay publication across links. A delayed observation never
extends its lease: availability expires after 30 seconds, even if translation
still works. Readers must tolerate a safe, temporary withdrawal under load.

Each link gets `clat<ifindex>`, an IPv4 /32 in reserved service space
`10.254.0.0/19`, and a private IPv6 mapping in `fd46:4:4::/48`.
The space is 32 blocks of 255 addresses: block `(ifindex - 1) / 255`, host
`(ifindex - 1) % 255 + 1`, so no address ends in `.0` (consumers reject it).
Ifindex 1-255 keep `10.254.0.<ifindex>`; 256 gets `10.254.1.1` and 512 gets
`10.254.2.2`. Reserve these ranges for this service; overlap with a local IPv4
subnet fails closed. Indexes above 8160 fail closed.
Tayga translates IPv4 into the discovered prefix. IPv6 SNAT uses the actual
uplink address, allowing raw-IP /128 grants without assuming an extra routed
IPv6 address or SLAAC /64. Reply conntrack restores the private mapping and
routes it to that link's TUN. The mapping is `fd46:4:4:<48 bits of
SHA-256(uplink source)>::<ifindex>`: an existing SNAT binding is reused only
while the uplink address is unchanged. After a modem renumbers on the same
ifindex, packets of an unchanged IPv4 socket (same ports) get a new private
IPv6 source, so they create new conntrack entries with SNAT to the new address
instead of inheriting the old binding. Old entries expire on their own; other
uplinks' connections are never touched. Each translator drops to nobody:nogroup after
opening its TUN. The controller retains only network administration/raw socket
and identity-drop capabilities plus CAP_KILL (to signal its tracked child
after that child drops UID), with systemd filesystem/device restrictions.

Source rules (priority 10000+index) select tables 46000+index for IPv4 sources
and private IPv6 mappings. An IPv4 fallback default of metric 46000+index
lets hotspot clients use an available translator; ordinary lower-metric native
routes take precedence. This is availability/failover, not hotspot bonding.
NAT44 on each TUN supports forwarded IPv4 clients. Existing hotspot ownership,
IPv4 forwarding, firewall and client admission remain with NetworkManager and
the sharing service. This service owns its `inet clat_<index>` NAT/filter table.
Its IPv6 forward filter permits only the mapped source toward the discovered
prefix and established replies on that translator. Unrelated IPv6 forwarding
is covered by the forwarding guard below; existing IPv4 hotspot admission
remains with its owner. The shared IPv4/IPv6
TUN keeps the uplink MTU so full-size incoming IPv6 packets fit. Both IPv4
default routes through it use plain `mtu` at uplink MTU minus 20 bytes for
translation overhead. The IPv6 minimum link MTU of 1280 therefore gives an
IPv4 MTU of 1260 and an MSS of 1220; only an uplink below 1280 (not valid for
IPv6) fails with a diagnostic. The route MTU stays unlocked so default local sockets retain DF
and path-MTU discovery; locking it clears DF and makes tayga fragment ordinary
stream-sized UDP and TCP packets into IPv6 fragments. TCP SYN and SYN-ACK MSS
is capped at that IPv4 MTU minus 40, for hotspot forwarding in both directions
and locally originated traffic.
Smaller advertised MSS values are preserved. This avoids an extra path-MTU
discovery round for full-sized TCP traffic; non-TCP traffic remains subject
to the IPv4 route MTU.
It never flushes another owner's rules or tables.

IPv6 forwarding is needed for translation. The controller enables the global
switch while preserving devices' forwarding values. When the switch was off,
it first records the old value (fsynced `forwarding` file in the runtime
directory), then installs the `inet clat_guard` table, which drops every
forwarded IPv6 packet that neither enters nor leaves a `clat*` TUN, and only
then enables forwarding. The guard has its own lifetime, separate from the
per-link tables: it stays through link teardown, failed or pending inverses
and a crash at any startup step, and is removed only after forwarding is back
at the recorded value, or when another owner takes forwarding over. A switch
that was already on belongs to another owner: CLAT records nothing, adds no
guard and never changes it back.

NetworkManager's IPv6 shared mode (`ipv6.method shared`) is such an owner. It
sets the global switch when sharing starts and never resets it. Each
reconciliation asks NetworkManager for activating or activated connections
with that method. Once one exists, CLAT hands forwarding over: it removes the
guard and forgets the recorded value, so it never writes 0 over the newer
owner's 1, even after sharing stops again (forwarding then stays on, as it
would without CLAT). Before restoring 0 the last withdrawal asks again; when
the answer is unknown (D-Bus failure) it keeps forwarding guarded and the
status `error` until a later retry can tell. An owner that appears during the
write gets its 1 back. Other software that enables IPv6 forwarding while CLAT
holds a recorded value is not detected; use NetworkManager sharing.

The controller does not change `accept_ra` or per-interface forwarding on
NM-managed links: NetworkManager continues processing router advertisements
in userspace. Owned
routes/rules/firewall/TUNs are removed on withdrawal. A root-only runtime cleanup
journal, written before each resource creation, and
ExecStopPost handle service failure/restart.

Stopping is controller-first. The unit uses `KillMode=mixed`, so `systemctl
stop` or `restart` sends SIGTERM only to the controller; tayga keeps running
until the controller has published `unavailable` and terminates it itself. If
the controller is busy (discovery, D-Bus, routes), it finishes that step
first. After SIGTERM every command has a shared 20 s budget; whatever is left
stays in the journal. If invalidation cannot be written, the controller leaves
its translators running and exits nonzero; only then does systemd kill the
rest of the group, and consumers already see the unit deactivating.
`TimeoutStopSec=45` bounds the whole stop, and ExecStopPost and the next start
replay what is left. The previous global forwarding
switch is restored only when no translators or pending resource inverses remain.
The runtime directory survives a clean stop as well as a restart, so a failed
ExecStopPost returns nonzero without losing its recovery intent. Journals are
fsynced before atomic replacement (including the directory); they survive a
process crash, not a reboot of the volatile `/run` filesystem. A reboot also
removes the kernel resources they describe. The stock single-instance tayga service
is masked; the image installs no replacement translator build.

## Read-only CeraUI contract

`/run/ceralive/clat/<ifindex>.json` is an atomic, world-readable snapshot in a
root-writable directory. Readers never write it or control the service.

```json
{"schema_version":2,"interface":"wwan0","ifindex":3,"tun":"clat3","tun_ifindex":7,"prefix":"64:ff9b::/96","ipv4":"10.254.0.3","state":"up","last_error":null,"boot_id":"e35d2950-56b9-4324-858a-c577b756106b","invocation_id":"5f31d8d55f3141faa50e248d73538aae","generation":"375be5e8cd6d4179909196f2d42ae78c","updated_at":1794614400,"observed_at":120.0,"expires_at":150.0}
```

All 15 fields are required:

| Field | Type and meaning |
| --- | --- |
| `schema_version` | Integer `2`. Version 1 readers must treat v2 as unknown and therefore unavailable; there is no parallel v1 snapshot. |
| `interface`, `ifindex` | String physical interface name and integer kernel ifindex; filename is `<ifindex>.json`. |
| `tun`, `tun_ifindex` | String translator TUN name and integer kernel ifindex; the latter is null until the TUN is created. |
| `prefix` | Validated RFC 6052 prefix string, or null before discovery. |
| `ipv4` | String translated IPv4 /32 address. |
| `state` | `starting`, `up`, `unavailable`, `down` or `error`. Only `up` is eligible. |
| `last_error` | Null or diagnostic string. The first two failed prefix refreshes may retain `up` with a diagnostic. |
| `boot_id` | Kernel `/proc/sys/kernel/random/boot_id`, UUID string. |
| `invocation_id` | systemd's 32-hex `INVOCATION_ID`, matching the unit's `InvocationID`. Direct test launches get a fresh random process token instead. |
| `generation` | Opaque random 32-hex token, renewed on every link activation/setup attempt, even when interface names/ifindices are reused. A changed NM device path or ActiveConnection also withdraws/recreates the link. |
| `updated_at` | Integer Unix wall-clock seconds when this snapshot was written; diagnostic only, never an availability clock. |
| `observed_at` | Finite number of seconds on Linux `CLOCK_BOOTTIME`, sampled **before** collecting NM grants and this link's discovery/route/liveness reconciliation, not at publication. This monotonic clock includes suspend and is scoped to `boot_id`. |
| `expires_at` | Finite `CLOCK_BOOTTIME` seconds: `observed_at + 30` for `up`; equal to `observed_at` for every other state. |

The writer uses a sibling temporary file plus rename, so readers see a complete
old or new snapshot. Rename is not a transaction with kernel or unit state.
The producer refuses to publish `up` for an already expired/future observation
or a dead tayga child. Child death is reconciled on the ten-second callback;
blocking work can delay it, so the expiry remains mandatory even while the main
unit is live. Refresh/traffic success is not implied by an `up` lease.

Consumers must fail closed:

- Read only bounded, regular, root-owned files in the trusted root-writable
  directory. Missing, unreadable, malformed, unknown-version or invalid field
  types/enums/addresses mean unavailable. Require a supported prefix, usable
  IPv4, safe names, positive ifindices and nonempty well-formed identity tokens.
- Require `boot_id` to match this boot, `state == "up"`, and
  `0 <= observed_at <= now < expires_at` using **CLOCK_BOOTTIME** on the same
  machine. Require `expires_at - observed_at == 30`; reject stale or future
  monotonic timestamps with no future-skew allowance. Wall-clock jumps in
  `updated_at` cannot renew or expire the lease. Never renew it by reading it.
- Require this specific unit active/running with a live MainPID, and match
  `invocation_id` to its current `InvocationID`. Invalidate cached eligibility
  on any boot, invocation or generation change. `Type=simple` active alone
  does not mean ready.
- Match filename/physical ifindex and interface to the current modem identity.
  Require an administratively-up **TUN**, the exact `tun_ifindex`, and the
  assigned snapshot IPv4 /32. Reused names/ifindices alone confer no identity.
- Recheck unit, physical device, TUN and snapshot identity immediately before
  asynchronous publication. Fence publication/withdrawal with the consumer's
  modem/session generation and existing sender reload path. Reconcile/poll as
  well as watching: rename replaces a watched inode. Invalidate on mismatches.

These checks provide bounded fail-closed availability, not race-free activation
authority. A crash during teardown leaves an unavailable snapshot and a replayable
inverse. Startup and ExecStopPost invalidate all previous snapshots before any
undo. Cleanup's final `down`/`error` rewrite samples fresh diagnostic and monotonic
time and gives **zero** availability lifetime; it never preserves or renews an
old `up` timestamp. It preserves the old activation identity for withdrawal;
a new service activation publishes its own invocation and generation.

Use `ipv4` as the sender bind source and `tun` as its IPv4 bind device. Keep
one logical modem/physical-link identity, avoiding a duplicate translated link.
Withdraw the source when unavailable. CeraUI is a **consumer only**: it must not
start a translator, repair routes/firewall/TUNs or restore forwarding. Those
resources have one owner, this image service. This change supplies the image
contract only; CeraUI consumption is a separate change.

## Tests

`bats tests/cellular-clat.bats` runs offline discovery/admission tests.
`CERALIVE_RUN_CLAT_CONTRACT=required ./run-tests` runs the complete network
contract. CI uses `CERALIVE_RUN_CLAT_CONTRACT=service` to run its service and UDP
transport coverage without requiring first-party sender/receiver binaries; the
complete mode additionally checks SRTLA. Missing dependencies fail the enabled
gate.

`tests/clat-netns.py` needs root, iproute2, nftables, tayga, Python with
dnspython, dbus-python and PyGObject, systemd as the host's init (251 or
newer) and real `srtla_send` / `srtla_rec` binaries. Run it only inside fresh
PID and mount namespaces and a named network namespace, with a shell as
PID 1, as `run-tests` does (`ip netns exec`, with `CLAT_TEST_NETNS` set to
`/run/netns/<name>`). The installed-unit part copies the unit file unchanged
to `/run/systemd/system` with a drop-in that only adds that network namespace,
an `ExtensionDirectories=` overlay carrying the controller (and tayga or
dnspython when the host lacks them) and the private D-Bus address; it refuses
to run if a `ceralive-clat` unit or `/run/ceralive/clat` already exists and
removes everything afterwards. Do not run two contracts at once. Set `CLAT_TEST_TAYGA`,
`CLAT_TEST_SENDER` and `CLAT_TEST_RECEIVER` to installed test binary paths.
It uses synthetic veths and a local DNS64/NAT64 peer with no external uplink.
It checks two simultaneously active translators, a never-default link (no
gateway, no main-table default, router known only from its RA, DNS64 resolver
off the link's prefix), source-bound IPv4 transport,
a real sender/IPv4 receiver, hotspot forwarding, native-IPv4 exclusion,
link withdrawal with a surviving second link, teardown, and absent/bad prefixes.
A private D-Bus fixture also runs the actual service through dual-stack, two
IPv6-only grants and link-loss states. Foreign-table refusal, crash-journal
cleanup and restoration of the global forwarding switch are also exercised.
It also checks route repair after a flap, preserved NM sysctls, TUN MTU and
DF-forced full-size datagrams without extra PTB responses, default-socket UDP
(1332, 1372 and 1452-byte payloads) and TCP bulk sends with zero IPv6 fragments
from both the box and hotspot, TCP MSS (including smaller advertised values),
and the scoped IPv6 filter with forwarding initially disabled or already
enabled by another owner. Tayga runs in foreground mode without debug output.
The real service lifecycle runs with the unit's restricted capability set and
no-new-privileges.
It also checks that the forwarding guard exists before forwarding at both
startup steps a crash can interrupt and survives a failed later inverse,
with real unrelated IPv6 packets; that NetworkManager IPv6 sharing started
after CLAT takes forwarding over and keeps it after CLAT stops, and the
reverse order; that fixed-port UDP from the box and a hotspot client keeps
working after the uplink renumbers on the same ifindex; and an IPv6 1280 link
(IPv4 1260): DF UDP and TCP without fragments or PTB, the box refusing and
the hotspot learning 1260 by ICMP for one byte more, and fragmented delivery
without DF. Through the installed unit, stop and restart are checked to
withdraw availability before any translator loses its TUN, while the
controller is held in a slow reconciliation, and a stop whose invalidation
cannot be written keeps its translator until the controller has exited,
leaves forwarding guarded, and recovers on the next start.
This proves packet forwarding, not encrypted SRT/video or carrier hardware.

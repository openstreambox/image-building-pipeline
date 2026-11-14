# IPv4 service on IPv6-only cellular links

Some SIMs, including T-Mobile US, provide no native IPv4 address. IPv4-only
stream receivers and IPv4 hotspot clients then need translation on the box.
`ceralive-clat.service` supplies this using Debian's packaged tayga. It does not
change modem profiles, reconnect a modem, or use NetworkManager dispatchers.

The image service reads NetworkManager D-Bus device state (activated modem
interfaces only). A native global IPv4 address excludes the link. A usable
IPv6 source, default route (with or without a gateway), and per-link DNS
servers are required. D-Bus changes
trigger reconciliation, with a ten-second retry for failed discovery or a dead
translator. Manager disappearance withdraws all grants.

The service sends an interface/source-bound AAAA query for `ipv4only.arpa` to
that link's IPv6 DNS servers. Both RFC 7050 sentinel addresses must confirm one
RFC 6052 prefix (/32, /40, /48, /56, /64 or /96). Missing, truncated, ambiguous
or inconsistent responses fail closed. `64:ff9b::/96` is used only when that
same discovery confirms it; there is no guessed fallback. DNS64 is evidence
from the network, not authenticated proof of an operator's identity. Prefixes
are revalidated every 60 seconds and when the address/gateway/DNS grant
changes. A changed prefix withdraws translation until the next retry; existing
flows are not migrated. Snapshots refresh on each reconciliation (at most ten
seconds apart while discovery is healthy).

Each link gets `clat<ifindex>`, an IPv4 /32 in reserved service space
`10.254.0.0/19`, and a private IPv6 mapping in `fd46:4:4::/112`.
Reserve these ranges for this service; overlap with a local IPv4 subnet fails
closed. Indexes above 8191 fail closed.
Tayga translates IPv4 into the discovered prefix. IPv6 SNAT uses the actual
uplink address, allowing raw-IP /128 grants without assuming an extra routed
IPv6 address or SLAAC /64. Reply conntrack restores the private mapping and
routes it to that link's TUN. Each translator drops to nobody:nogroup after
opening its TUN. The controller retains only network administration/raw socket
and identity-drop capabilities, with systemd filesystem/device restrictions.

Source rules (priority 10000+index) select tables 46000+index for IPv4 sources
and private IPv6 mappings. An IPv4 fallback default of metric 46000+index
lets hotspot clients use an available translator; ordinary lower-metric native
routes take precedence. This is availability/failover, not hotspot bonding.
NAT44 on each TUN supports forwarded IPv4 clients. Existing hotspot ownership,
IPv4 forwarding, firewall and client admission remain with NetworkManager and
the sharing service. This service owns only its `inet clat_<index>` NAT table.
It never flushes another owner's rules or tables.

IPv6 forwarding is needed for translation. The controller enables the global
switch while preserving other devices' forwarding values, enables forwarding
on the owned TUN and cellular link, and sets that link's accept_ra=2 so RA
continues during forwarding. Link settings and owned routes/rules/firewall/TUNs
are restored/removed on withdrawal. A root-only runtime cleanup journal and
ExecStopPost handle service failure/restart. The previous global forwarding
switch is restored when no translators remain and on service shutdown. The stock single-instance tayga service
is masked; the image installs no replacement translator build.

## Read-only CeraUI contract

`/run/ceralive/clat/<ifindex>.json` is an atomic, world-readable snapshot in a
root-writable directory. Readers never write it or control the service.

```json
{"schema_version":1,"interface":"wwan0","tun":"clat3","prefix":"64:ff9b::/96","ipv4":"10.254.0.3","state":"up","last_error":null,"updated_at":1794614400}
```

`state` is `starting`, `up`, `down` or `error`; `prefix` can be null before
successful discovery. `last_error` is null or a diagnostic string. Missing
service/file, unknown schema, stale timestamp or any state other than `up`
means unavailable. Readers must also check the service is running and TUN
exists; a snapshot alone is not a liveness lease. Use `ipv4` as the sender bind
source, and `tun` if specifying an IPv4 bind device; the cellular interface has
no IPv4 address. Withdraw that source when unavailable. This change supplies
the image contract only; CeraUI consumption is a separate change.

## Tests

`bats tests/cellular-clat.bats` runs offline discovery/admission tests.
`tests/clat-netns.py` needs root, iproute2, nftables, tayga, Python with
dnspython, dbus-python and PyGObject, and real
`srtla_send` / `srtla_rec` binaries. Run it only inside fresh PID, mount and
network namespaces, with a shell as PID 1. Set `CLAT_TEST_TAYGA`,
`CLAT_TEST_SENDER` and `CLAT_TEST_RECEIVER` to installed test binary paths.
It uses synthetic veths and a local DNS64/NAT64 peer with no external uplink.
It checks two simultaneously active translators, source-bound IPv4 transport,
a real sender/IPv4 receiver, hotspot forwarding, native-IPv4 exclusion,
link withdrawal with a surviving second link, teardown, and absent/bad prefixes.
A private D-Bus fixture also runs the actual service through dual-stack, two
IPv6-only grants and link-loss states.
This proves packet forwarding, not encrypted SRT/video or carrier hardware.

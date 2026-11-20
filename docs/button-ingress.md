# Device-bound browser ingress

Partner: [CeraUI #66](https://github.com/openstreambox/CeraUI/pull/66),
`docs/BUTTON-INGRESS.md` at `2e2378236a724dfd5f1c3d49d0b0bdf3ebd8f419`.
Stacked on the power-button change (#19). This front door owns the existing
HTTP/80 and HTTPS/443 origins. It replaces nginx for those origins, uses the
existing per-device TLS certificate, and passes static HTTP, preview and normal
RPC to TCP/18080. There is no browser origin or frontend discovery change.
Preview authentication and RPC authentication remain backend responsibilities.
The self-signed certificate still requires the existing browser trust decision.

## Trust boundary

Each current address gets an exact address + SO_BINDTODEVICE socket; IPv6 also
gets V6ONLY and scope index. There is no wildcard or SO_REUSEPORT listener.
Only IPv4 on an UP ARPHRD_ETHER link with a sysfs hardware device and no master
or virtual link kind is eligible. This includes physical wired and Wi-Fi/AP
interfaces, regardless of their names. Bridges, tunnels, VPNs, loopback, veth
and unknown links stay password-only. Incoming VPN packets addressed to a LAN
address cannot reach the device-bound LAN listener. Routed physical networks
outside the listener's subnet also remain password-only.

The netlink subscription precedes the initial snapshot. Each listener address
is a trust basis: interface index, name, admin-up state, Ethernet or not,
enslaved or not, link kind, address family, address and prefix length. Link
type and master are tracked as those eligibility classes, so a move between
two non-Ethernet types or directly between two masters does not retire an
(already password-only) basis; leaving either class does. Both sides of every
accepted connection belong to the basis it arrived on. Each link/address event
is parsed in the callback that reads it, and a basis is retired (listeners
closed, both sides of its connections closed, handlers cancelled) when an
event removes its link or address, changes any of those link facts (including
down, rename and enslavement), changes its prefix length, marks its address
tentative or failed, or is a non-generic link message for its interface. A
removal followed by readdition retires on the removal and never revives.
Events elsewhere, including new interfaces, other addresses on the same
interface and carrier changes, leave established sessions open.
Every event still withholds new trusted admission until a fresh dump is
synchronized with the event stream. That dump also retires any basis it no
longer contains and binds new ones without touching unchanged listeners.
On ENOBUFS, overflow, truncation, interrupted multicast messages, an unknown
message, a malformed message or trust attribute (short, fragmentary or
conflicting duplicate) or any other loss of event continuity, retire **all**
bases and their connections immediately. Rebuild from a fresh netlink subscription
established before a complete address dump; withhold privileged forwarding
until that dump is synchronized with events. An identical address and mask
after a lost remove/readd interval cannot prove continuity and must never
preserve or revive pre-loss evidence. The address dump counts only when `ip`
exits 0 with nothing on stderr; iproute2 reports an interrupted dump there and
may still exit 0. A failed, timed-out or interrupted dump is not lost history:
nothing from it is applied, established sessions stay judged by the
continuous event stream, and trusted admission stays withheld until a later
dump succeeds.
Only a drained, current snapshot enables trusted admission. A failed bind
withholds trusted admission globally and retries reconciliation. Address
removal/readdition, mask changes, renames and interface identity changes cannot
restore a prior connection's evidence. Events are checked again around async
upstream connection establishment: any event between the trusted decision and
the forwarded upgrade voids that grant, even if a refresh has restored
readiness meanwhile. Restart closes every session.

Each accepted request is inspected. Only an exact GET /ws WebSocket upgrade
without a body or forwarding/reserved metadata can reach a fresh private Unix
connection. Forwarded, all X-Forwarded-* (including empty values), Via and
X-Ceralive-Button-Path route to the ordinary backend unchanged. Host and Origin
are preserved. CONNECT, absolute targets, folded/duplicate headers and ambiguous
framing are refused. Ordinary paths never acquire trusted metadata later.
There is no arbitrary destination or proxy CONNECT capability. CeraUI keeps
its relay sender-ID veto and independently checks interface/address evidence
at every button action. Headerless LAN proxies cannot be distinguished from
the local client itself; physical confirmation is still mandatory.

The helper supplies version, accepted peer, exact listener interface and
accepted destination in X-Ceralive-Button-Path only over the protected Unix
endpoint. The runtime directory belongs to the backend service, root:root 0700;
CeraUI #66 creates its socket 0600. ExecStartPre removes only a root-owned socket
from that verified directory, after systemd has stopped the old service.
Unexpected files/symlinks stop startup. Missing Unix ingress falls back to
ordinary password-only RPC; it cannot authorize button operations.

Limits: 128 admitted connections, 16 KiB handshake, 5 s public/header and TLS
handshakes, 3 s upstream connection, 5 s upstream handshake, 64 KiB copy blocks,
10 s write drain, 120 s idle read, service 128 MiB and 1024 descriptors. Ordinary
HTTP asks the backend to close after one response. WebSocket pumps terminate
both sides together. These limits need realistic preview/load qualification.

## Service ownership

The helper runs root to traverse the private Unix directory and read the TLS
key, with only CAP_NET_RAW (SO_BINDTODEVICE) and CAP_NET_BIND_SERVICE. It has
no network-administration capability. Its filesystem is read-only; home,
devices, privilege escalation, kernel mutation and control groups are protected.
A separate oneshot has only CAP_NET_ADMIN and owns one nft table, dropping
non-loopback TCP/18080 for IPv4 and IPv6. It never flushes another table.
The backend Requires this fence, receives PORT=18080, and cannot bind any of
its fallback TCP ports (80, 8080, 81). Thus backend port failure cannot steal
the public origin. Stop ordering stops the backend before removing the fence.
The fence is essential because the partner backend binds a wildcard address.
The existing nginx service is masked to avoid port conflicts. TLS first-boot
restart propagates to the helper so hostname/certificate changes take effect.

Older backends without the Unix endpoint remain password-only. No backend
package pin, image build or rollout is implied. Rollback must restore nginx,
remove the backend drop-in and stop the front door/fence together while the
backend is stopped; never remove the fence under a running wildcard backend.

## Qualification

`tests/button-ingress-contract.py` uses synthetic identities/socket failures,
synthetic rtnetlink messages and real Unix/TCP transports; it checks that
established trusted and ordinary sessions survive unrelated link/address
changes and close on changes to their own basis or on lost history. `tests/button-ingress-kernel.py` runs in disposable
network namespaces, accepts a direct veth path then refuses overlapping-address
packets arriving on a second veth. This verifies the real SO_BINDTODEVICE
operation; a veth is deliberately not production-eligible. It then runs the
front door on real kernel rtnetlink events: a session survives a new interface,
another address, removal of another interface and its own MTU change, and
closes on removal of its own address and on its link going down. The Bats wrapper
requires passwordless isolated namespaces when CERALIVE_RUN_BUTTON_NETNS=required.
It skips with a reason otherwise. No physical board is required.

Before release, on **both ROCK 5B+ and Orange Pi 5 Plus**:

- Verify root directory/socket ownership, firewall IPv4/IPv6 isolation of 18080,
  forbidden fallback ports, stop/start ordering and absence of nginx conflicts.
- Exercise ordinary HTTP, TLS, static assets, preview token enforcement, normal
  password sign-in and authenticated RPC; measure load and idle reconnects.
- Confirm direct Ethernet and Wi-Fi station/AP button admission, physical tap
  confirmation, cancellation and deadline handling. Repeat while live without
  permitting short shutdown. Verify the separate power-board/LED prerequisites.
- Try an overlapping-subnet VPN, bridge, IPv6-only client, relay, public reserved
  metadata and LAN proxy with empty/nonempty forwarding headers: no button
  admission. Keep headerless-LAN-proxy limitations explicit.
- Remove/readd the same address between polls; change mask, rename, disconnect,
  and re-enumerate interfaces; restart helper/backend. An old prompt must never
  finish or revive. Induce netlink overflow and bind failure: ordinary login
  should recover while privileged admission remains withheld during uncertainty.
- Observe actual logind/input timings and fallback separately; check image size
  and actual free-slot reserve on the next authorized image build.

English/Spanish release documentation and these measured checks remain release
prerequisites. Host contracts do not establish physical-button, preview load,
LED, image-size or board qualification.

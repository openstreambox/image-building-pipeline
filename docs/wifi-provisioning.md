# First-boot WiFi provisioning portal

How a headless, never-configured CeraLive device is handed WiFi credentials with no
screen or keyboard. This is the end-to-end reference for Task 17 (and for anyone
debugging the portal on hardware).

- **Trigger + AP bring-up** — Task 11 (`ceralive-provision.sh` part 1)
- **Captive page + credential handoff + teardown** — Task 14 (`ceralive-provision.sh`
  part 2 + `ceralive-portal.sh`)
- Subsystem summary: [`docs/agents/add-on-subsystem.md`](agents/add-on-subsystem.md) → *First-boot WiFi provisioning portal*

## Artifacts

| File (committed under `mkosi/runtime/`) | Installed to | Role |
|--------------------------------------------|--------------|------|
| `ceralive-provision.sh` | `/usr/local/sbin/ceralive-provision` | Trigger, AP bring-up, portal lifecycle, `connect` handoff worker, teardown |
| `ceralive-provision.service` | `/etc/systemd/system/` | Runs `ceralive-provision start` once at boot |
| `ceralive-portal.sh` | `/usr/local/sbin/ceralive-portal` | inetd-style bash HTTP handler (the captive page) |
| `ceralive-portal.socket` | `/etc/systemd/system/` | Socket-activated listener on `192.168.42.1:80` (`Accept=yes`) |
| `ceralive-portal@.service` | `/etc/systemd/system/` | Per-connection handler instance |
| `brand/ceralive-mark-small-dark.svg` | `/usr/share/ceralive/brand/ceralive-mark-small-dark.svg` | Vendored CeraLive mark for the dark Ground Control page |

All six are installed by `customize/postinst-lib.sh::setup_provisioning` (single
source of truth — no inline twin in `mkosi.postinst.chroot`). Only
`ceralive-provision.service` is enabled at boot; the portal socket + template are
started/stopped imperatively by `ceralive-provision`.

## State on `/data` (survives reboots and A/B OTA slot swaps)

All under `/data/ceralive/provision/`:

| File | Meaning |
|------|---------|
| `force-portal` | Factory-reset re-trigger flag — start the portal even when profiles exist |
| `portal-active` | Setup marker: the setup owns `wlan0`; `key=value` (`ssid`, `gateway`, `iface`, `con`, `user_con`, `pending_join=1`). See *Setup marker* below |
| `pending-join` | The portal saved `ceralive-wifi` but no join has verified it yet: `ssid=<name>`, `con=ceralive-wifi` and `uuid=<profile UUID>` (one per covered profile). Each attempt picks a fresh UUID, writes this file (temp file, flushed, rename, directory flushed; any failure means no profile is saved), then creates the profile with exactly that `connection.uuid`. Removed by the connect worker after a verified join or after it deletes a failed profile. Every change happens under `pending-join.lock`, and a removal only while the file still names the remover's UUID. See *Unverified join* below |
| `teardown-requested` | Out-of-band teardown request honored at next service start |
| `scan.txt` | Cached visible SSIDs (one per line), scanned **before** the AP came up |
| `last-error` | After a failed join: `ssid=<name>` + `reason=auth_or_timeout` (the worker's join failed) or `reason=not_verified` (a boot found the join still pending and the network never came up) — shown by the portal |
| `ap-uuid` | UUIDs of setup AP profiles, one per line; a new one is added before its profile is created, and each stays until NetworkManager shows it neither active nor saved. Replaced only whole (temp file + rename) |

The WiFi credentials themselves are **never** written here — they go only into
NetworkManager's own `system-connections` store (`/etc/NetworkManager/system-connections`,
bind-mounted from `/data/nm/system-connections`, mode `0700`).

## Trigger (does the portal start this boot?)

Evaluated at runtime by `ceralive-provision start` (the unit cannot express it as a
static `Condition`):

1. `force-portal` flag present → **start** (factory-reset hook).
2. Else if there is **any** stored NM WiFi station profile on `/data` → **do not start**
   (the device can rejoin an uplink). This is the **EC4 OTA-safe** property: a RAUC
   update that preserves `/data` keeps the profiles, so the portal stays down. A
   `ceralive-wifi` whose join is still pending does not count (see *Unverified join*).
3. Else wait a **60–90 s grace window** (default 75 s): if NM reports connectivity
   (`full`/`limited`/`portal`) or a default route appears, an uplink exists → **do not
   start**. Otherwise → **start**.

Saved hotspots, ad-hoc and mesh profiles do not count. When a profile's mode
cannot be read, it still counts to avoid starting setup over a saved station.
The device's own setup AP is excluded from the stored-profile count. It is recognised
the same way cleanup recognises it (the UUID recorded in `ap-uuid`, or the settings
fingerprint below), not by its name, so a user's station profile that happens to be
called `ceralive-ap` counts as a saved network. If the setup AP's identity cannot be
read (NetworkManager or `ap-uuid` unreadable), every profile called `ceralive-ap` is
left out, as older images did.

Every profile listing is `nmcli -t -f UUID,TYPE,NAME connection show`: UUID and type
never contain `:`, so they are always the first two fields, and the name is the rest
of the line with nmcli's escaping (`\:`, `\\`) undone. The trigger, the setup AP
lookup, record pruning and the user-profile lookup all read it that way, so a name
with a colon cannot shift the UUID.

## Bring-up (`bring_up_ap`)

1. **Scan + cache** visible SSIDs to `scan.txt`. A single radio cannot scan while in AP
   mode, so this must happen *before* the AP is up.
2. **DNS capture**: write `address=/#/192.168.42.1` to
   `/etc/NetworkManager/dnsmasq-shared.d/ceralive-portal.conf`. NM's shared-mode dnsmasq
   reads it at activation, so every hostname resolves to the gateway → the operator's OS
   pops its captive-portal sign-in.
3. **Setup marker**: write `portal-active` (see *Setup marker*); if it cannot be
   written, stop here.
4. **CeraUI and the button ingress stop** (frees `0.0.0.0:80`, and CeraUI issues
   nothing more for `wlan0`). Both must then report inactive (an image without the
   ingress unit reports it inactive); otherwise bring-up stops here, releases the
   marker, starts them again and fails.
5. **AP up**: earlier setup AP profiles are deleted by UUID, a fresh UUID is
   added to `ap-uuid` next to any that NetworkManager still shows, and the profile
   is created with that `connection.uuid` and activated by it. NM-native AP (`802-11-wireless.mode ap` + `ipv4.method shared`), SSID
   `CeraLive-Setup-<short-id>`, passphrase `ceralive-setup`, gateway `192.168.42.1/24`.
6. **Portal**: `systemctl start ceralive-portal.socket` (binds `192.168.42.1:80`).

## The captive page (`ceralive-portal.sh`)

Served by systemd socket activation: `ceralive-portal.socket` (`Accept=yes`) accepts
each TCP connection and hands the socket to a fresh `ceralive-portal@<peer>.service`
instance as **stdin + stdout** (the classic inetd model). The bash handler reads one
HTTP request from stdin and writes the response to stdout.

**Why bash + socket activation:** the image ships no `busybox httpd` / `python3` /
`socat` / `nc` (socat and netcat were moved to the debug add-on — see
`manifests/packages/removed.md`). systemd + bash is the lightest HTTP server already
present — zero extra packages. The page is standalone plain HTML/CSS with no JS
framework and no build step (SC2).

**Portal branding [EXISTS in source; next image release]:** every page shows the
CeraLive mark from `/usr/share/ceralive/brand/` above its heading, embedded as an
SVG data URI. The page uses the dark Ground Control palette. If the mark is
missing, unreadable, larger than 65,536 bytes, or cannot be encoded, the handler
logs the reason and serves the page without an image. Artwork never blocks the
setup form.

`brand-assets.lock.json` pins the vendored release and SHA-256;
`BRAND-ASSETS-NOTICE.md` records the brand license and refresh command. Maintainers
with access to the brand repository run
`bun <ceralive-brand checkout>/consumer-kit/sync-brand-assets.ts --tag v2026.10.0`
from this repository's root to refresh it. No TypeScript sync script or Bun
toolchain is shipped here. Devices receive the change only with the next image
release; source tests do not qualify a built or booted image.

- **`GET` (any path)** → the provisioning form. The SSID field is an `<input list>` +
  `<datalist>` populated from `scan.txt`, so the operator can pick a scanned network or
  type a hidden/new one. If `last-error` exists, an error banner is shown.
- **`POST /`** → validate `ssid` (1–32 chars) and `psk` (empty for open, else 8–63 for
  WPA2); write the profile; answer with a "connecting…" page; trigger the handoff.

## Credential handoff (the captive-portal handoff problem)

Joining the target network means switching `wlan0` from AP to client mode, which drops
the operator's connection to the portal. So the join must be **detached** from the HTTP
request:

1. The `POST` handler writes the user's profile: `nmcli connection add … con-name
   ceralive-wifi … wifi-sec.psk <psk>` (credentials → NM storage only). The PSK is passed
   as quoted argv, never via a shell string or a file.
2. It answers the browser, then fires a detached worker in its own transient unit:
   `systemd-run --no-block --collect --unit=ceralive-provision-connect-<profile UUID>
   --property=RuntimeMaxSec=120 ceralive-provision connect ceralive-wifi <profile UUID>`.
   The transient unit outlives the per-connection portal service (which dies when the AP
   is torn down); its per-attempt name means a newer save never collides with an older
   worker that is still waiting.
3. The worker (`ceralive-provision connect <con>`):
   - exits quietly, touching nothing, whenever `pending-join` no longer names its UUID
     (a newer save replaced the attempt): checked under the join lock at start, around
     the AP drop and before the teardown or the failure handling,
   - sleeps briefly so the HTTP response flushes,
   - stops the portal socket and brings the AP connection down (freeing the radio — it
     does **not** `device disconnect`, which would block the client activation),
   - joins with a bounded `timeout <hard> nmcli --wait <soft> connection up <con>` and
     verifies connectivity,
   - **success** → run the four-condition teardown keeping the new client link,
   - **failure / timeout** → delete the bad profile, write `last-error`, and re-arm the
     AP (`bring_up_ap`) so the operator reconnects and retries.

### Unverified join

If the box loses power or reboots after the portal saved `ceralive-wifi` and before
the worker verified the join (or `systemd-run` could not start the worker),
`pending-join` is still there on the next boot. That boot does not count
`ceralive-wifi` as a stored profile, so with no other profile it goes through the
grace window:

- connectivity appears and a profile `pending-join` names is activated → the join counts as verified,
  `pending-join` is removed, and the boot carries on as for a configured box (a stale
  `portal-active` goes through the usual stale-marker teardown);
- connectivity appears but not through `ceralive-wifi` → no portal, and the join stays
  pending;
- the window expires → the profiles `pending-join` names are deleted (by UUID; another
  `ceralive-wifi` is a saved network of its own and is never touched), `last-error` gets
  `reason=not_verified`, `pending-join` is removed and the setup AP comes up as on a
  fresh card. A profile that cannot be deleted keeps `pending-join`.

Images before `pending-join` existed wrote a `portal-active` without the
`pending_join=1` line. Their failure path deleted the profile before every re-arm, so
such a marker next to a saved `ceralive-wifi` means their handoff was cut short: it is
treated as pending, and `pending-join` is written with the UUIDs of the
`ceralive-wifi` profiles found then, so the decision survives the stale-marker
teardown and covers only those profiles. With this image's marker, a missing `pending-join` means the
join was verified.

## Teardown — MAC6 end-state (all four)

| # | Condition | How |
|---|-----------|-----|
| a | AP mode disabled | `nmcli connection down` + `delete ceralive-ap` |
| b | Device joined target | `nmcli connection up <con>` activated + connectivity verified |
| c | Portal no longer reachable | `systemctl stop ceralive-portal.socket` → port 80 freed |
| d | CeraUI reachable on new IP | `systemctl start ceralive.service` → re-binds port 80 |

Two teardown entry points:

- **`connect` success** → `teardown_ap` with **keep-link** (does *not* `device disconnect
  wlan0`; it is carrying the freshly-joined client connection).
- **`ceralive-provision teardown`** (verb) or a `teardown-requested` flag → `teardown_ap`
  also releases `wlan0` (no client connection in this path) and clears the
  portal-active + force flags.

`systemctl stop ceralive-provision` runs `ExecStop=ceralive-provision service-stop` — a
link-down + portal-down clean stop that **retains** the AP profile and the factory-reset
flags so the next boot re-evaluates the trigger and a pending factory reset is not
silently disarmed. On a manual stop it removes the setup marker and restores CeraUI
and the button ingress to port 80; during shutdown it starts nothing and keeps the
marker (see *Shutdown cleanup* and *Setup marker*). A later boot that needs no portal
deletes the AP profile a stop left behind, without touching `wlan0` or CeraUI.

Every setup-only NetworkManager operation (up, down, delete, the active check) goes
by UUID, never by connection name, so a user's profile that happens to share the
name is never touched. The UUID is the one recorded in `ap-uuid`, which still
identifies the profile if its settings change later. A profile from an older run
without that record counts as the setup's only on positive evidence: connection
name, AP mode, this device's `CeraLive-Setup-<short-id>` SSID and the
`192.168.42.1/24` address. An empty, unreadable or malformed `ap-uuid` counts as
uncertain, never as "no setup AP". The marker then goes only on live evidence that
`wlan0` is not an AP: the interface doesn't exist, or NetworkManager has it in a
settled state (unmanaged, unavailable, disconnected or connected) and
`iw dev wlan0 info` reports a station-side type. A blank or unknown type, a device
still activating or deactivating, or anything unreadable keeps the marker. Only that
same proof lets a later run set the record aside (as `ap-uuid.unreadable`) and start
a fresh one.

Whether a recorded setup AP is still active comes from
`nmcli -t -f UUID,ACTIVE-PATH connection show --active`. Naming an active field makes
nmcli list every active or activating connection, including one whose saved profile
is gone; a UUID-only request lists only rows that still have a profile. A failed delete or an
unreadable NetworkManager is logged, `last-error` stays, and the run exits non-zero.

Whenever provisioning hands the front door back (after a join, on `stop`/`teardown`, or
when it undoes a failed bring-up), a CeraUI or ingress unit that does not start is
logged as an error and the command exits non-zero; the log never claims a restore that
did not happen. A joined Wi-Fi link stays up either way. An image without the ingress
unit counts as fully restored once CeraUI is up.

If the AP profile cannot be created or activated, or the portal socket cannot start
after the AP is up (port 80 on the AP gateway still taken), bring-up is undone: the AP goes down, the portal-active marker is removed,
CeraUI and the ingress are started again, and `start` fails. The AP profile, the
force flag and `last-error` stay, so the next boot or trigger tries again. A boot
that needs no portal also removes a DNS capture an older failed bring-up left
behind, so later shared connections don't send their DNS to the AP gateway.

### Setup marker

CeraUI reads `portal-active` as "the image's setup owns `wlan0`": while it exists,
CeraUI does not start, switch, restore or arm a hotspot on that radio, and checks
again right before it hands a hotspot to NetworkManager. The marker therefore covers
exactly the time the setup AP is up or about to come up:

- written before the AP profile is created or activated; if it cannot be written,
  no AP is brought up;
- followed by stopping CeraUI and the ingress, still before the AP is created. The
  marker stops new CeraUI activations, but a CeraUI AP already handed to
  NetworkManager just before can still be activating; activating `ceralive-ap` only
  after CeraUI has exited makes it the last request for `wlan0`, so NM gives it the
  device;
- kept through the station join and any re-arm after a failed join;
- removed before CeraUI starts again on every way out: a failed bring-up, a manual
  stop, and teardown (after a successful join the station is up on `wlan0` first,
  so CeraUI's handover sees the joined station). It is removed only once
  NetworkManager shows no setup AP active (an inactive or deleted profile counts as
  gone), and the removal is checked. If the AP is still up, NetworkManager can't be
  read, or the file can't be removed, the marker stays and the command logs an error
  and exits non-zero. CeraUI and the ingress still come back, so there is a front
  door, but CeraUI keeps off `wlan0` as the marker says;
- kept across shutdown, so the setup keeps priority until the next boot re-evaluates
  the trigger; that boot removes a marker it no longer needs through the stale-marker
  teardown, which keeps `wlan0` connected (a saved network may already be up on it).
  Only the explicit `teardown` verb or flag still releases `wlan0`.

## Port-80 / 443 coexistence

Three actors want HTTP ports in production:

- **CeraUI backend** (`ceralive.service`) binds `[80, 8080, 81]`, trying 80 first.
- **nginx TLS front** (Task 15) binds **443** and reverse-proxies to the backend on
  `127.0.0.1:80`.
- **The captive portal** needs `192.168.42.1:80` for captive UX.

`0.0.0.0:80` (the backend) conflicts with `192.168.42.1:80` (the portal), so provisioning
stops the backend for the AP window and restarts it on teardown — `Restart=always` does
**not** re-fire on an explicit `systemctl stop`, so the backend stays down until teardown.
nginx on 443 is unaffected; while there is no uplink there is no 443 client, and its
`127.0.0.1:80` upstream simply returns 502 until the backend restarts. After teardown the
backend re-binds 80, nginx's upstream recovers, and the device is reachable at
its selected mDNS hostname on the new network (`https://ceralive.local`,
`https://ceralive2.local`, and so on).

## Hardware qualification (`[PARTIAL]` overall)

Both RK3588 boards passed the 2026-09-25 Todo-48 force-portal → NM-native AP →
out-of-band teardown drill on their current production images. On each board
`nmcli -g WIFI-PROPERTIES.AP device show wlan0` returned `yes`; the `ceralive-ap`
connection reached `GENERAL.STATE:activated` and `802-11-wireless.mode:ap`,
`wlan0` held `192.168.42.1/24`, NetworkManager spawned a dnsmasq DHCP child,
and no `hostapd` process ran. After `/usr/local/sbin/ceralive-provision teardown`,
both boards returned to disconnected wlan0, inactive portal socket, active CeraUI,
absent force/active flags, and no AP profile. Both SSH connections used `eth0`
throughout. `iw` was absent on these production images, so the independent
corroboration was the actual kernel gateway address and NM dnsmasq process rather
than `iw dev`'s interface-type display. The named four-file Todo-48 transcript
set and its digests are recorded in `manifests/packages/removed.md`.

This closes the AP-capability gate for removing `hostapd` from **future builds**.
The boards were not re-imaged without it, and the operator's physical client join,
credential POST and automatic credential-handoff path were not exercised by this
drill. The provisioning subsystem remains `[PARTIAL]` for those separate paths;
its routed summary is in [`docs/agents/add-on-subsystem.md`](agents/add-on-subsystem.md).

## Verification

`tests/provision-portal.test.sh` is a pure-offline proof harness (no radio, no
systemd): it stubs `nmcli` / `ip` / `systemctl` / `systemd-run` / `timeout` and drives the
real scripts through bring-up, the `GET`/`POST` page, the credential handoff, all four
MAC6 conditions, the wrong-passphrase retry, the hard-timeout return-to-AP, and the
out-of-band teardown verb. It is gated in `tests/postinst-wiring.bats`
(*"provision portal: offline harness proves the 4-condition teardown + handoff"*).
Its GET scenarios also compare the embedded mark's SHA-256 to the vendored file,
reject the retired page colors, and prove the form still serves without artwork.
`tests/brand-assets-integrity.test.sh` runs in the default shell gate and checks
the lock, notice and installer wiring, including tamper, orphan and missing-notice
non-vacuity probes.

On hardware, after submitting credentials, confirm: the `CeraLive-Setup-*` hotspot
disappears, `journalctl -t ceralive-provision -t ceralive-portal` shows the join +
teardown, and CeraUI answers on the device's new IP or selected `.local`
hostname (`ceralive.local`, `ceralive2.local`, and so on).

### Shutdown cleanup

The provisioning service uses `service-stop` for ExecStop and checks the manager
state. Only `stopping` selects shutdown cleanup; every other state, empty output
or a failed query restores the application control plane, as do explicit
`stop`/`teardown` commands. The state string decides because `is-system-running`
also returns nonzero for `stopping`. Shutdown cleanup never starts CeraUI or the
button ingress. Portal stop jobs are queued without waiting during shutdown, and
NM link-down is bounded to five seconds (three seconds requested from nmcli). The
unit has a ten-second stop budget. This avoids blocking behind systemd's shutdown
transaction until its default 90-second timeout; AP profile and retrigger flags
remain available next boot.

# Power admission: deliberate power-off and reboot

A deliberate power-off or reboot goes through one admission path,
`ceralive-power`, and then through logind. It may end a stream on purpose, but it
never cuts a running system write. Every other shutdown waits for running writes
too, through `ceralive-write-drain.service`.

## Who may ask

| Origin | How the broker knows | What it may ask | Its intent |
| --- | --- | --- | --- |
| Power button, completed 3 s hold | peer is root in exactly `ceralive-button.service` | power-off | the physical hold |
| CeraUI, after its own checks and dialog | peer is root in exactly `ceralive.service` | power-off, reboot | CeraUI's gate and the dialog's confirm |
| Operator at a terminal: `ceralive-poweroff`, `ceralive-reboot` | root, or a member of `ceralive-power` (`ceralive`, and `ceralive-tailscale` on remote-access images) | power-off, reboot | a word typed on their own terminal |

The broker reads the caller from the socket: `SO_PEERCRED` and the socket-bound
peer pidfd (`SO_PEERPIDFD`), never from what the client sends. Without a peer pidfd
the request is refused. `/proc` reads are bracketed by that pidfd so they can't
describe a recycled PID. The unit is the caller's cgroup directly under
`/system.slice`; user units, nested scopes and similarly named units don't match.

**Operator confirmation.** The broker finds the caller's controlling terminal in
`/proc/<pid>/stat`. It must be in the system's mount namespace, and the caller must
be in that terminal's foreground process group. The broker opens the device itself
(no symlinks, verified with `fstat`: character device, same device number, owned
by the caller). It discards anything typed earlier, prints what will happen and
reads one line within 60 s. Only the exact word (`poweroff` or `reboot`) admits the
request. Before accepting, the broker checks again that the caller, its terminal,
session and foreground group are unchanged.

`sudo ceralive-poweroff` works with Debian's default `use_pty`: sudo runs the
command on its own root-owned pseudo-terminal that relays the person's terminal, so
the prompt and the typed word pass through it. Without `use_pty`, root would sit on
the login user's terminal and is refused; log in as the operator instead.

Refused: no terminal (`ssh box ceralive-poweroff`, cron, services), a piped answer,
a terminal owned by another account, a second prompt on the same
terminal, a timeout, a wrong word, or a caller that exits or hangs up. Nothing is
cached: every request asks again. Automation that drives a terminal and types the
word is deliberate automation. Release images have no passwords
(`passwd -l ceralive root`), which is why this is a typed word and not a polkit
password prompt.

## One commit at a time

Only one action is committed. A matching second request reports `PENDING` and
follows it; a conflicting one is refused. A client that disconnects after
admission does not cancel or resubmit anything. Up to 32 connections and 4
operator prompts are served at once; the button and CeraUI are still accepted
when operators fill the socket.

## Waiting for writes, then logind

An admitted request is held in the broker, upstream of logind, until the writers
have settled. A separate thread does this, so slow checks never delay admission
or a terminal prompt.

1. The power fence `/run/ceralive-power/fence` is written first. RAUC's
   pre-install handler (`/usr/lib/rauc/ceralive-pre-install`, set in every
   generated `system.conf`) refuses an install while it exists. RAUC runs that
   handler in its install worker after mounting the bundle and before writing
   any slot, whoever started the install: the CLI, a direct D-Bus call or the
   hawkBit updater. An install either became visible to the checks below or is
   refused before writing.
2. The broker takes `/run/lock/ceralive-update.lock`. The update units take it
   with `flock -n`, so a new RAUC staging, apt update, kernel stage or slot sync is
   refused. Only then does it take dpkg's frontend lock (`fcntl`, like apt). It
   keeps that one descriptor, and nothing in the broker opens the lock file again,
   because closing any descriptor on that file would drop the lock. It doesn't
   take dpkg while an update holds the update lock, so it never wedges an update
   between its apt phases.
3. It waits until no RAUC install runs and no writer is executing:
   - RAUC's `Installer.Operation` is `idle`, and nothing is mounted under RAUC's
     mount prefix (`/mnt/rauc/`). The second check is the authoritative one:
     RAUC 1.15.2 reports `idle` after rejecting a competing install while the
     first one still runs, but that install keeps its bundle mounted until it has
     finished. An unreadable answer counts as busy.
   - No writer unit is executing: `ceralive-software-update`,
     `ceralive-os-stage-guard`, `ceralive-slot-sync`, `ceralive-boot-script-sync`,
     `ceralive-kernel-stage-*` and `ceralive-rauc-arm@*`. A unit kept active after
     it finished (`RemainAfterExit=yes`, sub-state `exited`) is a receipt, not work.
   - No slot activation holds its lock.
4. It calls logind directly with `dbus-send`: `PowerOffWithFlags` or
   `RebootWithFlags` with `SD_LOGIND_SKIP_INHIBITORS`. There is no `systemctl` and
   no fallback to a direct target start. The D-Bus error name decides: a typed
   refusal (`AccessDenied`, `ServiceUnknown`, a masked unit, …) is `failed`, and
   the fence goes. No reply, a timeout, a lost connection or an error without a
   name is `uncertain`: the fence stays and nothing is retried.

Each admitted request gets an id, published with its state in
`/run/ceralive-power/state.json` and returned to the client
(`ADMITTED poweroff <id>`). States: `admitted`, `waiting` (with what it waits
for), `stuck` after 15 minutes (still waiting, never cut), `submitting`,
`submitted`, `failed`, `uncertain`.

**Broker restart.** A restarted broker reads that file. A request that wasn't
submitted yet keeps waiting. One that may have reached logind is reported
`uncertain`, keeps its fence and is never submitted again.

**Polkit.** The rule `60-ceralive-power-broker.rules` grants the power-off and
reboot `*-ignore-inhibit` actions only to root in exactly `ceralive-power.service`,
and answers `no` to everyone else for the three ignore-inhibit actions. So under
CeraUI's block lock, only the broker can skip it. `subject.system_unit` comes
from the D-Bus caller's pidfd: an ordinary process can't claim the broker's unit
by name, and a user service of the same name isn't that system unit. An
unrestricted root process that can manage systemd units or cgroups is outside
this boundary: it could run as the broker, or bypass logind entirely.

When no block lock is held, logind doesn't ask for the ignore-inhibit actions at
all, so raw root `systemctl poweroff -i` works through ordinary power
authorization. That's fine: nothing is protected then. The shutdown drain still
waits for running writes.

## Every shutdown waits for writes

`ceralive-write-drain.service` is active from boot and ordered after `rauc.service`,
the update and slot units, slot activation, boot-script sync, NetworkManager and
ModemManager. Per-attempt units order themselves before it: CeraUI's
`ceralive-kernel-stage-<id>.service` and the image's `ceralive-rauc-arm@.service`
carry `Before=ceralive-write-drain.service`. Stop order is the reverse, so during
any shutdown its `ExecStop` runs first. It writes the power fence, then returns
only when no write runs (the same checks as above, plus dpkg's lock holder). That
covers paths that don't use the broker: logind's own power-key handling (the
daemon-down fallback, where a short tap powers off) and a plain root `poweroff` on
an idle box. Networking stays up meanwhile, which a streamed RAUC install needs.

The drain has no timeout. After 15 minutes it writes a wall message saying what it
waits for. systemd's stock `poweroff`, `reboot` and `halt` targets would force the
action after 30 minutes (`JobTimeoutSec=30min`, `JobTimeoutAction=*-force`), so
`60-ceralive-wait-for-writes.conf` removes that deadline on all three. Every other
unit keeps its own stop timeout, so only a running write can hold a shutdown this
long. Cutting a stuck write is a separate decision: holding the power button until
the PMIC cuts power, about 10 s.

Only a system state that says the box is up (`running`, `degraded`, `starting`, …)
makes a manual `systemctl stop ceralive-write-drain` return at once. An empty or
unreadable state waits like a shutdown.

## Outside the guarantee

- Root commands that bypass logind (`systemctl poweroff --force`, starting
  `poweroff.target` directly) and the PMIC hold cut whatever runs.
- `systemctl stop ceralive` followed by plain `poweroff` remains a break-glass way
  to stop a stream; the drain still waits for writes.
- CeraUI's own configuration writes are atomic renames and aren't drained.

## Tests

- `tests/power-admission.bats` runs the hardware-free contracts
  (`tests/power-admission-contract.py`: real sockets and peer pidfds, a real
  pseudo-terminal, real locks) and checks the units, the rule, the target
  drop-ins, the RAUC handler and the installer.
- `CERALIVE_POWER_TEST_CONTAINER=<name> tests/real-power-admission.sh [--shutdown]`
  runs against real systemd 257, logind, polkit, OpenSSH and RAUC in a disposable
  container. It covers every origin, the raw `-i` refusal, a missing logind or
  polkit, a finished unit kept active, a direct D-Bus install while the broker
  waits, and a RAUC install whose client was killed. With `--shutdown` it runs one
  real power-off with a 10 s forced target deadline (the install is cut), then one
  with the image's drop-ins (the drain waits for the install).
- `CERALIVE_RAUC_TEST_CONTAINER=<name> tests/real-rauc-admission.sh` checks the
  RAUC side against the RAUC a container ships, also the image's own 1.15.2
  package in an arm64 container under qemu. It covers the bundle mount as the
  witness when RAUC reports `idle` after rejecting a competing install, and a
  fenced direct D-Bus install refused before writing.

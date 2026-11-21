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
`/proc/<pid>/stat`. It must be a system terminal, and the caller must be in that
terminal's foreground process group. A caller in the system's mount namespace
shares its `/dev/pts`. A caller in another mount namespace must hold that terminal
open on stdin, stdout or stderr, and the open file must be the same device and
inode as the system's `/dev/pts` entry. That is the case for a Tailscale SSH
session: `tailscaled.service` gets its own mount namespace from `ReadOnlyPaths=`,
its sessions inherit it, and their terminals are on the system's devpts. A pty of
a private devpts instance can carry the number of a different system terminal and
is refused. The number is also bound to the caller's session: the broker refuses
when any other session has a process whose controlling terminal shows that number.
A terminal is the controlling terminal of at most one session, and that session's
leader keeps it, so this rules out prompting on a terminal another session of the
same account controls, in any namespace. The broker opens the device itself
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
follows it; a conflicting one is refused. An operator's request is looked up
and joined under one lock, and joining never creates a request: if nothing is
pending, the operator goes through the typed-word prompt. Only the button,
CeraUI, or an operator whose word was checked on their own terminal can create
one. A client that disconnects after
admission does not cancel or resubmit anything. Up to 32 connections and 4
operator prompts are served at once; the button and CeraUI are still accepted
when operators fill the socket.

## Waiting for writes, then logind

An admitted request is held in the broker, upstream of logind, until the writers
have settled. A separate thread does this, so slow checks never delay admission
or a terminal prompt.

1. The broker's power fence `/run/ceralive-power/fence.d/broker` is written
   first. RAUC's pre-install handler (`/usr/lib/rauc/ceralive-pre-install`, set
   in every `system.conf` the image can carry, the inline fallback in
   `mkosi.postinst.chroot` included) refuses an install while any fence exists in
   `fence.d`. RAUC runs that
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
   - RAUC's `Installer.Operation` is `idle`, and nothing is mounted below RAUC's
     mount prefix in RAUC's own mount namespace. The packaged unit runs
     `rauc --mount=/run/rauc/mnt service` with `MountFlags=slave`, so its bundle
     mounts never show up in PID 1's mount table. The broker asks D-Bus for the
     owner of `de.pengutronix.rauc`, takes the prefix from that process's command
     line (else `mount-prefix=` in `system.conf`, else `/mnt/rauc`) and reads
     `/proc/<pid>/mountinfo`. The prefix itself is a mount point there
     (systemd binds the `RuntimeDirectory=` in) and doesn't count. `Operation`
     and the mount table are read between two owner lookups and count only when
     both found the same process (pid and start time). A changed owner is looked
     at again; one that never holds still counts as busy. Without a bus owner,
     `rauc.service` must be `inactive` or `failed`: a worker tearing down after
     its name is gone may still hold its bundle. A RAUC that starts after the
     fence can't write, because its install passes the pre-install handler
     after mounting. The mount check
     is the authoritative one: RAUC 1.15.2 reports `idle` after rejecting a
     competing install while the first one still runs, but that install keeps
     its bundle mounted until it has finished. An unreadable answer counts as
     busy.
   - No writer unit is executing: `ceralive-software-update`,
     `ceralive-os-stage-guard`, `ceralive-slot-sync`, `ceralive-boot-script-sync`,
     `ceralive-kernel-stage-*` and `ceralive-rauc-arm@*`. A unit kept active after
     it finished (`RemainAfterExit=yes`, sub-state `exited`) is a receipt, not work.
   - No slot activation holds its lock.
4. It records `submitting` first; if that can't be written, nothing is sent.
   Then it calls logind directly with `dbus-send`: `PowerOffWithFlags` or
   `RebootWithFlags` with `SD_LOGIND_SKIP_INHIBITORS`. There is no `systemctl` and
   no fallback to a direct target start. The D-Bus error name decides: a typed
   refusal (`AccessDenied`, `ServiceUnknown`, a masked unit, …) is `failed`, and
   the broker's fence goes (only its own; the drain's fence stays). No reply, a
   timeout, a lost connection or an error without a name is `uncertain`: the
   fence and the update lock stay, nothing is retried, and nothing new is
   taken until the box restarts or an operator clears it (below).

The admission lock only guards the request record. The probes, the locks and
the logind call run outside it, so a slow check never holds up a new client.

**The record.** `/run/ceralive-power/state.json` is the broker's one persisted
state. The latest request sits at the top level (`state`, `id`, `action`,
`origin`, `detail`), and every request of this boot sits under `requests` by
id. One function writes it, under the broker's lock, as one atomic replacement
(temporary file, fsync, rename). Nothing changes in memory unless the rename
happened, so what a client is told and what a restarted broker reads always
agree:
- An admission is that one write. If it fails, the client gets `REFUSED` and
  the file is unchanged. Only after it does the id go back to the client
  (`ADMITTED poweroff <id>`).
- `submitting` is written before logind is called; if that write fails, nothing
  is sent.
- A failure is let go only once it is recorded under its id. Until then the
  request stays (`failing`, retried each second) and nothing newer can replace
  it. Clients waiting on it get `FAILED … (not recorded yet …)` at once and are
  disconnected; new requests are refused with the reason ("refused by logind
  … could not be recorded yet"). The fence and the locks are already released,
  so updates aren't held. A failure that stays unrecordable (say `/run` is
  full) is repaired by freeing the space; a broker restarted meanwhile finds
  `submitting` and reports `uncertain` without resubmitting.
- A finished request (`failed`, `submitted`) is kept for 24 hours of boot time
  (`CLOCK_BOOTTIME`, with the boot id; a wall-clock correction doesn't age it);
  anything else is never dropped. A reader that tracks an id, like CeraUI, reads
  `requests[<id>]`, so newer requests can't hide its result.

States: `admitted`, `waiting` (with what it waits for), `stuck` after 15 minutes
(still waiting, never cut), `submitting`, `submitted`, `failed`, `uncertain`.

**Broker restart.** A restarted broker reads that file and keeps its
`requests`. A request that wasn't submitted yet keeps waiting. One that may
have reached logind is reported `uncertain`, keeps its fence and is never
submitted again.

Only a start with no record and no broker fence is idle. Lost evidence is not:
- A record that exists but can't be read is never written over.
- A broker fence that survived without a record of its request (or whose
  request isn't recorded as `failed`) means a request got past admission.

A record that parses but lacks what its state needs (a known `state`; for a
request, its id and action; `requests` as an object) counts as unreadable too.
In all these cases the broker keeps its fence and the update lock, restoring
them with backoff (1 s doubling to 30 s) until both hold. It reports
`uncertain` where it can write, and refuses new requests with the reason. A
quiet period proves nothing: logind may still be waiting for authorization of
the earlier call, which no visible property shows. So the broker never clears
this by itself.

**Explicit recovery.** An operator at their own terminal runs
`ceralive-poweroff --recover`. The broker prompts there, names the request (id
and action), says its outcome is unknown and that a shutdown may still be in
flight, and reads the typed word `recover`, under the same terminal checks as a
power-off. The confirmation clears only the request the prompt named: if that
one is gone or another took its place, it is refused ("the uncertain request
changed; run --recover again"). One recovery is checked at a time; another one
meanwhile is refused with a reason, and every operator gets an answer. It then
refuses if a shutdown is visibly under way: logind preparing for shutdown, a
shutdown job queued, or the manager not plainly `running` or `degraded`. Any
error or empty answer counts as under way. Otherwise it records the request as
`uncertain` and cleared, drops its fence and the locks, and takes requests
again. Nothing is resubmitted. The button and CeraUI can't recover. A reboot
also clears it (`/run` is per boot). While a request's outcome is unknown,
every other request, the same action included, is refused with these
instructions; none joins it. Only a record with exactly `"cleared": true` (and
the request's id) counts as recovered; any other `cleared` value makes the
record unreadable.

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

`ceralive-write-drain.service` is active within seconds of boot and ordered after
`rauc.service`, the update and slot units, slot activation, NetworkManager and
ModemManager. Its start waits for nothing slow: a shutdown queued while its start
job still waits would cancel that job, and then no `ExecStop` runs. The boot-only
oneshots (dpkg recovery, the health check, mark-good, boot-script sync) have
finished before anything ordered after them can start, so an ordering against
them would protect nothing and only leave the drain off for the whole boot health
chain. While they run, deliberate power-offs go through the broker's update and
dpkg locks and writer check; the drain still counts boot-script sync as a writer,
dpkg recovery is journaled and re-runs on the next boot, and the boot.scr sync
replaces its file atomically. Per-attempt units order themselves before it: CeraUI's
`ceralive-kernel-stage-<id>.service` and the image's `ceralive-rauc-arm@.service`
carry `Before=ceralive-write-drain.service`. Stop order is the reverse, so during
any shutdown its `ExecStop` runs first. It writes its own fence,
`fence.d/shutdown`, and doesn't continue until that write has succeeded (until
then it counts as busy and retries). Then it returns only when no write runs (the same checks as above, plus dpkg's lock holder). That
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

**When the broker refuses.** While a failure can't be recorded, or while a
request's outcome is unknown (above), the broker refuses new requests, the
button's hold included: the running button daemon sends its hold to the broker
and shows its usual refusal. CeraUI shows that the box was not shut down, and
the broker's `uncertain` notice when the record could be written. What works
then:
- `ceralive-poweroff --recover` at an operator's terminal, for an unknown
  outcome;
- logind's own key handling (the short tap) only applies once the button
  daemon is down and has handed the key back to logind. The shutdown then goes
  through the drain, which must first write its own fence (`fence.d/shutdown`).
  If storage also refuses that write, the drain keeps waiting on purpose;
- root on the box (`systemctl poweroff`), which also goes through the drain;
- holding the power button until the PMIC cuts power, the last resort.

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
  RAUC side against the RAUC a container ships, started through its packaged unit
  (`--mount=/run/rauc/mnt`, `MountFlags=slave`). It uses the broker's own witness:
  it must see the bundle mount when RAUC reports `idle` after rejecting a
  competing install, while PID 1's mount table shows nothing. It also covers a
  fenced direct D-Bus install refused before writing, and the same install
  retried and succeeding once the fence is gone. Under qemu-user, systemd can't
  set up the unit's mount namespace (226/NAMESPACE), so run it natively: the
  image's `rauc-service` package with RAUC 1.15.2 built for the host from the
  same sources.

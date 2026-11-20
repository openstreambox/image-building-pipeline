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

After admission the broker fences new writers and waits for running ones:

1. It takes `/run/lock/ceralive-update.lock` exclusively. The update units take it
   with `flock -n`, so a new RAUC staging, apt update, kernel stage or slot sync
   is refused while a power-off is pending.
2. It takes dpkg's frontend lock (`fcntl`, like apt), which waits for a running
   dpkg and blocks new ones.
3. It stops the dormant-by-default hawkBit updater if it runs, so it cannot start a
   RAUC install through D-Bus.
4. It waits until RAUC's `Installer.Operation` is `idle` and no writer unit
   (`ceralive-software-update`, `ceralive-os-stage-guard`, `ceralive-slot-sync`,
   `ceralive-kernel-stage-*`) is active, and until no slot activation holds its
   lock. RAUC is checked at the service, so an install whose client was killed is
   still waited for.
5. It calls logind directly over D-Bus: `PowerOffWithFlags` or `RebootWithFlags`
   with `SD_LOGIND_SKIP_INHIBITORS`. There is no `systemctl` and no fallback to a
   direct target start. A refusal is reported as `failed` and the fence is
   released; an unanswered call is `uncertain` and is never retried.

States, in `/run/ceralive-power/state.json` and streamed to the client:
`admitted`, `waiting` (with what it waits for), `stuck` after 15 minutes (still
waiting, never cut), `submitting`, `submitted`, `failed`, `uncertain`.

The polkit rule `60-ceralive-power-broker.rules` grants the power-off and reboot
`*-ignore-inhibit` actions only to root in `ceralive-power.service`, and answers
`no` to everyone else for the three ignore-inhibit actions. So `systemctl poweroff -i`
is refused while CeraUI's block lock is held. Without a block lock logind doesn't
ask for these actions, and root's plain power commands follow ordinary rules.

## Every shutdown waits for writes

`ceralive-write-drain.service` is active from boot and ordered after `rauc.service`,
the writer units, NetworkManager and ModemManager. Stop order is the reverse, so
during any shutdown its `ExecStop` runs first and returns only when no write is
running. That covers paths that don't use the broker: logind's own power-key
handling (the daemon-down fallback, where a short tap powers off), and plain root
`poweroff` on an idle box. Networking stays up meanwhile, which a streamed RAUC
install needs. The drain has no timeout; after 15 minutes it writes a wall message
saying what it waits for. Cutting a stuck write is a separate decision: holding the
power button until the PMIC cuts power, about 10 s.

A manual `systemctl stop ceralive-write-drain` returns at once; the drain only
waits while the system is stopping.

## Outside the guarantee

- Root commands that bypass logind (`systemctl poweroff --force`, starting
  `poweroff.target` directly) and the PMIC hold cut whatever runs.
- `systemctl stop ceralive` followed by plain `poweroff` remains a break-glass way
  to stop a stream; the drain still waits for writes.
- CeraUI's own configuration writes are atomic renames and aren't drained.

## Tests

- `tests/power-admission.bats` runs the hardware-free contracts (real sockets and
  peer pidfds, a real pseudo-terminal, real locks) and checks the units, the rule
  and the installer.
- `CERALIVE_POWER_TEST_CONTAINER=<name> tests/real-power-admission.sh [--shutdown]`
  runs against real systemd 257, logind, polkit, OpenSSH and RAUC in a disposable
  container: every origin, the raw `-i` refusal, a missing logind or polkit, a RAUC
  install whose client was killed, and with `--shutdown` one real power-off that has
  to wait for that install.

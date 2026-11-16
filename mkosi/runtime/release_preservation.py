"""Inert update, selector-entry and mirror owners. No installed device adapters."""
import re
import secrets
import time

import recovery_witness as witness

WEEK = 604800
OWNERS = {'update', 'selector', 'mirror'}


def _walltime():
    return time.time()


def walltime():
    try:
        return witness.uptime(_walltime())
    except Exception:
        return None


def digest(value):
    if not isinstance(value, str) or not re.fullmatch(witness.PIN_FORMAT, value):
        raise ValueError('unknown release identity')
    return value


def initial(current, slot):
    return dict(phase='idle', new_release=current, new_slot=slot,
                previous_release=None, previous_slot=None, activation=None,
                activated_wall=None, clock_boot=None, clock_uptime=None,
                clock_wall=None, elapsed=0, full_stream=False, retired=False,
                effect=None, refusal=None)


def validate(r):
    if r is None:
        return
    if type(r) is not dict or set(r) != set(initial(None, None)):
        raise ValueError('unknown preservation shape')
    digest(r['new_release'])
    if r['new_slot'] not in {'A', 'B'} or r['phase'] not in {'idle', 'pending', 'active'}:
        raise ValueError('unknown preservation phase or slot')
    if type(r['full_stream']) is not bool or type(r['retired']) is not bool:
        raise ValueError('invalid preservation verdict')
    witness.uptime(r['elapsed'])
    if r['elapsed'] > WEEK or (r['refusal'] is not None and
                              (type(r['refusal']) is not str or len(r['refusal']) > 256)):
        raise ValueError('invalid preservation evidence')
    if r['phase'] == 'idle':
        expected = initial(r['new_release'], r['new_slot'])
        expected['refusal'] = r['refusal']
        if r != expected:
            raise ValueError('invalid initial preservation state')
        return
    digest(r['previous_release'])
    if (r['previous_release'] == r['new_release'] or
            r['previous_slot'] not in {'A', 'B'} or r['previous_slot'] == r['new_slot'] or
            not isinstance(r['activation'], str) or not re.fullmatch('[0-9a-f]{32}', r['activation'])):
        raise ValueError('invalid activation binding')
    if r['phase'] == 'pending':
        if (any(r[k] is not None for k in ('activated_wall', 'clock_boot', 'clock_uptime', 'clock_wall'))
                or r['elapsed'] or r['full_stream'] or r['retired'] or r['effect'] is not None):
            raise ValueError('pending activation has unearned evidence')
    else:
        witness.uptime(r['activated_wall'])
        if r['clock_boot'] is None:
            if r['clock_uptime'] is not None or r['clock_wall'] is not None:
                raise ValueError('partial clock anchor')
        else:
            witness.boot_id(r['clock_boot'])
            witness.uptime(r['clock_uptime'])
            witness.uptime(r['clock_wall'])
        if r['effect'] is not None and r['effect'] not in OWNERS:
            raise ValueError('unknown retirement owner')
        if (r['effect'] is not None or r['retired']) and (not r['full_stream'] or r['elapsed'] < WEEK):
            raise ValueError('retirement without qualification')


def reasons(record):
    r = record.get('retention')
    if record['source'] != 'valid' or r is None:
        return ['Previous release retained: preservation evidence unavailable; local repair required.']
    result = []
    if r['phase'] == 'idle':
        result.append('Previous release retained: no new activation recorded.')
    elif r['phase'] == 'pending':
        result.append('Previous release retained: new activation not observed.')
    elif not r['retired']:
        if not r['full_stream']:
            result.append('Previous release retained: one full healthy stream not recorded.')
        if r['elapsed'] < WEEK:
            result.append('Previous release retained: seven days of proven elapsed time not recorded.')
        if r['clock_wall'] is None or r['clock_wall'] - r['activated_wall'] < WEEK:
            result.append('Previous release retained: seven-day wall-clock floor not proven.')
        if r['effect'] is not None:
            result.append('Previous release retained: interrupted retirement requires the same owner to retry.')
    if r['refusal']:
        result.append(r['refusal'])
    return result


def status(record):
    r = record.get('retention')
    why = reasons(record)
    return dict(release_retirement_allowed=False,  # a projection never grants an effect
                release_retention_eligible=bool(r and not why and not r['retired']),
                release_retention_reasons=why,
                previous_release_retired=bool(r and record['source'] == 'valid' and r['retired']))


class Owners:
    """All writers share the witness lock and its single atomic generation.

    Collectors and effects are trusted, bounded, synchronous, non-reentrant
    adapters. Effects receive an exact release/slot plan and must enforce it,
    including boot artifacts and selector entries. Retrying an interrupted effect
    must be idempotent. Nothing here installs those adapters or enables boot policy.
    """

    def __init__(self, store):
        self.store = store

    def _proof(self, boot, probe):
        try:
            p = probe()
            if not isinstance(p, dict):
                raise ValueError('missing observation')
            age = witness._boottime() - witness.uptime(p.get('observed_uptime'))
            if p.get('boot_id') != boot or not 0 <= age <= witness.FRESH_SECONDS:
                raise ValueError('stale observation')
            digest(p.get('running_release'))
            if p.get('running_slot') not in {'A', 'B'} or p.get('bootable') is not True:
                raise ValueError('unverified running release')
            return p
        except Exception:
            return None

    def _record(self, boot):
        witness.boot_id(boot)
        record = self.store.read()
        if record['current_boot'] != boot or record['source'] != 'valid':
            return record, None
        return record, record['retention']

    def _refuse(self, record, message, *, break_clock=False):
        r = record.get('retention')
        if r is not None:
            r['refusal'] = message
            if break_clock:
                r.update(clock_boot=None, clock_uptime=None, clock_wall=None)
        # Missing/corrupt state is never initialized here. Its unknown source and
        # reason are projected even though there is no trustworthy field to edit.
        if record['current_boot'] is not None:
            self.store.write(record)
        else:
            import hashlib
            self.store.project(record, hashlib.sha256(witness.encoded(record)).hexdigest())
        return dict(allowed=False, reasons=status(record)['release_retention_reasons'] or [message])

    @staticmethod
    def _running(record, r, p):
        return bool(p and p['running_release'] == r['new_release'] and
                    p['running_slot'] == r['new_slot'] and
                    record['boots'][record['current_boot']]['slot'] == r['new_slot'])

    @staticmethod
    def _eligible(r, now_wall):
        return (r['phase'] == 'active' and r['full_stream'] and r['elapsed'] >= WEEK
                and now_wall is not None and now_wall - r['activated_wall'] >= WEEK)

    def provision(self, boot, *, probe):
        """Explicit local setup only; never infer a prior release after data loss."""
        with self.store.locked():
            record, r = self._record(boot)
            if r is not None:
                raise FileExistsError('preservation already provisioned')
            p = self._proof(boot, probe)
            if (record['source'] != 'valid' or record['current_boot'] != boot or not p
                    or record['boots'][boot]['health'] != 'healthy'
                    or record['boots'][boot]['slot'] != p['running_slot']):
                raise ValueError('fresh known-good running release required')
            record['retention'] = initial(p['running_release'], p['running_slot'])
            self.store.write(record)

    def _armed(self, boot, pinned, p):
        return witness.Store.evidence(boot, pinned, lambda: p)[0]

    def _effect(self, record, boot, p, plan, apply):
        # Intent is already in record; durable commit MUST precede any effect.
        self.store.write(record)
        if not 0 <= witness._boottime() - p['observed_uptime'] <= witness.FRESH_SECONDS:
            return self._refuse(record, 'Previous release retained: evidence expired during persistence.')
        apply(dict(plan))
        return dict(allowed=True, plan=plan)

    def update(self, boot, *, candidate, pinned_bootloader, probe, apply):
        """Write only the other slot; preserve the current release before install."""
        digest(candidate)
        with self.store.locked():
            record, r = self._record(boot)
            if r is None:
                return self._refuse(record, 'Previous release retained: preservation state unavailable.')
            p = self._proof(boot, probe)
            if not self._running(record, r, p):
                return self._refuse(record, 'Previous release retained: running release identity is unknown or changed.')
            why = self._armed(boot, pinned_bootloader, p)
            if why:
                return self._refuse(record, why[0])
            if record['rescue']['required'] or record['remaining'] == 0:
                return self._refuse(record, 'Previous release retained: recovery is not available for an update.')
            if r['phase'] == 'pending' or r['effect'] is not None:
                return self._refuse(record, 'Previous release retained: interrupted operation needs reconciliation.')
            if (r['phase'] != 'idle' and not r['retired']
                    and not self._eligible(r, walltime())):
                return self._refuse(record, 'Previous release retained: update would replace an unqualified previous release.')
            try:
                digest(p.get('target_release'))
            except ValueError:
                return self._refuse(record, 'Previous release retained: target release identity unavailable.')
            if (p.get('target_slot') not in {'A', 'B'} or p['target_slot'] == r['new_slot']
                    or candidate == r['new_release']
                    or r['phase'] != 'idle' and not r['retired'] and
                    (p['target_release'] != r['previous_release'] or p['target_slot'] != r['previous_slot'])):
                return self._refuse(record, 'Previous release retained: update target does not match the other slot.')
            next_record = initial(candidate, p['target_slot'])
            next_record.update(phase='pending', previous_release=r['new_release'],
                               previous_slot=r['new_slot'], activation=secrets.token_hex(16))
            record['retention'] = next_record
            plan = dict(owner='update', release=candidate, slot=p['target_slot'],
                        activation=next_record['activation'])
            return self._effect(record, boot, p, plan, apply)

    def observe(self, boot, *, probe):
        """Observe actual activation and accumulate conservative elapsed time.

        Each same-boot delta earns min(positive boot-clock delta, positive wall
        delta). No time is earned across reboot, bad evidence or clock reversal.
        No callback accepts a caller-supplied clock or activation timestamp.
        """
        with self.store.locked():
            record, r = self._record(boot)
            p = self._proof(boot, probe)
            if r is None:
                return self._refuse(record, 'Previous release retained: preservation state unavailable.')
            if not self._running(record, r, p) or r['phase'] == 'idle':
                return self._refuse(record, 'Previous release retained: fresh activation evidence unavailable.',
                                    break_clock=r['phase'] == 'active')
            now, wall = witness.uptime(witness._boottime()), walltime()
            if wall is None:
                return self._refuse(record, 'Previous release retained: wall clock unavailable.',
                                    break_clock=r['phase'] == 'active')
            if r['phase'] == 'pending':
                r.update(phase='active', activated_wall=wall)
            elif r['clock_boot'] == boot:
                mono_delta, wall_delta = now - r['clock_uptime'], wall - r['clock_wall']
                if mono_delta < 0:
                    r['elapsed'] = 0
                if mono_delta >= 0 and wall_delta >= 0:
                    r['elapsed'] = min(WEEK, r['elapsed'] + min(mono_delta, wall_delta))
            r.update(clock_boot=boot, clock_uptime=now, clock_wall=wall, refusal=None)
            self.store.write(record)
            return dict(allowed=True)

    def stream(self, boot, *, probe):
        """Trusted media owner attests a completed real stream, never a snapshot.

        The collector must verify the entire stream was healthy on this exact
        activation, not just that media was healthy when queried. The witness is
        an additional current-health check, not a substitute for that collector.
        """
        with self.store.locked():
            record, r = self._record(boot)
            p = self._proof(boot, probe)
            if (r is None or r['phase'] != 'active' or not self._running(record, r, p)
                    or p.get('activation') != r['activation'] or p.get('full_healthy_stream') is not True
                    or record['boots'][boot]['health'] != 'healthy'):
                return self._refuse(record, 'Previous release retained: full healthy stream evidence unavailable.')
            r.update(full_stream=True, refusal=None)
            # Keep the existing observation vocabulary in the same atomic witness.
            record['release'].update(new_release=r['new_release'], previous_release=r['previous_release'],
                                     activated_at=r['activated_wall'], full_healthy_stream=True,
                                     trusted_now=walltime())
            self.store.write(record)
            return dict(allowed=True)

    def retire(self, boot, *, owner, pinned_bootloader, probe, apply):
        """Guard GC/update cleanup, selector-entry removal and destructive mirror.

        Callbacks own ALL copies, boot files and entries of the exact previous
        release. This never authorizes deleting the running release or bootloader.
        """
        if owner not in OWNERS:
            raise ValueError('unknown preservation owner')
        with self.store.locked():
            record, r = self._record(boot)
            p = self._proof(boot, probe)
            if r is None:
                return self._refuse(record, 'Previous release retained: preservation state unavailable.')
            if (not self._running(record, r, p) or p.get('target_release') != r['previous_release']
                    or p.get('target_slot') != r['previous_slot'] or r['retired']):
                return self._refuse(record, 'Previous release retained: exact running and target identities required.')
            why = self._armed(boot, pinned_bootloader, p)
            if why:
                return self._refuse(record, why[0])
            if (not self._eligible(r, walltime()) or
                    r['effect'] is not None and r['effect'] != owner):
                return self._refuse(record, 'Previous release retained: retirement requirements not met.')
            r.update(effect=owner, refusal=None)
            plan = dict(owner=owner, release=r['previous_release'], slot=r['previous_slot'],
                        activation=r['activation'])
            result = self._effect(record, boot, p, plan, apply)
            if result['allowed']:
                r.update(retired=True, effect=None)
                self.store.write(record)
            return result

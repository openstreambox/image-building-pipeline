"""Independent, host-only Power supervisor link v1 reference decoder.

Read LF-delimited bytes from stdin; emit decoded state as JSON after each line.
No serial access, third-party modules or target runtime dependency.
"""
import binascii
import json
import re
import sys


class Decoder:
    def __init__(self):
        self.result = dict.fromkeys(('accepted', 'restarts', 'missed', 'crc', 'malformed',
                                    'oversize', 'ignored', 'unknown_version', 'out_of_order'), 0)
        self.result.update(seq=0, boot='', have_status=False, rx_ms=0, fields={}, events=[])
        self.clocks = {}
        self.regression = []
        self.special = None
        self.now = 0

    @staticmethod
    def uint(text, base=10):
        if not re.fullmatch(r'[0-9]+' if base == 10 else r'[0-9a-fA-F]+', text):
            raise ValueError('invalid integer')
        value = int(text, base)
        if value > 0xffffffff:
            raise ValueError('integer overflow')
        return value

    @staticmethod
    def pairs(tokens):
        fields = {}
        for token in tokens:
            key, sep, value = token.partition('=')
            if (not sep or not re.fullmatch(r'[A-Za-z0-9_]{1,31}', key)
                    or not 1 <= len(value) <= 159 or key in fields or len(fields) == 48):
                raise ValueError('invalid field')
            fields[key] = value
        return fields

    def decode(self, raw):
        self.now += 1000
        r = self.result
        # A complete line is the public entry point; streaming hosts buffer to LF.
        if not raw.endswith(b'\n'):
            raise ValueError('incomplete line')
        payload = raw[:-1]
        nul = payload.find(b'\0')
        if nul >= 0 and nul < 511:
            r['malformed'] += 1
        elif len(raw) > 512:
            r['oversize'] += 1
        elif not payload.startswith(b'OSB1 '):
            if re.match(rb'OSB[0-9]+ ', payload):
                r['unknown_version'] += 1
                self.special = 'unknown_version'
            else:
                r['ignored'] += 1
                if not payload.startswith(b'OSB') and b'waiting for download' in payload:
                    self.special = 'bootloader'
        else:
            self.protocol(payload)
        r['link'] = self.special or ('ok' if r['have_status'] and self.now-r['rx_ms'] < 5000 else 'silent')
        # Return a snapshot, never aliases to mutable parser state.
        return json.loads(json.dumps(r))

    def protocol(self, payload):
        r = self.result
        body, sep, checksum = payload.rpartition(b' crc=')
        if (not sep or not re.fullmatch(rb'[0-9a-fA-F]{4}', checksum)
                or binascii.crc_hqx(body, 0xffff) != int(checksum, 16)):
            r['crc'] += 1
            return
        if any(c < 32 or c > 126 for c in payload):
            r['malformed'] += 1
            return
        try:
            text = body.decode('ascii')[5:]
            event = text.startswith('EVT ')
            if event:
                prefix, *trailer = text.rsplit(' ', 7)
                keys = ('seq', 'boot', 'rst', 'alive', 'hot', 'shutdowns', 'fw')
                if len(trailer) != 7 or any(not t.startswith(k+'=') for k, t in zip(keys, trailer)):
                    raise ValueError('event trailer')
                fields = self.pairs(trailer)
                uptime, space, human = prefix[4:].partition(' ')
                if not uptime.startswith('up='):
                    raise ValueError('event uptime')
                up = self.uint(uptime[3:])
            else:
                fields = self.pairs(text.split())
                up = self.uint(fields['up'])
            seq = self.uint(fields['seq'])
            if len(fields['boot']) != 8:
                raise ValueError('boot width')
            boot = f"{self.uint(fields['boot'], 16):08x}"
        except (ValueError, KeyError):
            r['malformed'] += 1
            return
        restart = bool(r['accepted'] and (boot != r['boot'] or
                       (event in self.clocks and up < self.clocks[event])))
        if r['accepted'] and not restart:
            delta = (seq-r['seq']) & 0xffffffff
            if delta == 0 or delta >= 0x80000000:
                if delta == 0:
                    self.regression = []
                elif self.regression and (seq-self.regression[-1]) & 0xffffffff == 1:
                    self.regression.append(seq)
                else:
                    self.regression = [seq]
                if len(self.regression) < 3:
                    r['out_of_order'] += 1
                    return
                restart = True
            else:
                r['missed'] += delta-1
        if restart:
            r['restarts'] += 1
            r['have_status'] = False
            self.clocks.clear()
        self.regression = []
        self.clocks[event] = up
        r.update(seq=seq, boot=boot, accepted=r['accepted']+1)
        self.special = None
        if event:
            r['events'] = (r['events']+[payload.decode('ascii')])[-1000:]
        else:
            r.update(fields=fields, have_status=True, rx_ms=self.now)


if __name__ == '__main__':
    decoder = Decoder()
    for wire in sys.stdin.buffer:
        print(json.dumps(decoder.decode(wire), sort_keys=True))

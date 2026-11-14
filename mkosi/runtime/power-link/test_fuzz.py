"""Reproducible C/Python differential checks, host-only and single worker."""
import binascii
import json
from pathlib import Path
import random
import subprocess
import sys

HERE = Path(__file__).resolve().parent


def frame(body):
    return body + f' crc={binascii.crc_hqx(body, 0xffff):04X}\n'.encode()


def main():
    totals = {}
    states = 0
    for seed in (17, 230, 680):
        rng = random.Random(seed)
        for sample in range(400):
            stream = bytearray()
            for i in range(rng.randrange(4, 30)):
                seq = rng.choice((i, 0, 1, 0xffffffff, 0x80000000, rng.getrandbits(32)))
                up = rng.choice((0, 1, 2, 100, 4294965, 4294966, 4294967))
                boot = rng.choice(('1234abcd', '1234ABCD', '00000000'))
                if rng.randrange(2):
                    body = f'OSB1 EVT up={up} text crc=literal seq={seq} boot={boot} rst=wdt alive=1 hot=none shutdowns=0 fw=test'.encode()
                else:
                    power = rng.choice(('ok', 'none', 'low', 'holdup', 'new'))
                    body = f'OSB1 up={up} seq={seq} boot={boot} power={power} gaps=0000 gaps2=8000'.encode()
                if body.startswith(b'OSB1 up='):
                    body += rng.choice((b' pack=ready/25.0C/00', b' pack=ready/uncal/00',
                                        b' pack=ready/na/00', b' pack=ready/0x1p0C/00',
                                        b' pack=ready/1e2C/00', b' profile=unfamiliar',
                                        b' thermal=hot', b' thermal=new'))
                mutation = rng.randrange(12)
                if mutation == 0:
                    body += rng.choice((b'\t', b'\r', b'\x7f', b'\xff'))
                wire = frame(body)
                if mutation == 1:
                    wire = wire[:-5] + b'000Z\n'
                elif mutation == 2:
                    wire = wire[:10] + b'\0' + wire[10:]
                elif mutation == 3:
                    wire = wire[:-1] + b'\r\n'
                elif mutation == 4:
                    wire = rng.choice((b'OSB10 ignored\n', b'OSB1x\n', b'waiting for download\n', b'noise\n'))
                elif mutation == 5:
                    wire = b'x' * rng.choice((510, 511, 512, 600)) + b'\0\n'
                stream.extend(wire)
            commands = ([str(HERE / 'test-vectors')],
                        [sys.executable, '-I', str(HERE / 'reference_decoder.py')])
            results = []
            for command in commands:
                output = subprocess.run(command, input=stream, capture_output=True, check=True)
                results.append([json.loads(row) for row in output.stdout.splitlines()])
            if results[0] != results[1]:
                raise AssertionError(f'disagreement: seed={seed}, sample={sample}')
            states += len(results[0])
            for key in ('accepted', 'restarts', 'missed', 'crc', 'malformed', 'oversize',
                        'ignored', 'unknown_version', 'out_of_order'):
                totals[key] = totals.get(key, 0) + results[0][-1][key]
            # The same streams exercise both semantic interpretations too.
            for mode in ('--semantics', '--published-semantics'):
                outputs = [subprocess.run([*cmd, mode], input=stream,
                                          capture_output=True, check=True).stdout for cmd in commands]
                if [json.loads(x) for x in outputs[0].splitlines()] != [json.loads(x) for x in outputs[1].splitlines()]:
                    raise AssertionError(f'{mode} disagreement: seed={seed}, sample={sample}')
    assert all(totals.values()), totals
    print(f'1200 streams, {states} states, framing, pure and published semantics: 0 disagreements')
    print(json.dumps(totals, sort_keys=True))


if __name__ == '__main__':
    main()

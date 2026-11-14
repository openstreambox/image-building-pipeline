"""Run the same fixed expectations against two independent decoders."""
import binascii
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

HERE = Path(__file__).resolve().parent


class VectorTest(unittest.TestCase):
    def test_semantics(self):
        cases = json.loads((HERE / 'fixtures/semantics.json').read_text())
        for case in cases:
            body = ('OSB1 up=0 seq=0 boot=1234abcd ' + case['fields']).rstrip().encode()
            wire = body + f' crc={binascii.crc_hqx(body, 0xffff):04X}\n'.encode()
            for command in ([os.fspath(HERE / 'test-vectors'), '--semantics'],
                            [sys.executable, '-I', os.fspath(HERE / 'reference_decoder.py'), '--semantics']):
                with self.subTest(case=case['fields'], decoder=command[0]):
                    result = subprocess.run(command, input=wire, capture_output=True, check=True)
                    self.assertEqual(json.loads(result.stdout), case['expected'])

    def test_conformance(self):
        vectors = sorted((HERE / 'fixtures/vectors').glob('*.txt'))
        self.assertEqual(len(vectors), 39)
        self.assertEqual({p.stem for p in vectors},
                         {p.stem for p in (HERE / 'fixtures/vectors').glob('*.json')})
        for wire in vectors:
            expected = json.loads(wire.with_suffix('.json').read_text())
            for command in ([os.fspath(HERE / 'test-vectors')],
                            [sys.executable, '-I', os.fspath(HERE / 'reference_decoder.py')]):
                with self.subTest(vector=wire.stem, decoder=command[0]):
                    result = subprocess.run(command, input=wire.read_bytes(), capture_output=True, check=True)
                    actual = [json.loads(row) for row in result.stdout.splitlines()]
                    self.assertEqual(actual, expected)
                    self.assertEqual([list(row['fields'].items()) for row in actual],
                                     [list(row['fields'].items()) for row in expected])


if __name__ == '__main__':
    unittest.main()

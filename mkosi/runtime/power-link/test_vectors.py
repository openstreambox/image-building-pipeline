"""Run the same fixed expectations against two independent decoders."""
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

HERE = Path(__file__).resolve().parent


class VectorTest(unittest.TestCase):
    def test_conformance(self):
        vectors = sorted((HERE / 'fixtures/vectors').glob('*.txt'))
        self.assertEqual(len(vectors), 35)
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


if __name__ == '__main__':
    unittest.main()

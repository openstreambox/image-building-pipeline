#!/usr/bin/env python3
"""Bounded stdlib contracts with synthetic archives and image roots."""
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('notices', ROOT / 'tools/generate-dependency-notices.py')
n = importlib.util.module_from_spec(spec)
spec.loader.exec_module(n)
BASE = ROOT / 'mkosi/runtime/licence-notices/dependencies'
INSTALL = BASE.parent / 'install-dependency-notices.sh'


def tar(text):
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode='w:gz') as archive:
        info = tarfile.TarInfo('alpha/LICENSE')
        info.size = len(text)
        archive.addfile(info, io.BytesIO(text))
    return out.getvalue()


class Notices(unittest.TestCase):
    def test_archive_and_upstream_drift(self):
        data = tar(b'Permission granted.\n')
        pin = {'sha256': n.sha(data), 'upstream_checksum': n.sha(data)}
        n.verify_archive(data, 'https://example.invalid/alpha.crate', pin)
        changed = tar(b'Changed grant.\n')
        with self.assertRaisesRegex(ValueError, 'SHA256'):
            n.verify_archive(changed, 'alpha', pin)
        pin['sha256'] = n.sha(changed)
        with self.assertRaisesRegex(ValueError, 'crate checksum'):
            n.verify_archive(changed, 'alpha', pin)
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, 'w') as z:
            z.writestr('alpha@v1/LICENSE', 'notice')
        with self.assertRaisesRegex(ValueError, 'Go module checksum'):
            n.verify_archive(buf.getvalue(), 'alpha.zip', {'sha256': n.sha(buf.getvalue()), 'upstream_checksum': 'h1:wrong'})

    def test_determinism_text_drift_and_unknown_gap(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp)
            url = 'https://example.invalid/alpha.crate'
            text = b'Copyright 2000 Example. Permission granted.\n'
            data = tar(text)
            (cache / n.sha(url.encode())).write_bytes(data)
            plan = {'gaps': [{'name': a, 'version': b} for a, b in sorted(n.GAPS)],
                    'inputs': {url: {'sha256': n.sha(data), 'upstream_checksum': n.sha(data)}},
                    'packages': [{'name': 'alpha', 'version': '1', 'scope': 'source only', 'origin': url,
                                  'texts': [{'source_path': 'alpha/LICENSE', 'source_sha256': n.sha(text),
                                             'start': 0, 'end': len(text), 'sha256': n.sha(text)}]}]}
            first = n.render(plan, cache)
            self.assertEqual(first, n.render(plan, cache))
            altered = copy.deepcopy(plan)
            altered['packages'][0]['texts'][0]['sha256'] = '0' * 64
            with self.assertRaisesRegex(ValueError, 'notice text drift'):
                n.render(altered, cache)
            plan['gaps'][0]['version'] = 'future'
            with self.assertRaisesRegex(ValueError, 'unreviewed missing text'):
                n.render(plan, cache)

    def test_public_inventory_and_membership(self):
        raw = (BASE / 'plan.json').read_bytes()
        self.assertEqual(n.sha(raw), (BASE / 'plan.sha256').read_text(errors='replace').strip())
        p = json.loads(raw)
        self.assertFalse(p['packaging_ready'])
        scopes = [x['scope'] for x in p['packages']]
        self.assertEqual(sum(x == 'measured Go buildinfo module' for x in scopes), 85)
        self.assertEqual(sum(x.startswith('go.sum source-only') for x in scopes), 46)
        self.assertEqual(sum(x.startswith('Cargo.lock source closure') for x in scopes), 122)
        self.assertEqual(sum(x.startswith('workspace path package') for x in scopes), 4)
        subprocess.run(['sha256sum', '--check', '--strict', 'SHA256SUMS'], cwd=BASE, check=True, stdout=subprocess.DEVNULL)
        for pkg in ('srtla', 'mediamtx'):
            text = (BASE / (pkg + '.txt')).read_text(errors='replace')
            self.assertIn('NOT measured shipped membership', text)
            self.assertIn('46 additional fetched modules are source-only', text)
            self.assertIn('No grant substituted', text)
        self.assertIn('AUTHORS', (BASE / 'srtla.txt').read_text(errors='replace'))
        self.assertTrue(b'9efc29b6e58cef28f6566a47aa7e142a55fead77' in (BASE / 'srtla.txt').read_bytes())

    def test_install_prune_retention_and_rejections(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            query = root / 'query'
            def run(version='4.2.0', base=BASE):
                query.write_text('#!/bin/sh\nprintf "srtla installed ' + version + '\\n"\n')
                query.chmod(0o755)
                return subprocess.run(['bash', str(INSTALL)], env=dict(os.environ,
                    LICENCE_NOTICES_DESTROOT=str(root), LICENCE_NOTICES_DPKG_QUERY=str(query),
                    DEPENDENCY_NOTICES_BASE=str(base)), capture_output=True)
            old = {'srtla': b'Parent MIT notice\n', 'mediamtx': (
                b'MediaMTX v1.19.2, installed as /usr/local/bin/mediamtx\n'
                b'Release tarball sha256: 562f419912a8668c18216a9e8c95359ec82fbb754e4a44e2953ef62b98eec688\nParent release LICENSE\n')}
            for pkg, text in old.items():
                dest = root / 'usr/share/doc' / pkg
                dest.mkdir(parents=True)
                (dest / 'copyright').write_bytes(text)
                (dest / 'README').touch()
            binary = root / 'usr/local/bin/mediamtx'
            binary.parent.mkdir(parents=True)
            binary.touch()
            self.assertNotEqual(run('future').returncode, 0)
            self.assertEqual((root / 'usr/share/doc/srtla/copyright').read_bytes(), old['srtla'])
            bad = root / 'bad'
            bad.mkdir()
            for name in ('srtla.txt', 'mediamtx.txt', 'SHA256SUMS'):
                (bad / name).write_bytes((BASE / name).read_bytes())
            (bad / 'srtla.txt').write_bytes(b'changed')
            self.assertNotEqual(run(base=bad).returncode, 0)
            result = run()
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            # Same reduction as app-layer and apt reprune, applied to the fixture.
            subprocess.run(['find', str(root / 'usr/share/doc'), '-type', 'f', '!', '-name', 'copyright', '-delete'], check=True)
            for pkg, parent in old.items():
                result = (root / 'usr/share/doc' / pkg / 'copyright').read_bytes()
                self.assertEqual(result, parent + (BASE / (pkg + '.txt')).read_bytes())
            self.assertNotEqual(run().returncode, 0)
            app = (ROOT / 'mkosi/mkosi.images/app/mkosi.postinst.chroot').read_text(errors='replace')
            self.assertLess(app.index('runtime/licence-notices/install-licence-notices.sh'), app.index('runtime/licence-notices/install-dependency-notices.sh'))
            main = app[app.index('main() {'):]
            self.assertLess(main.index('install-dependency-notices.sh'), main.index('  prune_final_image_payload'))


if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
"""Source dependency notice contracts (stdlib only).

Synthetic archives drive the derivation and its mutation controls; the real
committed inventory is checked offline. Set CERALIVE_DEPENDENCY_NOTICE_CACHE to
an archive cache to also re-derive the real inventory and payloads from the
pinned official archives.
"""
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / 'tools/generate-dependency-notices.py'
spec = importlib.util.spec_from_file_location('notices', TOOL)
n = importlib.util.module_from_spec(spec)
spec.loader.exec_module(n)
BASE = ROOT / 'mkosi/runtime/licence-notices/dependencies'
INSTALL = BASE.parent / 'install-dependency-notices.sh'
SROOT, MROOT = 'a' * 40, 'b' * 40


def sha(data):
    return hashlib.sha256(data).hexdigest()


def targz(files, commit=None):
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode='w:gz', format=tarfile.PAX_FORMAT,
                      pax_headers={'comment': commit} if commit else {}) as archive:
        for name, data in sorted(files.items()):
            info = tarfile.TarInfo(name)
            info.size, info.mtime = len(data), 0
            archive.addfile(info, io.BytesIO(data))
    return out.getvalue()


def modzip(files):
    out = io.BytesIO()
    with zipfile.ZipFile(out, 'w') as archive:
        for name, data in sorted(files.items()):
            archive.writestr(zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0)), data)
    return out.getvalue()


def buildinfo(deps, goarch='arm64', revision=MROOT, extra=''):
    def string(data):
        out, length = bytearray(), len(data)
        while True:
            byte = length & 0x7f
            length >>= 7
            out.append(byte | (0x80 if length else 0))
            if not length:
                return bytes(out) + data
    mod = ('path\tgithub.com/bluenviron/mediamtx\nmod\tgithub.com/bluenviron/mediamtx\tv1.19.2\t\n'
           + ''.join(f'dep\t{m}\t{v}\t{h}\n' for (m, v), h in deps.items()) + extra
           + f'build\tGOARCH={goarch}\nbuild\tvcs.revision={revision}\n').encode()
    return (b'\x7fELF' + b'\0' * 60 + b'\xff Go buildinf:' + bytes([8, 2]) + b'\0' * 16
            + string(b'go1.26.4') + string(b'S' * 16 + mod + b'E' * 16) + b'\0' * 32)


LICENSE = b'MIT License\n\nCopyright (c) 2001 Alpha Authors\n\nPermission is hereby granted, free of charge.\n'
THIRD = b'License notice for vendored signing code\nCopyright 2015 Vendor. Apache-2.0 terms follow.\n'
MIT_README = (b'# m\n\nUsage text.\n\nCopyright (c) 2006 Original Inc.\n\nPermission is hereby granted, free of charge\n\n'
              b'The above copyright notice and this permission notice shall be included.\n\nTHE SOFTWARE IS PROVIDED "AS IS".\n')


class Universe:
    """A complete synthetic source set: one crate closure, one go.sum closure, two releases."""

    def __init__(self, tmp):
        self.cache, self.base = Path(tmp) / 'cache', Path(tmp) / 'base'
        self.cache.mkdir()
        self.base.mkdir()
        self.crates = {
            ('alpha', '1.0.0'): {
                'alpha-1.0.0/Cargo.toml': b'[package]\nname = "alpha"\nversion = "1.0.0"\nlicense = "MIT"\n',
                'alpha-1.0.0/LICENSE-MIT': LICENSE,
                'alpha-1.0.0/THIRD-PARTY-NOTICES': THIRD,
                'alpha-1.0.0/APACHE-LICENSE-2.0': b'Apache License\nVersion 2.0, January 2004\n',
                'alpha-1.0.0/CONTRIBUTORS': b'Jane Contributor <jane@example.invalid>\n',
                'alpha-1.0.0/src/lib.rs': b'#![no_std]\n// Copyright 2001 Alpha Authors\n// SPDX-License-Identifier: MIT\n\npub fn f() {}\n',
                'alpha-1.0.0/src/table.rs': b'pub const SIGN: &str = "COPYRIGHT SIGN";\n',
                'alpha-1.0.0/logo.png': b'\x89PNG\r\n\x1a\n\0\0Copyright 2001\xff',
            },
        }
        self.modules = {
            ('example.com/m', 'v1.0.0'): {
                'example.com/m@v1.0.0/LICENSE': LICENSE,
                'example.com/m@v1.0.0/ATTRIBUTIONS.md': b'MIT notice: Copyright (c) 2016 Original Author\n',
                'example.com/m@v1.0.0/sub/MIT.LICENSE': b'Copyright (c) 2014 Sub Author\n',
                'example.com/m@v1.0.0/LICENSES/BSD-3-Clause.txt': b'BSD text\n',
                'example.com/m@v1.0.0/.reuse/dep5': b'Files: *\nCopyright: 2023 The Example community\n',
                'example.com/m@v1.0.0/img.png.license': b'SPDX-FileCopyrightText: 2023 Example\n',
                'example.com/m@v1.0.0/README.md': MIT_README,
                'example.com/m@v1.0.0/NOTES.md': b'# Notes\n\nIntro.\n\nOriginal library is Copyright 2006 Google Inc.\nSee above.\n\nOther.\n',
                'example.com/m@v1.0.0/m.go': b'// Copyright 2020 The M Authors.\n// Use of this source code is governed by a BSD-style license.\n\npackage m\n',
            },
            ('example.com/unused', 'v0.1.0'): {
                'example.com/unused@v0.1.0/COPYING': b'Copyright 2010 Unused.\nPermission is hereby granted.\n',
            },
        }
        self.measured = [('example.com/m', 'v1.0.0')]
        self.gaps = []
        self.supplements = []
        self.release_binaries = {'amd64': b'amd64 binary', 'arm64': None}
        self.goarch, self.revision, self.extra_buildinfo, self.h1_override = 'arm64', MROOT, '', {}
        self.workspace_manifest = b'[package]\nname = "srtla_send"\nversion = "4.2.0"\n'

    def put(self, url, data):
        (self.cache / sha(url.encode())).write_bytes(data)
        return sha(data)

    def write(self):
        lock = '# lock\nversion = 4\n\n[[package]]\nname = "srtla_send"\nversion = "4.2.0"\n'
        for (name, version), files in sorted(self.crates.items()):
            data = targz(files)
            self.put(f'https://static.crates.io/crates/{name}/{name}-{version}.crate', data)
            lock += (f'\n[[package]]\nname = "{name}"\nversion = "{version}"\n'
                     f'source = "registry+https://github.com/rust-lang/crates.io-index"\nchecksum = "{sha(data)}"\n')
        sums, h1 = '', {}
        for (mod, version), files in sorted(self.modules.items()):
            self.put(f'https://proxy.golang.org/{mod}/@v/{version}.zip', modzip(files))
            h1[(mod, version)] = n.go_h1(files)
            sums += f'{mod} {version} {h1[(mod, version)]}\n{mod} {version}/go.mod h1:x=\n'
        roots = []
        for payload, name, version, commit, lockname, lockdata in (
                ('srtla', 'CERALIVE/srtla-send-rs', 'v4.2.0', SROOT, 'Cargo.lock', lock),
                ('mediamtx', 'bluenviron/mediamtx', 'v1.19.2', MROOT, 'go.sum', sums)):
            url = f'https://codeload.github.com/{name}/tar.gz/{commit}'
            top = name.split('/')[1] + '-' + commit
            files = {f'{top}/{lockname}': lockdata.encode(), f'{top}/LICENSE': LICENSE}
            if payload == 'srtla':
                files[f'{top}/Cargo.toml'] = self.workspace_manifest
            data = targz(files, commit=commit)
            roots.append({'payload': payload, 'name': name, 'version': version, 'commit': commit, 'url': url,
                          'sha256': self.put(url, data), 'lock': lockname})
        releases = []
        deps = {k: self.h1_override.get(k, h1[k]) for k in self.measured}
        for arch in ('amd64', 'arm64'):
            binary = self.release_binaries[arch] or buildinfo(deps, self.goarch, self.revision, self.extra_buildinfo)
            url = f'https://github.com/bluenviron/mediamtx/releases/download/v1.19.2/mediamtx_v1.19.2_linux_{arch}.tar.gz'
            entry = {'arch': arch, 'url': url, 'sha256': self.put(url, targz({'mediamtx': binary, 'LICENSE': LICENSE}))}
            if arch == 'arm64':
                entry['measure_go_modules'] = True
            releases.append(entry)
        sources = {'schema': 2, 'roots': roots, 'supplements': self.supplements, 'gaps': self.gaps,
                   'installed': {'srtla': {'package': 'srtla', 'version': '4.2.0', 'architectures': ['amd64', 'arm64']},
                                 'mediamtx': {'version': 'v1.19.2', 'binary_path': '/usr/local/bin/mediamtx',
                                              'releases': releases}}}
        raw = json.dumps(sources, indent=2).encode()
        (self.base / 'sources.json').write_bytes(raw)
        return raw

    def derive(self):
        return n.derive(self.write(), n.Cache(self.cache))

    def commit(self):
        """Write a committed inventory exactly as a reviewed refresh would."""
        self.write()
        plan, result = n.generate(self.base, n.Cache(self.cache))
        data = n.dump(plan)
        (self.base / 'plan.json').write_bytes(data)
        (self.base / 'plan.sha256').write_text(sha(data) + '\n')
        for name, payload in result.items():
            (self.base / name).write_bytes(payload)
        (self.base / 'SHA256SUMS').write_bytes(n.sums(result))
        return plan

    def check(self):
        return subprocess.run(['python3', '-I', str(TOOL), '--cache', str(self.cache), '--base', str(self.base),
                               '--check'], capture_output=True, text=True)


def texts(plan, name):
    return {t['source_path'].split('/', 1)[1] if '@' not in t['source_path'] else t['source_path'].split('@', 1)[1].split('/', 1)[1]: t
            for p in plan['packages'] if p['name'] == name for t in p['texts']}


class Derivation(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.u = Universe(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_discovers_notice_variants_and_records_exclusions(self):
        plan, excerpts = self.u.derive()
        alpha, m = texts(plan, 'alpha'), texts(plan, 'example.com/m')
        for name in ('LICENSE-MIT', 'THIRD-PARTY-NOTICES', 'APACHE-LICENSE-2.0', 'CONTRIBUTORS'):
            self.assertEqual(alpha[name]['rule'], 'named', name)
        for name in ('LICENSE', 'ATTRIBUTIONS.md', 'sub/MIT.LICENSE', 'LICENSES/BSD-3-Clause.txt', '.reuse/dep5',
                     'img.png.license'):
            self.assertEqual(m[name]['rule'], 'named', name)
        for t in list(alpha.values()) + list(m.values()):
            if t['rule'] in ('named', 'embedded-licence'):
                self.assertEqual((t['start'], t['sha256']), (0, t['source_sha256']))
        # The embedded MIT text keeps its conditions and warranty, not just one paragraph.
        self.assertEqual(m['README.md']['rule'], 'embedded-licence')
        self.assertEqual(m['NOTES.md']['rule'], 'statement-paragraph')
        notes = excerpts[(next(p['origin'] for p in plan['packages'] if p['name'] == 'example.com/m'),
                          'example.com/m@v1.0.0/NOTES.md', m['NOTES.md']['start'], m['NOTES.md']['end'])]
        self.assertEqual(notes, b'Original library is Copyright 2006 Google Inc.\nSee above.\n')
        lib = alpha['src/lib.rs']
        self.assertEqual(lib['rule'], 'comment')
        lib_excerpt = [v for k, v in excerpts.items() if k[1] == 'alpha-1.0.0/src/lib.rs'][0]
        self.assertNotIn(b'#![no_std]', lib_excerpt)
        self.assertIn(b'Copyright 2001 Alpha Authors', lib_excerpt)
        self.assertIn('governed by a BSD-style license', excerpts[[k for k in excerpts if k[1].endswith('/m.go')][0]].decode())
        excluded = {(e['source_path'].rsplit('/', 1)[1], e['rule']) for p in plan['packages'] for e in p['excluded']}
        self.assertEqual(excluded, {('logo.png', 'binary'), ('table.rs', 'mention-outside-comments')})
        scopes = {p['name']: p['scope'] for p in plan['packages']}
        self.assertEqual(scopes['example.com/m'], 'measured Go buildinfo module')
        self.assertTrue(scopes['example.com/unused'].startswith('go.sum source-only'))
        self.assertEqual(plan['measurement']['modules'], 1)
        self.assertEqual(plan['counts']['go_mod_only_entries'], 2)

    def test_regeneration_is_deterministic_and_check_passes(self):
        first = self.u.commit()
        self.assertEqual(n.dump(first), n.dump(self.u.derive()[0]))
        result = self.u.check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_reviewer_cases_fail_against_the_archives(self):
        plan = self.u.commit()
        committed = (self.u.base / 'plan.json').read_bytes()

        def mutate(change):
            p = copy.deepcopy(plan)
            change(p)
            data = n.dump(p)
            (self.u.base / 'plan.json').write_bytes(data)
            (self.u.base / 'plan.sha256').write_text(sha(data) + '\n')
            result = self.u.check()
            (self.u.base / 'plan.json').write_bytes(committed)
            (self.u.base / 'plan.sha256').write_text(sha(committed) + '\n')
            return result

        alpha = next(p for p in plan['packages'] if p['name'] == 'alpha')
        idx = next(i for i, t in enumerate(alpha['texts']) if t['source_path'].endswith('THIRD-PARTY-NOTICES'))
        cases = {
            'omitted notice file': lambda p: p['packages'][[x['name'] for x in p['packages']].index('alpha')]['texts'].pop(idx),
            'truncated licence': lambda p: p['packages'][[x['name'] for x in p['packages']].index('alpha')]['texts'][0].update(end=10),
            'misrouted package': lambda p: p['packages'][[x['name'] for x in p['packages']].index('example.com/unused')].update(payload='srtla'),
            'dropped exclusion record': lambda p: p['packages'][[x['name'] for x in p['packages']].index('alpha')]['excluded'].pop(),
        }
        for name, change in cases.items():
            result = mutate(change)
            self.assertNotEqual(result.returncode, 0, name)
            self.assertRegex(result.stderr, 'committed plan.json differs from derivation|wrong payload', name)
        control = self.u.check()
        self.assertEqual(control.returncode, 0, control.stderr)
        payload = self.u.base / 'mediamtx.txt'
        payload.write_bytes(payload.read_bytes()[:-20])
        sums = n.sums({name: (self.u.base / name).read_bytes() for name in ('identity.tsv', 'mediamtx.txt', 'srtla.txt')})
        (self.u.base / 'SHA256SUMS').write_bytes(sums)
        self.assertRegex(self.u.check().stderr, 'committed payload differs: mediamtx.txt')

    def test_unlisted_and_stale_gaps(self):
        self.u.crates[('beta', '2.0.0')] = {'beta-2.0.0/Cargo.toml': b'[package]\nname = "beta"\nversion = "2.0.0"\n',
                                           'beta-2.0.0/src/lib.rs': b'// Copyright 2002 Beta\n'}
        with self.assertRaisesRegex(ValueError, r"unlisted missing licence text: \[\('beta', '2.0.0'\)\]"):
            self.u.derive()
        self.u.gaps = [{'name': 'beta', 'version': '1.9.0', 'unresolved': True, 'resolution': 'Reviewed.'}]
        with self.assertRaisesRegex(ValueError, 'unlisted missing licence text'):
            self.u.derive()
        self.u.gaps[0]['version'] = '2.0.0'
        plan, _ = self.u.derive()
        rendered = n.render(plan, self.u.derive()[1])
        self.assertIn(b'UNRESOLVED: beta 2.0.0: Reviewed.', rendered['srtla.txt'])
        self.assertNotIn(b'UNRESOLVED', rendered['mediamtx.txt'])
        del self.u.crates[('beta', '2.0.0')]
        with self.assertRaisesRegex(ValueError, 'listed gap no longer missing'):
            self.u.derive()

    def test_code_named_files_do_not_hide_a_gap(self):
        self.u.modules[('example.com/unused', 'v0.1.0')] = {
            'example.com/unused@v0.1.0/check_license.sh': b'#!/bin/sh\n# checks headers\n',
            'example.com/unused@v0.1.0/.licenserc.yaml': b'header: x\n'}
        with self.assertRaisesRegex(ValueError, 'unlisted missing licence text'):
            self.u.derive()

    def test_resolved_gap_requires_its_retained_supplement(self):
        files = self.u.crates[('alpha', '1.0.0')]
        for path in ('alpha-1.0.0/LICENSE-MIT', 'alpha-1.0.0/APACHE-LICENSE-2.0'):
            files.pop(path)
        commit = 'c' * 40
        files['alpha-1.0.0/.cargo_vcs_info.json'] = json.dumps({'git': {'sha1': commit}}).encode()
        url = 'https://codeload.github.com/example/alpha/tar.gz/' + commit
        path = 'alpha-' + commit + '/LICENSE'
        self.u.supplements = [{'for': ['alpha', '1.0.0'], 'name': 'example/alpha', 'commit': commit,
                               'url': url, 'sha256': self.u.put(url, targz({path: LICENSE}, commit))}]
        self.u.gaps = [{'name': 'alpha', 'version': '1.0.0', 'unresolved': False,
                        'resolution': 'MIT text recovered from recorded source commit.',
                        'evidence': [{'origin': url, 'source_path': path, 'sha256': sha(LICENSE)}]}]
        plan, excerpts = self.u.derive()
        n.check_payloads(plan, n.render(plan, excerpts))
        swapped = url.replace('example/alpha', 'another/alpha')
        self.u.put(swapped, (self.u.cache / sha(url.encode())).read_bytes())
        self.u.supplements[0]['url'] = swapped
        with self.assertRaisesRegex(ValueError, 'source URL differs'):
            self.u.derive()
        self.u.supplements[0]['url'] = url
        for change in ('no-supplement', 'no-evidence', 'wrong-evidence'):
            with self.subTest(change=change):
                original_supplements, original_gaps = copy.deepcopy(self.u.supplements), copy.deepcopy(self.u.gaps)
                if change == 'no-supplement':
                    self.u.supplements = []
                elif change == 'no-evidence':
                    self.u.gaps[0].pop('evidence')
                else:
                    self.u.gaps[0]['evidence'][0]['sha256'] = '0' * 64
                with self.assertRaisesRegex(ValueError, 'gap.*evidence'):
                    self.u.derive()
                self.u.supplements, self.u.gaps = original_supplements, original_gaps

    def test_source_archive_origin_and_commit_are_cross_bound(self):
        raw = json.loads(self.u.write())
        for change, message in (('url', 'source URL differs'), ('commit', 'source archive commit differs'),
                                ('top-member', 'source archive member outside')):
            sources = copy.deepcopy(raw)
            entry = sources['roots'][0]
            if change == 'url':
                old = entry['url']
                entry['url'] = entry['url'].replace('CERALIVE', 'another-owner')
                self.u.put(entry['url'], (self.u.cache / sha(old.encode())).read_bytes())
            elif change == 'commit':
                entry['commit'] = 'd' * 40
                old = entry['url']
                entry['url'] = old.replace(SROOT, entry['commit'])
                self.u.put(entry['url'], (self.u.cache / sha(old.encode())).read_bytes())
            else:
                data = targz({'loose-file': LICENSE}, commit=SROOT)
                entry['sha256'] = self.u.put(entry['url'], data)
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, message):
                n.derive(json.dumps(sources).encode(), n.Cache(self.u.cache))

    def test_workspace_lock_entry_requires_a_root_manifest(self):
        self.u.workspace_manifest = b'[workspace]\nmembers = []\n'
        with self.assertRaisesRegex(ValueError, 'workspace package missing from root archive'):
            self.u.derive()

    def test_offline_payload_bytes_and_framing_match_the_plan(self):
        plan, excerpts = self.u.derive()
        result = n.render(plan, excerpts)
        n.check_payloads(plan, result)
        for change in ('truncated', 'omitted', 'reordered', 'extra', 'identity'):
            altered = dict(result)
            if change == 'truncated':
                altered['srtla.txt'] = altered['srtla.txt'].replace(LICENSE, b'MIT License\n', 1)
            elif change == 'omitted':
                altered['srtla.txt'] = altered['srtla.txt'].replace(THIRD, b'', 1)
            elif change == 'reordered':
                altered['srtla.txt'] = altered['srtla.txt'].replace(b'Scope: ', b'Origin: ', 1)
            elif change == 'extra':
                altered['mediamtx.txt'] += b'not in plan\n'
            else:
                altered['identity.tsv'] += b'srtla\twrong\t1\tarm64\n'
            # Refreshing packaging checksums must not bless changed plan records.
            self.assertNotEqual(n.sums(altered), n.sums(result))
            with self.subTest(change=change), self.assertRaises(ValueError):
                n.check_payloads(plan, altered)

    def test_supplement_must_be_the_recorded_vcs_commit(self):
        files = self.u.crates[('alpha', '1.0.0')]
        files['alpha-1.0.0/.cargo_vcs_info.json'] = json.dumps({'git': {'sha1': 'c' * 40}}).encode()
        url = 'https://codeload.github.com/example/alpha/tar.gz/' + 'd' * 40
        self.u.supplements = [{'for': ['alpha', '1.0.0'], 'name': 'example/alpha', 'commit': 'd' * 40, 'url': url,
                               'sha256': self.u.put(url, targz({'alpha-' + 'd' * 40 + '/LICENSE': LICENSE}))}]
        with self.assertRaisesRegex(ValueError, 'not the crate VCS commit'):
            self.u.derive()

    def test_archive_and_measurement_drift(self):
        self.u.write()
        crate_url = 'https://static.crates.io/crates/alpha/alpha-1.0.0.crate'
        (self.u.cache / sha(crate_url.encode())).write_bytes(targz({'alpha-1.0.0/LICENSE-MIT': b'changed'}))
        with self.assertRaisesRegex(ValueError, 'archive SHA256 drift: ' + re.escape(crate_url)):
            n.derive((self.u.base / 'sources.json').read_bytes(), n.Cache(self.u.cache))
        self.u.write()
        mod_url = 'https://proxy.golang.org/example.com/m/@v/v1.0.0.zip'
        files = dict(self.u.modules[('example.com/m', 'v1.0.0')])
        files['example.com/m@v1.0.0/LICENSE'] = b'changed'
        (self.u.cache / sha(mod_url.encode())).write_bytes(modzip(files))
        with self.assertRaisesRegex(ValueError, 'Go module checksum drift'):
            n.derive((self.u.base / 'sources.json').read_bytes(), n.Cache(self.u.cache))
        for attribute, value, message in (
                ('h1_override', {('example.com/m', 'v1.0.0'): 'h1:other='}, 'measured module differs from go.sum'),
                ('extra_buildinfo', '=>\texample.com/fork\tv1.0.0\th1:y=\n', 'module replacement'),
                ('goarch', 'amd64', 'measured binary identity differs'),
                ('revision', 'c' * 40, 'measured binary identity differs')):
            fresh = Universe(tempfile.mkdtemp(dir=self.tmp.name))
            setattr(fresh, attribute, value)
            with self.assertRaisesRegex(ValueError, message):
                fresh.derive()

    def test_offline_plan_invariants(self):
        plan, _ = self.u.derive()

        def broken(change):
            p = copy.deepcopy(plan)
            change(p)
            return p
        alpha = [x['name'] for x in plan['packages']].index('alpha')
        named = next(i for i, t in enumerate(plan['packages'][alpha]['texts']) if t['rule'] == 'named')
        for change, message in (
                (lambda p: p['packages'][alpha]['texts'][named].update(end=5, sha256='0' * 64), 'not retained whole'),
                (lambda p: p['packages'][alpha].update(payload='mediamtx'), 'wrong payload'),
                (lambda p: p['packages'][alpha]['excluded'].append({'source_path': 'x', 'rule': 'skip', 'source_sha256': None}),
                 'exclusion without a recorded rule'),
                (lambda p: p['packages'][alpha].update(texts=[t for t in p['packages'][alpha]['texts']
                                                               if not n.is_grant(t['source_path'], False)]),
                 'unlisted missing licence text'),
                (lambda p: p['counts'].update(go_modules_measured=2), 'count mismatch')):
            with self.assertRaisesRegex(ValueError, message):
                n.check_plan(broken(change))


class CommittedInventory(unittest.TestCase):
    def test_committed_plan_is_consistent_and_honest(self):
        raw = (BASE / 'plan.json').read_bytes()
        self.assertEqual(sha(raw), (BASE / 'plan.sha256').read_text().strip())
        plan = json.loads(raw)
        self.assertEqual(raw, n.dump(plan))
        n.check_plan(plan)
        n.check_payloads(plan, {name: (BASE / name).read_bytes()
                                for name in ('srtla.txt', 'mediamtx.txt', 'identity.tsv')})
        self.assertEqual(plan['sources_sha256'], sha((BASE / 'sources.json').read_bytes()))
        self.assertFalse(plan['packaging_ready'])
        self.assertEqual(plan['counts'], {'go_mod_only_entries': 191, 'go_modules_measured': 85,
                                          'go_modules_source_only': 46, 'rust_registry_crates': 122,
                                          'rust_workspace_packages': 4})
        self.assertEqual((plan['measurement']['arch'], plan['measurement']['go']), ('arm64', 'go1.26.4'))
        named = {(p['name'], t['source_path'].rsplit('/', 1)[1]) for p in plan['packages'] for t in p['texts']
                 if t['rule'] == 'named'}
        for item in (('go.mongodb.org/mongo-driver/v2', 'THIRD-PARTY-NOTICES'),
                     ('github.com/matthewhartstonge/argon2', 'ATTRIBUTIONS.md'),
                     ('github.com/sergi/go-diff', 'APACHE-LICENSE-2.0'), ('github.com/sergi/go-diff', 'CONTRIBUTORS')):
            self.assertIn(item, named)
        self.assertEqual({(g['name'], g['version']) for g in plan['gaps']},
                         {('r-efi', '5.3.0'), ('r-efi', '6.0.0'), ('valuable', '0.1.1'),
                          ('github.com/benburkert/openpgp', 'v0.0.0-20160410205803-c2471f86866c')})
        subprocess.run(['sha256sum', '--check', '--strict', 'SHA256SUMS'], cwd=BASE, check=True, stdout=subprocess.DEVNULL)
        srtla, mtx = (BASE / 'srtla.txt').read_text(), (BASE / 'mediamtx.txt').read_text()
        self.assertIn('NOT measured shipped membership', srtla)
        self.assertIn('46 additional fetched go.sum modules are source-only', mtx)
        self.assertIn('No grant is substituted', mtx)
        self.assertIn('License notice for AWS V4', mtx)
        self.assertIn('Leonard Hecker', mtx)
        self.assertIn('9efc29b6e58cef28f6566a47aa7e142a55fead77', srtla)

    def test_identity_follows_the_image_pins(self):
        plan = json.loads((BASE / 'plan.json').read_bytes())
        identity = [line.split('\t') for line in (BASE / 'identity.tsv').read_text().splitlines()
                    if line and not line.startswith('#')]
        recipe = dict(line.split('=', 1) for line in
                      (ROOT / 'mkosi/runtime/rtmp-gateway/mediamtx.recipe.conf').read_text().splitlines()
                      if re.match(r'MEDIAMTX_\w+=', line))
        mtx = [row for row in identity if row[0] == 'mediamtx']
        self.assertEqual({(row[2], row[3], row[4]) for row in mtx},
                         {(recipe['MEDIAMTX_VERSION'], arch, recipe['MEDIAMTX_SHA256_' + arch]) for arch in ('amd64', 'arm64')})
        self.assertEqual({row[1] for row in mtx}, {plan['mediamtx_identity']['binary_path']})
        self.assertIn('install -D -m 0755 "${tmpdir}/mediamtx" "${destroot}' + plan['mediamtx_identity']['binary_path'] + '"',
                      (ROOT / 'mkosi/customize/postinst.d/services.sh').read_text())
        releases = json.loads((ROOT / 'manifests/first-party-releases.json').read_text())
        pins = {}

        def walk(node):
            if isinstance(node, dict):
                for key, value in node.items():
                    if isinstance(value, str) and key.startswith('srtla['):
                        pins[key[6:-1]] = value
                    walk(value)
            elif isinstance(node, list):
                for value in node:
                    walk(value)
        walk(releases)
        self.assertEqual({(row[2], row[3]) for row in identity if row[0] == 'srtla'},
                         {(version, arch) for arch, version in pins.items()})
        self.assertEqual(set(pins), {'amd64', 'arm64'})

    @unittest.skipUnless(os.environ.get('CERALIVE_DEPENDENCY_NOTICE_CACHE'), 'set CERALIVE_DEPENDENCY_NOTICE_CACHE '
                         'to re-derive the real inventory from the pinned archives')
    def test_real_inventory_rederives_from_pinned_archives(self):
        result = subprocess.run(['python3', '-I', str(TOOL), '--cache', os.environ['CERALIVE_DEPENDENCY_NOTICE_CACHE'],
                                 '--check'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


class Installer(unittest.TestCase):
    BIN_ARM, BIN_AMD = b'synthetic arm64 binary', b'synthetic amd64 binary'
    TAR_ARM, TAR_AMD = '1' * 64, '2' * 64

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / 'root'
        self.base = Path(self.tmp.name) / 'base'
        self.base.mkdir()
        payloads = {'srtla.txt': b'\nSOURCE DEPENDENCY NOTICES (srtla)\nRust text\n',
                    'mediamtx.txt': b'\nSOURCE DEPENDENCY NOTICES (mediamtx)\nGo text\n',
                    'identity.tsv': ('# identities\nsrtla\tsrtla\t4.2.0\tamd64\nsrtla\tsrtla\t4.2.0\tarm64\n'
                                     f'mediamtx\t/usr/local/bin/mediamtx\tv1.19.2\tamd64\t{self.TAR_AMD}\t{sha(self.BIN_AMD)}\n'
                                     f'mediamtx\t/usr/local/bin/mediamtx\tv1.19.2\tarm64\t{self.TAR_ARM}\t{sha(self.BIN_ARM)}\n').encode()}
        for name, data in payloads.items():
            (self.base / name).write_bytes(data)
        (self.base / 'SHA256SUMS').write_bytes(n.sums(payloads))
        plan = n.dump({'payload_sha256': {name: sha(data) for name, data in payloads.items()}})
        (self.base / 'plan.json').write_bytes(plan)
        (self.base / 'plan.sha256').write_text(sha(plan) + '\n')
        self.parents = {'srtla': b'srtla 4.2.0\n\nParent MIT notice\n',
                        'mediamtx': (b'MediaMTX v1.19.2, installed as /usr/local/bin/mediamtx\n\nSource: x\n'
                                     b'Release tarball sha256: ' + self.TAR_ARM.encode() + b'\nParent release LICENSE\n')}
        for pkg, text in self.parents.items():
            (self.root / 'usr/share/doc' / pkg).mkdir(parents=True)
            (self.root / 'usr/share/doc' / pkg / 'copyright').write_bytes(text)
            (self.root / 'usr/share/doc' / pkg / 'README').touch()
        (self.root / 'usr/local/bin').mkdir(parents=True)
        (self.root / 'usr/local/bin/mediamtx').write_bytes(self.BIN_ARM)
        self.rows = ['srtla\tinstalled\t4.2.0\tarm64']

    def tearDown(self):
        self.tmp.cleanup()

    def snapshot(self):
        return {str(p.relative_to(self.root)): (p.is_symlink(), p.read_bytes() if p.is_file() and not p.is_symlink() else None)
                for p in sorted(self.root.rglob('*'))}

    def run_install(self, rows=None, base=None, query_rc=0):
        query = Path(self.tmp.name) / 'query'
        lines = ''.join(row + '\n' for row in (self.rows if rows is None else rows))
        query.write_text(f"#!/bin/sh\nprintf '%s' '{lines}'\nexit {query_rc}\n")
        query.chmod(0o755)
        return subprocess.run(['bash', str(INSTALL)], capture_output=True, text=True, env=dict(
            os.environ, LICENCE_NOTICES_DESTROOT=str(self.root), LICENCE_NOTICES_DPKG_QUERY=str(query),
            DEPENDENCY_NOTICES_BASE=str(base or self.base)))

    def refused(self, message, **kwargs):
        before = self.snapshot()
        result = self.run_install(**kwargs)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn('[dependency-notices] FATAL:', result.stderr)
        self.assertRegex(result.stderr, message)
        self.assertEqual(self.snapshot(), before, 'a refusal changed files')

    def test_appends_once_and_survives_doc_pruning(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('appended source dependency notices to /usr/share/doc/srtla/copyright', result.stderr)
        # Same reduction as the app-layer and apt doc pruning.
        subprocess.run(['find', str(self.root / 'usr/share/doc'), '-type', 'f', '!', '-name', 'copyright', '-delete'], check=True)
        for pkg, parent in self.parents.items():
            self.assertEqual((self.root / 'usr/share/doc' / pkg / 'copyright').read_bytes(),
                             parent + (self.base / (pkg + '.txt')).read_bytes())
        self.refused('already present in .*/srtla/copyright')

    def test_other_architecture_release(self):
        doc = self.root / 'usr/share/doc/mediamtx/copyright'
        doc.write_bytes(doc.read_bytes().replace(self.TAR_ARM.encode(), self.TAR_AMD.encode()))
        (self.root / 'usr/local/bin/mediamtx').write_bytes(self.BIN_AMD)
        result = self.run_install(rows=['srtla\tinstalled\t4.2.0\tamd64'])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_absent_components_are_skipped(self):
        for path in ('usr/local/bin/mediamtx', 'usr/share/doc/mediamtx/copyright', 'usr/share/doc/srtla/copyright'):
            (self.root / path).unlink()
        before = self.snapshot()
        result = self.run_install(rows=['other\tinstalled\t1\tarm64'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('srtla is not installed', result.stderr)
        self.assertIn('MediaMTX is not installed', result.stderr)
        self.assertEqual(self.snapshot(), before)

    def test_real_payloads_verify(self):
        (self.root / 'usr/local/bin/mediamtx').unlink()
        (self.root / 'usr/share/doc/mediamtx/copyright').unlink()
        result = self.run_install(base=BASE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'usr/share/doc/srtla/copyright').read_bytes(),
                         self.parents['srtla'] + (BASE / 'srtla.txt').read_bytes())

    def test_srtla_identity_refusals(self):
        self.refused(r'srtla 4\.3\.0 \(arm64\) is installed, but the dependency notices cover only', rows=['srtla\tinstalled\t4.3.0\tarm64'])
        self.refused(r'srtla 4\.2\.0 \(armhf\) is installed', rows=['srtla\tinstalled\t4.2.0\tarmhf'])
        self.refused("dpkg state 'half-installed'", rows=['srtla\thalf-installed\t4.2.0\tarm64'])
        self.refused('2 dpkg records', rows=['srtla\tinstalled\t4.2.0\tarm64', 'srtla\tinstalled\t4.2.0\tamd64'])
        self.refused('dpkg-query failed', query_rc=1)
        doc = self.root / 'usr/share/doc/srtla/copyright'
        doc.write_bytes(b'srtla 4.1.0\nold parent\n')
        self.refused("starts with 'srtla 4.1.0'")
        doc.unlink()
        self.refused('srtla/copyright is missing; install-licence-notices.sh must run first')

    def test_rewritten_checksums_do_not_bless_changed_payloads(self):
        (self.base / 'srtla.txt').write_bytes(b'cut licence\n')
        payloads = {name: (self.base / name).read_bytes()
                    for name in ('srtla.txt', 'mediamtx.txt', 'identity.tsv')}
        (self.base / 'SHA256SUMS').write_bytes(n.sums(payloads))
        self.refused('notice payloads differ from the reviewed plan')

    def test_missing_or_changed_plan_refuses_before_writes(self):
        original = (self.base / 'plan.json').read_bytes()
        (self.base / 'plan.json').write_bytes(original + b'\n')
        self.refused('plan.json does not match plan.sha256')
        (self.base / 'plan.json').unlink()
        self.refused('missing reviewed notice plan')

    def test_rejects_unknown_or_malformed_digest_map_entries(self):
        original = json.loads((self.base / 'plan.json').read_bytes())
        for change in ('extra-key', 'nested-value', 'bad-hash', 'duplicate-key', 'unclosed-map',
                       'missing-comma', 'trailing-comma'):
            with self.subTest(change=change):
                for pkg, parent in self.parents.items():
                    (self.root / 'usr/share/doc' / pkg / 'copyright').write_bytes(parent)
                plan = copy.deepcopy(original)
                if change == 'extra-key':
                    plan['payload_sha256']['zz.txt'] = '0' * 64
                elif change == 'nested-value':
                    plan['payload_sha256']['srtla.txt'] = {'sha256': '0' * 64}
                elif change == 'bad-hash':
                    plan['payload_sha256']['srtla.txt'] = 'z' * 64
                raw = n.dump(plan)
                if change == 'duplicate-key':
                    row = next(line for line in raw.splitlines(keepends=True) if b'"identity.tsv"' in line)
                    raw = raw.replace(row, row + row)
                elif change == 'unclosed-map':
                    raw = raw.replace(b'  }', b'  ]', 1)
                elif change == 'missing-comma':
                    raw = raw.replace(b'",\n', b'"\n', 1)
                elif change == 'trailing-comma':
                    raw = raw.replace(b'"\n  }', b'",\n  }', 1)
                (self.base / 'plan.json').write_bytes(raw)
                (self.base / 'plan.sha256').write_text(sha(raw) + '\n')
                self.refused('invalid payload digest map|plan lacks exactly three payload digests')

    def test_mediamtx_identity_refusals(self):
        binary = self.root / 'usr/local/bin/mediamtx'
        doc = self.root / 'usr/share/doc/mediamtx/copyright'
        binary.write_bytes(b'other build')
        self.refused('is not the arm64 binary')
        binary.write_bytes(self.BIN_ARM)
        parent = doc.read_bytes()
        doc.write_bytes(parent.replace(self.TAR_ARM.encode(), b'3' * 64))
        self.refused('release tarball 3{64} is not covered')
        doc.write_bytes(parent.replace(b'v1.19.2', b'v1.20.0'))
        self.refused("starts with 'MediaMTX v1.20.0")
        doc.write_bytes(parent + b'Release tarball sha256: ' + self.TAR_AMD.encode() + b'\n')
        self.refused('exactly one release tarball')
        doc.write_bytes(parent)
        self.refused('mediamtx dpkg package is present', rows=self.rows + ['mediamtx\tinstalled\t1.19.2\tarm64'])
        (self.root / 'usr/bin').mkdir()
        (self.root / 'usr/bin/mediamtx').write_bytes(self.BIN_ARM)
        self.refused('unexpected MediaMTX at /usr/bin/mediamtx')
        (self.root / 'usr/bin/mediamtx').unlink()
        binary.unlink()
        self.refused('mediamtx/copyright exists but /usr/local/bin/mediamtx is missing')
        binary.write_bytes(self.BIN_ARM)
        doc.unlink()
        self.refused('/usr/local/bin/mediamtx exists but .*mediamtx/copyright is missing')

    def test_destination_and_payload_refusals(self):
        doc = self.root / 'usr/share/doc/mediamtx/copyright'
        doc.write_bytes(doc.read_bytes() + b'\nSOURCE DEPENDENCY NOTICES (earlier)\n')
        self.refused('already present in .*/mediamtx/copyright')
        doc.write_bytes(self.parents['mediamtx'])
        real = self.root / 'usr/share/doc/srtla-real'
        (self.root / 'usr/share/doc/srtla').rename(real)
        (self.root / 'usr/share/doc/srtla').symlink_to(real)
        self.refused('is a symlink')
        (self.root / 'usr/share/doc/srtla').unlink()
        real.rename(self.root / 'usr/share/doc/srtla')
        (self.base / 'srtla.txt').write_bytes(b'changed')
        self.refused('do not match SHA256SUMS')
        (self.base / 'extra.txt').touch()
        with (self.base / 'SHA256SUMS').open('a') as sums:
            sums.write(f'{sha(b"")}  extra.txt\n')
        self.refused('must list exactly')

    def test_app_layer_order(self):
        app = (ROOT / 'mkosi/mkosi.images/app/mkosi.postinst.chroot').read_text()
        main = app[app.index('main() {'):]
        self.assertLess(main.index('install-licence-notices.sh'), main.index('install-dependency-notices.sh'))
        self.assertLess(main.index('install-dependency-notices.sh'), main.index('  prune_final_image_payload'))


if __name__ == '__main__':
    unittest.main()

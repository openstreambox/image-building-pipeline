#!/usr/bin/env python3
"""Firmware and boot loader notices: generator, committed data, installer, prune.

Part A  tools/generate-boot-firmware-notices.py on synthetic sources and archives:
        classes, verbatim texts, determinism, --check and the refusals.
Part B  the committed payloads: checksums, every verbatim text against its pinned
        git blob, and agreement with the image's own pins.
Part C  the production installer on synthetic installed trees: what it writes and
        every identity, partial-tree, symlink and payload refusal, with nothing
        written on refusal.
Part D  the written files survive the app layer's doc prune and the on-device
        reprune hook (and doc-notice-policy.sh when that exists, or the file
        named by BOOT_FIRMWARE_NOTICES_EXTRA_POLICY).
Part E  the app layer runs the installer after the package installs and before
        the doc prune.
Offline; runs only git and the scripts under test.
"""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / 'mkosi/runtime/licence-notices/boot-firmware'
INSTALLER = ROOT / 'mkosi/runtime/licence-notices/install-boot-firmware-notices.sh'
APP = ROOT / 'mkosi/mkosi.images/app/mkosi.postinst.chroot'
FW, UB = 'armbian-firmware-full', 'linux-u-boot-rock-5b-plus-edge'

spec = importlib.util.spec_from_file_location('gen', ROOT / 'tools/generate-boot-firmware-notices.py')
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

passed = 0


def ok(label):
    global passed
    passed += 1
    print(f'ok   {label}')


def check(cond, label):
    if not cond:
        print(f'FAIL {label}', file=sys.stderr)
        sys.exit(1)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def blob(data):
    return hashlib.sha1(b'blob %d\0' % len(data) + data).hexdigest()


# --- fixture builders -----------------------------------------------------------

GIT_ENV = dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@example.invalid',
               GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@example.invalid',
               GIT_AUTHOR_DATE='2026-01-01T00:00:00Z', GIT_COMMITTER_DATE='2026-01-01T00:00:00Z',
               GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')


def make_repo(sources, key, files):
    work = sources / f'{key}.work'
    for path, data in files.items():
        (work / path).parent.mkdir(parents=True, exist_ok=True)
        (work / path).write_bytes(data)
    run = lambda *a: subprocess.run(['git', *a], cwd=work, env=GIT_ENV, check=True, capture_output=True).stdout
    run('init', '-q')
    run('add', '-A')
    run('commit', '-q', '-m', 'fixture')
    subprocess.run(['git', 'clone', '-q', '--bare', str(work), str(sources / f'{key}.git')],
                   env=GIT_ENV, check=True, capture_output=True)
    commit = run('rev-parse', 'HEAD').decode().strip()
    shutil.rmtree(work)
    return commit


def tar_xz(entries):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w:xz') as tf:
        for name, value in entries:
            info = tarfile.TarInfo(name)
            info.mtime = 0
            if isinstance(value, tuple):
                info.type, info.linkname = tarfile.SYMTYPE, value[1]
                tf.addfile(info)
            elif value is None:
                info.type, info.mode = tarfile.DIRTYPE, 0o755
                tf.addfile(info)
            else:
                info.size, info.mode = len(value), 0o644
                tf.addfile(info, io.BytesIO(value))
    return buf.getvalue()


def ar(members):
    out = bytearray(b'!<arch>\n')
    for name, data in members:
        out += f'{name:<16}{0:<12}{0:<6}{0:<6}{100644:<8}{len(data):<10}`\n'.encode()
        out += data
        if len(data) % 2:
            out += b'\n'
    return bytes(out)


def md5sums(files):
    return ''.join(f'{hashlib.md5(d).hexdigest()}  {p}\n' for p, d in sorted(files.items())
                   if not isinstance(d, tuple) and d is not None).encode()


def make_deb(path, fields, files):
    control = ''.join(f'{k}: {v}\n' for k, v in fields.items()).encode()
    sums = md5sums(files)
    data = tar_xz([('./' + p, d) for p, d in sorted(files.items())])
    path.write_bytes(ar([('debian-binary', b'2.0\n'),
                         ('control.tar.xz', tar_xz([('./control', control), ('./md5sums', sums)])),
                         ('data.tar.xz', data)]))
    return sums


def rkns(images, total):
    """A loader with an RKNS v2 header (sha256 image hashes) and the given images."""
    d = bytearray(total)
    d[0:4] = b'RKNS'
    struct.pack_into('<II', d, 8, (len(images) << 16) | 0x180, 1)
    for i, (off, body) in enumerate(images):
        o = 120 + i * 88
        struct.pack_into('<I', d, o, ((len(body) // 512) << 16) | (off // 512))
        d[o + 24:o + 56] = hashlib.sha256(body).digest()
        d[off:off + len(body)] = body
    return d


class Fixture:
    """Synthetic sources, archives and inputs.json in the shape of the real ones."""

    def __init__(self, base):
        self.base = base
        self.sources, self.debs, self.out = base / 'sources', base / 'debs', base / 'out'
        for d in (self.sources, self.debs, self.out):
            d.mkdir(parents=True)
        b = lambda s: s.encode()
        self.lf_files = {
            'WHENCE': b('   WHENCE\n\n' + '-' * 40 + '\n\nDriver: alpha - Alpha\n\nFile: a/up.bin\nFile: a/same.bin\n'
                        'Licence: Redistributable. See LICENCE.alpha for details.\n\n' + '-' * 40 + '\n\n'
                        'Driver: beta - Beta\n\nFile: b/changed.bin\nLicence: GPL-2.0\n\n' + '-' * 40 + '\n\n'
                        'Driver: gamma\n\nFile: c/orig.bin\nLicence:\n  Redistributable.\n  See LICENCE.alpha.\n\n'
                        + '-' * 40 + '\n\nDriver: delta\n\nFile: a/up2.bin\nLicence: Allegedly free.\n\n'
                        + '-' * 40 + '\n\nDriver: epsilon\n\nFile: f/mit.bin\n\nLicence: MIT\n\nCopyright 2009 Example\n\n'
                        + '-' * 40 + '\n\nDriver: zeta\n\nFile: f/apache.bin\n\n'
                        'License: Apache-2.0. See Apache-2.0 for details.\n\n'
                        + '-' * 40 + '\n\nDriver: eta\n\nFile: f/bsd.bin\n\n'
                        'Licence: Redistributable, BSD-3-Clause licence, See LICENCE.alpha for details\n\n'
                        + '-' * 40 + '\n\nDriver: theta\n\nFile: f/dual.bin\nFile: f/twice.bin\n\n'
                        'Licence: Dual GPLv2/MPL. See README.md and WHENCE\n\n'
                        + '-' * 40 + '\n\nDriver: iota\n\nFile: f/twice.bin\n\nLicence: MIT\n'),
            'LICENSES/LICENCE.alpha': b('Alpha licence text.\nKeep this notice.\n'),
            'LICENSES/MIT': b('MIT License fixture\n'),
            'LICENSES/Apache-2.0': b('Apache License 2.0 fixture\n'),
            'LICENSES/GPL-2.0': b('GNU GENERAL PUBLIC LICENSE fixture\n'),
            'LICENSES/LICENCE.unused': b('unused\n'),
            'a/up.bin': b'\x00UP', 'a/same.bin': b'\x00SAME', 'a/up2.bin': b'\x00UP2',
            'b/changed.bin': b'\x00UPSTREAM-B', 'c/orig.bin': b'\x00ORIG', 'README.md': b('upstream readme\n'),
            'f/mit.bin': b'\x00MIT', 'f/apache.bin': b'\x00APACHE', 'f/bsd.bin': b'\x00BSD', 'f/dual.bin': b'\x00DUAL',
            'f/twice.bin': b'\x00TWICE',
        }
        self.arm_files = {
            'README.md': b('# Armbian firmware\n\nNote: Some firmware files are proprietary and distributed under '
                           'their respective licenses. Redistribution is limited to non-commercial or usage-only '
                           'contexts.\n'),
            'a/same.bin': b'\x00SAME', 'b/changed.bin': b'\x00ARMBIAN-B', 'd/copy.bin': b'\x00ORIG',
            'e/only.bin': b'\x00ONLY',
        }
        self.tpl = bytes(range(256)) * 2 + b'TPLTAIL'
        self.uboot_files = {'Licenses/README': b('U-Boot licence summary\n'), 'Licenses/gpl-2.0.txt': b('GPL2\n'),
                            'Licenses/bsd-3-clause.txt': b('BSD3\n'), 'README': b('u-boot\n')}
        self.tfa_files = {'docs/license.rst': b('License\n=======\nBSD-3-Clause\n'), 'license.rst': b('See docs/license.rst\n'),
                          'lib/compiler-rt/LICENSE.TXT': b('compiler-rt\n'), 'licenses/LICENSE.MIT': b('MIT\n'),
                          'licenses/LICENSE-APACHE-2.0.txt': b('Apache\n')}
        commits = {
            'linux-firmware': make_repo(self.sources, 'linux-firmware', self.lf_files),
            'armbian-firmware': make_repo(self.sources, 'armbian-firmware', self.arm_files),
            'u-boot': make_repo(self.sources, 'u-boot', self.uboot_files),
            'tf-a': make_repo(self.sources, 'tf-a', self.tfa_files),
            'armbian-rkbin': make_repo(self.sources, 'armbian-rkbin', {
                'LICENSE.TXT': b('Repository binary licence agreement\n'), 'rk35/ddr.bin': self.tpl}),
            'rockchip-rkbin': make_repo(self.sources, 'rockchip-rkbin', {
                'LICENSE': b('Rockchip licence\n'), 'bin/rk35/ddr.bin': self.tpl[:-1] + b'X'}),
        }
        self.commits = commits
        # Firmware archive: overlay wins; one identical overlay file, a symlink, a doc file.
        fw = {f'lib/firmware/{p}': d for p, d in {**{k: v for k, v in self.lf_files.items()
                                                      if not k.startswith(('WHENCE', 'LICENSES'))},
                                                   **self.arm_files}.items()}
        fw['lib/firmware/link.bin'] = ('link', 'a/up.bin')
        fw['usr/share/doc/armbian-firmware-full/changelog.gz'] = b'\x1f\x8bchangelog'
        for d in ('lib', 'lib/firmware', 'usr', 'usr/share', 'usr/share/doc', 'usr/share/doc/armbian-firmware-full'):
            fw[d] = None
        self.fw_files = fw
        banner, bl31 = b'U-Boot 2026.04_armbian-fixture', b'v2.13.0(release):armbian'
        image0 = self.tpl + bytes(1024 - len(self.tpl))
        loader = rkns([(2048, image0), (3072, b'SPL'.ljust(512, b'\0'))], 8192)
        loader[5000:5000 + len(banner)] = banner
        loader[6000:6000 + len(bl31)] = bl31
        spi = bytes(512) + self.tpl + bytes(100) + banner + bl31
        ub = {
            'usr/lib/linux-u-boot-edge-rock-5b-plus/u-boot-rockchip.bin': bytes(loader),
            'usr/lib/linux-u-boot-edge-rock-5b-plus/u-boot-rockchip-spi.bin': spi,
            'usr/lib/linux-u-boot-edge-rock-5b-plus/u-boot-metadata.sh':
                b(f'declare UBOOT_GIT_REVISION="{commits["u-boot"]}"\n'),
            'usr/lib/u-boot/LICENSE': self.uboot_files['Licenses/README'],
            'usr/lib/u-boot/platform_install.sh': b('#!/bin/sh\n'),
            'usr/share/doc/linux-u-boot-rock-5b-plus-edge/changelog.gz': b'\x1f\x8bub',
        }
        self.ub_files = ub
        self.loader = bytes(loader)
        self.write_debs()

    def write_debs(self, fw_mutate=None, ub_mutate=None):
        fw, ub = dict(self.fw_files), dict(self.ub_files)
        if fw_mutate:
            fw_mutate(fw)
        if ub_mutate:
            ub_mutate(ub)
        for p in self.debs.iterdir():
            p.unlink()
        self.fw_deb, self.ub_deb = self.debs / 'fw_1.0_all.deb', self.debs / 'ub_1.0_arm64.deb'
        self.fw_sums = make_deb(self.fw_deb, {'Package': FW, 'Version': '1.0', 'Architecture': 'all',
                                              'Armbian-Original-Hash': 'fw-hash'}, fw)
        self.ub_sums = make_deb(self.ub_deb, {'Package': UB, 'Version': '2.0', 'Architecture': 'arm64',
                                              'Description': 'Das U-Boot\n version "2026.04" patches hash "0123abcd"',
                                              'Armbian-Original-Hash': 'ub-hash'}, ub)
        self.write_inputs()

    def write_inputs(self, tweak=None):
        real = json.loads((DATA / 'inputs.json').read_text())
        inputs = json.loads(json.dumps(real))
        inputs['packages'] = {
            FW: {'version': '1.0', 'architecture': 'all', 'url': 'https://example.invalid/pool/fw_1.0_all.deb',
                 'sha256': sha(self.fw_deb.read_bytes()), 'bytes': self.fw_deb.stat().st_size,
                 'armbian_original_hash': 'fw-hash'},
            UB: {'version': '2.0', 'architecture': 'arm64', 'url': 'https://example.invalid/pool/ub_1.0_arm64.deb',
                 'sha256': sha(self.ub_deb.read_bytes()), 'bytes': self.ub_deb.stat().st_size,
                 'armbian_original_hash': 'ub-hash'},
        }
        for key, commit in self.commits.items():
            inputs['sources'][key].update(url=f'https://example.invalid/{key}', commit=commit)
        u = inputs['uboot']
        u['u_boot_banner'] = 'U-Boot 2026.04_armbian-fixture'
        u['tpl'].update(bytes=len(self.tpl), path='rk35/ddr.bin', compare_path='bin/rk35/ddr.bin')
        if tweak:
            tweak(inputs)
        (self.out / 'inputs.json').write_text(json.dumps(inputs, indent=2) + '\n')
        return inputs

    def generate(self):
        out, _ = gen.generate(self.out, self.sources, self.debs)
        for name, data in out.items():
            (self.out / name).write_bytes(data)
        return out


def refuses(fix, pattern, label):
    try:
        fix.generate()
    except gen.DeriveError as e:
        check(re.search(pattern, str(e)), f'{label}: wrong message: {e}')
        ok(label)
        return
    check(False, f'{label}: generator accepted it')


# --- Part A: generator --------------------------------------------------------------

tmp = Path(tempfile.mkdtemp())
try:
    fix = Fixture(tmp / 'a')
    out = fix.generate()
    rows = {l.split('\t')[0]: l.split('\t') for l in out['firmware-files.tsv'].decode().splitlines()
            if not l.startswith('#')}
    classes = {p: r[2] for p, r in rows.items()}
    check(classes == {'README.md': 'armbian-changed', 'a/same.bin': 'upstream', 'a/up.bin': 'upstream',
                      'a/up2.bin': 'upstream', 'b/changed.bin': 'armbian-changed', 'c/orig.bin': 'upstream',
                      'd/copy.bin': 'upstream-other-path', 'e/only.bin': 'armbian-only', 'f/mit.bin': 'upstream',
                      'f/apache.bin': 'upstream', 'f/bsd.bin': 'upstream', 'f/dual.bin': 'upstream',
                      'f/twice.bin': 'upstream'},
          f'classes {classes}')
    check('link.bin' not in rows, 'symlinks are not firmware files')
    check(rows['a/up.bin'][3] == 'WHENCE entry for this path; licence files: LICENSES/LICENCE.alpha', 'upstream cover')
    check(rows['a/up2.bin'][3] == 'WHENCE entry for this path; it names no licence file', 'no named licence file')
    check(rows['d/copy.bin'][3].startswith('same bytes as linux-firmware c/orig.bin; WHENCE entry for that path; '
                                           'licence files: LICENSES/LICENCE.alpha'), 'other-path cover')
    check('its WHENCE entry describes those, not these' in rows['b/changed.bin'][3]
          and 'GPL-2.0' not in rows['b/changed.bin'][3], 'a WHENCE entry for other bytes is not a grant')
    check('with no WHENCE entry' in rows['README.md'][3], 'replaced file without an entry says so')
    check(rows['e/only.bin'][3] == 'no licence statement established in either source', 'overlay-only gap')
    check(rows['a/same.bin'][5] == 'armbian-firmware' and rows['a/up.bin'][5] == 'linux-firmware', 'origin column')
    ok('firmware files are classified by their exact bytes, and other bytes never borrow an entry')

    entry = 'WHENCE entry for this path; '
    check(rows['f/mit.bin'][3] == entry + 'licence files: LICENSES/MIT', f'Licence: MIT {rows["f/mit.bin"][3]}')
    check(rows['f/apache.bin'][3] == entry + 'licence files: LICENSES/Apache-2.0',
          f'License: Apache-2.0 {rows["f/apache.bin"][3]}')
    check(rows['f/bsd.bin'][3] == entry + 'licence files: LICENSES/LICENCE.alpha', 'reviewed name without a file')
    check(rows['f/dual.bin'][3] == entry + 'it names no licence file', 'free text, README.md or WHENCE name no licence file')
    check(rows['f/twice.bin'][3] == entry + 'licence files: LICENSES/MIT', 'every Licence field of a path counts')
    ok('SPDX-named licence fields resolve to the licence files of that name; free text names none')

    payload = out[f'{FW}.txt']
    texts = [l.split('\t') for l in out['texts.tsv'].decode().splitlines() if not l.startswith('#')]
    for name, off, n, s, b_, src, commit, path in texts:
        data = out[name][int(off):int(off) + int(n)]
        check(sha(data) == s and blob(data) == b_, f'text range {path}')
        files = {'linux-firmware': fix.lf_files, 'armbian-firmware': fix.arm_files, 'u-boot': fix.uboot_files,
                 'tf-a': fix.tfa_files}.get(src)
        if files is not None:
            check(files[path] == data, f'{path} is the source bytes')
        check(commit == fix.commits[src], f'{path} commit')
    fw_paths = [t[7] for t in texts if t[0] == f'{FW}.txt']
    check(fw_paths == ['WHENCE', 'LICENSES/Apache-2.0', 'LICENSES/GPL-2.0', 'LICENSES/LICENCE.alpha', 'LICENSES/MIT',
                       'README.md'], f'firmware texts {fw_paths}')
    check(b'Redistribution is limited to non-commercial or usage-only contexts.' in payload, 'overlay README verbatim')
    check(b'does not grant any licence' in payload and re.search(rb'\n +1  upstream-other-path\n', payload),
          'scope statement and counts')
    ok('every verbatim text is byte-identical to its pinned source blob; the overlay notice is kept as published')

    ub_payload = out[f'{UB}.txt'].decode()
    ub_paths = [(t[5], t[7]) for t in texts if t[0] == f'{UB}.txt']
    bl31_texts = json.loads((DATA / 'inputs.json').read_text())['uboot']['bl31']['texts']
    check(ub_paths == [('u-boot', 'Licenses/README'), ('u-boot', 'Licenses/bsd-3-clause.txt'),
                       ('u-boot', 'Licenses/gpl-2.0.txt')] + [('tf-a', p) for p in bl31_texts]
          + [('armbian-rkbin', 'LICENSE.TXT')], f'U-Boot texts {ub_paths}')
    check(ub_paths[-1] == ('armbian-rkbin', 'LICENSE.TXT') and not any(s == 'rockchip-rkbin' for s, _ in ub_paths),
          'only the source repository licence file is reproduced for the DDR blob')
    for phrase in ('No licence text that applies to these bytes has been established',
                   'it is not established as the terms for it', 'but different bytes',
                   f'git blob {blob(fix.tpl)}', 'this file does not rely on a rebuild',
                   'its build origin is not established',
                   'patches hash 0123abcd', 'Which of those parts this build contains has not been'):
        check(phrase in ' '.join(ub_payload.split()), f'U-Boot statement: {phrase}')
    ok('the U-Boot file names each part, its exact source and the unestablished DDR terms')

    check(gen.generate(fix.out, fix.sources, fix.debs)[0] == out, 'deterministic')
    check(gen.main(['--sources', str(fix.sources), '--debs', str(fix.debs), '--out', str(fix.out), '--check']) == 0,
          '--check passes')
    (fix.out / 'firmware-files.tsv').write_bytes(out['firmware-files.tsv'].replace(b'\tupstream\t', b'\tarmbian-only\t', 1))
    check(gen.main(['--sources', str(fix.sources), '--debs', str(fix.debs), '--out', str(fix.out), '--check']) == 1,
          '--check finds a changed file')
    (fix.out / 'firmware-files.tsv').write_bytes(out['firmware-files.tsv'])
    ok('generation is deterministic and --check detects drift in the committed files')

    good_inputs = (fix.out / 'inputs.json').read_text()
    fix.fw_deb.write_bytes(fix.fw_deb.read_bytes()[:-1] + b'\0')
    refuses(fix, 'size or sha256 differs', 'refuses an archive that is not the pinned one')
    fix.write_debs(fw_mutate=lambda f: f.update({'lib/firmware/a/up.bin': b'\x00TAMPERED'}))
    refuses(fix, 'a/up.bin: package bytes match neither', 'refuses firmware bytes no pinned source has')
    fix.write_debs(fw_mutate=lambda f: f.update({'lib/firmware/a/same.bin': b'\x00OTHER'}))
    refuses(fix, 'a/same.bin: package bytes are not armbian/firmware', 'refuses overlay paths with other bytes')
    fix.write_debs(ub_mutate=lambda f: f.update({'usr/lib/u-boot/LICENSE': b'edited\n'}))
    refuses(fix, 'is not U-Boot Licenses/README', 'refuses a licence summary that is not the pinned README')
    fix.write_debs(ub_mutate=lambda f: f.update({'usr/lib/linux-u-boot-edge-rock-5b-plus/u-boot-rockchip.bin':
                                                 fix.loader[:2100] + b'X' + fix.loader[2101:]}))
    refuses(fix, 'RKNS image 0: header hash', 'refuses a loader whose RKNS hashes do not verify')
    fix.write_debs()
    fix.write_inputs(lambda i: i['uboot']['tpl'].update(path='LICENSE.TXT'))
    refuses(fix, 'TPL bytes are not', 'refuses a DDR blob identity that does not match')
    fix.write_inputs(lambda i: i['uboot']['tpl'].update(compare_path='rk35/ddr.bin', compare_source='armbian-rkbin'))
    refuses(fix, 'comparison DDR blob', 'refuses when the comparison blob is the same bytes')
    fix.write_inputs(lambda i: i['packages'][UB].update(version='2.1'))
    refuses(fix, 'Version', 'refuses a control field that differs from the pin')
    fix.write_inputs()
    lf = fix.sources / 'linux-firmware.git'
    shutil.rmtree(lf)
    files = dict(fix.lf_files)
    files['WHENCE'] = files['WHENCE'].replace(b'See LICENCE.alpha for details', b'See LICENCE.missing')
    fix.commits['linux-firmware'] = make_repo(fix.sources, 'linux-firmware', files)
    fix.write_inputs()
    refuses(fix, 'names LICENCE.missing, which is not a file', 'refuses a WHENCE licence name with no file')
    shutil.rmtree(lf)
    files['WHENCE'] = fix.lf_files['WHENCE'] + b'\n' + b'-' * 40 + b'\n\nFile: z/orphan.bin\n'
    fix.commits['linux-firmware'] = make_repo(fix.sources, 'linux-firmware', files)
    fix.write_inputs()
    refuses(fix, 'no licence line after it', 'refuses a WHENCE entry format it cannot read')

    def whence_case(old, new, drop=()):
        shutil.rmtree(lf)
        files = {k: v for k, v in fix.lf_files.items() if k not in drop}
        check(old in files['WHENCE'], f'fixture has {old!r}')
        files['WHENCE'] = files['WHENCE'].replace(old, new)
        fix.commits['linux-firmware'] = make_repo(fix.sources, 'linux-firmware', files)
        fix.write_inputs()

    whence_case(b'Licence: MIT\n', b'Licence: BSD-2-Clause\n')
    refuses(fix, 'names BSD-2-Clause, which is not a file', 'refuses an SPDX name with no licence file')
    whence_case(b'Licence: MIT\n', b'Licence: MIT\n', drop=('LICENSES/MIT',))
    refuses(fix, 'names MIT, which is not a file', 'refuses a bare SPDX name whose file is missing')
    whence_case(b'See Apache-2.0 for details.', b'See LICENSE.apache for details.')
    refuses(fix, 'names LICENSE.apache, which is not a file', 'refuses a licence file name that does not exist')
    whence_case(b'BSD-3-Clause licence, See LICENCE.alpha for details', b'BSD-3-Clause licence')
    refuses(fix, 'BSD-3-Clause with no licence file in the same field', 'a reviewed name without a file needs a named file')
    whence_case(b'Licence: MIT\n', b'Licence: MIT\n')
    fix.write_inputs(lambda i: i['firmware']['licence_names_without_file'].update(ISC='unused'))
    refuses(fix, 'licence_names_without_file lists ISC', 'refuses an unused reviewed exception')
    shutil.rmtree(lf)
    fix.commits['linux-firmware'] = make_repo(fix.sources, 'linux-firmware', fix.lf_files)
    fix.write_inputs()
    check(fix.generate() == out, 'restored fixture regenerates identical output')
    ok('fixture restored after the refusal controls')

    # --- Part B: committed data ---------------------------------------------------------
    names = sorted(p.name for p in DATA.iterdir())
    check(names == sorted(['SHA256SUMS', 'inputs.json', *gen.OUTPUTS]), f'committed file set {names}')
    sums = dict(reversed(l.split('  ', 1)) for l in (DATA / 'SHA256SUMS').read_text().splitlines())
    check(set(sums) == set(names) - {'SHA256SUMS'}, 'SHA256SUMS covers every file')
    for name, s in sums.items():
        check(sha((DATA / name).read_bytes()) == s, f'{name} matches SHA256SUMS')
    real = json.loads((DATA / 'inputs.json').read_text())
    texts = [l.split('\t') for l in (DATA / 'texts.tsv').read_text().splitlines() if not l.startswith('#')]
    for name, off, n, s, b_, src, commit, path in texts:
        data = (DATA / name).read_bytes()[int(off):int(off) + int(n)]
        check(sha(data) == s and blob(data) == b_, f'committed text {path}')
        check(commit == real['sources'][src]['commit'], f'{path} names its pinned commit')
    pinned = {(t[5], t[7]): t[4] for t in texts}
    for key, path, want in (('linux-firmware', 'WHENCE', 'f1c472d29522cc2d12eaa9ac2b6e4b1688223799'),
                            ('linux-firmware', 'LICENSES/LICENCE.mali_csffw', '2478564cb003c35727b718e93f16cf34674d4884'),
                            ('linux-firmware', 'LICENSES/LICENCE.rtlwifi_firmware.txt', 'd70921f493795acb9af2a38f405193ba7a1b28a3'),
                            ('linux-firmware', 'LICENSES/LICENSE.r8169', 'f4afd4561287f50b6c532c55e9e5b8d65e15dad3'),
                            ('linux-firmware', 'LICENSES/MIT', '987c4a87a1e987c480891ea945c525720f6f89c2'),
                            ('linux-firmware', 'LICENSES/Apache-2.0', '8f71f43fee3f78649d238238cbde51e6d7055c82'),
                            ('armbian-firmware', 'README.md', 'a6cb44f3c2515ff282ed14adc3b49d28bf2d251a'),
                            ('u-boot', 'Licenses/README', 'd09f0fe2cb8273dde401dc4a44a9c76288cd5eff'),
                            ('tf-a', 'docs/license.rst', 'e35b9bbc2622603e839f347d2703fc059a05a0b4'),
                            ('armbian-rkbin', 'LICENSE.TXT', '07488283c5a5937bd109164e5ca9c6f07b4b0dc9')):
        check(pinned.get((key, path)) == want, f'{key} {path} is blob {want}')
    check(not any(t[5] == 'rockchip-rkbin' for t in texts), 'no Rockchip licence text is presented for the DDR blob')
    fw_texts = [t for t in texts if t[0] == f'{FW}.txt']
    check(len(fw_texts) == 133 and sum(t[7].startswith('LICENSES/') for t in fw_texts) == 131,
          'WHENCE, 131 licence files and the overlay README')
    check(any(t[7] == 'Licenses/gpl-2.0.txt' for t in texts), 'U-Boot GPL-2.0 text included')
    rows = [l.split('\t') for l in (DATA / 'firmware-files.tsv').read_text().splitlines() if not l.startswith('#')]
    counts = {}
    for r in rows:
        counts[r[2]] = counts.get(r[2], 0) + 1
        refs = re.findall(r'LICENSES/[\w.\-]+', r[3])
        check(all(any(t[7] == x for t in fw_texts) for x in refs), f'{r[0]} names only included texts')
        if r[2] in ('armbian-changed', 'armbian-only'):
            check(not refs and 'no licence statement established' in r[3], f'{r[0]} borrows no licence')
    check(counts == {'upstream': 4505, 'upstream-other-path': 51, 'armbian-changed': 49, 'armbian-only': 700},
          f'committed class counts {counts}')
    # The WHENCE reproduced in the payload, read back: a row that names no licence file
    # must come from a free-text Licence field, never from one naming MIT or Apache-2.0.
    whence_text = next(t for t in fw_texts if t[7] == 'WHENCE')
    whence = gen.parse_whence((DATA / f'{FW}.txt').read_bytes()[int(whence_text[1]):][:int(whence_text[2])].decode())
    by_path = {r[0]: r for r in rows}
    for path, want in (('radeon/R100_cp.bin', 'LICENSES/MIT'), ('r128/r128_cce.bin', 'LICENSES/MIT'),
                       ('intel/avs/max98357a-tplg.bin', 'LICENSES/Apache-2.0'),
                       ('qcom/yamato_pfp.fw', 'LICENSES/LICENSE.qcom_yamato')):
        check(by_path[path][3] == f'WHENCE entry for this path; licence files: {want}', f'{path}: {by_path[path][3]}')
    named = {x: sum(r[3].endswith(f'licence files: {x}') for r in rows) for x in ('LICENSES/MIT', 'LICENSES/Apache-2.0')}
    check(named == {'LICENSES/MIT': 28, 'LICENSES/Apache-2.0': 15}, f'rows naming MIT and Apache-2.0: {named}')
    no_file = [r for r in rows if r[3].endswith('it names no licence file')]
    check(len(no_file) == 39, f'{len(no_file)} rows name no licence file')
    free_text = ('Allegedly GPL', 'Dual GPLv2/MPL', 'GPLv2 or OpenIB.org BSD license')
    for r in no_file:
        entry = r[0] if r[3].startswith('WHENCE entry for this path') else r[3].split()[4].rstrip(';')
        fields = whence[entry]['licence']
        check(fields and all(f.startswith(free_text) for f in fields), f'{r[0]} names no file but its field is {fields}')
        check(not any(w in ('MIT', 'Apache-2.0') or w.startswith(('LICEN', 'NOTICE', 'GPL-'))
                      for f in fields for w in re.findall(r'[\w.+\-]+', f)), f'{r[0]} field names a licence file')
    payload = (DATA / f'{FW}.txt').read_bytes()
    check(b'Redistribution is limited to non-commercial or usage-only contexts.' in payload, 'README notice kept')
    ident = [l.split('\t') for l in (DATA / 'identity.tsv').read_text().splitlines() if not l.startswith('#')]
    versions = {l.strip() for l in (ROOT / 'manifests/armbian-bsp-deb-versions.txt').read_text().splitlines()}
    for name, pin in real['packages'].items():
        check(f'{name}={pin["version"]}' in versions, f'{name} {pin["version"]} is the image pin')
        check(['package', name, pin['version'], pin['architecture']] == next(r[:4] for r in ident if r[:2] == ['package', name]),
              f'{name} identity row')
    content = json.loads((ROOT / 'manifests/armbian-firmware-content.json').read_text())
    content = content[0] if isinstance(content, list) else content
    fwpin = real['packages'][FW]
    check((content['archive_sha256'], content['compressed_bytes'], content['version']) ==
          (fwpin['sha256'], fwpin['bytes'], fwpin['version']), 'firmware archive pin agrees with the image')
    loader = next(r for r in ident if r[0] == 'loader')
    blobs = [l.split('\t') for l in (ROOT / 'manifests/bootloader-blobs.tsv').read_text().splitlines()
             if l and not l.startswith('#')]
    mine = [r for r in blobs if r[2] == UB]
    check(mine and all(r[3] == real['packages'][UB]['version'] and r[4] == 'u-boot-rockchip.bin'
                       and r[5] == loader[3] for r in mine), 'the image writes exactly the described loader')
    check(any(r[0] == 'rock-5b-plus' and r[1] == 'default' for r in mine), 'rock-5b-plus default uses it')
    ok('committed payloads match their checksums, pinned blobs, class counts and the image pins')

    # --- Part C: installer ----------------------------------------------------------------
    fix.write_debs()
    out = fix.generate()

    def build_root(case, fw_status='install ok installed', ub_status='hold ok installed', extra=''):
        root = tmp / 'c' / case
        info = root / 'var/lib/dpkg/info'
        info.mkdir(parents=True)
        (root / 'usr/lib').mkdir(parents=True)
        (root / 'lib').symlink_to('usr/lib')
        for files in (fix.fw_files, fix.ub_files):
            for p, d in files.items():
                if d is None or isinstance(d, tuple):
                    continue
                dest = root / p.replace('lib/firmware/', 'usr/lib/firmware/', 1) if p.startswith('lib/') else root / p
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(d)
        (root / 'usr/lib/firmware/link.bin').symlink_to('a/up.bin')
        lists = {FW: fix.fw_files, UB: fix.ub_files}
        for pkg, files in lists.items():
            (info / f'{pkg}.list').write_text('/.\n' + ''.join(f'/{p}\n' for p in sorted(files)))
        (info / f'{FW}.md5sums').write_bytes(fix.fw_sums)
        (info / f'{UB}.md5sums').write_bytes(fix.ub_sums)
        (root / 'var/lib/dpkg/status').write_text(
            f'Package: base-files\nStatus: install ok installed\nVersion: 13\nArchitecture: arm64\n\n'
            f'Package: {FW}\nStatus: {fw_status}\nPriority: optional\nVersion: 1.0\nArchitecture: all\n\n'
            f'Package: {UB}\nStatus: {ub_status}\nVersion: 2.0\nArchitecture: arm64\n' + extra)
        return root

    def install(root, base=fix.out):
        env = dict(os.environ, LICENCE_NOTICES_DESTROOT=str(root), BOOT_FIRMWARE_NOTICES_BASE=str(base))
        r = subprocess.run(['bash', str(INSTALLER)], env=env, capture_output=True, text=True)
        return r.returncode, r.stderr

    def written(root):
        return [p for p in (FW, UB) if (root / f'usr/share/doc/{p}/copyright').exists()
                or (root / f'usr/share/doc/{p}/copyright').is_symlink()]

    def refused(root, pattern, label, base=fix.out, keep=()):
        rc, log = install(root, base)
        check(rc != 0, f'{label}: installer succeeded')
        check(re.search(pattern, log), f'{label}: wrong message:\n{log}')
        check(written(root) == list(keep), f'{label}: wrote {written(root)} before refusing')
        ok(label)

    root = build_root('good')
    (root / 'usr/lib/firmware/e/only.bin').unlink()   # pruned by the image
    (root / 'usr/lib/firmware/a/up2.bin').unlink()
    rc, log = install(root)
    check(rc == 0, f'good tree installs:\n{log}')
    fwc = (root / f'usr/share/doc/{FW}/copyright').read_bytes()
    ubc = (root / f'usr/share/doc/{UB}/copyright').read_bytes()
    check(fwc.startswith(out[f'{FW}.txt']) and ubc == out[f'{UB}.txt'], 'payloads written verbatim')
    for p in (FW, UB):
        check(oct((root / f'usr/share/doc/{p}/copyright').stat().st_mode & 0o777) == '0o644', 'mode 0644')
    tail = fwc[len(out[f'{FW}.txt']):].decode()
    check('Shipped in this image: 11 of 13' in tail, 'shipped count')
    check('\nshipped\tupstream\ta/up.bin\tWHENCE entry for this path; licence files: LICENSES/LICENCE.alpha\n' in tail,
          'shipped row')
    check('\nremoved\tarmbian-only\te/only.bin\t' in tail and '\nremoved\tupstream\ta/up2.bin\t' in tail, 'removed rows')
    check(re.search(r'\n\s+0 of\s+1  armbian-only\n', tail), 'per-class shipped counts')
    rc2, _ = install(root)
    check(rc2 != 0 and (root / f'usr/share/doc/{FW}/copyright').read_bytes() == fwc, 'a second run refuses and keeps the file')
    ok('installer writes both copyright files with the shipped and removed firmware, and refuses to run twice')

    root = build_root('docs-pruned')
    shutil.rmtree(root / 'usr/share/doc')
    rc, log = install(root)
    check(rc == 0, f'optional doc files may be pruned:\n{log}')
    ok('package doc files that a prune removed are not required')

    root = build_root('uncovered', extra='\nPackage: linux-u-boot-orangepi5-plus-edge\nStatus: install ok installed\n'
                                         'Version: 26.8.3\nArchitecture: arm64\n')
    rc, log = install(root)
    check(rc == 0 and 'uncovered: linux-u-boot-orangepi5-plus-edge 26.8.3' in log
          and not (root / 'usr/share/doc/linux-u-boot-orangepi5-plus-edge').exists(), 'uncovered package logged, no file')
    ok('another U-Boot package is logged as uncovered and gets no invented notice')

    root = build_root('absent', fw_status='deinstall ok config-files', ub_status='purge ok not-installed')
    rc, log = install(root)
    check(rc == 0 and written(root) == [] and 'nothing to do' in log, 'absent packages skipped')
    ok('packages that are not installed are skipped')

    root = build_root('drift-version')
    status = root / 'var/lib/dpkg/status'
    status.write_text(status.read_text().replace('Version: 1.0', 'Version: 1.1'))
    refused(root, r'armbian-firmware-full 1\.1 \(all\) is installed, but the notices cover 1\.0', 'refuses another version')
    root = build_root('drift-arch')
    status = root / 'var/lib/dpkg/status'
    status.write_text(status.read_text().replace('Version: 2.0\nArchitecture: arm64', 'Version: 2.0\nArchitecture: armhf'))
    refused(root, r'2\.0 \(armhf\) is installed', 'refuses another architecture')
    root = build_root('half', fw_status='install reinstreq half-installed')
    refused(root, "dpkg state 'install reinstreq half-installed'", 'refuses an unfinished package state')
    root = build_root('reinstreq', ub_status='hold reinstreq installed')
    refused(root, "dpkg state 'hold reinstreq installed'", 'refuses a package dpkg flags for reinstallation')
    root = build_root('dup', extra=f'\nPackage: {FW}\nStatus: install ok installed\nVersion: 1.0\nArchitecture: all\n')
    refused(root, 'has 2 dpkg records', 'refuses duplicate package records')
    root = build_root('nostatus')
    (root / 'var/lib/dpkg/status').unlink()
    refused(root, 'cannot read', 'refuses without a package database')
    root = build_root('md5')
    (root / f'var/lib/dpkg/info/{UB}.md5sums').write_bytes(fix.ub_sums + b'0' * 32 + b'  x\n')
    refused(root, 'installed md5sums differ', 'refuses another archive with the same version')
    root = build_root('fw-byte')
    (root / 'usr/lib/firmware/c/orig.bin').write_bytes(b'\x00CHANGED')
    refused(root, 'firmware file c/orig.bin differs', 'refuses a changed firmware file')
    root = build_root('fw-symlink')
    (root / 'usr/lib/firmware/c/orig.bin').unlink()
    (root / 'usr/lib/firmware/c/orig.bin').symlink_to('../a/up.bin')
    refused(root, 'c/orig.bin is a symlink', 'refuses a firmware file replaced by a symlink')
    root = build_root('fw-dir-symlink')
    shutil.move(root / 'usr/lib/firmware/e', root / 'elsewhere')
    (root / 'usr/lib/firmware/e').symlink_to('../../../elsewhere')
    refused(root, 'firmware directory e is a symlink', 'refuses a symlinked firmware directory')
    root = build_root('fw-root-symlink')
    shutil.move(root / 'usr/lib/firmware', root / 'fwreal')
    (root / 'usr/lib/firmware').symlink_to('../../fwreal')
    refused(root, 'is not a real directory', 'refuses a symlinked firmware root')
    root = build_root('fw-unmerged')
    (root / 'lib').unlink()
    (root / 'lib').mkdir()
    refused(root, 'merged-/usr symlink', 'refuses an unmerged /lib')
    root = build_root('fw-extra')
    (root / 'usr/lib/firmware/x.bin').write_bytes(b'x')
    with open(root / f'var/lib/dpkg/info/{FW}.list', 'a') as f:
        f.write('/lib/firmware/x.bin\n')
    refused(root, 'x.bin is in its dpkg file list but not in firmware-files.tsv', 'refuses unpinned package files')
    root = build_root('fw-unlisted')
    lst = root / f'var/lib/dpkg/info/{FW}.list'
    lst.write_text(lst.read_text().replace('/lib/firmware/d/copy.bin\n', ''))
    refused(root, 'd/copy.bin is pinned but not in its dpkg file list', 'refuses a file list without a pinned file')
    root = build_root('fw-empty')
    for p in list((root / 'usr/lib/firmware').rglob('*')):
        if p.is_file() and not p.is_symlink():
            p.unlink()
    refused(root, 'none of its firmware files is present', 'refuses a firmware tree with nothing in it')
    root = build_root('ub-missing')
    (root / 'usr/lib/linux-u-boot-edge-rock-5b-plus/u-boot-rockchip.bin').unlink()
    refused(root, 'u-boot-rockchip.bin is missing; the installation is partial', 'refuses a partial U-Boot install')
    root = build_root('ub-changed')
    (root / 'usr/lib/u-boot/LICENSE').write_bytes(b'edited\n')
    refused(root, '/usr/lib/u-boot/LICENSE differs from the pinned archive', 'refuses a changed U-Boot file')
    root = build_root('ub-extra')
    (root / 'usr/lib/u-boot/extra.bin').write_bytes(b'x')
    with open(root / f'var/lib/dpkg/info/{UB}.list', 'a') as f:
        f.write('/usr/lib/u-boot/extra.bin\n')
    refused(root, 'extra.bin is in its dpkg file list but not in identity.tsv', 'refuses unpinned U-Boot files')
    root = build_root('ub-dirlink')
    shutil.move(root / 'usr/lib/u-boot', root / 'ubreal')
    (root / 'usr/lib/u-boot').symlink_to('../../ubreal')
    refused(root, 'u-boot is a symlink; refusing to follow it', 'refuses a symlinked U-Boot directory')
    root = build_root('doc-symlink')
    (root / 'outside').mkdir()
    shutil.rmtree(root / f'usr/share/doc/{UB}')
    (root / f'usr/share/doc/{UB}').symlink_to('../../../outside')
    refused(root, f'{UB} is a symlink', 'refuses a symlinked doc directory, writing nothing')
    check(not any((root / 'outside').iterdir()), 'nothing written outside')
    root = build_root('doc-file')
    shutil.rmtree(root / f'usr/share/doc/{UB}')
    (root / f'usr/share/doc/{UB}').write_text('not a directory\n')
    refused(root, f'/usr/share/doc/{UB} exists and is not a directory',
            'refuses a second package whose doc path is a file, writing nothing for either package')
    check((root / f'usr/share/doc/{UB}').read_text() == 'not a directory\n', 'blocking file untouched')
    check(not (root / f'usr/share/doc/{FW}/copyright').exists(), 'first package left without a partial write')
    root = build_root('doc-fifo')
    shutil.rmtree(root / f'usr/share/doc/{UB}')
    os.mkfifo(root / f'usr/share/doc/{UB}')
    refused(root, f'/usr/share/doc/{UB} exists and is not a directory',
            'refuses a second package whose doc path is a FIFO, writing nothing for either package')
    root = build_root('own-copyright')
    (root / f'usr/share/doc/{UB}/copyright').write_text('package-provided\n')
    refused(root, 'already has', 'refuses a package that ships its own copyright', keep=(UB,))
    check((root / f'usr/share/doc/{UB}/copyright').read_text() == 'package-provided\n', 'package file untouched')

    def bad_base(case, mutate):
        base = tmp / 'c' / f'{case}-base'
        shutil.copytree(fix.out, base)
        mutate(base)
        return base

    def resum(base):
        lines = [f'{sha((base / n).read_bytes())}  {n}' for n in sorted(p.name for p in base.iterdir() if p.name != 'SHA256SUMS')]
        (base / 'SHA256SUMS').write_text('\n'.join(lines) + '\n')

    def edit_text(base):
        p = base / f'{FW}.txt'
        p.write_bytes(p.read_bytes().replace(b'Alpha licence text.', b'Alpha licence TEXT.'))
        resum(base)

    refused(build_root('text-edit'), 'verbatim text LICENSES/LICENCE.alpha .* changed',
            'refuses an altered verbatim text even with matching checksums', base=bad_base('text', edit_text))
    refused(build_root('payload-edit'), 'do not match SHA256SUMS', 'refuses a payload that differs from its checksum',
            base=bad_base('payload', lambda b: (b / f'{UB}.txt').write_bytes(b'x')))
    refused(build_root('payload-missing'), 'SHA256SUMS lists', 'refuses a missing payload file',
            base=bad_base('missing', lambda b: ((b / 'texts.tsv').unlink(), resum(b))))
    refused(build_root('payload-symlink'), 'missing or a symlink', 'refuses a symlinked payload file',
            base=bad_base('plink', lambda b: ((b / 'identity.tsv').rename(b / 'id'), (b / 'identity.tsv').symlink_to('id'))))

    def table_edit(base):
        p = base / 'firmware-files.tsv'
        p.write_text(p.read_text().replace('\tupstream\t', '\tgranted\t', 1))
        resum(base)
    refused(build_root('table-edit'), 'malformed firmware-files.tsv row', 'refuses an unknown class',
            base=bad_base('table', table_edit))

    # --- Part D: prune survival ---------------------------------------------------------
    root = build_root('prune')
    (root / f'usr/share/doc/{FW}/NEWS').write_text('news\n')
    rc, log = install(root)
    check(rc == 0, f'prune case installs:\n{log}')
    doc = root / 'usr/share/doc'
    before = {p: (doc / p / 'copyright').read_bytes() for p in (FW, UB)}
    empty = tmp / 'empty.list'
    empty.write_text('')
    env = dict(os.environ, CERALIVE_DOC_ROOT=str(doc), CERALIVE_PRUNE_PATHS_LIST=str(empty), SRCDIR=str(ROOT / 'mkosi'))
    subprocess.run(['bash', '-c', f'source "{APP}"; prune_package_docs'], env=env, check=True, capture_output=True)
    check({p: (doc / p / 'copyright').read_bytes() for p in (FW, UB)} == before, 'app layer prune keeps them')
    check(not (doc / FW / 'changelog.gz').exists() and not (doc / FW / 'NEWS').exists(), 'app layer prune ran')
    (doc / UB / 'changelog.gz').write_bytes(b'again')
    subprocess.run(['bash', str(ROOT / 'mkosi/runtime/ceralive-reprune.sh')], env=env, check=True, capture_output=True)
    check({p: (doc / p / 'copyright').read_bytes() for p in (FW, UB)} == before, 'reprune hook keeps them')
    check(not (doc / UB / 'changelog.gz').exists(), 'reprune hook ran')
    policies = [p for p in (ROOT / 'mkosi/runtime/doc-notice-policy.sh',
                            Path(os.environ.get('BOOT_FIRMWARE_NOTICES_EXTRA_POLICY', '/nonexistent'))) if p.is_file()]
    for policy in policies:
        (doc / UB / 'changelog.gz').write_bytes(b'again')
        subprocess.run(['bash', '-c', f'source "{policy}"; doc_notice_prune "{doc}"'], check=True, capture_output=True)
        check({p: (doc / p / 'copyright').read_bytes() for p in (FW, UB)} == before, f'{policy} keeps them')
        check(not (doc / UB / 'changelog.gz').exists(), f'{policy} ran')
    ok(f'copyright files survive the app layer prune, the reprune hook and {len(policies)} notice policy file(s)')

    # --- Part E: wiring ---------------------------------------------------------------------
    app = APP.read_text().splitlines()
    idx = lambda pat: next(i for i, l in enumerate(app) if re.fullmatch(pat, l))
    hook = idx(r'  bash "\$\{SRCDIR:\?\}/runtime/licence-notices/install-boot-firmware-notices\.sh"')
    check(idx(r'    install_first_party_apps') < idx(r'  bash .*/install-licence-notices\.sh"') < hook
          < idx(r'  prune_final_image_payload'), 'hook order')
    check(os.access(INSTALLER, os.X_OK), 'installer executable')
    ok('app layer runs the installer after the package installs and the other notices, before the doc prune')
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print(f'PASS: boot firmware notices ({passed} checks)')

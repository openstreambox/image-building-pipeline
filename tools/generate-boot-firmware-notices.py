#!/usr/bin/env python3
"""Derive the firmware and boot loader notice payloads (stdlib only).

Reads the reviewed pins in mkosi/runtime/licence-notices/boot-firmware/inputs.json,
the two pinned Armbian archives and local Git repositories holding each pinned
source commit (a blobless clone is enough; git fetches the few text blobs it
needs). tools/fetch-boot-firmware-notice-sources.sh prepares both.

Writes, deterministically:
  armbian-firmware-full.txt           static part of that package's copyright file
  linux-u-boot-rock-5b-plus-edge.txt  the U-Boot package's copyright file
  firmware-files.tsv                  every firmware file of the package: sha256,
                                      class and the source entry for its exact bytes
  identity.tsv                        installed identity the installer checks
  texts.tsv                           byte range, sha256 and git blob of every
                                      verbatim text inside the payloads
  excerpts.tsv                        byte range and sha256 of every verbatim
                                      excerpt inside the payloads, with its place
                                      in the source file
  SHA256SUMS                          all of the above plus inputs.json

Every claim the payloads make about an archive is checked here first: archive
sha256 and size, control fields, each firmware file's git blob against the
pinned trees, the loader's RKNS header hashes, the DDR blob identity, version
strings and the U-Boot licence summary, and each reviewed historical origin (an
earlier linux-firmware commit with an armbian-changed file's exact bytes, its
WHENCE group and licence files). Any mismatch stops before output exists.
Nothing from the archives is executed or written to disk.

  generate-boot-firmware-notices.py --sources DIR --debs DIR [--out DIR]
  generate-boot-firmware-notices.py --sources DIR --debs DIR --check
"""
import argparse
import hashlib
import io
import json
import lzma
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tarfile
import tempfile

DEFAULT_DIR = Path(__file__).resolve().parents[1] / 'mkosi/runtime/licence-notices/boot-firmware'
RULE = '=' * 78
OUTPUTS = ('armbian-firmware-full.txt', 'linux-u-boot-rock-5b-plus-edge.txt',
           'firmware-files.tsv', 'identity.tsv', 'texts.tsv', 'excerpts.tsv')
NOTICE_NAME = re.compile(r'(?i)(licen[cs]e|notice|readme|whence|copying|copyright)')
# A WHENCE Licence field is free text. Each word is resolved against the pinned
# licence directories: a word that is the name of a file there names that file. A
# word shaped like a licence file name or an SPDX identifier must resolve, or
# generation stops; other words ("GPLv2", "Dual GPLv2/MPL") name no file.
WORD = re.compile(r'[A-Za-z0-9][A-Za-z0-9._+\-]*')
FILE_LIKE = re.compile(r'(?:LICEN[CS]E[\w.\-]*|NOTICE\.[\w.\-]+|GPL-[\d.]+[\w\-]*)')
SPDX_LIKE = re.compile(r'[A-Za-z][A-Za-z0-9.]*(?:-[A-Za-z0-9.]+)*-(?:\d[\w.]*|Clause)(?:-[A-Za-z0-9.]+)*\+?')
SPDX_BARE = frozenset({'0BSD', 'ISC', 'MIT', 'NCSA', 'Unlicense', 'X11', 'Zlib'})
SAFE_PATH = re.compile(r'^[^\t\n\r\\]+$')


class DeriveError(Exception):
    pass


def fail(msg):
    raise DeriveError(msg)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def git_blob_id(data):
    return hashlib.sha1(b'blob %d\0' % len(data) + data).hexdigest()


# --- archives -----------------------------------------------------------------

class Slice(io.RawIOBase):
    """Read-only view of one ar member, so large members are streamed."""

    def __init__(self, f, offset, size):
        super().__init__()
        self.f, self.pos, self.end = f, offset, offset + size

    def readable(self):
        return True

    def readinto(self, b):
        n = min(len(b), self.end - self.pos)
        if n <= 0:
            return 0
        self.f.seek(self.pos)
        data = self.f.read(n)
        b[:len(data)] = data
        self.pos += len(data)
        return len(data)


def ar_index(f, label):
    """Return {name: (offset, size)} of a Debian ar archive."""
    f.seek(0)
    if f.read(8) != b'!<arch>\n':
        fail(f'{label}: not an ar archive')
    members, pos = {}, 8
    while True:
        f.seek(pos)
        header = f.read(60)
        if not header:
            return members
        if len(header) != 60 or header[58:60] != b'`\n':
            fail(f'{label}: corrupt ar header')
        name = header[:16].decode().strip().rstrip('/')
        size = int(header[48:58].decode().strip())
        members[name] = (pos + 60, size)
        pos += 60 + size + (size % 2)


def open_member(f, members, prefix, label):
    name = next((n for n in members if n.startswith(prefix)), None)
    if not name:
        fail(f'{label}: missing {prefix} member')
    stream = io.BufferedReader(Slice(f, *members[name]), 1 << 20)
    if name.endswith('.xz'):
        stream = lzma.open(stream)
    elif not name.endswith('.tar'):
        fail(f'{label}: unsupported member {name}')
    return tarfile.open(fileobj=stream, mode='r|')


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def control_fields(text):
    fields, key = {}, None
    for line in text.splitlines():
        if line[:1] in (' ', '\t') and key:
            fields[key] += '\n' + line
        elif ':' in line:
            key, value = line.split(':', 1)
            fields[key] = value.strip()
    return fields


def read_deb(path, pin, name, keep=()):
    """Verify an archive against its pin; return control data, file hashes and kept bytes."""
    if path.stat().st_size != pin['bytes'] or file_sha256(path) != pin['sha256']:
        fail(f'{path.name}: size or sha256 differs from the pin for {name}')
    with open(path, 'rb') as f:
        members = ar_index(f, path.name)
        if 'debian-binary' not in members:
            fail(f'{path.name}: not a Debian package')
        f.seek(members['debian-binary'][0])
        if f.read(4) != b'2.0\n':
            fail(f'{path.name}: not a format 2.0 package')
        control = {}
        with open_member(f, members, 'control.tar', path.name) as tf:
            for m in tf:
                if m.isreg():
                    control[m.name.removeprefix('./')] = tf.extractfile(m).read()
        files, links, kept = {}, {}, {}
        with open_member(f, members, 'data.tar', path.name) as tf:
            for m in tf:
                rel = m.name.removeprefix('./').lstrip('/')
                if m.isreg():
                    if not SAFE_PATH.match(rel):
                        fail(f'{path.name}: unsupported character in {rel!r}')
                    h, g = hashlib.sha256(), hashlib.sha1(b'blob %d\0' % m.size)
                    src = tf.extractfile(m)
                    buf = bytearray() if rel in keep else None
                    for chunk in iter(lambda: src.read(1 << 20), b''):
                        h.update(chunk)
                        g.update(chunk)
                        if buf is not None:
                            buf += chunk
                    files[rel] = {'sha256': h.hexdigest(), 'git_blob': g.hexdigest(), 'size': m.size}
                    if buf is not None:
                        kept[rel] = bytes(buf)
                elif m.issym() or m.islnk():
                    links[rel] = m.linkname
                elif not m.isdir():
                    fail(f'{path.name}: unexpected member type for {rel}')
    if 'control' not in control or 'md5sums' not in control:
        fail(f'{path.name}: no control or md5sums control file')
    fields = control_fields(control['control'].decode())
    for key, want in (('Package', name), ('Version', pin['version']),
                      ('Architecture', pin['architecture']),
                      ('Armbian-Original-Hash', pin['armbian_original_hash'])):
        if fields.get(key) != want:
            fail(f'{path.name}: control field {key} is {fields.get(key)!r}, pinned {want!r}')
    missing = [k for k in keep if k not in kept]
    if missing:
        fail(f'{path.name}: missing {", ".join(missing)}')
    return {'fields': fields, 'md5sums_sha256': sha256(control['md5sums']), 'files': files,
            'links': links, 'kept': kept}


# --- sources ------------------------------------------------------------------

class Repo:
    def __init__(self, key, pin, root):
        self.key, self.url, self.commit = key, pin['url'], pin['commit']
        self.tag = pin.get('tag')
        self.dir = root / f'{key}.git'
        if not self.dir.is_dir():
            fail(f'source repository {self.dir} is missing; run tools/fetch-boot-firmware-notice-sources.sh')
        resolved = self.git('rev-parse', '--verify', f'{self.commit}^{{commit}}').decode().strip()
        if resolved != self.commit:
            fail(f'{key}: {self.commit} resolves to {resolved}')
        self.tree = {}
        for entry in self.git('ls-tree', '-r', '-z', '--full-tree', self.commit).split(b'\0'):
            if not entry:
                continue
            meta, path = entry.split(b'\t', 1)
            _mode, kind, oid = meta.decode().split()
            if kind == 'blob':
                self.tree[path.decode()] = oid

    def git(self, *args, stdin=None, env=None):
        try:
            return subprocess.run(['git', '--git-dir', str(self.dir), *args], check=True, input=stdin,
                                  capture_output=True, env=env).stdout
        except subprocess.CalledProcessError as e:
            fail(f'{self.key}: git {" ".join(args)} failed: {e.stderr.decode().strip()}')

    def prefetch(self, paths):
        """Fetch the missing blobs of a blobless clone in one request instead of one each."""
        oids = sorted({self.tree[p] for p in paths if p in self.tree})
        if not oids:
            return
        env = dict(os.environ, GIT_NO_LAZY_FETCH='1')
        state = self.git('cat-file', '--batch-check', stdin=('\n'.join(oids) + '\n').encode(), env=env)
        missing = [line.split()[0] for line in state.decode().splitlines() if line.endswith(' missing')]
        if missing:
            self.git('-c', 'fetch.negotiationAlgorithm=noop', 'fetch', '-q', '--no-tags', '--no-write-fetch-head',
                     '--recurse-submodules=no', '--filter=blob:none', '--stdin', 'origin',
                     stdin=('\n'.join(missing) + '\n').encode())

    def text(self, path):
        oid = self.tree.get(path)
        if not oid:
            fail(f'{self.key}: {path} does not exist at {self.commit}')
        data = self.git('cat-file', 'blob', oid)
        if git_blob_id(data) != oid:
            fail(f'{self.key}: blob {oid} for {path} does not hash to its id')
        return data

    def at(self):
        return f'{self.url} at {self.commit}' + (f' (tag {self.tag})' if self.tag else '')


# --- WHENCE -------------------------------------------------------------------

def parse_whence(text):
    """File path -> {'licence': [Licence field bodies]} from linux-firmware's WHENCE."""
    entries = {}
    for section in re.split(r'\n-{10,}\n', text):
        lines = section.split('\n')
        group, i = [], 0
        while i < len(lines):
            line = lines[i]
            file_match = re.match(r'^(?:Raw)?File:\s*(.+?)\s*$', line)
            licence_match = re.match(r'^Licen[cs]e:\s*(.*)$', line)
            if file_match:
                group.append(file_match.group(1).strip('"'))
            elif licence_match:
                body = licence_match.group(1)
                while i + 1 < len(lines) and re.match(r'^[ \t]+\S', lines[i + 1]):
                    i += 1
                    body += ' ' + lines[i].strip()
                for path in group:
                    entries.setdefault(path, {'licence': []})['licence'].append(' '.join(body.split()))
                group = []
            i += 1
        if group:
            fail(f'WHENCE lists {group[0]} with no licence line after it; the format changed')
    return entries


def whence_groups(data):
    """Every licence group of a WHENCE file, located by byte offset in data.

    Uses the same section, File and Licence rules as parse_whence. A section runs
    between separator lines, without its leading and trailing blank lines. A group
    runs from its first non-blank line after the section's last Driver line, or
    after the previous group's Licence field, to the end of its own Licence field,
    continuation lines included. Returns dicts with 'section' and 'span' (byte
    ranges), 'driver', 'files' and 'licence' (whitespace-normalised field body).
    """
    lines, pos = [], 0
    for raw in data.splitlines(keepends=True):
        lines.append((pos, pos + len(raw), raw.decode('utf-8').rstrip('\n')))
        pos += len(raw)
    groups, section, driver, start, files, i = [], [], None, None, [], 0
    sec_start = sec_end = None
    while i < len(lines):
        begin, end, line = lines[i]
        if re.fullmatch(r'-{10,}', line):
            for g in section:
                g['section'] = (sec_start, sec_end)
            groups.extend(section)
            section, driver, start, files, sec_start, sec_end = [], None, None, [], None, None
            i += 1
            continue
        if line.strip():
            sec_start = begin if sec_start is None else sec_start
            sec_end = end
        if line.startswith('Driver:'):
            driver, start, files = line[len('Driver:'):].strip(), None, []
        elif line.strip():
            start = begin if start is None else start
            file_match = re.match(r'^(?:Raw)?File:\s*(.+?)\s*$', line)
            licence_match = re.match(r'^Licen[cs]e:\s*(.*)$', line)
            if file_match:
                files.append(file_match.group(1).strip('"'))
            elif licence_match:
                body = licence_match.group(1)
                while i + 1 < len(lines) and re.match(r'^[ \t]+\S', lines[i + 1][2]):
                    i += 1
                    body += ' ' + lines[i][2].strip()
                    end = lines[i][1]
                sec_end = end
                section.append({'span': (start, end), 'driver': driver, 'files': files,
                                'licence': ' '.join(body.split())})
                start, files = None, []
        i += 1
    for g in section:
        g['section'] = (sec_start, sec_end)
    groups.extend(section)
    return groups


# --- payload assembly -----------------------------------------------------------

class Payload:
    def __init__(self, name):
        self.name, self.buf, self.texts, self.excerpts = name, bytearray(), [], []

    def write(self, text=''):
        self.buf += text.encode()

    def line(self, text=''):
        self.write(text + '\n')

    def verbatim(self, repo, path, data, title=None):
        self.line(RULE)
        if title:
            self.line(title)
        self.line(f'File: {path}')
        self.line(f'Source: {repo.at()}')
        self.line(f'Git blob: {git_blob_id(data)}')
        self.line(f'Bytes: {len(data)}, reproduced verbatim from the next line')
        self.line(RULE)
        offset = len(self.buf)
        self.buf += data
        self.texts.append((self.name, offset, len(data), sha256(data), git_blob_id(data),
                           repo.key, repo.commit, path))
        if not data.endswith(b'\n'):
            self.write('\n')
        self.line()

    def excerpt(self, repo, path, data, spans, title):
        """Reproduce the first of spans [((start, end), label), ...] of data verbatim.

        Each later span must lie inside the first. Every span is recorded at its own
        position within the reproduced bytes, so excerpts.tsv locates it both in the
        payload and in the source file.
        """
        (first, last), _ = spans[0]
        if not 0 <= first < last <= len(data) or any(not first <= a < b <= last for (a, b), _ in spans[1:]):
            fail(f'{repo.key}: excerpt of {path} out of range')
        self.line(RULE)
        self.line(title)
        self.line(f'File: {path} (excerpt)')
        self.line(f'Source: {repo.at()}')
        self.line(f'Git blob of the whole file: {git_blob_id(data)}, {len(data)} bytes')
        self.line(f'Excerpt: bytes {first} to {last - 1} of that file ({last - first} bytes), '
                  'reproduced verbatim from the next line')
        self.line(RULE)
        offset = len(self.buf)
        self.buf += data[first:last]
        for (a, b), what in spans:
            self.excerpts.append((self.name, offset + a - first, b - a, sha256(data[a:b]), repo.key, repo.commit,
                                  path, git_blob_id(data), a, what))
        if not data[first:last].endswith(b'\n'):
            self.write('\n')
        self.line()


def wrap(text, width=78, indent=''):
    words, lines, cur = text.split(), [], indent
    for word in words:
        if len(cur) + len(word) + (0 if cur == indent else 1) > width and cur != indent:
            lines.append(cur)
            cur = indent
        cur += ('' if cur == indent else ' ') + word
    if cur.strip():
        lines.append(cur)
    return '\n'.join(lines)


def para(payload, text, indent=''):
    payload.line(wrap(text, indent=indent))
    payload.line()


# --- firmware -----------------------------------------------------------------

CLASS_TEXT = {
    'upstream': 'identical to linux-firmware at the same path; the WHENCE entry for that path describes these bytes',
    'upstream-other-path': 'identical to a linux-firmware file at another path, named in the entry column; the WHENCE entry for that path describes a file with these exact bytes',
    'armbian-changed': 'armbian/firmware replaced the linux-firmware file at this path with different bytes; the WHENCE entry for the path describes the replaced bytes, not these',
    'armbian-only': 'only in armbian/firmware; no file with these bytes is in linux-firmware',
}


def licence_field_files(body, tree, dirs):
    """Return (licence files, unresolved licence-like words) of one WHENCE Licence field.

    Every word is looked up in the licence directories, in order; a word that is a
    file there names it. In the repository root only a word shaped like a licence
    file name counts, so WHENCE or README.md never do. A word shaped like a licence
    file name or an SPDX identifier that is no file is returned as unresolved; the
    caller stops on it unless it is a reviewed exception. Other words name nothing,
    so a free-form field such as "Allegedly GPLv2+" names no licence file.
    """
    files, unresolved = set(), []
    for raw in WORD.findall(body):
        word = raw.rstrip('.-')
        if not word:
            continue
        path = next((d + word for d in dirs if d + word in tree and (d or FILE_LIKE.fullmatch(word))), None)
        if path:
            files.add(path)
        elif (FILE_LIKE.fullmatch(word) or SPDX_LIKE.fullmatch(word) or word in SPDX_BARE) \
                and word not in unresolved:
            unresolved.append(word)
    return files, unresolved


HISTORICAL_KEYS = frozenset({'sha256', 'bytes', 'git_blob', 'source', 'subject', 'whence_blob', 'driver',
                             'licence', 'licence_files'})


def derive_historical(inputs, deb, repos):
    """Check every reviewed historical origin; return its facts, or stop.

    An entry names an armbian-changed file whose exact bytes an earlier linux-firmware
    commit has at the same path. Before anything is rendered, each claim is checked:
    the reviewed sha256, size and git blob against the package and the pinned overlay;
    the pinned linux-firmware has other bytes there; the earlier commit is from the
    same repository, has the reviewed subject and these exact bytes at this path; its
    WHENCE is the reviewed blob, lists the path in exactly one group, under the
    reviewed Driver line, closed by the reviewed Licence field; and that field names
    exactly the reviewed licence files, as the reviewed blobs. A file of the same
    name with other bytes, at any commit, establishes nothing.
    """
    cfg = inputs['firmware']
    entries = cfg.get('historical_origins', {})
    if not isinstance(entries, dict):
        fail('historical_origins must be an object')
    upstream, overlay = repos[cfg['upstream']], repos[cfg['overlay']]
    up_pin = inputs['sources'][cfg['upstream']]
    facts = {}
    for path, e in sorted(entries.items()):
        label = f'historical origin of {path}'
        if not isinstance(e, dict) or set(e) != HISTORICAL_KEYS:
            fail(f'{label}: needs exactly the fields {", ".join(sorted(HISTORICAL_KEYS))}')
        if not (isinstance(e['licence_files'], dict) and e['licence_files']
                and all(re.fullmatch(r'[0-9a-f]{40}', str(v)) for v in e['licence_files'].values())):
            fail(f'{label}: licence_files must map each licence file to its git blob')
        key = e['source']
        if key not in repos or key in (cfg['upstream'], cfg['overlay']):
            fail(f'{label}: source {key!r} is not a separate pinned source')
        pin = inputs['sources'][key]
        if (pin['url'], pin['fetch']) != (up_pin['url'], up_pin['fetch']) or pin['commit'] == up_pin['commit']:
            fail(f'{label}: {key} is not another commit of the pinned linux-firmware repository')
        hist = repos[key]
        info = deb['files'].get(cfg['prefix'] + path)
        if info is None:
            fail(f'{label}: the package has no firmware file {path}')
        if (info['sha256'], info['size'], info['git_blob']) != (e['sha256'], e['bytes'], e['git_blob']):
            fail(f'{label}: the package bytes differ from the reviewed sha256, size or git blob')
        blob = info['git_blob']
        if overlay.tree.get(path) != blob:
            fail(f'{label}: armbian/firmware {overlay.commit} does not have these bytes at this path')
        if path not in upstream.tree or upstream.tree[path] == blob:
            fail(f'{label}: not armbian-changed; linux-firmware {upstream.commit} has no other bytes at this path')
        if hist.tree.get(path) != blob:
            fail(f'{label}: linux-firmware {hist.commit} does not have these bytes at this path')
        subject = hist.git('log', '-1', '--format=%s', hist.commit).decode().strip()
        if subject != e['subject']:
            fail(f'{label}: commit {hist.commit} has the subject {subject!r}, reviewed {e["subject"]!r}')
        whence_path = cfg['whence']
        if hist.tree.get(whence_path) != e['whence_blob']:
            fail(f'{label}: {whence_path} at {hist.commit} is not the reviewed blob {e["whence_blob"]}')
        hist.prefetch([whence_path, *e['licence_files']])
        whence_data = hist.text(whence_path)
        groups = [g for g in whence_groups(whence_data) if path in g['files']]
        if len(groups) != 1:
            fail(f'{label}: {whence_path} at {hist.commit} lists this path in {len(groups)} groups, not one')
        group = groups[0]
        listed = re.findall(rf'(?m)^(?:Raw)?File:[ \t]*"?{re.escape(path)}"?[ \t]*$', whence_data.decode('utf-8'))
        if len(listed) != 1:
            fail(f'{label}: {whence_path} at {hist.commit} has {len(listed)} File lines for this path, not one')
        if group['driver'] != e['driver']:
            fail(f'{label}: the group is under Driver {group["driver"]!r}, reviewed {e["driver"]!r}')
        if group['licence'] != e['licence']:
            fail(f'{label}: the group\'s Licence field is {group["licence"]!r}, reviewed {e["licence"]!r}')
        files, unresolved = licence_field_files(group['licence'], hist.tree, cfg['licence_dirs'])
        if unresolved:
            fail(f'{label}: the Licence field names {", ".join(unresolved)}, which is not a file at {hist.commit}')
        named = {f: hist.tree[f] for f in files}
        if named != e['licence_files']:
            fail(f'{label}: the Licence field names {named} at {hist.commit}, reviewed {e["licence_files"]}')
        facts[path] = {'entry': e, 'repo': hist, 'blob': blob, 'upstream_blob': upstream.tree[path],
                       'whence': whence_data, 'group': group,
                       'texts': [(f, hist.text(f)) for f in sorted(named)]}
    return facts


def historical_cover(path, fact):
    names = ', '.join(f'{f} (git blob {b})' for f, b in sorted(fact['entry']['licence_files'].items()))
    return (f'linux-firmware has other bytes at this path (git blob {fact["upstream_blob"]}); its WHENCE entry '
            f'describes those, not these; linux-firmware commit {fact["repo"].commit} has these exact bytes at '
            f'this path, and its WHENCE group for this path names {names}; see "Historical linux-firmware origins"')


def derive_firmware(inputs, deb, repos):
    cfg = inputs['firmware']
    upstream, overlay = repos[cfg['upstream']], repos[cfg['overlay']]
    prefix = cfg['prefix']
    historical = derive_historical(inputs, deb, repos)
    whence_data = upstream.text(cfg['whence'])
    whence = parse_whence(whence_data.decode('utf-8'))
    by_blob = {}
    for path, oid in upstream.tree.items():
        by_blob.setdefault(oid, []).append(path)

    without_file = cfg.get('licence_names_without_file', {})
    used_without_file = set()

    def licence_files(path):
        """Resolved licence files the WHENCE entry for path names, over all its Licence fields."""
        found = set()
        for body in whence[path]['licence']:
            files, unresolved = licence_field_files(body, upstream.tree, cfg['licence_dirs'])
            for word in unresolved:
                if word not in without_file:
                    fail(f'WHENCE names {word}, which is not a file at {upstream.commit}')
                if not files:
                    fail(f'WHENCE names {word} with no licence file in the same field; '
                         'licence_names_without_file does not cover that')
                used_without_file.add(word)
            found |= files
        return found

    rows, texts, counts = [], set(), {}
    for rel in sorted(p for p in deb['files'] if p.startswith(prefix)):
        info = deb['files'][rel]
        path = rel[len(prefix):]
        blob = info['git_blob']
        if path in overlay.tree:
            if overlay.tree[path] != blob:
                fail(f'{path}: package bytes are not armbian/firmware {overlay.commit} at that path')
            origin = 'armbian-firmware'
        elif upstream.tree.get(path) == blob:
            origin = 'linux-firmware'
        else:
            fail(f'{path}: package bytes match neither pinned source at that path')
        entry, refs, upstream_blob = '-', set(), '-'
        if upstream.tree.get(path) == blob:
            cls = 'upstream'
            if path in whence:
                entry, refs = path, licence_files(path)
        elif path in upstream.tree:
            cls, upstream_blob = 'armbian-changed', upstream.tree[path]
            if path in whence:
                entry, refs = path, licence_files(path)
        elif blob in by_blob:
            cls = 'upstream-other-path'
            others = sorted(by_blob[blob])
            named = [p for p in others if p in whence]
            entry = named[0] if named else others[0]
            refs = licence_files(entry) if named else set()
            if not named:
                entry = others[0] + ' (no WHENCE entry)'
        else:
            cls = 'armbian-only'
        resolved = sorted(refs)
        texts |= set(resolved)
        files = f'licence files: {", ".join(resolved)}' if resolved else 'it names no licence file'
        if cls == 'upstream':
            cover = (f'WHENCE entry for this path; {files}' if entry != '-'
                     else 'no WHENCE entry for this path; no licence statement established')
        elif cls == 'upstream-other-path':
            other = entry.removesuffix(' (no WHENCE entry)')
            cover = (f'same bytes as linux-firmware {other}; WHENCE entry for that path; {files}'
                     if other in whence else
                     f'same bytes as linux-firmware {other}, which has no WHENCE entry; '
                     'no licence statement established')
        elif cls == 'armbian-changed' and path in historical:
            cover = historical_cover(path, historical[path])
        elif cls == 'armbian-changed':
            cover = (f'linux-firmware has other bytes at this path (git blob {upstream_blob})'
                     + ('; its WHENCE entry describes those, not these' if entry != '-' else ', with no WHENCE entry')
                     + '; no licence statement established for these bytes')
        else:
            cover = 'no licence statement established in either source'
        counts[cls] = counts.get(cls, 0) + 1
        rows.append((path, info['sha256'], cls, cover, blob, origin))
    if not rows:
        fail('the firmware package has no files under ' + prefix)
    unused = sorted(set(without_file) - used_without_file)
    if unused:
        fail(f'licence_names_without_file lists {", ".join(unused)}, which no Licence field of this '
             'package\'s files uses; review the list')
    notices = sorted(p[len(prefix):] for p in deb['files']
                     if p.startswith(prefix) and NOTICE_NAME.search(p.rsplit('/', 1)[-1]))
    return rows, sorted(texts), counts, whence_data, notices, historical


def firmware_payload(inputs, deb, repos, rows, texts, counts, whence_data, notices, historical):
    cfg = inputs['firmware']
    pin = inputs['packages'][cfg['package']]
    upstream, overlay = repos[cfg['upstream']], repos[cfg['overlay']]
    p = Payload(f'{cfg["package"]}.txt')
    p.line(f'{cfg["package"]} {pin["version"]}')
    p.line()
    para(p, 'This package ships without a copyright file. The image build added this one. '
            'It reproduces, verbatim, the origin and licence texts of the two sources the package '
            'is built from, and its last section lists every firmware file of the package, whether '
            'this image ships it, and which source entry, if any, describes those exact bytes.')
    para(p, 'This file records origins and notices. It does not grant any licence, it is not legal '
            'advice, and it does not establish that every file may be redistributed. Where no licence '
            'statement was found for a file, this file says so and reproduces none for it; the texts '
            'below do not cover that file.')
    p.line(f'Archive: {pin["url"]}')
    p.line(f'Archive sha256: {pin["sha256"]}')
    p.line(f'Package: {cfg["package"]} {pin["version"]} ({pin["architecture"]}), '
           f'Armbian-Original-Hash {pin["armbian_original_hash"]}')
    p.line()
    p.line('Sources, in installation order:')
    p.line(f'  linux-firmware    {upstream.url}')
    p.line(f'                    commit {upstream.commit}')
    p.line(f'  armbian/firmware  {overlay.url}')
    p.line(f'                    commit {overlay.commit}')
    p.line()
    para(p, cfg['recipe'])
    total = len(rows)
    p.line(f'Firmware files in the package: {total}, under /usr/lib/firmware')
    for cls in CLASS_TEXT:
        p.line(f'  {counts.get(cls, 0):5d}  {cls}')
    p.line()
    p.line('Classes used in the last section:')
    for cls, text in CLASS_TEXT.items():
        p.line(f'  {cls}')
        p.line(wrap(text, indent='      '))
    p.line()
    para(p, 'For armbian-changed and armbian-only files no licence statement for the shipped bytes '
            'was found in either source. A WHENCE entry for the same path that describes other bytes '
            'is not a statement about these bytes.')
    para(p, f'linux-firmware documents the origin and licence of its files in {cfg["whence"]}. That '
            f'file and every licence file it names for this package\'s files ({len(texts)} files) '
            'follow verbatim. armbian/firmware has no per-file licence record; its '
            f'{cfg["overlay_readme"]} follows verbatim, as published, and this file does not '
            'interpret it.')
    p.line(wrap('Notice and README files the package installs itself. Those this image ships stay at '
                'these paths under /usr/lib/firmware; the last section says which:'))
    for path in notices:
        p.line(f'  {path}')
    p.line()
    upstream.prefetch(texts)
    p.verbatim(upstream, cfg['whence'], whence_data)
    for path in texts:
        p.verbatim(upstream, path, upstream.text(path))
    p.verbatim(overlay, cfg['overlay_readme'], overlay.text(cfg['overlay_readme']),
               title='armbian/firmware README, reproduced as published')
    if historical:
        historical_section(p, cfg, upstream, overlay, historical)
    p.line(RULE)
    p.line('Firmware files of this package')
    p.line(RULE)
    para(p, 'Columns: shipped or removed (by the image build), class, path under /usr/lib/firmware, '
            'source entry and licence files. Added when the image was built, from the files present.')
    return p


def historical_section(p, cfg, upstream, overlay, historical):
    """Origins of armbian-changed files whose exact bytes an earlier linux-firmware commit has."""
    p.line(RULE)
    p.line('Historical linux-firmware origins')
    p.line(RULE)
    para(p, 'armbian/firmware replaced each file below with bytes that differ from linux-firmware at the '
            'pinned commit, so the WHENCE above does not describe them. An earlier commit of the same '
            'linux-firmware repository has these exact bytes at the same path, and its WHENCE lists that '
            'path. For each file, this section names that commit, reproduces verbatim the WHENCE section '
            'that lists the path, gives the byte range of the group within it that lists the path, and '
            'gives the licence file that group names.')
    para(p, 'armbian/firmware does not record where it took these bytes from, and this section does not '
            'establish that step. It records origins. It does not interpret the licence text, and it does '
            'not establish that the text\'s conditions are met.')
    reproduced = {t[4]: t for t in p.texts}
    for path, fact in sorted(historical.items()):
        e, hist, group = fact['entry'], fact['repo'], fact['group']
        (s0, s1), (g0, g1) = group['section'], group['span']
        p.line(path)
        p.line(f'  sha256 {e["sha256"]}, {e["bytes"]} bytes, git blob {fact["blob"]}')
        p.line(f'  armbian/firmware commit {overlay.commit}: these bytes at this path (the package\'s copy)')
        p.line(f'  linux-firmware commit {upstream.commit} (pinned): other bytes at this path '
               f'(git blob {fact["upstream_blob"]})')
        p.line(f'  linux-firmware commit {hist.commit}: these bytes at this path')
        p.line(f'    subject: {e["subject"]}')
        p.line()
        para(p, f'{cfg["whence"]} at that commit is git blob {e["whence_blob"]}. The section below, '
                f'bytes {s0} to {s1 - 1} of it, lists this path under "Driver: {e["driver"]}". The '
                f'Licence field "{e["licence"]}" closes the group that lists this path: bytes {g0} to '
                f'{g1 - 1} of that {cfg["whence"]}.'
                + (' The other Licence fields in this section close other groups and do not apply to '
                   'this path.' if len(re.findall(rb'(?m)^Licen[cs]e:', fact['whence'][s0:s1])) > 1
                   else ''), '  ')
        p.excerpt(hist, cfg['whence'], fact['whence'], [((s0, s1), 'section'), ((g0, g1), f'group for {path}')],
                  title=f'linux-firmware WHENCE section for {path}, at the commit above')
        for name, data in fact['texts']:
            same = reproduced.get(git_blob_id(data))
            if same:
                para(p, f'Licence file named by that group: {name} at commit {hist.commit}, git blob '
                        f'{git_blob_id(data)}. These are the same bytes as {same[7]}, reproduced above from '
                        f'{same[5]} at {same[6]}.')
                p.texts.append((p.name, same[1], same[2], same[3], same[4], hist.key, hist.commit, name))
            else:
                p.verbatim(hist, name, data, title=f'Licence file named by the WHENCE group for {path}')
                reproduced[git_blob_id(data)] = p.texts[-1]


# --- U-Boot -------------------------------------------------------------------

def parse_rkns(data):
    if data[:4] != b'RKNS':
        fail('loader does not start with an RKNS header')
    size_and_n, boot_flag = struct.unpack_from('<II', data, 8)
    hash_type = boot_flag & 0xf
    images = []
    for i in range(size_and_n >> 16):
        o = 120 + i * 88
        so, = struct.unpack_from('<I', data, o)
        off, size = (so & 0xffff) * 512, (so >> 16) * 512
        hlen = 32 if hash_type == 1 else 64
        want = data[o + 24:o + 24 + hlen].hex()
        body = data[off:off + size]
        got = hashlib.sha256(body).hexdigest() if hash_type == 1 else hashlib.sha512(body).hexdigest()
        if got != want:
            fail(f'RKNS image {i}: header hash does not match its bytes')
        images.append((off, size))
    return images


def derive_uboot(inputs, deb, raw, repos):
    cfg = inputs['uboot']
    pin = inputs['packages'][cfg['package']]
    loader, spi = raw[cfg['loader']], raw[cfg['spi_loader']]
    images = parse_rkns(loader)
    off, size = images[cfg['tpl']['rkns_image']]
    tpl_cfg = cfg['tpl']
    tpl = loader[off:off + tpl_cfg['bytes']]
    if loader[off + tpl_cfg['bytes']:off + size] != bytes(size - tpl_cfg['bytes']):
        fail('TPL padding is not zero')
    rkbin, compare = repos[tpl_cfg['source']], repos[tpl_cfg['compare_source']]
    tpl_blob = git_blob_id(tpl)
    if rkbin.tree.get(tpl_cfg['path']) != tpl_blob:
        fail(f'TPL bytes are not {tpl_cfg["source"]} {tpl_cfg["path"]}')
    compare_blob = compare.tree.get(tpl_cfg['compare_path'])
    if not compare_blob or compare_blob == tpl_blob:
        fail('the comparison DDR blob is missing or now identical; review the TPL statement')
    spi_offset = spi.find(tpl)
    if spi_offset < 0:
        fail('the SPI loader does not contain the same TPL bytes')
    for blob, label in ((loader, 'loader'), (spi, 'SPI loader')):
        for needle in (cfg['bl31']['version_string'], cfg['u_boot_banner']):
            if needle.encode() not in blob:
                fail(f'{label} lacks {needle!r}')
    uboot = repos['u-boot']
    if f'UBOOT_GIT_REVISION="{uboot.commit}"'.encode() not in raw[cfg['metadata']]:
        fail('U-Boot metadata does not record the pinned revision')
    summary = raw[cfg['licence_summary']]
    readme = cfg['u_boot_licence_dir'] + 'README'
    if git_blob_id(summary) != uboot.tree.get(readme):
        fail(f'{cfg["licence_summary"]} is not U-Boot {readme}')
    patches = re.search(r'patches hash "([0-9a-f]+)"', deb['fields'].get('Description', ''))
    if not patches:
        fail('package description has no patches hash')
    return {'tpl_offset': off, 'tpl_size': size, 'tpl_blob': tpl_blob, 'compare_blob': compare_blob,
            'spi_offset': spi_offset, 'loader_sha256': sha256(loader), 'spi_sha256': sha256(spi),
            'patches': patches.group(1), 'pin': pin}


def uboot_payload(inputs, facts, repos):
    cfg = inputs['uboot']
    pin, tpl_cfg = facts['pin'], cfg['tpl']
    uboot, tfa = repos['u-boot'], repos[cfg['bl31']['source']]
    rkbin, compare = repos[tpl_cfg['source']], repos[tpl_cfg['compare_source']]
    p = Payload(f'{cfg["package"]}.txt')
    p.line(f'{cfg["package"]} {pin["version"]}')
    p.line()
    para(p, 'This package ships without a copyright file. The image build added this one. It names '
            'the sources of the boot loader this package installs and reproduces their licence texts '
            'verbatim. Where no licence text could be established for a part, it says so and '
            'reproduces none for that part.')
    para(p, 'This file records origins and notices. It does not grant any licence and it is not '
            'legal advice. The source of each part below was identified from the loader\'s structure, '
            'hashes and version strings; this file does not rely on a rebuild. The DDR initialisation '
            'part is a binary, identical to a file of the repository named below; its build origin '
            'is not established.')
    p.line(f'Archive: {pin["url"]}')
    p.line(f'Archive sha256: {pin["sha256"]}')
    p.line(f'Package: {cfg["package"]} {pin["version"]} ({pin["architecture"]}), '
           f'Armbian-Original-Hash {pin["armbian_original_hash"]}')
    p.line()
    p.line(f'Loader: /{cfg["loader"]}')
    p.line(f'  sha256 {facts["loader_sha256"]}')
    para(p, f'For {cfg["board"]}, the image build writes this file to the boot medium at 32 KiB. '
            'It holds:')
    end = facts['tpl_offset'] + tpl_cfg['bytes']
    p.line('1. DDR initialisation (TPL)')
    para(p, f'Bytes {facts["tpl_offset"]} to {end - 1} of the loader, the first {tpl_cfg["bytes"]} bytes '
            f'of RKNS image {tpl_cfg["rkns_image"]} (the remaining {facts["tpl_size"] - tpl_cfg["bytes"]} bytes '
            f'of that image are zero), are identical to {tpl_cfg["path"]} in {rkbin.at()} '
            f'(git blob {facts["tpl_blob"]}).', '   ')
    para(p, f'{compare.url} at {compare.commit} has {tpl_cfg["compare_path"]} with the same declared '
            f'version, but different bytes (git blob {facts["compare_blob"]}). Its terms are therefore '
            'not evidence for these bytes, and its licence file is not reproduced here.', '   ')
    para(p, 'No licence text that applies to these bytes has been established. The '
            f'{tpl_cfg["repository_notice"]} of {rkbin.url} is reproduced below only because it is the '
            'licence file of the repository these bytes were taken from. It does not name this file, '
            'and it is not established as the terms for it.', '   ')
    p.line('2. SPL, U-Boot proper and the device trees in the FIT image')
    para(p, f'Das U-Boot, {uboot.at()}, with Armbian\'s patches from https://github.com/armbian/build '
            f'({", ".join(cfg["armbian_patch_dirs"])}; patches hash {facts["patches"]} in the package '
            'description; the patches are not reproduced here). The package installs U-Boot\'s licence '
            f'summary as /{cfg["licence_summary"]}, identical to {cfg["u_boot_licence_dir"]}README at '
            f'that commit. Every file of {cfg["u_boot_licence_dir"]} at that commit is reproduced below.',
         '   ')
    p.line('3. BL31 (Trusted Firmware-A)')
    para(p, f'Trusted Firmware-A, {tfa.at()}, built by Armbian; the loader carries the version string '
            f'"{cfg["bl31"]["version_string"]}". Its licence files at that commit are reproduced below. '
            'docs/license.rst says that code taken from other projects keeps its original licence text '
            'in its source files. Which of those parts this build contains has not been established, and '
            'those in-file notices are not reproduced here.', '   ')
    p.line(f'Second loader: /{cfg["spi_loader"]}')
    p.line(f'  sha256 {facts["spi_sha256"]}')
    para(p, f'It contains the same TPL bytes (at offset {facts["spi_offset"]}) and the same version strings. '
            'The image build does not write it to a boot medium.')
    uboot_texts = sorted(x for x in uboot.tree if x.startswith(cfg['u_boot_licence_dir']))
    uboot.prefetch(uboot_texts)
    tfa.prefetch(cfg['bl31']['texts'])
    for path in uboot_texts:
        p.verbatim(uboot, path, uboot.text(path), title='Das U-Boot')
    for path in cfg['bl31']['texts']:
        p.verbatim(tfa, path, tfa.text(path), title='Trusted Firmware-A')
    p.verbatim(rkbin, tpl_cfg['repository_notice'], rkbin.text(tpl_cfg['repository_notice']),
               title='Repository licence file only; not established as the terms for the DDR blob above')
    return p


# --- driver -------------------------------------------------------------------

def generate(base, sources, debs):
    inputs_raw = (base / 'inputs.json').read_bytes()
    inputs = json.loads(inputs_raw)
    if inputs.get('schema') != 1:
        fail('inputs.json schema must be 1')
    repos = {key: Repo(key, pin, sources) for key, pin in sorted(inputs['sources'].items())}
    archives = {}
    for name, pin in inputs['packages'].items():
        path = debs / pin['url'].rsplit('/', 1)[-1]
        if not path.is_file():
            fail(f'archive {path} is missing; run tools/fetch-boot-firmware-notice-sources.sh')
        keep = ()
        if name == inputs['uboot']['package']:
            u = inputs['uboot']
            keep = (u['loader'], u['spi_loader'], u['metadata'], u['licence_summary'])
        archives[name] = (path, read_deb(path, pin, name, keep))

    fw_name = inputs['firmware']['package']
    fw_deb = archives[fw_name][1]
    rows, texts, counts, whence_data, notices, historical = derive_firmware(inputs, fw_deb, repos)
    fw = firmware_payload(inputs, fw_deb, repos, rows, texts, counts, whence_data, notices, historical)

    ub_name = inputs['uboot']['package']
    ub_deb = archives[ub_name][1]
    facts = derive_uboot(inputs, ub_deb, ub_deb['kept'], repos)
    ub = uboot_payload(inputs, facts, repos)

    out = {fw.name: bytes(fw.buf), ub.name: bytes(ub.buf)}
    lines = ['# Generated by tools/generate-boot-firmware-notices.py from inputs.json. Do not edit.',
             '# path\tsha256\tclass\tsource entry and licence files\tgit blob\torigin']
    lines += ['\t'.join(r) for r in rows]
    out['firmware-files.tsv'] = ('\n'.join(lines) + '\n').encode()

    ident = ['# Generated by tools/generate-boot-firmware-notices.py from inputs.json. Do not edit.',
             '# package\tname\tversion\tarchitecture\tmd5sums sha256\tpayload',
             '# file\tname\tpath\tsha256\trequired|optional (optional: may be pruned, checked when present)',
             '# firmware\tname\tpackage path prefix\tfile table',
             '# loader\tname\tpath\tsha256 (cross-checked against manifests/bootloader-blobs.tsv)']
    for name in sorted(archives):
        pin, deb = inputs['packages'][name], archives[name][1]
        ident.append('\t'.join(('package', name, pin['version'], pin['architecture'],
                                deb['md5sums_sha256'], f'{name}.txt')))
        for rel in sorted(deb['files']):
            if name == fw_name and rel.startswith(inputs['firmware']['prefix']):
                continue
            kind = 'optional' if rel.startswith('usr/share/doc/') else 'required'
            ident.append('\t'.join(('file', name, '/' + rel, deb['files'][rel]['sha256'], kind)))
    ident.append('\t'.join(('firmware', fw_name, inputs['firmware']['prefix'], 'firmware-files.tsv')))
    ident.append('\t'.join(('loader', ub_name, '/' + inputs['uboot']['loader'], facts['loader_sha256'])))
    out['identity.tsv'] = ('\n'.join(ident) + '\n').encode()

    tl = ['# Generated by tools/generate-boot-firmware-notices.py. Verbatim texts inside the payloads.',
          '# payload\tbyte offset\tbytes\tsha256\tgit blob\tsource\tcommit\tpath']
    tl += ['\t'.join(map(str, t)) for t in fw.texts + ub.texts]
    out['texts.tsv'] = ('\n'.join(tl) + '\n').encode()

    el = ['# Generated by tools/generate-boot-firmware-notices.py. Verbatim excerpts inside the payloads.',
          '# payload\tbyte offset\tbytes\tsha256\tsource\tcommit\tpath\tgit blob of the whole file'
          '\tbyte offset in that file\tpart']
    el += ['\t'.join(map(str, t)) for t in fw.excerpts + ub.excerpts]
    out['excerpts.tsv'] = ('\n'.join(el) + '\n').encode()

    sums = {name: sha256(data) for name, data in out.items()}
    sums['inputs.json'] = sha256(inputs_raw)
    out['SHA256SUMS'] = ''.join(f'{sums[n]}  {n}\n' for n in sorted(sums)).encode()
    return out, counts


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--sources', type=Path, required=True, help='directory holding <key>.git repositories')
    ap.add_argument('--debs', type=Path, required=True, help='directory holding the pinned archives')
    ap.add_argument('--out', type=Path, default=DEFAULT_DIR, help='payload directory (reads inputs.json there)')
    ap.add_argument('--check', action='store_true', help='compare with the committed files; write nothing')
    args = ap.parse_args(argv)
    try:
        out, counts = generate(args.out, args.sources, args.debs)
    except DeriveError as e:
        print(f'generate-boot-firmware-notices: {e}', file=sys.stderr)
        return 1
    if args.check:
        bad = [n for n, data in sorted(out.items())
               if not (args.out / n).is_file() or (args.out / n).read_bytes() != data]
        if bad:
            print('generate-boot-firmware-notices: differs from the committed files: ' + ', '.join(bad),
                  file=sys.stderr)
            return 1
        print('generate-boot-firmware-notices: committed files reproduce exactly')
        return 0
    for name, data in out.items():
        with tempfile.NamedTemporaryFile(dir=args.out, delete=False) as tmp:
            tmp.write(data)
        Path(tmp.name).chmod(0o644)
        Path(tmp.name).replace(args.out / name)
    print('generate-boot-firmware-notices: wrote ' + ', '.join(sorted(out)) + '; classes: ' +
          ', '.join(f'{k} {v}' for k, v in sorted(counts.items())))
    return 0


if __name__ == '__main__':
    sys.exit(main())

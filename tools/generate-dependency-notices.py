#!/usr/bin/env python3
"""Derive and regenerate the srtla and MediaMTX source dependency notices (stdlib).

sources.json is the reviewed input: pinned root source archives, the official
MediaMTX release archives, supplemental exact-commit archives and the named,
version-pinned licence-text gaps. Everything else is derived from those pins:
the Cargo.lock and go.sum closures, every crate and Go module archive (checked
against the lock checksums), the measured Go module set (read from the release
binary's embedded build information, never executed) and the notice selection.

The derived inventory must equal the committed plan.json byte for byte, so an
omitted, truncated, unlisted or misrouted text fails before any output exists.
Cache files are named SHA256(URL). Offline is the default; --fetch downloads a
missing archive from its official origin and verifies it before caching it.
Nothing is extracted to disk or executed.
"""
import argparse
import base64
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import tarfile
import tomllib
import urllib.request
import zipfile

HERE = Path(__file__).resolve().parents[1] / 'mkosi/runtime/licence-notices/dependencies'
PAYLOADS = ('srtla', 'mediamtx')
OFFICIAL = ('https://codeload.github.com/', 'https://static.crates.io/crates/',
            'https://proxy.golang.org/', 'https://github.com/bluenviron/mediamtx/releases/download/',
            'https://go.dev/', 'https://static.rust-lang.org/',
            'https://api.github.com/repos/golang/go/', 'https://api.github.com/repos/rust-lang/rust/',
            'https://raw.githubusercontent.com/rust-lang/rust/',
            'https://raw.githubusercontent.com/llvm/llvm-project/')

# Discovery. A file whose name contains any of these words anywhere (any case,
# any extension or none), or that sits below a licences or REUSE metadata
# directory, is a notice file and is retained whole.
NOTICE_NAME = re.compile(r'(?i)(licen[cs]|copying|copyright|notice|authors|contributors|patent'
                         r'|attribution|credits|unlicense|third[-_. ]?party|legal|dep5)')
NOTICE_DIR = re.compile(r'(?i)licen[cs]es?|\.reuse')
# A retained file counts as a licence grant for the gap check only when its name
# says so and it is not program or configuration source. This can only add gaps.
GRANT_NAME = re.compile(r'(?i)(?:^|[^a-z])(?:licen[cs]e[sd]?|copying|unlicense)(?:[^a-z]|$)')
NOT_GRANT_SUFFIX = {'.sh', '.go', '.rs', '.py', '.pl', '.c', '.h', '.js', '.ts', '.json',
                    '.toml', '.yaml', '.yml', '.mod', '.sum', '.bat', '.ansi'}
# Any mention of the word or sign. Comment blocks containing one are retained.
MENTION = re.compile(rb'(?i)copyright|\xc2\xa9')
# Licence grant or condition wording. Outside comments it means an embedded
# licence text, so the whole file is retained.
GRANT = re.compile(rb'(?i)permission is hereby granted|redistribution and use in source|the above copyright notice'
                   rb'|provided ["\']?as is|without warrant')
# Comment blocks holding a mention, grant wording or a licence pointer are retained.
LICENCE_POINTER = re.compile(rb'(?i)licensed under|governed by an? [-\w]+ licen[cs]e')
# Copyright statement forms. Outside a retained comment block, the paragraph holding one is retained.
STATEMENT = re.compile(rb'(?i)copyright\s*:?\s*(?:\(c\)|\xc2\xa9|&copy;|[0-9]{4})|\xc2\xa9\s*[0-9]{4}'
                       rb'|\(c\)\s*[0-9]{4}|spdx-filecopyrighttext')
COMMENT = re.compile(rb'^[ \t]*/\*.*?\*/|^[ \t]*<!--.*?-->'
                     rb'|(?:^[ \t]*(?://|#(?![!\[a-zA-Z])|;)[^\n]*(?:\n|$))+', re.S | re.M)
PARAGRAPH = re.compile(rb'(?:^[ \t]*\S[^\n]*(?:\n|$))+', re.M)
MAX_PARAGRAPH = 65536
EXCLUSION_RULES = {
    'unassigned-reference-context': 'Repository-wide reference text; no runtime applicability established in this selection.',
    'build-context-only': 'Compiler/tool source context, not assigned to the installed runtime payload.',
    'test-context-only': 'Test or example source context; no installed membership evidence.',
    'binary': 'Content is not UTF-8 text (or contains NUL), so it cannot be reproduced in a text notice.',
    'mention-outside-comments': 'The word or sign also occurs outside comment blocks, but not in a copyright '
                                'statement form (identifiers, tables, strings); those occurrences are not retained.',
    'non-regular-member': 'Archive member is a link or special file, not file content.',
    'empty': 'Notice-named file is empty.',
}
TEXT_RULES = {
    'named': 'Whole file: notice, licence or authorship file name, or below a licences or REUSE metadata directory.',
    'comment': 'Comment block mentioning copyright, or holding licence grant, condition or pointer wording.',
    'statement-paragraph': 'Paragraph holding a copyright statement outside comment blocks.',
    'embedded-licence': 'Whole file: licence grant or condition wording outside comment blocks.',
}
SCOPES = {
    'root': 'root source at {commit}',
    'crate': 'Cargo.lock source closure; binary membership unproven',
    'workspace': 'workspace path package covered by root archive',
    'measured': 'measured Go buildinfo module',
    'source-only': 'go.sum source-only entry; binary membership unproven',
    'supplement': 'supplemental public repository at {commit}; recorded VCS commit of {for}',
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def check(ok, message):
    if not ok:
        raise ValueError(message)


def dump(obj):
    return (json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False) + '\n').encode()


def go_h1(files):
    # golang.org/x/mod/sumdb/dirhash.Hash1 over the module zip contents.
    lines = ''.join(f'{sha(files[n])}  {n}\n' for n in sorted(files)).encode()
    return 'h1:' + base64.b64encode(hashlib.sha256(lines).digest()).decode()


def unpack(data, is_zip):
    files, other = {}, []
    if is_zip:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            entries = [(i.filename, archive.read(i)) for i in archive.infolist() if not i.is_dir()]
    else:
        entries = []
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:*') as archive:
            for i in archive:
                if i.isfile():
                    entries.append((i.name, archive.extractfile(i).read()))
                elif not i.isdir() and i.type not in (tarfile.XGLTYPE, tarfile.XHDTYPE):
                    other.append(i.name)
    for name, content in entries:
        check(not name.startswith('/') and '..' not in PurePosixPath(name).parts
              and '\n' not in name and name not in files, 'unsafe or duplicate archive path: ' + name)
        files[name] = content
    return files, sorted(other)


class Cache:
    def __init__(self, root, fetch=False):
        self.root, self.fetch = Path(root), fetch

    def get(self, url, verify):
        path = self.root / sha(url.encode())
        if path.exists():
            data = path.read_bytes()
        else:
            check(self.fetch, 'archive missing from cache (use --fetch): ' + url)
            check(url.startswith(OFFICIAL), 'not an official origin: ' + url)
            with urllib.request.urlopen(url, timeout=120) as response:
                data = response.read()
        result = verify(data)
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        return data, result


def pinned(expected, url):
    def verify(data):
        check(sha(data) == expected, 'archive SHA256 drift: ' + url)
    return verify


def source_pin(entry):
    name, commit = entry['name'], entry['commit']
    check(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', name)
          and re.fullmatch('[0-9a-f]{40}', commit), 'invalid source repository or commit')
    url = f'https://codeload.github.com/{name}/tar.gz/{commit}'
    check(entry['url'] == url, 'source URL differs from repository and commit: ' + name)

    def verify(data):
        pinned(entry['sha256'], url)(data)
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:*') as archive:
            check(archive.pax_headers.get('comment') == commit,
                  'source archive commit differs from pin: ' + name)
            top = name.split('/')[1] + '-' + commit
            check(all(i.name == top or i.name.startswith(top + '/') for i in archive),
                  'source archive member outside pinned root: ' + name)
    return verify


def workspace_manifests(files):
    root = tomllib.loads(root_file(files, 'Cargo.toml').decode())
    inherited = root.get('workspace', {}).get('package', {})
    result = {}
    for path, data in files.items():
        if not path.endswith('/Cargo.toml'):
            continue
        package = tomllib.loads(data.decode()).get('package')
        if not package:
            continue
        version = package.get('version')
        if version == {'workspace': True}:
            version = inherited.get('version')
        check(isinstance(version, str), 'unsupported workspace package version: ' + path)
        key = (package['name'], version)
        check(key not in result, 'duplicate workspace package manifest: ' + repr(key))
        result[key] = {'source_path': path, 'source_sha256': sha(data)}
    return result


def inner(path, is_zip):
    # Path below the archive's top directory (a Go module zip's is "<module>@<version>/").
    parts = PurePosixPath(path).parts
    if is_zip:
        top = next((i for i, x in enumerate(parts) if '@' in x), None)
        check(top is not None, 'module zip member outside <module>@<version>/: ' + path)
        return PurePosixPath(*parts[top + 1:])
    return PurePosixPath(*parts[1:])


def is_named(path, is_zip):
    p = inner(path, is_zip)
    return bool(NOTICE_NAME.search(p.name)) or any(NOTICE_DIR.fullmatch(x) for x in p.parts[:-1])


def is_grant(path, is_zip):
    p = inner(path, is_zip)
    return (bool(GRANT_NAME.search(p.name)) or any(NOTICE_DIR.fullmatch(x) for x in p.parts[:-1])) \
        and p.suffix.lower() not in NOT_GRANT_SUFFIX


def is_text(data):
    if b'\0' in data:
        return False
    try:
        data.decode('utf-8')
    except UnicodeDecodeError:
        return False
    return True


def merge(spans):
    out = []
    for start, end in sorted(spans):
        if out and start <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], end))
        else:
            out.append((start, end))
    return out


def classify(files, other, is_zip):
    """Return (texts, excluded) for one archive: every candidate is one or the other."""
    texts, excluded = [], []
    for name in other:
        if is_named(name, is_zip):
            excluded.append((name, 'non-regular-member'))
    for name in sorted(files):
        data = files[name]
        named = is_named(name, is_zip)
        mentions = [m.start() for m in MENTION.finditer(data)]
        statements = [m.start() for m in STATEMENT.finditer(data)]
        grants = [m.start() for m in GRANT.finditer(data)]
        if not (named or mentions or statements or grants or LICENCE_POINTER.search(data)):
            continue
        if data and not is_text(data):
            excluded.append((name, 'binary'))
            continue
        if named:
            if data:
                texts.append((name, 0, len(data), 'named'))
            else:
                excluded.append((name, 'empty'))
            continue
        spans = [(m.start(), m.end()) for m in COMMENT.finditer(data)
                 if MENTION.search(m.group()) or GRANT.search(m.group()) or LICENCE_POINTER.search(m.group())]
        covered = lambda pos, spans=spans: any(a <= pos < e for a, e in spans)
        if any(not covered(p) for p in grants):
            texts.append((name, 0, len(data), 'embedded-licence'))
            continue
        loose = [p for p in statements if not covered(p)]
        paragraphs = [(m.start(), m.end()) for m in PARAGRAPH.finditer(data)
                      if any(m.start() <= p < m.end() for p in loose)]
        for a, e in paragraphs:
            check(e - a <= MAX_PARAGRAPH, f'statement paragraph over {MAX_PARAGRAPH} bytes needs review: {name}')
        check(all(any(a <= p < e for a, e in paragraphs) for p in loose), 'uncovered statement: ' + name)
        rule = {**{s: 'comment' for s in spans}, **{s: 'statement-paragraph' for s in paragraphs}}
        for start, end in merge(spans + paragraphs):
            kinds = {rule[s] for s in rule if start <= s[0] and s[1] <= end}
            texts.append((name, start, end, 'statement-paragraph' if 'statement-paragraph' in kinds else 'comment'))
        everything = merge(spans + paragraphs)
        if any(not any(a <= p < e for a, e in everything) for p in mentions):
            excluded.append((name, 'mention-outside-comments'))
    return texts, excluded


def parse_buildinfo(binary):
    """Read the module list embedded by the Go linker (debug/buildinfo format, Go >= 1.18)."""
    magic = b'\xff Go buildinf:'
    pos = binary.find(magic)
    while pos >= 0:
        if binary[pos + 15] & 2:
            break
        pos = binary.find(magic, pos + 1)
    check(pos >= 0, 'no inline Go build information in binary')

    def string(offset):
        length, shift = 0, 0
        while True:
            byte = binary[offset]
            offset += 1
            length |= (byte & 0x7f) << shift
            shift += 7
            if byte < 0x80:
                break
        return binary[offset:offset + length], offset + length
    version, offset = string(pos + 32)
    mod, _ = string(offset)
    if len(mod) >= 33 and mod[-17:-16] == b'\n':
        mod = mod[16:-16]
    info = {'go': version.decode(), 'deps': {}, 'settings': {}}
    for line in mod.decode().splitlines():
        fields = line.split('\t')
        check(fields[0] != '=>', 'module replacement in build information needs explicit handling')
        if fields[0] == 'path':
            info['path'] = fields[1]
        elif fields[0] == 'mod':
            info['main'] = fields[1:3]
        elif fields[0] == 'dep':
            check(len(fields) == 4 and fields[3].startswith('h1:'), 'dependency without checksum: ' + line)
            info['deps'][(fields[1], fields[2])] = fields[3]
        elif fields[0] == 'build':
            key, _, value = fields[1].partition('=')
            info['settings'][key] = value
    return info


def root_file(files, name):
    found = [b for n, b in files.items() if n.count('/') == 1 and n.endswith('/' + name)]
    check(len(found) == 1, 'missing root file ' + name)
    return found[0]


def go_escape(text):
    return ''.join('!' + c.lower() if c.isupper() else c for c in text)


def package(name, version, kind, payload, origin, files, other, scope, excerpts, metadata=None):
    texts, excluded = classify(files, other, kind == 'go-module')
    record = {'name': name, 'version': version, 'kind': kind, 'payload': payload, 'scope': scope,
              'origin': origin, 'metadata': metadata, 'texts': [], 'excluded': []}
    for path, start, end, rule in texts:
        data = files[path]
        excerpt = data[start:end]
        excerpts[(origin, path, start, end)] = excerpt
        record['texts'].append({'source_path': path, 'source_sha256': sha(data), 'start': start, 'end': end,
                                'sha256': sha(excerpt), 'rule': rule})
    for path, rule in excluded:
        record['excluded'].append({'source_path': path, 'rule': rule,
                                   'source_sha256': sha(files[path]) if path in files else None})
    return record


def runtime_scope(name, path):
    """Conservative source scopes, never an object membership assertion."""
    if name in ('llvm-LICENSE.TXT', 'rust-license-metadata.json', 'rust-REUSE.toml',
                 'rust-.gitmodules', 'rust-compiler_rustc_target_src_spec_targets_aarch64_unknown_linux_gnu.rs') or '/vendor/cc-' in path or '/library/proc_macro/' in path or path.endswith('/build.rs'):
        return 'build-context-only'
    if name == 'go-source.tar.gz' and (
            (not path.startswith('go/src/') and path not in ('go/LICENSE', 'go/PATENTS'))
            or Path(path).name.startswith(('make.', 'all.', 'run.', 'clean.', 'bootstrap.', 'buildall.'))):
        return 'build-context-only'
    if name == 'go-source.tar.gz' and path.startswith(('go/src/cmd/', 'go/pkg/tool/', 'go/misc/', 'go/test/')):
        return 'build-context-only'
    if '/testdata/' in path or '/tests/' in path or '/examples/' in path or path.endswith('_test.go'):
        return 'test-context-only'
    if name.startswith(('rust-LICENSES_GPL-', 'rust-LICENSES_GCC-', 'rust-LICENSES_CC-', 'rust-LICENSES_OFL-')):
        return 'unassigned-reference-context'
    if name == 'go-source.tar.gz':
        return 'Go shared/runtime source candidate; package/function membership unmeasured'
    if name.startswith('llvm-') or '/compiler-builtins/' in path or '/unwind/' in path:
        return 'conditional runtime source candidate; static inclusion unverified'
    if name == 'rust-src.tar.xz' and any('/library/' + x + '/' in path for x in ('alloc', 'core', 'std')):
        return 'standard-library source candidate; alloc/core/std paths measured, whole-file membership unverified'
    return 'Rust shared/runtime source candidate; optional and other-target material included, membership unverified'


def runtime_packages(config, cache, measurement, inputs, excerpts):
    """Consume only pinned official public sources; retain exclusions separately."""
    check(config['go_version'] == measurement['go'] == 'go1.26.4'
          and config['measured_mediamtx_sha256'] == measurement['binary_sha256'], 'runtime Go identity mismatch')
    check(config['measured_sender_arm64_sha256'] ==
          'c1c91ed3bb25c917c783193768a82e2ec5fd3b9f1d40dd26cc29ed9b461b2ba2',
          'runtime sender identity mismatch')
    rust = 'b30f3df3ba3c4c9de2f58f1a75dd9500b79b3f8d'
    check(config['rust_commit'] == rust and config['rust_distribution'] == 'nightly-2026-06-12',
          'runtime Rust identity mismatch')
    check(len(config['inputs']) == 37, 'runtime input set incomplete')
    data = {}
    for entry in config['inputs']:
        name, url = entry['file'], entry['url']
        check(name not in data and name == Path(name).name, 'duplicate/unsafe runtime input')
        raw, _ = cache.get(url, pinned(entry['sha256'], url))
        check(len(raw) == entry['size'], 'runtime input size mismatch')
        data[name] = raw
        inputs[url] = {'sha256': sha(raw), 'bytes': len(raw), 'scope': entry['scope']}
    manifest = tomllib.loads(data['2026-06-12.toml'].decode())
    check(manifest['pkg']['rustc']['git_commit_hash'] == rust, 'runtime distribution commit mismatch')
    check(sha(data['2026-06-12.toml']) == data['2026-06-12.toml.sha256'].decode().split()[0],
          'runtime manifest checksum mismatch')
    check(sha(data['rust-src.tar.xz']) == manifest['pkg']['rust-src']['target']['*']['xz_hash'],
          'runtime source distribution mismatch')
    check(json.loads(data['go-tag.json'])['object']['sha'] == config['go_commit'] == 'a9ce111d580581fb925ae88f125c69b7d93504ea', 'runtime Go tag mismatch')
    release = next(x for x in json.loads(data['go-releases.json']) if x['version'] == config['go_version'])
    check(any(x['kind'] == 'source' and x['sha256'] == sha(data['go-source.tar.gz']) for x in release['files']),
          'runtime Go release checksum mismatch')
    tree = json.loads(data['rust-tree.json'])
    check(tree['sha'] == rust and not tree['truncated'], 'runtime Rust tree mismatch')
    blobs = {x['path']: x['sha'] for x in tree['tree'] if x['type'] == 'blob'}
    for entry in config['inputs']:
        prefix = 'https://raw.githubusercontent.com/rust-lang/rust/' + rust + '/'
        if entry['url'].startswith(prefix):
            raw = data[entry['file']]
            check(hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest()
                  == blobs[entry['url'][len(prefix):]], 'runtime Rust blob mismatch')
    sender, _ = unpack(data['sender-source.tar.gz'], False)
    check(tomllib.loads(root_file(sender, 'rust-toolchain.toml').decode())['toolchain']['channel']
          == config['rust_distribution'], 'runtime sender toolchain pin mismatch')
    packages, context = [], []
    for entry in config['inputs']:
        name, url = entry['file'], entry['url']
        if entry['scope'] == 'identity':
            continue
        files, other = unpack(data[name], False) if name.endswith(('.tar.gz', '.tar.xz')) else ({'source/' + name: data[name]}, [])
        if name == 'go-source.tar.gz':
            check(files['go/VERSION'].splitlines()[0] == config['go_version'].encode(), 'runtime Go VERSION mismatch')
        grouped = {}
        for path, raw in files.items():
            scope = runtime_scope(name, path)
            if scope in ('build-context-only', 'test-context-only', 'unassigned-reference-context'):
                if is_named(path, False):
                    context.append({'input': url, 'source_path': path, 'source_sha256': sha(raw), 'reason': scope})
                continue
            grouped.setdefault(scope, {})[path] = raw
        for scope, selected in sorted(grouped.items()):
            version = config['go_version'] if name.startswith('go-') else rust
            if name.startswith('llvm-'):
                version = url.split('/llvm-project/', 1)[1].split('/', 1)[0]
            elif name == 'backtrace.tar.gz':
                version = url.rsplit('/', 1)[-1]
            p = package(name, version,
                        'runtime', 'mediamtx' if name.startswith('go-') else 'srtla', url,
                        selected, other, scope, excerpts)
            packages.append(p)
    return packages, {'source_identities': {k: config[k] for k in ('go_version', 'go_commit', 'rust_commit', 'rust_distribution')},
                      'sender_arm64_sha256': config['measured_sender_arm64_sha256'],
                      'excluded_named_context': context, 'gaps': config['gaps'], 'limits': config['limits']}


def derive(sources_raw, cache):
    """Rebuild the whole inventory from sources.json and pinned archives. Returns (plan, excerpts)."""
    sources = json.loads(sources_raw)
    check(sources.get('schema') == 2, 'unsupported sources schema')
    inputs, packages, excerpts = {}, [], {}

    def load(url, verify, upstream=None, is_zip=None):
        data, _ = cache.get(url, verify)
        files, other = unpack(data, url.endswith('.zip') if is_zip is None else is_zip)
        inputs[url] = {'sha256': sha(data), 'bytes': len(data), 'upstream_checksum': upstream, 'files': len(files)}
        return files, other

    roots = {}
    for root in sources['roots']:
        check(root['payload'] in PAYLOADS and re.fullmatch('[0-9a-f]{40}', root['commit']), 'bad root entry')
        files, other = load(root['url'], source_pin(root))
        roots[root['payload']] = (root, files)
        packages.append(package(root['name'], root['version'], 'root', root['payload'], root['url'], files, other,
                                SCOPES['root'].format(commit=root['commit']), excerpts))

    measured, measurement, identity = {}, None, []
    mtx = sources['installed']['mediamtx']
    for release in mtx['releases']:
        url = release['url']
        check(url.startswith(OFFICIAL[3]) and release['arch'] in ('amd64', 'arm64'), 'bad release entry')
        files, _ = load(url, pinned(release['sha256'], url), is_zip=False)
        check(set(files) >= {'mediamtx', 'LICENSE'}, 'release archive lacks mediamtx or LICENSE')
        identity.append({'arch': release['arch'], 'tarball_sha256': release['sha256'],
                         'binary_sha256': sha(files['mediamtx']), 'license_sha256': sha(files['LICENSE'])})
        if release.get('measure_go_modules'):
            check(measurement is None, 'only one measured architecture is supported')
            info = parse_buildinfo(files['mediamtx'])
            root = roots['mediamtx'][0]
            check(info.get('main', [None])[0] == info.get('path') and info['main'][1] == root['version']
                  and info['settings'].get('vcs.revision') == root['commit']
                  and info['settings'].get('GOARCH') == release['arch'], 'measured binary identity differs from root')
            measured = info['deps']
            measurement = {'arch': release['arch'], 'go': info['go'], 'binary_sha256': sha(files['mediamtx']),
                           'modules': len(measured), 'release_url': url}

    srtla_root = roots['srtla'][1]
    lock = tomllib.loads(root_file(srtla_root, 'Cargo.lock').decode())
    crates = {}
    workspace = workspace_manifests(srtla_root)
    for entry in lock['package']:
        name, version = entry['name'], entry['version']
        if 'source' not in entry:
            check((name, version) in workspace,
                  'Cargo workspace package missing from root archive: ' + name + ' ' + version)
            packages.append({'name': name, 'version': version, 'kind': 'workspace', 'payload': 'srtla',
                             'scope': SCOPES['workspace'], 'origin': None,
                             'metadata': workspace[(name, version)], 'texts': [],
                             'excluded': []})
            continue
        check(entry['source'] == 'registry+https://github.com/rust-lang/crates.io-index', 'unsupported Cargo source')
        url = f'https://static.crates.io/crates/{name}/{name}-{version}.crate'
        files, other = load(url, pinned(entry['checksum'], url), entry['checksum'])
        crates[(name, version)] = files
        manifest = tomllib.loads(root_file(files, 'Cargo.toml').decode())['package']
        meta = {k: manifest[k] for k in ('license', 'license-file', 'authors', 'repository') if k in manifest}
        packages.append(package(name, version, 'crate', 'srtla', url, files, other, SCOPES['crate'], excerpts, meta))

    sums, go_mod_only = {}, 0
    for line in root_file(roots['mediamtx'][1], 'go.sum').decode().splitlines():
        mod, version, digest = line.split()
        if version.endswith('/go.mod'):
            go_mod_only += 1
        else:
            sums[(mod, version)] = digest
    for key, digest in measured.items():
        check(sums.get(key) == digest, 'measured module differs from go.sum: ' + ' '.join(key))
    modules = {}
    for (mod, version), digest in sorted(sums.items()):
        url = f'https://proxy.golang.org/{go_escape(mod)}/@v/{go_escape(version)}.zip'

        def verify(data, digest=digest, url=url):
            check(go_h1(unpack(data, True)[0]) == digest, 'Go module checksum drift: ' + url)
        files, other = load(url, verify, digest)
        modules[(mod, version)] = files
        kind = 'measured' if (mod, version) in measured else 'source-only'
        packages.append(package(mod, version, 'go-module', 'mediamtx', url, files, other, SCOPES[kind], excerpts))

    for sup in sources['supplements']:
        target = tuple(sup['for'])
        if target in crates:
            vcs = json.loads(root_file(crates[target], '.cargo_vcs_info.json'))
            check(vcs['git']['sha1'] == sup['commit'], 'supplement commit is not the crate VCS commit')
            payload = 'srtla'
        else:
            check(target in modules and target[1].endswith('-' + sup['commit'][:12]),
                  'supplement commit is not the Go pseudo-version commit')
            payload = 'mediamtx'
        files, other = load(sup['url'], source_pin(sup))
        packages.append(package(sup['name'], target[1], 'supplement', payload, sup['url'], files, other,
                                SCOPES['supplement'].format(commit=sup['commit'], **{'for': '@'.join(target)}),
                                excerpts, {'for': list(target)}))

    runtime = None
    if 'runtime' in sources:
        added, runtime = runtime_packages(sources['runtime'], cache, measurement, inputs, excerpts)
        packages.extend(added)

    plan = {
        'schema': 2,
        'sources_sha256': sha(sources_raw),
        'note': 'Derived by tools/generate-dependency-notices.py from sources.json; do not edit by hand.',
        'text_rules': TEXT_RULES,
        'exclusion_rules': EXCLUSION_RULES,
        'gaps': sources['gaps'],
        'inputs': inputs,
        'packages': packages,
        'measurement': measurement,
        'mediamtx_identity': {'version': mtx['version'], 'binary_path': mtx['binary_path'], 'releases': identity},
        'srtla_identity': sources['installed']['srtla'],
        'counts': {
            'rust_registry_crates': sum(p['kind'] == 'crate' for p in packages),
            'rust_workspace_packages': sum(p['kind'] == 'workspace' for p in packages),
            'go_modules_measured': sum(p['scope'] == SCOPES['measured'] for p in packages),
            'go_modules_source_only': sum(p['scope'] == SCOPES['source-only'] for p in packages),
            'go_mod_only_entries': go_mod_only,
        },
        'limits': [
            'Cargo.lock includes optional, test and target-specific packages; no complete shipped Rust membership claim.',
            'Go buildinfo records module membership for one architecture, not individual files or functions.',
            'Runtime source supplements, when present, do not establish complete installed membership.',
            'Sources have not been rebuilt; no source-to-binary reproducibility claim.',
            'Mechanical notice discovery is not a legal or compliance clearance.',
        ],
        'packaging_ready': False,
    }
    if runtime is not None:
        plan['runtime'] = runtime
    check_plan(plan)
    plan['payload_sha256'] = {name: sha(data) for name, data in render(plan, excerpts).items()}
    return plan, excerpts


def check_plan(plan):
    """Invariants that hold for any correct plan, checkable without archives."""
    check(plan.get('schema') == 2, 'unsupported plan schema')
    by_key = {(p['name'], p['version']): p for p in plan['packages'] if p['kind'] in ('crate', 'go-module')}
    for p in plan['packages']:
        expected = {'crate': 'srtla', 'workspace': 'srtla', 'go-module': 'mediamtx'}.get(p['kind'])
        if p['kind'] == 'runtime':
            expected = 'mediamtx' if p['name'].startswith('go-') else 'srtla'
            check('runtime' in plan and 'candidate' in p['scope'], 'runtime scope/evidence missing')
        check(p['payload'] in PAYLOADS and (expected is None or p['payload'] == expected),
              f"package routed to the wrong payload: {p['name']} {p['version']}")
        check((p['origin'] is None) == (p['kind'] == 'workspace'), 'origin missing: ' + p['name'])
        check(p['origin'] is None or p['origin'] in plan['inputs'], 'origin not in inputs: ' + p['name'])
        previous = ('', 0)
        for t in p['texts']:
            check(t['rule'] in TEXT_RULES and 0 <= t['start'] < t['end'], 'invalid text record: ' + t['source_path'])
            check((t['source_path'], t['start']) >= previous, 'texts unordered or overlapping: ' + t['source_path'])
            previous = (t['source_path'], t['end'])
            if t['rule'] == 'named':
                check(t['start'] == 0 and t['sha256'] == t['source_sha256'],
                      'named notice file is not retained whole: ' + t['source_path'])
        for e in p['excluded']:
            check(e['rule'] in EXCLUSION_RULES, 'exclusion without a recorded rule: ' + e['source_path'])
        if p['kind'] == 'supplement':
            target = re.search(r'recorded VCS commit of (.+)$', p['scope']).group(1).rsplit('@', 1)
            check(tuple(target) in by_key and by_key[tuple(target)]['payload'] == p['payload'],
                  'supplement routed differently from its package: ' + p['name'])
    missing = {(p['name'], p['version']) for p in by_key.values()
               if not any(is_grant(t['source_path'], p['kind'] == 'go-module')
                          for t in p['texts'] if t['rule'] == 'named')}
    listed = {(g['name'], g['version']) for g in plan['gaps']}
    check(not missing - listed, 'unlisted missing licence text: ' + repr(sorted(missing - listed)))
    check(not listed - missing, 'listed gap no longer missing (review and remove): ' + repr(sorted(listed - missing)))
    for g in plan['gaps']:
        check(g['resolution'] and isinstance(g['unresolved'], bool), 'gap without a recorded resolution')
        evidence = g.get('evidence', [])
        check(g['unresolved'] or evidence, 'resolved gap lacks evidence: ' + g['name'])
        target = (g['name'], g['version'])
        for e in evidence:
            owners = [p for p in plan['packages'] if p['origin'] == e['origin']
                      and ((p['name'], p['version']) == target or
                           (p['kind'] == 'supplement' and p['metadata'].get('for') == list(target)))]
            check(len(owners) == 1 and any(
                t['source_path'] == e['source_path'] and t['sha256'] == e['sha256']
                and t['start'] == 0 and t['sha256'] == t['source_sha256']
                and t['rule'] in ('named', 'embedded-licence') for t in owners[0]['texts']),
                'gap evidence is not retained whole for its package: ' + g['name'])
    counts = plan['counts']
    check(counts['rust_registry_crates'] == sum(p['kind'] == 'crate' for p in plan['packages'])
          and counts['go_modules_measured'] == sum(p['scope'] == SCOPES['measured'] for p in plan['packages'])
          and counts['go_modules_source_only'] == sum(p['scope'] == SCOPES['source-only'] for p in plan['packages'])
          and counts['go_modules_measured'] == (plan['measurement'] or {}).get('modules', 0), 'count mismatch')


def render(plan, excerpts):
    c, m = plan['counts'], plan['measurement']
    common = (
        '\nSOURCE DEPENDENCY NOTICES (source coverage, not compliance clearance)\n'
        'Retained: whole notice, licence and authorship files; comment blocks that\n'
        'mention copyright; paragraphs with copyright statements outside comments.\n'
        'Each excluded file and its reason is listed in the source inventory.\n'
        'Runtime source supplements, when present, have separate candidate scopes.\n'
    )
    headers = {
        'srtla': common + (
            f"Rust: {c['rust_registry_crates']} registry crates and {c['rust_workspace_packages']} workspace packages,\n"
            'the complete Cargo.lock source set, NOT measured shipped membership.\n'),
        'mediamtx': common + (
            f"Go: {c['go_modules_measured']} modules measured in the {m['arch']} {m['go'].removeprefix('go')} release "
            f"build information;\n{c['go_modules_source_only']} additional fetched go.sum modules are source-only. "
            f"No membership\nmeasurement for other architectures. Module metadata does not identify\n"
            'included files or functions.\n'),
    }
    buffers = {k: bytearray(v.encode()) for k, v in headers.items()}
    if 'runtime' in plan:
        for out in buffers.values():
            out.extend(b'\nRUNTIME SOURCE NOTICE SUPPLEMENT (conservative source superset)\n')
            for line in plan['runtime']['limits'] + plan['runtime']['gaps']:
                out.extend((line + '\n').encode())
    payload_of = {(p['name'], p['version']): p['payload'] for p in plan['packages']}
    for g in plan['gaps']:
        if g['unresolved']:
            buffers[payload_of[(g['name'], g['version'])]].extend(
                f"UNRESOLVED: {g['name']} {g['version']}: {g['resolution']}\n".encode())
    for p in plan['packages']:
        out = buffers[p['payload']]
        out.extend(f"\n===== {p['name']} {p['version']} =====\nScope: {p['scope']}\n"
                   f"Origin: {p['origin'] or 'workspace root archive'}\n".encode())
        for t in p['texts']:
            excerpt = excerpts[(p['origin'], t['source_path'], t['start'], t['end'])]
            check(sha(excerpt) == t['sha256'], 'notice text drift')
            out.extend(f"File: {t['source_path']}\nSource SHA256: {t['source_sha256']}\n"
                       f"Bytes: [{t['start']},{t['end']}) SHA256: {t['sha256']}\n\n".encode())
            out.extend(excerpt + b'\n')
    result = {k + '.txt': bytes(v) for k, v in buffers.items()}
    ident = plan['mediamtx_identity']
    lines = [f"srtla\t{plan['srtla_identity']['package']}\t{plan['srtla_identity']['version']}\t{a}"
             for a in plan['srtla_identity']['architectures']]
    if 'runtime' in plan and 'sender_arm64_sha256' in plan['runtime']:
        lines.append('runtime-srtla\tarm64\t/usr/bin/srtla_send\t' + plan['runtime']['sender_arm64_sha256'])
    lines += [f"mediamtx\t{ident['binary_path']}\t{ident['version']}\t{r['arch']}\t{r['tarball_sha256']}"
              f"\t{r['binary_sha256']}" for r in ident['releases']]
    result['identity.tsv'] = ('# Installed identities covered by these notices (generated; tab separated).\n'
                              '# srtla <dpkg package> <version> <architecture>\n'
                              '# mediamtx <binary path> <version> <architecture> <release tarball sha256> <binary sha256>\n'
                              + '\n'.join(lines) + '\n').encode()
    return result


def sums(result):
    return ''.join(f'{sha(data)}  {name}\n' for name, data in sorted(result.items())).encode()


def check_payloads(plan, result):
    """Verify every planned text byte and all framing without an archive cache."""
    check_plan(plan)
    check(set(result) == {'srtla.txt', 'mediamtx.txt', 'identity.tsv'}, 'payload set differs from plan')
    offsets, excerpts = {k: 0 for k in PAYLOADS}, {}
    for p in plan['packages']:
        data = result[p['payload'] + '.txt']
        for t in p['texts']:
            marker = (f"File: {t['source_path']}\nSource SHA256: {t['source_sha256']}\n"
                      f"Bytes: [{t['start']},{t['end']}) SHA256: {t['sha256']}\n\n").encode()
            start = data.find(marker, offsets[p['payload']])
            check(start >= 0, 'planned notice missing from payload: ' + t['source_path'])
            start += len(marker)
            end = start + t['end'] - t['start']
            excerpt = data[start:end]
            check(sha(excerpt) == t['sha256'], 'payload notice bytes differ from plan: ' + t['source_path'])
            excerpts[(p['origin'], t['source_path'], t['start'], t['end'])] = excerpt
            offsets[p['payload']] = end + 1
    check(render(plan, excerpts) == result, 'payload framing or identity differs from plan')
    check(plan.get('payload_sha256') == {name: sha(data) for name, data in result.items()},
          'payload digests differ from plan')


def generate(base, cache):
    sources_raw = (base / 'sources.json').read_bytes()
    plan, excerpts = derive(sources_raw, cache)
    return plan, render(plan, excerpts)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--cache', type=Path, required=True, help='directory of archives named SHA256(URL)')
    parser.add_argument('--fetch', action='store_true', help='download missing archives from official origins')
    parser.add_argument('--base', type=Path, default=HERE, help=argparse.SUPPRESS)
    parser.add_argument('--output', type=Path, help='new directory for the regenerated payloads')
    parser.add_argument('--write-plan', type=Path, help='write the derived inventory here for review (new file)')
    parser.add_argument('--check', action='store_true', help='require committed plan and payloads to match')
    args = parser.parse_args()
    plan, result = generate(args.base, Cache(args.cache, args.fetch))
    plan_bytes = dump(plan)
    for path in (args.output, args.write_plan):
        check(path is None or not path.exists(), f'{path} must not exist')
    if args.write_plan:
        args.write_plan.write_bytes(plan_bytes)
    if args.check:
        check((args.base / 'plan.json').read_bytes() == plan_bytes, 'committed plan.json differs from derivation')
        check((args.base / 'plan.sha256').read_text().strip() == sha(plan_bytes), 'plan.sha256 differs')
        for name, data in result.items():
            check((args.base / name).read_bytes() == data, 'committed payload differs: ' + name)
        check((args.base / 'SHA256SUMS').read_bytes() == sums(result), 'committed SHA256SUMS differs')
        print('committed inventory and payloads match the derivation')
    if args.output:
        args.output.mkdir(parents=True)
        for name, data in result.items():
            (args.output / name).write_bytes(data)
        (args.output / 'plan.json').write_bytes(plan_bytes)
        (args.output / 'plan.sha256').write_text(sha(plan_bytes) + '\n')
        (args.output / 'SHA256SUMS').write_bytes(sums(result))


if __name__ == '__main__':
    main()

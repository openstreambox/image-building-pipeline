#!/usr/bin/env python3
"""Regenerate static notice payloads from pinned official source archives (stdlib).
Cache keys are SHA256(URL). Offline is the default; --fetch permits downloading
missing inputs only. Nothing is extracted to disk or executed.
"""
import argparse
import base64
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import tarfile
import urllib.request
import zipfile


def sha(data):
    return hashlib.sha256(data).hexdigest()


def check(ok, message):
    if not ok:
        raise ValueError(message)


def unpack(data, zip_archive=False):
    if zip_archive:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            entries = [(i.filename, archive.read(i)) for i in archive.infolist() if not i.is_dir()]
    else:
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
            entries = [(i.name, archive.extractfile(i).read()) for i in archive if i.isfile()]
    files = {}
    for name, content in entries:
        check(not name.startswith('/') and '..' not in PurePosixPath(name).parts
              and '\n' not in name and name not in files, 'unsafe or duplicate archive path')
        files[name] = content
    return files


def verify_archive(data, url, pin):
    check(sha(data) == pin['sha256'], 'archive SHA256 drift: ' + url)
    files = unpack(data, url.endswith('.zip'))
    upstream = pin['upstream_checksum']
    if upstream and upstream.startswith('h1:'):
        lines = ''.join(f'{sha(files[n])}  {n}\n' for n in sorted(files)).encode()
        actual = 'h1:' + base64.b64encode(hashlib.sha256(lines).digest()).decode()
        check(actual == upstream, 'Go module checksum drift')
    elif upstream:
        check(sha(data) == upstream, 'crate checksum drift')
    return files


GAPS = {('r-efi', '5.3.0'), ('r-efi', '6.0.0'), ('valuable', '0.1.1'),
        ('r-efi/r-efi', '5.3.0'), ('r-efi/r-efi', '6.0.0'),
        ('github.com/benburkert/openpgp', 'v0.0.0-20160410205803-c2471f86866c'),
        ('benburkert/openpgp', 'v0.0.0-20160410205803-c2471f86866c')}


def render(plan, cache, fetch=False):
    check({(g['name'], g['version']) for g in plan['gaps']} == GAPS, 'unreviewed missing text')
    # The reviewed inventory fixes versions, origins, ranges and metadata together.
    # Refresh it deliberately when changing any source pin; there is no enrol mode.
    buffers = {key: bytearray((
        '\nSOURCE DEPENDENCY NOTICES (source coverage, not compliance clearance)\n'
        'Rust: complete Cargo.lock source set, NOT measured shipped membership.\n'
        'Go: 85 matching modules measured in the arm64 Go 1.26.4 release buildinfo;\n'
        '46 additional fetched modules are source-only. No amd64 membership measurement.\n'
        'Module metadata does not identify included files or functions.\n'
        'Compiler/runtime notices require separate exact-source verification.\n'
        'UNRESOLVED: benburkert/openpgp v0.0.0-20160410205803-c2471f86866c\n'
        'headers refer to absent BSD LICENSE in module zip and exact commit\n'
        'c2471f86866ca6ab0679b9d216cb6a84cfe90db1. No grant substituted.\n'
    ).encode()) for key in ('srtla', 'mediamtx')}
    archives = {}
    for package in plan['packages']:
        origin = package.get('origin')
        if origin and origin not in archives:
            pin = plan['inputs'][origin]
            path = cache / sha(origin.encode())
            if not path.exists() and fetch:
                check(origin.startswith(('https://codeload.github.com/', 'https://static.crates.io/',
                                         'https://proxy.golang.org/')), 'nonofficial origin')
                with urllib.request.urlopen(origin, timeout=90) as response:
                    data = response.read()
                verify_archive(data, origin, pin)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            archives[origin] = verify_archive(path.read_bytes(), origin, pin)
        key = 'mediamtx' if (package['name'] in ('bluenviron/mediamtx', 'benburkert/openpgp')
                             or package['scope'] == 'measured Go buildinfo module'
                             or package['scope'].startswith('go.sum source-only')) else 'srtla'
        out = buffers[key]
        out.extend(f"\n===== {package['name']} {package['version']} =====\nScope: {package['scope']}\nOrigin: {origin or 'workspace root archive'}\n".encode())
        for text in package['texts']:
            data = archives[origin][text['source_path']]
            check(sha(data) == text['source_sha256'], 'source text drift')
            start, end = text['start'], text['end']
            check(0 <= start < end <= len(data), 'invalid text range')
            excerpt = data[start:end]
            check(sha(excerpt) == text['sha256'], 'notice text drift')
            out.extend(f"File: {text['source_path']}\nSource SHA256: {text['source_sha256']}\nBytes: [{start},{end}) SHA256: {text['sha256']}\n\n".encode())
            out.extend(excerpt + b'\n')
    return {key + '.txt': bytes(value) for key, value in buffers.items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--fetch', action='store_true')
    args = parser.parse_args()
    base = Path(__file__).resolve().parents[1] / 'mkosi/runtime/licence-notices/dependencies'
    raw = (base / 'plan.json').read_bytes()
    check(sha(raw) == (base / 'plan.sha256').read_text().strip(), 'notice inventory drift')
    result = render(json.loads(raw), args.cache, args.fetch)
    check(not args.output.exists(), 'output must be new')
    args.output.mkdir(parents=True)
    for name, data in result.items():
        (args.output / name).write_bytes(data)
    (args.output / 'SHA256SUMS').write_text(''.join(f'{sha(data)}  {name}\n' for name, data in sorted(result.items())))


if __name__ == '__main__':
    main()

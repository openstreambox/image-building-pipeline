#!/usr/bin/env python3
"""Export every .deb an image installed, next to its package lock, as one tar.

    export-debs.py <packages.lock.json> <staging dir> <output .debs.tar>
                   --snapshot YYYYMMDDTHHMMSSZ --debian-keyring <rootfs keyring>
                   [--suite trixie] [--security-suite trixie-security] [--arch arm64]

Non-Debian rows (first-party, local overrides, BSP, userspace pins, generated and
source-built packages) must match a staged .deb by SHA-256 and control fields.

Debian rows are taken from the build's own dated snapshot (the pockets the build
resolved from: the base and security suites, component main). For each pocket the
signed InRelease is verified with gpgv against the image's own Debian archive
keyring, its Packages.xz is checked against InRelease, and the row's
(name, version, arch, SHA-256) must name one Filename across the pockets. That file
is downloaded and checked against the lock digest and control fields.

The tar holds files/<name>_<version>_<arch>.deb for every exported row, the
InRelease and Packages.xz of each pocket under indexes/<archive>/<suite>/,
SHA256SUMS and export.json (per row: digest, file, and either where it was staged
or the pocket and Filename it came from). Members are sorted, owned by root and
dated SOURCE_DATE_EPOCH (or 0), so the same inputs give the same tar.

Fails, writing nothing, when a row has no file, is ambiguous across pockets, or a
file's control fields differ from its row. The first-party archive's client
credentials are never exported. The output must not exist yet.
Test hook: CERALIVE_EXPORT_SNAPSHOT_BASE replaces https://snapshot.debian.org/archive.
"""
import argparse
import hashlib
import io
import json
import lzma
import os
import pathlib
import re
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request

# Installed from the image, but never republished: the first-party archive's client
# credentials (a private key) stay out of the export and out of the image apt source.
UNSERVED_NAMES = {"ceralive-apt-credentials"}


def die(msg: str) -> None:
    raise SystemExit(f"export-debs: {msg}")


def sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(4 << 20), b""):
            h.update(block)
    return h.hexdigest()


def row_sha(row: dict) -> str:
    if row.get("sha256"):
        return row["sha256"]
    shas = list(((row.get("artifact") or {}).get("sha256") or {}).values())
    if len(shas) != 1:
        die(f"{row.get('name')}: no single artifact digest")
    return shas[0]


def control(path: pathlib.Path) -> tuple:
    out = subprocess.run(["dpkg-deb", "-f", str(path), "Package", "Version", "Architecture"],
                         check=True, capture_output=True, text=True).stdout
    fields = dict(line.split(": ", 1) for line in out.splitlines() if ": " in line)
    return fields.get("Package", ""), fields.get("Version", ""), fields.get("Architecture", "")


def fetch(url: str, attempts: int = 4) -> bytes:
    for n in range(attempts):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "image-export-debs"})
            with urllib.request.urlopen(req, timeout=300) as r:
                return r.read()
        except OSError as e:
            if n == attempts - 1:
                die(f"cannot fetch {url}: {e}")
            time.sleep(2 ** n)
    return b""


def gpgv_signed_text(data: bytes, keyring: str) -> str:
    with tempfile.TemporaryDirectory() as d:
        src, out = os.path.join(d, "InRelease"), os.path.join(d, "Release")
        pathlib.Path(src).write_bytes(data)
        r = subprocess.run(["gpgv", "--keyring", keyring, "--output", out, src], capture_output=True, text=True)
        if r.returncode != 0:
            die(f"gpgv refused a Debian InRelease: {r.stderr.strip()[-300:]}")
        return pathlib.Path(out).read_text(encoding="utf-8")


def field(block: str, name: str) -> str:
    m = re.search(rf"^{re.escape(name)}:[ \t]*(.*)$", block, re.M)
    return m.group(1).strip() if m else ""


def pocket_index(root: str, suite: str, arch: str, keyring: str) -> tuple:
    """Verified (InRelease bytes, Packages.xz bytes, {(name, version, arch, sha): Filename})."""
    inrelease = fetch(f"{root}/dists/{suite}/InRelease")
    signed = gpgv_signed_text(inrelease, keyring)
    rel = f"main/binary-{arch}/Packages.xz"
    want, inside = None, False
    for line in signed.splitlines():
        if line.startswith("SHA256:"):
            inside = True
            continue
        if inside and line.startswith(" "):
            sha, size, name = line.split()
            if name == rel:
                want = (sha, int(size))
        elif inside:
            inside = False
    if not want:
        die(f"{root} {suite}: InRelease lists no {rel}")
    packed = fetch(f"{root}/dists/{suite}/{rel}")
    if (hashlib.sha256(packed).hexdigest(), len(packed)) != want:
        die(f"{root} {suite}: {rel} differs from its InRelease")
    index = {}
    for block in re.split(r"\n\s*\n", lzma.decompress(packed).decode("utf-8")):
        if block.strip():
            key = tuple(field(block, k) for k in ("Package", "Version", "Architecture", "SHA256"))
            index[key] = field(block, "Filename")
    return inrelease, packed, index


def write_tar(lock: pathlib.Path, out: pathlib.Path, chosen: list, meta: dict, snapshot: str) -> None:
    mtime = int(os.environ.get("SOURCE_DATE_EPOCH", "0") or 0)
    sums, record, members = [], [], []
    for r, src, provenance in chosen:
        name = f"files/{r['name']}_{r['version'].split(':', 1)[-1]}_{r['arch']}.deb"
        sums.append(f"{row_sha(r)}  {name}\n")
        record.append({"name": r["name"], "version": r["version"], "arch": r["arch"],
                       "origin": r["origin"], "sha256": row_sha(r), "file": name, **provenance})
        members.append((name, src))
    for name, data in meta.items():
        sums.append(f"{hashlib.sha256(data).hexdigest()}  {name}\n")
    blobs = dict(meta)
    blobs["SHA256SUMS"] = "".join(sorted(sums)).encode()
    blobs["export.json"] = (json.dumps({"lock_sha256": sha256(lock), "debian_snapshot": snapshot,
                                        "packages": sorted(record, key=lambda x: x["file"])},
                                       indent=1, sort_keys=True) + "\n").encode()

    def info(name: str, size: int) -> tarfile.TarInfo:
        t = tarfile.TarInfo(name)
        t.size, t.mtime, t.mode, t.uid, t.gid, t.uname, t.gname = size, mtime, 0o644, 0, 0, "root", "root"
        return t

    partial = out.with_name(out.name + ".partial")
    try:
        with tarfile.open(partial, "w", format=tarfile.PAX_FORMAT) as tar:
            for name, data in sorted(blobs.items()):
                tar.addfile(info(name, len(data)), io.BytesIO(data))
            for name, src in sorted(members):
                with open(src, "rb") as f:
                    tar.addfile(info(name, src.stat().st_size), f)
        os.chmod(partial, 0o644)
        partial.rename(out)
    except BaseException:
        partial.unlink(missing_ok=True)
        raise


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("lock", type=pathlib.Path)
    p.add_argument("staging", type=pathlib.Path)
    p.add_argument("out", type=pathlib.Path)
    p.add_argument("--snapshot", required=True)
    p.add_argument("--debian-keyring", required=True)
    p.add_argument("--suite", default="trixie")
    p.add_argument("--security-suite", default="trixie-security")
    p.add_argument("--arch", default="arm64")
    a = p.parse_args()
    lock, staging, out = a.lock, a.staging, a.out
    if out.exists() or not out.name.endswith(".debs.tar"):
        die(f"{out} already exists or does not end in .debs.tar")
    if not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z", a.snapshot):
        die("--snapshot must be YYYYMMDDTHHMMSSZ")
    if not os.path.isfile(a.debian_keyring):
        die(f"no Debian archive keyring at {a.debian_keyring}")
    rows = [r for r in json.loads(lock.read_text())["packages"] if r["name"] not in UNSERVED_NAMES]
    others = [r for r in rows if r.get("origin") != "debian"]
    debian = [r for r in rows if r.get("origin") == "debian"]

    # Non-Debian rows: the staged files.
    by_sha: dict = {}
    for deb in sorted(staging.rglob("*.deb")):
        if deb.is_file():
            by_sha.setdefault(sha256(deb), []).append(deb)
    missing, chosen = [], []  # chosen: (row, file, provenance)
    for r in others:
        files = by_sha.get(row_sha(r), [])
        if not files:
            missing.append(r)
            continue
        if control(files[0]) != (r["name"], r["version"], r["arch"]):
            die(f"{files[0]} does not carry {r['name']} {r['version']} {r['arch']}")
        chosen.append((r, files[0], {"staged_as": str(files[0].relative_to(staging))}))
    for r in missing:
        print(f"export-debs: no staged file for {r['origin']} {r['name']} {r['version']} {r['arch']}", file=sys.stderr)
    if missing:
        die(f"{len(missing)} of {len(others)} non-Debian rows have no staged .deb")

    # Debian rows: the build's own dated pockets, verified, matched by digest.
    base = os.environ.get("CERALIVE_EXPORT_SNAPSHOT_BASE", "https://snapshot.debian.org/archive")
    meta, indexes = {}, []
    for archive, suite in (("debian", a.suite), ("debian-security", a.security_suite)):
        root = f"{base}/{archive}/{a.snapshot}"
        inrelease, packed, index = pocket_index(root, suite, a.arch, a.debian_keyring)
        meta[f"indexes/{archive}/{suite}/InRelease"] = inrelease
        meta[f"indexes/{archive}/{suite}/main/binary-{a.arch}/Packages.xz"] = packed
        indexes.append((archive, suite, root, index))
    work = tempfile.TemporaryDirectory(prefix=".export-debs.", dir=out.parent)
    try:
        unresolved = []
        for r in debian:
            key = (r["name"], r["version"], r["arch"], r["sha256"])
            hits = [(archive, suite, root, idx[key]) for archive, suite, root, idx in indexes if key in idx]
            if len({h[3] for h in hits}) != 1:
                unresolved.append((r, len(hits)))
                continue
            archive, suite, root, filename = hits[0]
            dest = pathlib.Path(work.name) / r["sha256"]
            dest.write_bytes(fetch(f"{root}/{filename}"))
            if sha256(dest) != r["sha256"] or control(dest) != (r["name"], r["version"], r["arch"]):
                die(f"{r['name']} {r['version']}: the snapshot file differs from the lock")
            chosen.append((r, dest, {"archive": archive, "pocket": suite, "filename": filename}))
        for r, n in unresolved:
            print(f"export-debs: {r['name']} {r['version']} {r['arch']}: {n} snapshot pockets match", file=sys.stderr)
        if unresolved:
            die(f"{len(unresolved)} of {len(debian)} Debian rows are not in exactly one pocket of snapshot {a.snapshot}")
        write_tar(lock, out, chosen, meta, a.snapshot)
    finally:
        work.cleanup()
    print(f"export-debs: {len(chosen)} packages ({len(debian)} Debian) -> {out}")


if __name__ == "__main__":
    main()

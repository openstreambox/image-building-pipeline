#!/usr/bin/env python3
"""Export the exact non-Debian .debs an image installed, next to its package lock.

    export-debs.py <packages.lock.json> <staging dir> <output .debs.tar>

Every lock row whose origin is not "debian" (first-party, local overrides, BSP,
userspace pins, generated and source-built packages) must match a staged .deb by
SHA-256. The tar holds each as <name>_<version>_<arch>.deb, plus SHA256SUMS and
export.json (row, digest, where it was staged); members are sorted, owned by root
and dated SOURCE_DATE_EPOCH (or 0), so the tar is reproducible. Debian rows are not exported: a dated-snapshot
build can fetch each one again by its locked digest from Debian's signed index.

Fails, writing nothing, when a row has no staged file, when two staged files claim
one row, or when a staged file's control fields differ from its row. The
first-party archive's client credentials are never exported. The output must not
exist yet.
"""
import hashlib
import json
import os
import pathlib
import subprocess
import io
import sys
import tarfile

# Installed from the image, but never republished: the first-party archive's client
# credentials (a private key) stay out of the export and out of the image apt source.
UNSERVED_NAMES = {"ceralive-apt-credentials"}


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
        raise SystemExit(f"export-debs: {row.get('name')}: no single artifact digest")
    return shas[0]


def control(path: pathlib.Path) -> tuple:
    out = subprocess.run(["dpkg-deb", "-f", str(path), "Package", "Version", "Architecture"],
                         check=True, capture_output=True, text=True).stdout
    fields = dict(line.split(": ", 1) for line in out.splitlines() if ": " in line)
    return fields.get("Package", ""), fields.get("Version", ""), fields.get("Architecture", "")


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    lock, staging, out = (pathlib.Path(a) for a in sys.argv[1:])
    if out.exists() or not out.name.endswith(".debs.tar"):
        raise SystemExit(f"export-debs: {out} already exists or does not end in .debs.tar")
    rows = [r for r in json.loads(lock.read_text())["packages"]
            if r.get("origin") != "debian" and r["name"] not in UNSERVED_NAMES]
    by_sha: dict = {}
    for deb in sorted(staging.rglob("*.deb")):
        if deb.is_file():
            by_sha.setdefault(sha256(deb), []).append(deb)
    missing, chosen = [], []
    for r in rows:
        files = by_sha.get(row_sha(r), [])
        if not files:
            missing.append(r)
            continue
        if control(files[0]) != (r["name"], r["version"], r["arch"]):
            raise SystemExit(f"export-debs: {files[0]} does not carry {r['name']} {r['version']} {r['arch']}")
        chosen.append((r, files[0]))
    for r in missing:
        print(f"export-debs: no staged file for {r['origin']} {r['name']} {r['version']} {r['arch']}", file=sys.stderr)
    if missing:
        raise SystemExit(f"export-debs: {len(missing)} of {len(rows)} non-Debian rows have no staged .deb")
    mtime = int(os.environ.get("SOURCE_DATE_EPOCH", "0") or 0)
    sums, record, members = [], [], []
    for r, src in chosen:
        name = f"{r['name']}_{r['version'].split(':', 1)[-1]}_{r['arch']}.deb"
        sums.append(f"{row_sha(r)}  {name}\n")
        record.append({"name": r["name"], "version": r["version"], "arch": r["arch"],
                       "origin": r["origin"], "sha256": row_sha(r), "file": name,
                       "staged_as": str(src.relative_to(staging))})
        members.append((name, src))
    meta = {"SHA256SUMS": "".join(sorted(sums)).encode(),
            "export.json": (json.dumps({"lock_sha256": sha256(lock), "packages": record},
                                       indent=1, sort_keys=True) + "\n").encode()}

    def info(name: str, size: int) -> tarfile.TarInfo:
        t = tarfile.TarInfo(name)
        t.size, t.mtime, t.mode, t.uid, t.gid, t.uname, t.gname = size, mtime, 0o644, 0, 0, "root", "root"
        return t

    partial = out.with_name(out.name + ".partial")
    try:
        with tarfile.open(partial, "w", format=tarfile.USTAR_FORMAT) as tar:
            for name, data in sorted(meta.items()):
                tar.addfile(info(name, len(data)), io.BytesIO(data))
            for name, src in sorted(members):
                with open(src, "rb") as f:
                    tar.addfile(info(name, src.stat().st_size), f)
        os.chmod(partial, 0o644)
        partial.rename(out)
    except BaseException:
        partial.unlink(missing_ok=True)
        raise
    print(f"export-debs: {len(chosen)} non-Debian packages -> {out}")


if __name__ == "__main__":
    main()

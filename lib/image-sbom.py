#!/usr/bin/env python3
"""Emit a CycloneDX inventory from the reconciled final-image package lock."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sys
from urllib.parse import quote


def validate_snapshot(value):
    if not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z", value):
        raise ValueError("expected a UTC snapshot timestamp")
    stamp = datetime.strptime(value, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
    if stamp > datetime.now(timezone.utc):
        raise ValueError("snapshot timestamp is in the future")


def digest(value):
    if not re.fullmatch(r"[0-9a-f]{64}", value):
        raise ValueError("invalid SHA-256 digest")
    return {"alg": "SHA-256", "content": value}


def file_hash(path):
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
    return digest(hasher.hexdigest())


def property_value(name, value):
    return {"name": f"ceralive:{name}", "value": value}


def package_component(package):
    origin = package["origin"]
    name, version, arch = (package[key] for key in ("name", "version", "arch"))
    namespace = "debian/" if origin == "debian" else ""
    purl = f"pkg:deb/{namespace}{name}@{quote(version, safe='')}?arch={quote(arch, safe='')}"
    props = [property_value("deb:origin", origin)]
    if "source" in package:
        props.extend(property_value(f"source:{key}", value)
                     for key, value in sorted(package["source"].items()))
    if "sha256" in package:
        archive_hash = package["sha256"]
    else:
        (filename, archive_hash), = package["artifact"]["sha256"].items()
        props.append(property_value("deb:filename", filename))
    return {"type": "library", "name": name, "version": version, "bom-ref": purl,
            "purl": purl, "hashes": [digest(archive_hash)], "properties": props}


def generate(args):
    expected = (args.root / "usr/lib/ceralive/build-lock/debian-snapshot").read_text().strip()
    if expected != args.snapshot:
        raise ValueError("final rootfs snapshot marker differs from build option")
    lock = json.loads(args.lock.read_text())
    packages = {item["name"]: item for item in lock["packages"]}
    components = [package_component(item) for item in lock["packages"]]

    def add_file(relative, version):
        path = (args.root / relative).resolve(strict=True)
        if not path.is_relative_to(args.root.resolve()) or not path.is_file():
            raise ValueError(f"invalid installed payload path: {relative}")
        components.append({"type": "file", "name": relative, "version": version,
                           "hashes": [file_hash(path)]})

    add_file("usr/local/bin/mediamtx", args.mediamtx_version)
    for package, relative in (("ceralive-device", "usr/local/bin/ceralive"),
                              ("srtla", "usr/bin/srtla_send")):
        if package in packages:
            add_file(relative, packages[package]["version"])
    for pattern in ("vmlinuz-*", "initrd.img-*"):
        for payload in sorted((args.root / "boot").glob(pattern)):
            add_file(f"boot/{payload.name}", payload.name.split("-", 1)[1])
    boot_image = args.root / "boot/Image"
    if boot_image.exists():
        add_file("boot/Image", args.image_version)

    for row in args.boot_blobs.splitlines():
        name, sector, _, sha256, package, version = row.split("\t")
        components.append({"type": "firmware", "name": name, "version": version,
                           "hashes": [digest(sha256)],
                           "properties": [property_value("raw:sector", sector),
                                          property_value("deb:package", package)]})

    properties = [property_value("debian:snapshot", args.snapshot),
                  property_value("board", args.board)]
    for suite, date in sorted(lock["debian_release_dates"].items()):
        properties.append(property_value(f"debian:release-date:{suite}", date))
    for sidecar in args.artifact:
        # These checksums were computed by the artifact producers. Reuse
        # them to avoid rereading the multi-gigabyte raw image and bundle.
        sha256, name = sidecar.read_text().strip().split(maxsplit=1)
        if sidecar.name != f"{name}.sha256":
            raise ValueError(f"checksum filename mismatch: {sidecar.name}")
        properties.append(property_value(f"artifact:sha256:{name}", digest(sha256)["content"]))

    bom = {"bomFormat": "CycloneDX", "specVersion": "1.6", "version": 1,
           "metadata": {"component": {"type": "operating-system",
                                      "name": f"CeraLive image ({args.board})",
                                      "version": args.image_version},
                        "properties": properties},
           "components": components}
    data = (json.dumps(bom, sort_keys=True, indent=2) + "\n").encode()
    temporary = args.output.with_suffix(".tmp")
    temporary.write_bytes(data)
    temporary.replace(args.output)
    checksum = args.output.with_suffix(".json.sha256")
    temporary.write_text(f"{hashlib.sha256(data).hexdigest()}  {args.output.name}\n")
    temporary.replace(checksum)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("validate-snapshot").add_argument("snapshot")
    emit = commands.add_parser("emit")
    for argument in ("root", "lock", "output"):
        emit.add_argument(f"--{argument}", type=Path, required=True)
    for argument in ("board", "snapshot", "image-version", "mediamtx-version"):
        emit.add_argument(f"--{argument}", required=True)
    emit.add_argument("--boot-blobs", default="")
    emit.add_argument("--artifact", action="append", type=Path, required=True)
    args = parser.parse_args()
    try:
        validate_snapshot(args.snapshot)
        if args.command == "emit":
            generate(args)
    except (KeyError, OSError, ValueError) as exc:
        print(f"image SBOM: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

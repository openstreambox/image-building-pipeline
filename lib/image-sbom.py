#!/usr/bin/env python3
"""Emit a CycloneDX inventory from the reconciled final-image package lock."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import lzma
from pathlib import Path
import re
import sys
from urllib.parse import quote, urlsplit


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


def stream_sha256(stream):
    hasher = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        hasher.update(block)
    return hasher.hexdigest()


def file_hash(path):
    with path.open("rb") as stream:
        return digest(stream_sha256(stream))


def property_value(name, value):
    return {"name": f"ceralive:{name}", "value": value}


def deb_purl(vendor, name, version, arch, qualifier, repository):
    return (f"pkg:deb/{quote(vendor, safe='')}/{quote(name.lower(), safe='')}@{quote(version, safe=':')}"
            f"?arch={quote(arch, safe='')}&{qualifier}={quote(repository, safe=':')}")


def userspace_repositories(pin_file, installed):
    repositories = {}
    for line in pin_file.read_text().splitlines():
        fields = line.split()
        if not fields or fields[0] not in installed:
            continue
        name, _, _, url = fields[:4]
        source = urlsplit(url)
        host = source.hostname or ""
        # The fetch pin is the source of truth. Preserve the repository path,
        # and omit credentials, query parameters, and the individual asset.
        authority = f"[{host}]" if ":" in host else host
        if source.port:
            authority += f":{source.port}"
        vendor = host or "local"
        path = source.path.rsplit("/", 1)[0]
        segments = source.path.strip("/").split("/")
        if host == "github.com" and len(segments) >= 3:
            vendor = segments[0].lower()
            path = "/" + "/".join(segments[:2])
        elif host == "radxa-repo.github.io":
            vendor = "radxa"
            path = "/" + segments[0]
        repositories.setdefault(name, (vendor, f"{source.scheme}://{authority}{path}"))
    return repositories


def package_component(package, debian_suite, armbian_suite, repositories):
    origin = package["origin"]
    name, version, arch = (package[key] for key in ("name", "version", "arch"))
    qualifier = "distro"
    if origin == "debian":
        vendor, distro = "debian", debian_suite
    elif origin == "bsp":
        vendor, distro = "armbian", armbian_suite
    elif origin == "userspace-pin":
        vendor, distro = repositories[name]
        qualifier = "repository_url"
    else:
        vendor, distro = "ceralive", debian_suite
    purl = deb_purl(vendor, name, version, arch, qualifier, distro)
    props = [property_value("deb:origin", origin)]
    source = package["debian_source"]
    props.extend(property_value(f"deb:source:{key}", source[key]) for key in ("name", "version"))
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
    record = args.root / "usr/lib/ceralive/build-lock/debian-snapshot.json"
    expected = json.loads(record.read_text())
    if expected["timestamp"] != args.snapshot:
        raise ValueError("final rootfs snapshot marker differs from build option")
    lock = json.loads(args.lock.read_text())
    packages = {item["name"]: item for item in lock["packages"]}
    snapshot = lock["debian_snapshot"]
    if snapshot != expected:
        raise ValueError("package lock snapshot differs from the final rootfs record")
    installed = {item["name"] for item in lock["packages"] if item["origin"] == "userspace-pin"}
    if installed and not args.userspace_pins:
        raise ValueError("installed userspace packages require their fetch pin manifest")
    repositories = userspace_repositories(args.userspace_pins, installed) if installed else {}
    components = [package_component(item, args.debian_suite, args.armbian_suite, repositories)
                  for item in lock["packages"]]

    def add_file(relative, version, root=args.root, name=None):
        path = (root / relative).resolve(strict=True)
        if not path.is_relative_to(root.resolve()) or not path.is_file():
            raise ValueError(f"invalid installed payload path: {relative}")
        component = {"type": "file", "name": name or relative, "hashes": [file_hash(path)]}
        if version:
            component["version"] = version
        components.append(component)

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
        version = args.kernel_release
        if not version:
            resolved_name = boot_image.resolve().name
            if resolved_name.startswith("vmlinuz-"):
                version = resolved_name.removeprefix("vmlinuz-")
            else:
                kernels = list((args.root / "boot").glob("vmlinuz-*"))
                if len(kernels) == 1:
                    version = kernels[0].name.removeprefix("vmlinuz-")
        add_file("boot/Image", version)
    if args.boot_payload:
        add_file("boot.scr", args.image_version, args.boot_payload, "usr/lib/ceralive/boot/boot.scr")

    for row in args.boot_blobs.splitlines():
        name, sector, _, sha256, package, version = row.split("\t")
        components.append({"type": "firmware", "name": name, "version": version,
                           "hashes": [digest(sha256)],
                           "properties": [property_value("raw:sector", sector),
                                          property_value("deb:package", package)]})

    properties = [property_value("debian:snapshot", args.snapshot),
                  property_value("board", args.board)]
    properties.append(property_value("debian:snapshot-scope", snapshot["scope"]))
    properties.extend(property_value("debian:snapshot-exclusion", exclusion)
                      for exclusion in snapshot["exclusions"])
    properties.append(property_value(
        "inventory-scope",
        "Installed binary packages and selected executables, kernel, initramfs, slot boot.scr and raw-gap blobs. "
        "Firmware package hashes cover archives. Per-file firmware and factory boot-partition files "
        "are outside this subset.",
    ))
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


def verify_candidate(args):
    bom = json.loads(args.sbom.read_text())
    properties = {}
    for prop in bom["metadata"]["properties"]:
        key = prop["name"]
        if key == "ceralive:debian:snapshot" or key.startswith("ceralive:artifact:sha256:"):
            if key in properties:
                raise ValueError(f"duplicate SBOM property: {key}")
            properties[key] = prop["value"]
    if properties.get("ceralive:debian:snapshot") != args.snapshot:
        raise ValueError("candidate snapshot does not match SBOM")

    raw = args.compressed.name.removesuffix(".xz")
    bundle_name = str(Path(raw).with_suffix(".raucb"))
    expected = {}
    for name in (raw, args.compressed.name, bundle_name):
        expected[name] = digest(properties[f"ceralive:artifact:sha256:{name}"])["content"]
    for path, name in ((args.compressed, args.compressed.name), (args.bundle, bundle_name)):
        if file_hash(path)["content"] != expected[name]:
            raise ValueError(f"candidate digest differs from SBOM: {path.name}")
    with lzma.open(args.compressed, "rb") as stream:
        if stream_sha256(stream) != expected[raw]:
            raise ValueError("uncompressed candidate raw digest differs from SBOM")

    # These are consumed by the candidate metadata step and later release
    # tooling. Write them from the verified bytes and the published filenames.
    for path, name, value in (
        (args.compressed.parent / "raw.sha256", raw, expected[raw]),
        (args.compressed.with_suffix(".xz.sha256"), args.compressed.name, expected[args.compressed.name]),
        (args.bundle.with_suffix(".raucb.sha256"), args.bundle.name, expected[bundle_name]),
    ):
        path.write_text(f"{value}  {name}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("validate-snapshot").add_argument("snapshot")
    emit = commands.add_parser("emit")
    for argument in ("root", "lock", "output"):
        emit.add_argument(f"--{argument}", type=Path, required=True)
    for argument in ("board", "snapshot", "image-version", "mediamtx-version", "debian-suite", "armbian-suite"):
        emit.add_argument(f"--{argument}", required=True)
    emit.add_argument("--boot-blobs", default="")
    emit.add_argument("--boot-payload", type=Path)
    emit.add_argument("--userspace-pins", type=Path)
    emit.add_argument("--kernel-release", default="")
    emit.add_argument("--artifact", action="append", type=Path, required=True)
    verify = commands.add_parser("verify-candidate")
    for argument in ("sbom", "compressed", "bundle"):
        verify.add_argument(f"--{argument}", type=Path, required=True)
    verify.add_argument("--snapshot", required=True)
    args = parser.parse_args()
    try:
        validate_snapshot(args.snapshot)
        if args.command == "emit":
            generate(args)
        elif args.command == "verify-candidate":
            verify_candidate(args)
    except (EOFError, KeyError, OSError, ValueError, lzma.LZMAError) as exc:
        print(f"image SBOM: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

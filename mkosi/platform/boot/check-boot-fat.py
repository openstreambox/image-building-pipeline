#!/usr/bin/python3
"""Check the shared FAT32 partition and clear only Linux's dirty byte."""

import argparse
import os
from pathlib import Path
import re
import stat
import struct
import subprocess
import sys

DIRTY_OFFSET = 65
FAULT_MARKER = Path("/run/ceralive/boot-fat-fault")
FAT32_HEALTHY_FLAGS = (1 << 27) | (1 << 26)  # Clean shutdown and no hard error.
# dosfstools 4.2 reports the Linux dirty byte as a difference from the backup
# boot sector. Insist on precisely this difference and no other repairs.
DIRTY_REPORT = (
    "There are differences between boot sector and its backup.\n"
    "This is mostly harmless. Differences: (offset:original/backup)\n"
    "  65:01/00\n"
    "  Not automatically fixing this.\n"
    "Dirty bit is set. Fs was not properly unmounted and some data may be corrupt.\n"
    " Automatically removing dirty bit.\n"
)
# FSINFO is a cache. This mount does not enable the vfat usefree option.
FREE_SUMMARY = (
    r"(?:Free cluster summary uninitialized \(should be \d+\)\n"
    r"|(?P<stale>Free cluster summary wrong \(\d+ vs\. really \d+\)\n  Auto-correcting\.\n))?"
)


def clear_dirty_byte(fd):
    # A FAT entry can also record a dirty shutdown or an I/O error. fsck.fat
    # reports the shutdown flag with the same message as the boot-sector byte.
    boot = os.pread(fd, 512, 0)
    if len(boot) != 512 or boot[DIRTY_OFFSET] != 1:
        raise OSError("dirty byte did not match the read-only check")
    sector_size, _, reserved, tables = struct.unpack_from("<HBHB", boot, 11)
    fat_sectors, = struct.unpack_from("<I", boot, 36)
    if sector_size not in (512, 1024, 2048, 4096) or not reserved or not fat_sectors or tables not in (1, 2):
        raise OSError("unexpected FAT32 geometry")
    for table in range(tables):
        offset = (reserved + table * fat_sectors) * sector_size + 4
        flags = int.from_bytes(os.pread(fd, 4, offset), "little")
        if flags & FAT32_HEALTHY_FLAGS != FAT32_HEALTHY_FLAGS:
            raise OSError("FAT table reports a dirty shutdown or an I/O error")
    if os.pwrite(fd, b"\x00", DIRTY_OFFSET) != 1:
        raise OSError("short write while clearing the dirty byte")
    os.fsync(fd)


def check(device):
    # O_EXCL refuses a mounted block device and holds it against a concurrent
    # mount through the check and write. The child reads that same device.
    fd = os.open(device, os.O_RDWR | os.O_EXCL)
    try:
        mode = os.fstat(fd).st_mode
        if not (stat.S_ISBLK(mode) or stat.S_ISREG(mode)):
            raise OSError("expected a block device or a regular FAT image")
        path = f"/proc/self/fd/{fd}"
        result = subprocess.run(
            ["/usr/sbin/fsck.fat", "-n", path],
            pass_fds=(fd,), env={**os.environ, "LC_ALL": "C"},
            capture_output=True, text=True, errors="backslashreplace", timeout=12,
        )
        print(result.stdout, end="", flush=True)
        if result.stderr:
            print(result.stderr, end="", file=sys.stderr)
        report = re.fullmatch(
            r"fsck\.fat [^\n]+\n"
            rf"(?P<dirty>{re.escape(DIRTY_REPORT)})?"
            rf"{FREE_SUMMARY}(?P<unchanged>\nLeaving filesystem unchanged\.\n)?"
            rf"{path}: \d+ files, \d+/\d+ clusters\n",
            result.stdout,
        )
        if result.stderr or report is None:
            raise OSError(f"read-only fsck.fat reported filesystem diagnostics (exit {result.returncode})")
        changes_proposed = bool(report["dirty"] or report["stale"])
        if result.returncode != int(changes_proposed) or bool(report["unchanged"]) != changes_proposed:
            raise OSError(f"read-only fsck.fat status disagreed with its report (exit {result.returncode})")
        if report["dirty"]:
            clear_dirty_byte(fd)
            print("Shared /boot FAT check passed and cleared the dirty byte.")
        else:
            print("Shared /boot FAT check passed without writes.")
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device")
    parser.add_argument("--fault-marker", type=Path, default=FAULT_MARKER)
    args = parser.parse_args()
    try:
        check(args.device)
    except (OSError, subprocess.TimeoutExpired) as error:
        message = f"Shared /boot FAT check needs attention: {error}"
        print(f"<4>{message}", file=sys.stderr)
        try:
            args.fault_marker.parent.mkdir(parents=True, exist_ok=True)
            args.fault_marker.write_text(f"{message}\n")
        except OSError as marker_error:
            print(f"<4>Could not record the /boot FAT fault: {marker_error}", file=sys.stderr)
    else:
        try:
            args.fault_marker.unlink(missing_ok=True)
        except OSError as error:
            print(f"<4>Could not clear the /boot FAT fault: {error}", file=sys.stderr)


if __name__ == "__main__":
    main()

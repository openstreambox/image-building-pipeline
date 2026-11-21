#!/usr/bin/python3
"""Start srtla_send with the arguments CeraUI published.

srtla-send.service runs this as root. It reads the argument vector from
/run/srtla-send/argv (each argument ended by a NUL byte, no program name)
and replaces itself with the sender, so the sender is the unit's main
process and systemd sees its exit status.

Root runs what the file says, so the file is opened once, without following
a symlink and without blocking on a FIFO, and the open descriptor is checked:
a regular file owned by root, writable by nobody else, 1 to 8192 bytes,
ending in a NUL. Its directory must be owned by root and writable by nobody
else, so nobody else can swap the file. Callers publish a fresh 0600 file
by renaming it into place in the same directory.

Exit 78 (EX_CONFIG): the file is missing or refused. The unit does not
retry that, nor the sender's own usage error (exit 2).

Test overrides: CERALIVE_SRTLA_SEND_ARGV, CERALIVE_SRTLA_SEND_BIN and
CERALIVE_SRTLA_SEND_OWNER_UID.
"""
import os
import stat
import sys

REFUSED = 78
MAX_BYTES = 8192


def refuse(message: str) -> "NoReturn":  # noqa: F821
    print(f"srtla-send-launch: {message}", file=sys.stderr)
    sys.exit(REFUSED)


def main() -> None:
    path = os.environ.get("CERALIVE_SRTLA_SEND_ARGV", "/run/srtla-send/argv")
    sender = os.environ.get("CERALIVE_SRTLA_SEND_BIN", "/usr/bin/srtla_send")
    owner = int(os.environ.get("CERALIVE_SRTLA_SEND_OWNER_UID", "0"))

    parent = os.path.dirname(os.path.abspath(path))
    try:
        dir_st = os.lstat(parent)
    except OSError as error:
        refuse(f"cannot inspect {parent}: {error.strerror}")
    if not stat.S_ISDIR(dir_st.st_mode):
        refuse(f"{parent} is not a directory")
    if dir_st.st_uid != owner or dir_st.st_mode & 0o022:
        refuse(f"{parent} must be owned by uid {owner} and writable by nobody else")

    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except OSError as error:
        refuse(f"cannot open {path}: {error.strerror}")
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            refuse(f"{path} is not a regular file")
        if st.st_uid != owner:
            refuse(f"{path} is owned by uid {st.st_uid}, not {owner}")
        if st.st_mode & 0o022:
            refuse(f"{path} is writable by group or others (mode {stat.S_IMODE(st.st_mode):o})")
        chunks = []
        size = 0
        while size <= MAX_BYTES:
            chunk = os.read(fd, MAX_BYTES + 1 - size)
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
    except OSError as error:
        refuse(f"cannot read {path}: {error.strerror}")
    finally:
        os.close(fd)
    data = b"".join(chunks)
    if not 0 < len(data) <= MAX_BYTES:
        refuse(f"{path} has {len(data)} bytes (1 to {MAX_BYTES} allowed)")
    if not data.endswith(b"\0"):
        refuse(f"{path} does not end in a NUL byte (truncated write?)")
    args = [os.fsdecode(arg) for arg in data[:-1].split(b"\0")]
    if len(args) < 4:
        refuse(f"{path} has {len(args)} arguments; the sender needs at least 4")
    port = args[0]
    if not (port.isascii() and port.isdigit() and len(port) <= 5 and 1 <= int(port) <= 65535):
        refuse(f"first argument is not a port: {port!r}")

    try:
        os.execv(sender, [sender, *args])
    except OSError as error:
        print(f"srtla-send-launch: cannot run {sender}: {error.strerror}", file=sys.stderr)
        sys.exit(127)


if __name__ == "__main__":
    main()

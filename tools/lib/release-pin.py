#!/usr/bin/env python3
"""Atomically save the release selection without parsing or rewriting secrets."""
import argparse
import os
from pathlib import Path
import re
import stat
import tempfile

TAG = r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
# Replace only our canonical final assignment. Older entries and multiline
# values stay byte-for-byte intact; Compose uses the final assignment.
FINAL_PIN = re.compile(rb"(?m)^ARCUS_SIGNAL_IMAGE_TAG=v[0-9]+\.[0-9]+\.[0-9]+(?:\r?\n)?\Z")


def check(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or not os.access(path, os.W_OK) or not os.access(path.parent, os.W_OK):
        raise OSError("unwritable configuration")
    return info


def save(path, tag):
    info = check(path)
    original = path.read_bytes()
    newline = b"\r\n" if b"\r\n" in original else b"\n"
    pin = b"ARCUS_SIGNAL_IMAGE_TAG=" + tag.encode("ascii") + newline
    match = FINAL_PIN.search(original)
    if match:
        updated = original[:match.start()] + pin
    else:
        updated = original + (newline if original and not original.endswith(b"\n") else b"") + pin
    if updated == original:
        return
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".arcus-release-pin-", delete=False) as output:
            temporary = Path(output.name)
            output.write(updated)
            output.flush()
            os.fchown(output.fileno(), info.st_uid, info.st_gid)
            os.fchmod(output.fileno(), stat.S_IMODE(info.st_mode))
            os.fsync(output.fileno())
        current = path.lstat()
        fields = ("st_dev", "st_ino", "st_mtime_ns", "st_ctime_ns", "st_size")
        if any(getattr(current, field) != getattr(info, field) for field in fields):
            raise OSError("configuration changed during deployment")
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Check writability without changing configuration")
    parser.add_argument("env_file", type=Path)
    parser.add_argument("tag")
    args = parser.parse_args()
    if not re.fullmatch(TAG, args.tag):
        parser.error("Supply a stable vMAJOR.MINOR.PATCH tag")
    try:
        if args.check:
            check(args.env_file)
        else:
            save(args.env_file, args.tag)
    except OSError:
        parser.exit(4, "Release pin unavailable: use a writable regular .env file and directory; check for concurrent edits.\n")


if __name__ == "__main__":
    main()

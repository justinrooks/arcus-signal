#!/usr/bin/env python3

import os
from pathlib import Path
import signal
import sys
import time


def write_marker(path: str, contents: str) -> None:
    Path(path).write_text(contents, encoding="utf-8")


def run_waiting_mode(mode: str, pid_path: str, ready_path: str, term_path: str) -> None:
    def handle_term(_signal_number: int, _frame: object) -> None:
        write_marker(term_path, "TERM\n")
        if mode == "graceful":
            sys.exit(0)

    signal.signal(signal.SIGTERM, handle_term)
    write_marker(pid_path, f"{os.getpid()}\n")
    write_marker(ready_path, "ready\n")

    if mode == "timeout":
        sys.stderr.write("waiting for timeout\n")
        sys.stderr.flush()

    while True:
        time.sleep(0.05)


def main() -> None:
    mode = sys.argv[1]

    if mode == "empty":
        return

    if mode == "success":
        sys.stdout.write("line one\n")
        sys.stderr.write("line two\n")
        return

    if mode == "nonzero":
        sys.stderr.write("boom\n")
        sys.exit(7)

    if mode == "large":
        for index in range(1, 15001):
            sys.stdout.write(f"stdout-{index:05d}\n")
            sys.stderr.write(f"stderr-{index:05d}\n")
        return

    if mode in {"graceful", "ignore-term", "timeout"}:
        run_waiting_mode(mode, sys.argv[2], sys.argv[3], sys.argv[4])
        return

    raise ValueError(f"Unknown fixture mode: {mode}")


if __name__ == "__main__":
    main()

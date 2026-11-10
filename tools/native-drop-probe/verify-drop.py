#!/usr/bin/env python3
"""Check the exact bytes saved by a native Finder/Explorer drop; never modify it."""
import hashlib
import pathlib
import sys

EXPECTED = (
    "Barrier native file drop preview\r\n"
    "UTF-8: 中文檔名與內容 / Windows / macOS\r\n"
    "This file was generated when the destination requested its contents.\r\n"
).encode("utf-8")


def main():
    if len(sys.argv) != 2:
        print("Usage: python verify-drop.py <path-to-dropped-file>", file=sys.stderr)
        return 2
    try:
        with pathlib.Path(sys.argv[1]).open("rb") as source:
            actual = source.read(len(EXPECTED) + 1)
    except OSError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    if actual != EXPECTED:
        print("FAIL: content is incomplete or differs from the fixture", file=sys.stderr)
        return 1
    print(f"PASS: {len(EXPECTED)} bytes; SHA-256 {hashlib.sha256(actual).hexdigest()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

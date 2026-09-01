#!/usr/bin/env python3
"""Validate Xcode project.pbxproj object IDs and references.

Usage:
    python3 scripts/validate_pbxproj.py FrameBoost/FrameBoost.xcodeproj/project.pbxproj

The validator:
- collects every 24-character hex object ID defined as `ID = {isa = ...;`
- finds 24-character hex IDs referenced anywhere in the project
- reports referenced IDs that are not defined
- reports suspicious alphanumeric IDs longer than 24 characters
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ID = r"[A-Fa-f0-9]{24}"
DEFINED_RE = re.compile(rf"^\s*({ID})\s*=\s*\{{\s*isa\s*=", re.MULTILINE)
REF_RE = re.compile(rf"(?<![A-Za-z0-9])({ID})(?![A-Za-z0-9])")
LONG_RE = re.compile(r"(?<![A-Za-z0-9])([A-Za-z0-9]{25,})(?![A-Za-z0-9])")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {Path(sys.argv[0]).name} path/to/project.pbxproj")
        return 2

    path = Path(sys.argv[1])
    if not path.is_file():
        print(f"ERROR: file not found: {path}")
        return 2

    text = path.read_text(encoding="utf-8")
    defined = set(DEFINED_RE.findall(text))
    referenced = set(REF_RE.findall(text))
    dangling = sorted(referenced - defined)

    # Ignore the 24-character IDs already handled above. Any longer token made
    # only of alphanumeric characters in this file is suspicious and is useful
    # for catching accidental extra zeros in hand-edited object IDs.
    long_tokens = sorted(set(LONG_RE.findall(text)))
    suspicious = [token for token in long_tokens if not token.startswith("http")]

    print(f"Defined PBX objects: {len(defined)}")
    print(f"Referenced PBX objects: {len(referenced)}")

    failed = False

    if dangling:
        failed = True
        print("ERROR: dangling PBX references:")
        for token in dangling:
            print(f"  {token}")

    if suspicious:
        failed = True
        print("ERROR: suspicious object/reference tokens longer than 24 characters:")
        for token in suspicious:
            print(f"  {token} ({len(token)} chars)")

    if failed:
        return 1

    print("PBX object graph: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

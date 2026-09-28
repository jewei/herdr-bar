#!/usr/bin/env python3
"""Check the shared text rules without a toolchain-specific Swift rewrite."""

from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
paths = subprocess.check_output(
    ["git", "ls-files", "-z"], cwd=root
).decode().split("\0")
suffixes = {".swift", ".sh", ".py", ".json", ".yml", ".yaml", ".md", ".plist"}
errors = []
for name in filter(None, paths):
    path = root / name
    if path.suffix not in suffixes and name not in {".editorconfig", ".gitignore", "LICENSE"}:
        continue
    data = path.read_bytes()
    if data and not data.endswith(b"\n"):
        errors.append(f"{name}: missing final newline")
    for number, line in enumerate(data.split(b"\n"), 1):
        if line.endswith((b" ", b"\t", b"\r")) or b"\t" in line:
            errors.append(f"{name}:{number}: use spaces, LF, and no trailing whitespace")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print("Text format checks passed.")

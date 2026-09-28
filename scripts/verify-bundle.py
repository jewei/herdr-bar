#!/usr/bin/env python3
"""Validate an app against its source metadata and print its CPU architecture."""

from pathlib import Path
import plistlib
import re
import subprocess
import sys


def verify(app, source):
    with source.open("rb") as stream:
        expected = plistlib.load(stream)
    with (app / "Contents/Info.plist").open("rb") as stream:
        actual = plistlib.load(stream)
    if actual != expected:
        raise ValueError("The bundle metadata differs from the source metadata.")
    required = {
        "CFBundleIdentifier": "dev.jewei.herdr-bar",
        "CFBundleExecutable": "HerdrBar",
        "CFBundlePackageType": "APPL",
        "LSMinimumSystemVersion": "14.0",
        "LSUIElement": True,
    }
    for key, value in required.items():
        if actual.get(key) != value:
            raise ValueError(f"Invalid {key}: {actual.get(key)!r}")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", actual.get("CFBundleShortVersionString", "")):
        raise ValueError("Use a three-part marketing version.")
    if not re.fullmatch(r"[1-9][0-9]*", actual.get("CFBundleVersion", "")):
        raise ValueError("Use a positive integer build number.")
    binary = app / "Contents/MacOS/HerdrBar"
    if not binary.is_file() or not binary.stat().st_mode & 0o111:
        raise ValueError("The app executable is missing or is not executable.")
    architectures = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
    if len(architectures) != 1 or architectures[0] not in {"arm64", "x86_64"}:
        raise ValueError(f"Expected one supported architecture; found {architectures!r}.")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    return architectures[0]


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("Usage: verify-bundle.py APP SOURCE_PLIST")
    try:
        print(verify(Path(sys.argv[1]), Path(sys.argv[2])))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))

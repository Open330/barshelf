#!/usr/bin/env python3
"""Fails when the docs advertise a BarShelf release that is not the current one.

The repo once shipped a README promising "the current v0.1.4 build is Developer
ID signed, notarized, and stapled" while the newest release — and the cask, and
every other doc — was v0.1.3. Anyone following the README looked for an asset
that did not exist, and anyone running that unreleased build was told forever
that they were up to date.

`RELEASED_VERSION` is the source of truth here: `scripts/release.sh` writes it
only after a notarized public release exists, so whatever it says is genuinely
downloadable. Every `vX.Y.Z` reference in the user-facing docs has to match it.

It replaced a Homebrew cask that lived in this repo and served the same purpose.
That cask turned out to be a second copy of one in Open330/homebrew-tap, and the
two drifted three releases apart — a user who installed from the tap was told by
the app to run `brew upgrade`, and brew told them they were already current. The
tap is the only cask now; `.github/workflows/tap-bump.yml` keeps it in step with
the release, and `scripts/verify-release.sh` fails if it ever falls behind again.

Run directly, or via CI. Exits non-zero with the offending file:line.
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RELEASED = ROOT / "RELEASED_VERSION"
# Files that tell a user which build to download.
CHECKED = ["README.md", "docs/INSTALL.md", "site/index.html"]

# The version this tree is *becoming*, which is a different thing from the
# version that is currently downloadable. It is written in three places and
# nothing kept them in sync: a stale CLI constant (0.1.4 against an app already
# at 0.2.0) surfaced only when `release.sh` refused to package the release.
BUILD_SCRIPT = ROOT / "scripts" / "build_app.sh"
CLI_SOURCE = ROOT / "Sources" / "BarShelfCLI" / "BarShelfKit" / "BarShelfMain.swift"
NOTES = ROOT / "RELEASE_NOTES.md"

APP_VERSION = re.compile(r"^APP_VERSION=\$\{APP_VERSION:-([0-9][^}]*)\}", re.MULTILINE)
CLI_VERSION = re.compile(r'public static let version = "([^"]+)"')
NOTES_VERSION = re.compile(r"^#\s*BarShelf\s+([0-9][0-9A-Za-z.\-]*)", re.MULTILINE)

# Only "vX.Y.Z" — the form used to name a release. Bare numbers are left alone
# so macOS/Swift versions and shell examples do not trip the check.
DOC_VERSION = re.compile(r"\bv(\d+\.\d+\.\d+)\b")

# Other projects' versions that legitimately appear in these docs. Adding to
# this list should be a deliberate edit, not something that quietly passes —
# that is the whole point of failing on an unrecognized version.
EXTERNAL_VERSIONS = [
    "muxa v0.8.18",  # minimum remote muxa the muxa Watch widget talks to
]


def is_external(line: str, version: str) -> bool:
    return any(
        phrase.endswith(f"v{version}") and phrase in line
        for phrase in EXTERNAL_VERSIONS
    )


def main() -> int:
    if not RELEASED.exists():
        print(f"error: {RELEASED.name} is missing", file=sys.stderr)
        return 1
    current = RELEASED.read_text().strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", current):
        print(f"error: {RELEASED.name} does not hold a version: {current!r}", file=sys.stderr)
        return 1

    problems: list[str] = []
    for name in CHECKED:
        path = ROOT / name
        if not path.exists():
            problems.append(f"{name}: missing")
            continue
        for number, line in enumerate(path.read_text().splitlines(), start=1):
            for found in DOC_VERSION.findall(line):
                if found != current and not is_external(line, found):
                    problems.append(
                        f"{name}:{number}: advertises v{found}, "
                        f"but the current release is v{current}"
                    )

    development_problems = check_development_version()

    if problems or development_problems:
        print("error: version references are out of sync", file=sys.stderr)
        for problem in problems + development_problems:
            print(f"  {problem}", file=sys.stderr)
        if problems:
            print(
                "\nThe docs advertise a build that is not the current release:"
                "\neither cut it (see docs/RELEASING.md) or correct the docs.",
                file=sys.stderr,
            )
        if development_problems:
            print(
                "\nThe app, the CLI and the release notes have to agree on the"
                "\nversion this tree builds, or release.sh refuses to package it.",
                file=sys.stderr,
            )
        return 1

    print(f"ok: docs advertise v{current}, the released build")
    return 0


def check_development_version() -> list[str]:
    """The app, the CLI and the release notes must agree on the next version."""
    found: dict[str, str | None] = {}
    for label, path, pattern in [
        ("scripts/build_app.sh (APP_VERSION)", BUILD_SCRIPT, APP_VERSION),
        ("Sources/BarShelfCLI/BarShelfKit/BarShelfMain.swift", CLI_SOURCE, CLI_VERSION),
        ("RELEASE_NOTES.md", NOTES, NOTES_VERSION),
    ]:
        if not path.exists():
            found[label] = None
            continue
        match = pattern.search(path.read_text())
        found[label] = match.group(1) if match else None

    missing = [label for label, value in found.items() if value is None]
    if missing:
        return [f"{label}: no version found" for label in missing]

    distinct = set(found.values())
    if len(distinct) == 1:
        print(f"ok: this tree builds v{distinct.pop()} consistently")
        return []
    return ["in-development version disagrees:"] + [
        f"  {label}: {value}" for label, value in found.items()
    ]


if __name__ == "__main__":
    sys.exit(main())

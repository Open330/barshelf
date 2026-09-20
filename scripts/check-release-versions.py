#!/usr/bin/env python3
"""Fails when the docs advertise a BarShelf release that is not the current one.

The repo once shipped a README promising "the current v0.1.4 build is Developer
ID signed, notarized, and stapled" while the newest release — and the cask, and
every other doc — was v0.1.3. Anyone following the README looked for an asset
that did not exist, and anyone running that unreleased build was told forever
that they were up to date.

The Homebrew cask is the source of truth here: `scripts/release.sh` rewrites its
`version`/`sha256` only after a notarized public release exists, so whatever it
says is genuinely downloadable. Every `vX.Y.Z` reference in the user-facing docs
has to match it.

Run directly, or via CI. Exits non-zero with the offending file:line.
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CASK = ROOT / "Casks" / "barshelf.rb"
# Files that tell a user which build to download.
CHECKED = ["README.md", "docs/INSTALL.md", "site/index.html"]

CASK_VERSION = re.compile(r'^\s*version\s+"([^"]+)"', re.MULTILINE)
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
    match = CASK_VERSION.search(CASK.read_text())
    if not match:
        print(f"error: no version found in {CASK.relative_to(ROOT)}", file=sys.stderr)
        return 1
    current = match.group(1)

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

    if problems:
        print("error: release version references are out of sync", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(
            "\nEither cut that release (see docs/RELEASING.md) or correct the docs.",
            file=sys.stderr,
        )
        return 1

    print(f"ok: docs advertise v{current}, matching the cask")
    return 0


if __name__ == "__main__":
    sys.exit(main())

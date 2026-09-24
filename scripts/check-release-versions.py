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

import json
import pathlib
import re
import subprocess
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
#
# Deliberately not `\bv...\b`. A trailing `\b` needs a non-word character
# after the version, and Korean is word characters to `re`: "v0.2.1은" has no
# boundary after the 1, so every version carrying a Korean particle was
# invisible to this check. Most of this project's docs are Korean, and one such
# line had been advertising a superseded release on the live site.
DOC_VERSION = re.compile(r"(?<![\w.])v(\d+\.\d+\.\d+)(?!\d)")

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
    widget_problems = check_widget_versions(current) + check_registry_versions()

    if problems or development_problems or widget_problems:
        print("error: version references are out of sync", file=sys.stderr)
        for problem in problems + development_problems + widget_problems:
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
        if widget_problems:
            print(
                "\nA widget whose version does not move with its files is a"
                "\nchange that reaches nobody: the app replaces an installed"
                "\nwidget only when the bundled copy declares a newer version,"
                "\nand the gallery offers an update only when the registry"
                "\ndoes. Bump `version` in the widget's widget.json and copy it"
                "\ninto registry/index.json.",
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


def check_registry_versions() -> list[str]:
    """A bundled widget's registry entry has to declare the version it ships.

    The gallery offers an update when the *registry* is newer than what is
    installed, so a registry stuck behind the widget can never offer one. Both
    bundled entries had drifted — the registry said Sensors 0.1.0 against a
    widget at 0.3.0, so the card's Update button could not appear at all.
    """
    index = ROOT / "registry" / "index.json"
    if not index.exists():
        return ["registry/index.json: missing"]
    entries = json.loads(index.read_text()).get("widgets", [])

    problems: list[str] = []
    checked = 0
    for entry in entries:
        bundled = (entry.get("install") or {}).get("bundled")
        if not bundled:
            continue  # installed from a URL — the archive carries its version
        manifest = ROOT / "widgets" / bundled / "widget.json"
        if not manifest.exists():
            problems.append(
                f"registry/index.json: {entry.get('id')} installs bundled "
                f"\"{bundled}\", which is not in widgets/"
            )
            continue
        checked += 1
        widget = json.loads(manifest.read_text())
        shipped = widget.get("version")
        # The gallery reads this to hold back an update the host would refuse.
        if entry.get("minHostVersion") != widget.get("minHostVersion"):
            problems.append(
                f"registry/index.json: {entry.get('id')} minHostVersion is "
                f"{entry.get('minHostVersion')}, widgets/{bundled} declares {widget.get('minHostVersion')}"
            )
        if entry.get("version") != shipped:
            problems.append(
                f"registry/index.json: {entry.get('id')} says "
                f"{entry.get('version')}, widgets/{bundled} ships {shipped}"
            )
    if not problems:
        print(f"ok: {checked} bundled registry entries match their widgets")
    return problems


def check_widget_versions(released: str) -> list[str]:
    """A changed widget has to declare a new version, or the change is inert.

    Widget behaviour is data. The app refreshes an installed widget from its
    own bundle only when the bundled copy declares a *newer* version, so a
    fix to `workflow.json` that forgets `version` ships in the release and
    then reaches nobody — which is exactly how the Sensors widget spent a day
    showing a decimal on one Mac that had been "updated" twice.
    """
    tag = f"v{released}"
    if subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", f"{tag}^{{commit}}"],
        cwd=ROOT, capture_output=True,
    ).returncode != 0:
        # Shallow clone or a tree without tags: nothing to compare against.
        print(f"skip: no {tag} tag to compare widget versions against")
        return []

    # Against the working tree, not HEAD: the version lives in a file this
    # check reads from disk, so comparing commits would pass a tree whose
    # widget.json was edited back down after the commit.
    changed = subprocess.run(
        ["git", "diff", "--name-only", tag, "--", "widgets/"],
        cwd=ROOT, capture_output=True, text=True, check=True,
    ).stdout.split()
    names = sorted({
        pathlib.PurePosixPath(path).parts[1]
        for path in changed
        if len(pathlib.PurePosixPath(path).parts) > 2
    })
    if not names:
        print("ok: no widget changed since the last release")
        return []

    problems: list[str] = []
    checked = 0
    for name in names:
        manifest = ROOT / "widgets" / name / "widget.json"
        if not manifest.exists():
            continue  # removed widget
        released_manifest = subprocess.run(
            ["git", "show", f"{tag}:widgets/{name}/widget.json"],
            cwd=ROOT, capture_output=True, text=True,
        )
        if released_manifest.returncode != 0:
            continue  # new widget — any version is a first version
        checked += 1
        before = json.loads(released_manifest.stdout).get("version")
        after = json.loads(manifest.read_text()).get("version")
        if after is None:
            problems.append(f"widgets/{name}/widget.json: no version declared")
        elif before == after:
            problems.append(
                f"widgets/{name}: files changed since {tag} but version is "
                f"still {after}"
            )
    if not problems and checked:
        print(f"ok: {checked} changed widget(s) declare a new version")
    return problems


if __name__ == "__main__":
    sys.exit(main())

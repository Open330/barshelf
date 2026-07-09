#!/usr/bin/env python3
"""Regenerate Sources/MbkCLI/MbkKit/AgentSpecEmbedded.swift from docs/AGENTS.md.

`mbk agent-spec` prefers the on-disk docs/AGENTS.md (dev checkout) and falls
back to the embedded copy this script produces, so the standalone release
binary (which ships no resources) still prints the full spec. Run this whenever
docs/AGENTS.md changes:

    python3 scripts/gen-agent-spec.py
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOC = ROOT / "docs" / "AGENTS.md"
OUT = ROOT / "Sources" / "MbkCLI" / "MbkKit" / "AgentSpecEmbedded.swift"
DELIM = "#####"


def main() -> int:
    content = DOC.read_text()
    if (DELIM + '"""') in content or ('"""' + DELIM) in content:
        print("error: raw-string delimiter collides with doc content", file=sys.stderr)
        return 1
    lines = [
        "// Generated from docs/AGENTS.md by scripts/gen-agent-spec.py (do not edit by hand).",
        "// `mbk agent-spec` prints the on-disk docs/AGENTS.md when found (dev checkout),",
        "// otherwise this embedded copy - so the packaged bare binary still works.",
        "",
        "enum AgentSpecEmbedded {",
        f'    static let markdown = {DELIM}"""',
        content.rstrip("\n"),
        f'"""{DELIM}',
        "}",
    ]
    _ = OUT.write_text("\n".join(lines) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)} ({len(content)} bytes of markdown)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Read BarShelf's process counters without launching or changing the app."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def command(*args):
    return subprocess.run(
        args, check=True, capture_output=True, text=True,
        env={**os.environ, "LC_ALL": "C", "TZ": "UTC"},
    ).stdout


def duration_seconds(value):
    days, separator, clock = value.partition("-")
    if not separator:
        days, clock = "0", days
    seconds = 0.0
    for field in clock.split(":"):
        seconds = seconds * 60 + float(field)
    return round(int(days) * 86400 + seconds, 2)


def processes(executable):
    matches = {"app": [], "helper": []}
    app_command = str(executable)
    uid = str(os.geteuid())
    helper_command = re.compile(re.escape(app_command) + r" automation-helper --app-pid [0-9]+")
    for line in command("/bin/ps", "-Aww", "-o", "pid=,uid=,lstart=,etime=,cputime=,command=").splitlines():
        fields = line.split(maxsplit=9)
        if len(fields) != 10 or fields[1] != uid:
            continue
        invocation = fields[9].rstrip()
        if invocation == app_command:
            role = "app"
        elif helper_command.fullmatch(invocation):
            # An adopted helper still has its original owner's PID in argv.
            role = "helper"
        else:
            continue
        matches[role].append({
            "pid": int(fields[0]),
            "started_at_utc": " ".join(fields[2:7]),
            "elapsed_seconds": int(duration_seconds(fields[7])),
            "cpu_seconds": duration_seconds(fields[8]),
            "phys_footprint_bytes": None,
        })

    for role, candidates in matches.items():
        if len(candidates) > 1:
            raise ValueError(f"Multiple BarShelf {role} processes match {executable}")
    if not matches["app"]:
        raise ValueError(f"BarShelf is not running from {executable} for this user")
    return {role: candidates[0] for role, candidates in matches.items() if candidates}


def identities(readings):
    return {role: (reading["pid"], reading["started_at_utc"]) for role, reading in readings.items()}


def footprint_bytes(pid):
    try:
        output = command("/usr/bin/footprint", "-f", "bytes", str(pid))
        match = re.search(r"^\s*phys_footprint:\s*([0-9]+)\s+B\s*$", output, re.MULTILINE)
        if match:
            return int(match[1])
    except subprocess.CalledProcessError:
        pass
    print(f"Physical footprint unavailable for PID {pid}", file=sys.stderr)
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path("/Applications/BarShelf.app"),
                        help="installed bundle path (default: %(default)s)")
    parser.add_argument("--cpu-only", action="store_true", help="skip footprint collection")
    args = parser.parse_args()
    bundle = args.app.resolve()
    executable = bundle / "Contents/MacOS/barshelf-app"
    try:
        with (bundle / "Contents/Info.plist").open("rb") as info:
            build = plistlib.load(info)
        sampled_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
        readings = processes(executable)
        if not args.cpu_only:
            for reading in readings.values():
                reading["phys_footprint_bytes"] = footprint_bytes(reading["pid"])
            if identities(readings) != identities(processes(executable)):
                raise ValueError("BarShelf process identities changed during collection. Retake the snapshot.")
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{parser.prog}: {error}\n")

    footprints = [reading["phys_footprint_bytes"] for reading in readings.values()]
    print(json.dumps({
        "sampled_at_utc": sampled_at,
        "bundle": str(bundle),
        "version": build.get("CFBundleShortVersionString"),
        "source_commit": build.get("BarShelfSourceCommit"),
        "app": readings["app"],
        "helper": readings.get("helper"),
        "total_cpu_seconds": round(sum(reading["cpu_seconds"] for reading in readings.values()), 2),
        "total_phys_footprint_bytes": sum(footprints) if None not in footprints else None,
    }, indent=2))


if __name__ == "__main__":
    main()

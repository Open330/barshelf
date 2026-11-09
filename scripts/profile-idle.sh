#!/usr/bin/env bash
# Where BarShelf spends its time when nobody is using it.
#
#   scripts/profile-idle.sh [seconds] [symbols-binary]
#
# TOP=n lists n functions (default 30); KEEP_TRACE=path keeps the trace for
# Instruments.
#
# Attaches to the running app without touching the screen or the keyboard:
# measures its CPU over the window (from its CPU time, not a single `top`
# sample), records a Time Profiler trace for the same window, and prints the
# app's own functions by the share of samples they appear in.
#
# A release build is stripped. To name its functions, pass an unstripped
# build of the same commit: `swift build -c release --product barshelf-app`
# in a checkout of the release tag lays its code out identically (the
# script checks the __text section matches before trusting the names).
set -euo pipefail

SECONDS_TO_RECORD=${1:-60}
SYMBOLS=${2:-}
APP_BIN=/Applications/BarShelf.app/Contents/MacOS/barshelf-app
PID=$(pgrep -x barshelf-app || true)
[[ -n "${PID}" ]] || { echo "BarShelf is not running" >&2; exit 1; }

WORK=$(mktemp -d)
trap '[[ -n "${KEEP_TRACE:-}" && -e "${WORK}/idle.trace" ]] && rm -rf "${KEEP_TRACE}" && mv "${WORK}/idle.trace" "${KEEP_TRACE}"; rm -rf "${WORK}"' EXIT

cpu_seconds() { /bin/ps -o cputime= -p "${PID}" | awk -F'[:.]' '{ print $1 * 60 + $2 + $3 / 100 }'; }

before=$(cpu_seconds)
xcrun xctrace record --template "Time Profiler" --attach "${PID}" \
  --time-limit "${SECONDS_TO_RECORD}s" --output "${WORK}/idle.trace" --no-prompt >/dev/null
after=$(cpu_seconds)
echo "BarShelf $(defaults read /Applications/BarShelf.app/Contents/Info CFBundleShortVersionString) (pid ${PID})"
awk -v a="${before}" -v b="${after}" -v s="${SECONDS_TO_RECORD}" \
  'BEGIN { printf "CPU over %ss: %.2f%% (%.0f ms)\n", s, (b - a) / s * 100, (b - a) * 1000 }'
echo "Footprint: $(/usr/bin/footprint "${PID}" 2>/dev/null | awk '/phys_footprint:/ { print $2, $3; exit }')"

xcrun xctrace export --input "${WORK}/idle.trace" \
  --xpath '/trace-toc/run/data/table[@schema="time-profile"]' > "${WORK}/profile.xml"

if [[ -n "${SYMBOLS}" ]]; then
  text() { size -m -l "$1" | awk '/Section __text:/ { print $3, $5 }'; }
  [[ "$(text "${APP_BIN}")" == "$(text "${SYMBOLS}")" ]] \
    || { echo "warning: ${SYMBOLS} is laid out differently; names would be wrong" >&2; SYMBOLS=""; }
fi

TOP=${TOP:-30} python3 - "${WORK}/profile.xml" "${SYMBOLS}" <<'PY'
import collections, os, subprocess, sys, xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
symbols = sys.argv[2]
ids = {e.get("id"): e for e in root.iter() if e.get("id")}
deref = lambda e: ids.get(e.get("ref"), e) if e is not None and e.get("ref") else e

samples, addresses, load = [], set(), None
for row in root.iter("row"):
    trace = deref(row.find("tagged-backtrace") if row.find("tagged-backtrace") is not None else row.find("backtrace"))
    if trace is None:
        continue
    frames = []
    for frame in trace.findall("frame"):
        frame = deref(frame)
        binary = frame.find("binary")
        binary = deref(binary) if binary is not None else None
        name = frame.get("name", "?")
        if binary is not None and binary.get("name") == "barshelf-app":
            load = binary.get("load-addr")
            if name.startswith("0x"):
                addresses.add(frame.get("addr"))
                name = ("app", frame.get("addr"))
        frames.append(name)
    samples.append(frames)

names = {}
if symbols and addresses and load:
    ordered = sorted(addresses)
    out = subprocess.run(["atos", "-o", symbols, "-arch", "arm64", "-l", load, *ordered],
                         capture_output=True, text=True).stdout.splitlines()
    demangled = subprocess.run(["swift", "demangle", "--simplified"], input="\n".join(out),
                               capture_output=True, text=True).stdout.splitlines()
    names = dict(zip(ordered, demangled))

def label(frame):
    if isinstance(frame, tuple):
        return names.get(frame[1], frame[1]).split(" (in ")[0][:110]
    return frame[:110]

inclusive = collections.Counter()
for frames in samples:
    for name in {label(f) for f in frames if isinstance(f, tuple) or "NSStatusItem" in f}:
        inclusive[name] += 1
print(f"\n{len(samples)} samples (1 ms each). App functions and status item work, by share of samples:")
for name, count in inclusive.most_common(int(os.environ.get("TOP", "30"))):
    print(f"{count / max(len(samples), 1) * 100:5.1f}%  {name}")
PY

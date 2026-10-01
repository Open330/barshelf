#!/usr/bin/env bash
# Sync Localization/Localizable.xcstrings with the strings the app's UI uses.
#
#   bash scripts/sync-strings.sh           update the catalog in place
#   bash scripts/sync-strings.sh --check   fail if the catalog is out of date
#
# Strings come from the compiler (`-emit-localized-strings`), not from a text
# scan: only the compiler knows that `Text("\(count) installed")` looks up the
# key "%lld installed", and a scanner's guess never matches at runtime.
#
# Translations are added in the catalog (Xcode's editor, or by hand). This
# script only adds new source strings and marks removed ones stale; it never
# touches a translation. `build_app.sh` compiles the catalog into the app.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CATALOG="${ROOT}/Localization/Localizable.xcstrings"
# A scratch build of its own: the compiler only emits strings for files it
# recompiles, so the data directory persists next to that build and is
# refreshed file by file.
SCRATCH="${ROOT}/.build/strings"
DATA="${SCRATCH}/stringsdata"
mkdir -p "${DATA}"

if ! log=$(swift build --package-path "${ROOT}" --target MenubucketApp --scratch-path "${SCRATCH}" \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "${DATA}" 2>&1); then
  echo "${log}" >&2
  exit 1
fi

# Only the app's own sources: MenubucketCore's messages are not UI text, and
# a file that no longer exists must not keep its strings alive.
files=()
while IFS= read -r source; do
  name=$(basename "${source}" .swift)
  [[ -f "${DATA}/${name}.stringsdata" ]] && files+=("${DATA}/${name}.stringsdata")
done < <(find "${ROOT}/Sources/MenubucketApp" -name '*.swift' | sort)

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
# `sync` takes the table name from the catalog's file name.
if [[ -f "${CATALOG}" ]]; then
  cp "${CATALOG}" "${WORK}/Localizable.xcstrings"
else
  echo '{"sourceLanguage":"en","strings":{},"version":"1.0"}' > "${WORK}/Localizable.xcstrings"
fi
xcrun xcstringstool sync "${WORK}/Localizable.xcstrings" --stringsdata "${files[@]}"
# Stable key order and formatting, so a sync that changes nothing shows no diff.
python3 - "${WORK}/Localizable.xcstrings" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    catalog = json.load(f)
with open(path, "w") as f:
    json.dump(catalog, f, indent=2, sort_keys=True, ensure_ascii=False)
    f.write("\n")
PY

if [[ "${1:-}" == "--check" ]]; then
  if ! cmp -s "${WORK}/Localizable.xcstrings" "${CATALOG}"; then
    echo "error: Localization/Localizable.xcstrings is out of date; run scripts/sync-strings.sh" >&2
    exit 1
  fi
  echo "ok: string catalog matches the source"
else
  mkdir -p "$(dirname "${CATALOG}")"
  mv "${WORK}/Localizable.xcstrings" "${CATALOG}"
  count=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['strings']))" "${CATALOG}")
  echo "Synced ${count} strings into ${CATALOG#"${ROOT}/"}"
fi

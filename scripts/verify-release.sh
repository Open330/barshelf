#!/usr/bin/env bash
# Verifies a published GitHub Release the way a user's Mac will see it.
#
# The release is built and signed on a developer's machine, so CI never sees
# the signing key and cannot vouch for the build beforehand. What it *can* do is
# check the artifact after the fact — which catches the failures that actually
# happen: forgot to notarize, uploaded a stale zip, checksums not regenerated,
# version in the bundle not the version in the tag.
#
# It also asserts the exact property BarShelf's in-app updater requires before
# it will replace anything, so a release that clients would silently refuse
# fails here instead.
#
#   scripts/verify-release.sh v0.2.0
#
# EXPECTED_TEAM (optional): fail unless the assets are signed by this Team ID.
set -euo pipefail

TAG=${1:-}
if [[ -z "${TAG}" ]]; then
  echo "usage: scripts/verify-release.sh <tag>   (e.g. v0.2.0)" >&2
  exit 2
fi
VERSION=${TAG#v}
REPO=${REPO:-Open330/barshelf}
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

APP_ZIP="BarShelf-${VERSION}-arm64.zip"
CLI_TAR="barshelf-cli-${VERSION}-arm64.tar.gz"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

echo "Verifying ${REPO} ${TAG}"
gh release download "${TAG}" --repo "${REPO}" --dir "${WORK}" \
  --pattern "${APP_ZIP}" --pattern "${CLI_TAR}" --pattern "SHA256SUMS" \
  || fail "could not download the release assets"

for asset in "${APP_ZIP}" "${CLI_TAR}" SHA256SUMS; do
  [[ -f "${WORK}/${asset}" ]] || fail "missing asset: ${asset}"
done
ok "all three assets are published"

# --- checksums -------------------------------------------------------------
( cd "${WORK}" && shasum -a 256 -c SHA256SUMS ) >/dev/null \
  || fail "SHA256SUMS does not match the published assets"
ok "SHA256SUMS matches"

# --- expand ----------------------------------------------------------------
# ditto, because the signature is computed over extended attributes a generic
# unzip drops.
ditto -x -k "${WORK}/${APP_ZIP}" "${WORK}/app" || fail "could not expand ${APP_ZIP}"
APP="${WORK}/app/BarShelf.app"
[[ -d "${APP}" ]] || fail "${APP_ZIP} does not contain BarShelf.app at its root"
ok "archive contains BarShelf.app at its root (the layout the updater expects)"

# --- version ---------------------------------------------------------------
BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "${APP}/Contents/Info.plist" 2>/dev/null || echo "")
[[ "${BUNDLE_VERSION}" == "${VERSION}" ]] \
  || fail "bundle reports ${BUNDLE_VERSION:-nothing}, tag says ${VERSION}"
ok "bundle version matches the tag (${VERSION})"

COMMIT=$(/usr/libexec/PlistBuddy -c "Print :BarShelfSourceCommit" \
  "${APP}/Contents/Info.plist" 2>/dev/null || echo "")
case "${COMMIT}" in
  "") echo "warning: no BarShelfSourceCommit — this build predates provenance" >&2 ;;
  *-dirty) fail "built from a dirty working tree (${COMMIT})" ;;
  unknown) fail "built outside a git checkout" ;;
  *) ok "built from commit ${COMMIT}" ;;
esac

# --- signature -------------------------------------------------------------
codesign --verify --deep --strict --verbose=2 "${APP}" 2>/dev/null \
  || fail "code signature is not valid"
ok "code signature is valid"

TEAM=$(codesign -dv --verbose=2 "${APP}" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[[ -n "${TEAM}" && "${TEAM}" != "not set" ]] || fail "no Team ID — the build is ad-hoc signed"
if [[ -n "${EXPECTED_TEAM:-}" && "${TEAM}" != "${EXPECTED_TEAM}" ]]; then
  fail "signed by team ${TEAM}, expected ${EXPECTED_TEAM}"
fi
ok "signed by team ${TEAM}"

# The requirement BarShelf's own updater enforces. If this fails, every client
# refuses the update and falls back to the download page.
REQUIREMENT="anchor apple generic \
and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
and certificate leaf[subject.OU] = \"${TEAM}\""
codesign --verify --strict --requirements "=${REQUIREMENT}" "${APP}" 2>/dev/null \
  || fail "does not satisfy the Developer ID requirement the in-app updater enforces"
ok "satisfies the Developer ID requirement the in-app updater enforces"

# --- notarization ----------------------------------------------------------
xcrun stapler validate "${APP}" >/dev/null 2>&1 \
  || fail "no stapled notarization ticket"
ok "notarization ticket is stapled"

spctl --assess --type execute "${APP}" >/dev/null 2>&1 \
  || fail "Gatekeeper rejects the app"
ok "Gatekeeper accepts the app"

# --- CLI -------------------------------------------------------------------
# `barshelf upgrade` extracts these two by member name from the root of the
# tarball, and pins them to the same Developer ID requirement the app uses.
# A standalone Mach-O cannot carry a stapled ticket, so this requirement — plus
# the CDHash cross-check release.sh does against the notarization log — is the
# whole of what a client can verify.
tar -xzf "${WORK}/${CLI_TAR}" -C "${WORK}" || fail "could not expand ${CLI_TAR}"
for binary in barshelf bsf; do
  [[ -f "${WORK}/${binary}" ]] || fail "${CLI_TAR} is missing ${binary} at its root"
  codesign --verify --strict "${WORK}/${binary}" 2>/dev/null \
    || fail "${binary} is not validly signed"
  codesign --verify --strict --requirements "=${REQUIREMENT}" "${WORK}/${binary}" 2>/dev/null \
    || fail "${binary} does not satisfy the Developer ID requirement \`barshelf upgrade\` enforces"
  CLI_VERSION=$("${WORK}/${binary}" --version | awk '{print $2}')
  [[ "${CLI_VERSION}" == "${VERSION}" ]] \
    || fail "${binary} reports ${CLI_VERSION}, not ${VERSION} (stale upload?)"
done
ok "both CLI binaries are signed, pinned, and report ${VERSION}"

# --- Homebrew tap ----------------------------------------------------------
# The cask and the formula live in Open330/homebrew-tap, and a release that
# does not reach them leaves Homebrew users with no update path: BarShelf
# refuses to replace a Homebrew-installed copy (correctly — it would desync
# brew's records) and points at `brew upgrade`, which then reports they are
# already current. That is exactly how both files sat at 0.1.3 while the
# project shipped 0.3.0, so it is checked rather than remembered.
TAP_RAW="https://raw.githubusercontent.com/Open330/homebrew-tap/main"
tap_version() {
  curl -fsSL "${TAP_RAW}/$1" 2>/dev/null \
    | sed -n 's/^[[:space:]]*version "\([^"]*\)".*/\1/p' | head -n 1
}
TAP_CASK_VERSION=$(tap_version "Casks/barshelf.rb")
TAP_FORMULA_VERSION=$(tap_version "Formula/barshelf-cli.rb")
for pair in "cask:${TAP_CASK_VERSION}" "formula:${TAP_FORMULA_VERSION}"; do
  what="${pair%%:*}"
  found="${pair#*:}"
  [[ -n "${found}" ]] || fail "could not read the tap's ${what} version"
  [[ "${found}" == "${VERSION}" ]] \
    || fail "the tap's ${what} is at ${found}, not ${VERSION} — Homebrew users have no update path until it is bumped (see .github/workflows/tap-bump.yml)"
done
ok "the Homebrew tap's cask and formula are at ${VERSION}"

echo
echo "${TAG} verified: a Mac will install this."

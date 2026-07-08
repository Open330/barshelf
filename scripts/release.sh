#!/usr/bin/env bash
# Packages a GitHub Release payload: MenuBucket-<ver>-<arch>.zip (.app) and
# mbk-<ver>-<arch>.tar.gz, plus SHA256SUMS. Run scripts/build_app.sh first
# (this script runs it if dist/ is missing).
#
# Signing: uses ad-hoc identity unless CODESIGN_IDENTITY is set to a
# "Developer ID Application: …" cert (then notarization becomes possible;
# see docs/INSTALL.md).
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${PROJECT_ROOT}/dist"
RELEASE_DIR="${DIST_DIR}/release"
ARCH="$(uname -m)"

VERSION=${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "${DIST_DIR}/MenuBucket.app/Contents/Info.plist" 2>/dev/null || echo "0.1.0")}

if [[ ! -d "${DIST_DIR}/MenuBucket.app" || ! -x "${DIST_DIR}/mbk" ]]; then
  bash "${PROJECT_ROOT}/scripts/build_app.sh"
fi

rm -rf "${RELEASE_DIR}"
mkdir -p "${RELEASE_DIR}"

APP_ZIP="${RELEASE_DIR}/MenuBucket-${VERSION}-${ARCH}.zip"
MBK_TAR="${RELEASE_DIR}/mbk-${VERSION}-${ARCH}.tar.gz"

# ditto preserves resource forks, permissions, and code signatures.
ditto -c -k --keepParent "${DIST_DIR}/MenuBucket.app" "${APP_ZIP}"
tar -czf "${MBK_TAR}" -C "${DIST_DIR}" mbk

(cd "${RELEASE_DIR}" && shasum -a 256 ./*.zip ./*.tar.gz > SHA256SUMS)

echo "Release payload at ${RELEASE_DIR}:"
ls -la "${RELEASE_DIR}"

#!/usr/bin/env bash
# Packages a GitHub Release payload: MenuBucket-<ver>-<arch>.zip (.app) and
# mbk-<ver>-<arch>.tar.gz, plus SHA256SUMS. Run scripts/build_app.sh first
# (this script runs it if dist/ is missing).
#
# Signing: uses ad-hoc identity unless SIGN_IDENTITY is set to a
# "Developer ID Application: …" cert. With SIGN_IDENTITY set, NOTARIZE=1
# submits the zip to Apple notary service and staples the ticket.
# Notary credentials (env or ~/.appstoreconnect):
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (default:
#   ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8)
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

if [[ "${NOTARIZE:-0}" == "1" ]]; then
  if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    echo "error: NOTARIZE=1 requires SIGN_IDENTITY (Developer ID Application cert)" >&2
    exit 1
  fi
  ASC_KEY_ID=${ASC_KEY_ID:?set ASC_KEY_ID}
  ASC_ISSUER_ID=${ASC_ISSUER_ID:?set ASC_ISSUER_ID}
  ASC_KEY_PATH=${ASC_KEY_PATH:-"${HOME}/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"}

  echo "Submitting ${APP_ZIP} to Apple notary service (waits for result)…"
  xcrun notarytool submit "${APP_ZIP}" \
    --key "${ASC_KEY_PATH}" --key-id "${ASC_KEY_ID}" --issuer "${ASC_ISSUER_ID}" \
    --wait

  echo "Stapling ticket to ${DIST_DIR}/MenuBucket.app"
  xcrun stapler staple "${DIST_DIR}/MenuBucket.app"

  # Re-zip so the shipped archive contains the stapled bundle.
  rm -f "${APP_ZIP}"
  ditto -c -k --keepParent "${DIST_DIR}/MenuBucket.app" "${APP_ZIP}"
fi

(cd "${RELEASE_DIR}" && shasum -a 256 ./*.zip ./*.tar.gz > SHA256SUMS)

echo "Release payload at ${RELEASE_DIR}:"
ls -la "${RELEASE_DIR}"

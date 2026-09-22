#!/usr/bin/env bash
# Builds and packages a GitHub Release payload: BarShelf-<ver>-<arch>.zip
# (.app) and barshelf-cli-<ver>-<arch>.tar.gz, plus SHA256SUMS.
#
# Public releases are fail-closed: VERSION, a Developer ID Application
# identity, and notarization credentials are required. For a local-only
# unsigned package, opt in explicitly with NOTARIZE=0 ALLOW_UNNOTARIZED=1.
# Notary credentials (env or ~/.appstoreconnect):
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (default:
#   ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8)
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${PROJECT_ROOT}/dist"
ARCH="$(uname -m)"
APP_DISPLAY_NAME=${APP_DISPLAY_NAME:-BarShelf}
APP_BUNDLE_NAME=${APP_BUNDLE_NAME:-"${APP_DISPLAY_NAME}.app"}
APP_BUNDLE_PATH="${DIST_DIR}/${APP_BUNDLE_NAME}"
NOTARIZE=${NOTARIZE:-1}
ALLOW_UNNOTARIZED=${ALLOW_UNNOTARIZED:-0}

VERSION=${VERSION:-}
if [[ -z "${VERSION}" ]]; then
  echo "error: set VERSION explicitly (for example VERSION=0.1.3)" >&2
  exit 1
fi
if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "error: VERSION must be a release version such as 0.1.3: ${VERSION}" >&2
  exit 1
fi
if [[ "${ARCH}" != "arm64" ]]; then
  echo "error: public BarShelf releases currently support arm64 only (host: ${ARCH})" >&2
  exit 1
fi

if [[ "${NOTARIZE}" == "1" ]]; then
  if [[ -z "${SIGN_IDENTITY:-}" || "${SIGN_IDENTITY}" == "-" ]]; then
    echo "error: a Developer ID Application SIGN_IDENTITY is required" >&2
    exit 1
  fi
  ASC_KEY_ID=${ASC_KEY_ID:?set ASC_KEY_ID}
  ASC_ISSUER_ID=${ASC_ISSUER_ID:?set ASC_ISSUER_ID}
  ASC_KEY_PATH=${ASC_KEY_PATH:-"${HOME}/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"}
  if [[ ! -f "${ASC_KEY_PATH}" ]]; then
    echo "error: App Store Connect key not found: ${ASC_KEY_PATH}" >&2
    exit 1
  fi
  RELEASE_DIR=${RELEASE_DIR:-"${DIST_DIR}/release"}
elif [[ "${ALLOW_UNNOTARIZED}" == "1" ]]; then
  echo "warning: creating a local-only unnotarized package" >&2
  SIGN_IDENTITY=${SIGN_IDENTITY:--}
  RELEASE_DIR=${RELEASE_DIR:-"${DIST_DIR}/local-release"}
else
  echo "error: public releases require NOTARIZE=1; for local packaging only, set NOTARIZE=0 ALLOW_UNNOTARIZED=1" >&2
  exit 1
fi

# A public release must be reproducible from a commit anyone can check out.
# Only the notarized path is gated: `ALLOW_UNNOTARIZED=1` exists precisely for
# local packaging, where iterating on a dirty tree is the whole point.
if [[ "${NOTARIZE}" == "1" ]]; then
  if ! git -C "${PROJECT_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
    echo "error: public releases must be built from a git checkout" >&2
    exit 1
  fi
  if [[ -n "$(git -C "${PROJECT_ROOT}" status --porcelain)" ]]; then
    echo "error: the working tree has uncommitted changes." >&2
    echo "       A published binary has to correspond to a commit; otherwise" >&2
    echo "       nobody can reproduce or audit what was shipped." >&2
    git -C "${PROJECT_ROOT}" status --short >&2
    exit 1
  fi
  RELEASE_TAG="v${VERSION}"
  if ! git -C "${PROJECT_ROOT}" rev-parse -q --verify "refs/tags/${RELEASE_TAG}" >/dev/null; then
    echo "error: tag ${RELEASE_TAG} does not exist." >&2
    echo "       Tag first, then build, so the artifact provably comes from it:" >&2
    echo "         git tag -a ${RELEASE_TAG} -m \"BarShelf ${VERSION}\"" >&2
    exit 1
  fi
  TAGGED_COMMIT=$(git -C "${PROJECT_ROOT}" rev-parse "${RELEASE_TAG}^{commit}")
  HEAD_COMMIT=$(git -C "${PROJECT_ROOT}" rev-parse HEAD)
  if [[ "${TAGGED_COMMIT}" != "${HEAD_COMMIT}" ]]; then
    echo "error: HEAD is not ${RELEASE_TAG}." >&2
    echo "       ${RELEASE_TAG} -> ${TAGGED_COMMIT}" >&2
    echo "       HEAD      -> ${HEAD_COMMIT}" >&2
    echo "       Check out the tag before building: git checkout ${RELEASE_TAG}" >&2
    exit 1
  fi
  echo "Releasing ${RELEASE_TAG} from ${HEAD_COMMIT}"
fi

# Always rebuild from the current source tree. Reusing dist/ can silently ship
# stale binaries, and APP_VERSION must exactly match the requested release.
APP_VERSION="${VERSION}" SIGN_IDENTITY="${SIGN_IDENTITY}" \
  bash "${PROJECT_ROOT}/scripts/build_app.sh"

BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "${APP_BUNDLE_PATH}/Contents/Info.plist")
CLI_VERSION=$("${DIST_DIR}/barshelf" --version | awk '{print $2}')
BSF_VERSION=$("${DIST_DIR}/bsf" --version | awk '{print $2}')
if [[ "${BUNDLE_VERSION}" != "${VERSION}" || "${CLI_VERSION}" != "${VERSION}" || "${BSF_VERSION}" != "${VERSION}" ]]; then
  echo "error: release version mismatch" >&2
  echo "  requested: ${VERSION}" >&2
  echo "  app:       ${BUNDLE_VERSION}" >&2
  echo "  barshelf:  ${CLI_VERSION}" >&2
  echo "  bsf:       ${BSF_VERSION}" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE_PATH}"
codesign --verify --strict --verbose=2 "${DIST_DIR}/barshelf"
codesign --verify --strict --verbose=2 "${DIST_DIR}/bsf"

if [[ "${NOTARIZE}" == "1" ]]; then
  for binary in "${APP_BUNDLE_PATH}" "${DIST_DIR}/barshelf" "${DIST_DIR}/bsf"; do
    SIGNATURE_DETAILS=$(codesign -dvv "${binary}" 2>&1)
    if ! grep -q '^Authority=Developer ID Application:' <<<"${SIGNATURE_DETAILS}"; then
      echo "error: not signed with Developer ID Application: ${binary}" >&2
      exit 1
    fi
  done
fi

rm -rf "${RELEASE_DIR}"
mkdir -p "${RELEASE_DIR}"

APP_ZIP="${RELEASE_DIR}/${APP_DISPLAY_NAME}-${VERSION}-${ARCH}.zip"
CLI_TAR="${RELEASE_DIR}/barshelf-cli-${VERSION}-${ARCH}.tar.gz"

# ditto preserves resource forks, permissions, and code signatures.
ditto -c -k --keepParent "${APP_BUNDLE_PATH}" "${APP_ZIP}"
tar -czf "${CLI_TAR}" -C "${DIST_DIR}" barshelf bsf

if [[ "${NOTARIZE}" == "1" ]]; then
  echo "Submitting ${APP_ZIP} to Apple notary service (waits for result)…"
  xcrun notarytool submit "${APP_ZIP}" \
    --key "${ASC_KEY_PATH}" --key-id "${ASC_KEY_ID}" --issuer "${ASC_ISSUER_ID}" \
    --wait

  # Standalone CLI binaries cannot carry a stapled ticket, but submitting the
  # exact signed binaries in a temporary zip registers their code hashes with
  # Apple's notary service. The shipped tar.gz contains those same bytes.
  CLI_NOTARY_DIR=$(mktemp -d "${RELEASE_DIR}/cli-notary.XXXXXX")
  CLI_NOTARY_ZIP="${RELEASE_DIR}/cli-notary.zip"
  cp "${DIST_DIR}/barshelf" "${DIST_DIR}/bsf" "${CLI_NOTARY_DIR}/"
  ditto -c -k "${CLI_NOTARY_DIR}" "${CLI_NOTARY_ZIP}"
  echo "Submitting signed CLI binaries to Apple notary service…"
  CLI_NOTARY_RESULT=$(xcrun notarytool submit "${CLI_NOTARY_ZIP}" \
    --key "${ASC_KEY_PATH}" --key-id "${ASC_KEY_ID}" --issuer "${ASC_ISSUER_ID}" \
    --wait --output-format json)
  CLI_SUBMISSION_ID=$(jq -er '.id' <<<"${CLI_NOTARY_RESULT}")
  CLI_NOTARY_STATUS=$(jq -er '.status' <<<"${CLI_NOTARY_RESULT}")
  echo "  id: ${CLI_SUBMISSION_ID}"
  echo "  status: ${CLI_NOTARY_STATUS}"
  if [[ "${CLI_NOTARY_STATUS}" != "Accepted" ]]; then
    echo "error: CLI notarization was not accepted" >&2
    exit 1
  fi
  CLI_NOTARY_LOG=$(mktemp "${RELEASE_DIR}/cli-notary-log.XXXXXX.json")
  xcrun notarytool log "${CLI_SUBMISSION_ID}" \
    --key "${ASC_KEY_PATH}" --key-id "${ASC_KEY_ID}" --issuer "${ASC_ISSUER_ID}" \
    "${CLI_NOTARY_LOG}" >/dev/null
  rm -rf "${CLI_NOTARY_DIR}" "${CLI_NOTARY_ZIP}"

  echo "Stapling ticket to ${APP_BUNDLE_PATH}"
  xcrun stapler staple "${APP_BUNDLE_PATH}"
  xcrun stapler validate "${APP_BUNDLE_PATH}"

  # Re-zip so the shipped archive contains the stapled bundle.
  rm -f "${APP_ZIP}"
  ditto -c -k --keepParent "${APP_BUNDLE_PATH}" "${APP_ZIP}"

  # Verify the exact archives that will be uploaded, not only the build tree.
  VERIFY_DIR=$(mktemp -d "${RELEASE_DIR}/verify.XXXXXX")
  trap 'rm -rf "${VERIFY_DIR}"' EXIT
  ditto -x -k "${APP_ZIP}" "${VERIFY_DIR}/app"
  mkdir -p "${VERIFY_DIR}/cli"
  tar -xzf "${CLI_TAR}" -C "${VERIFY_DIR}/cli"

  EXTRACTED_APP="${VERIFY_DIR}/app/${APP_BUNDLE_NAME}"
  codesign --verify --deep --strict --verbose=2 "${EXTRACTED_APP}"
  xcrun stapler validate "${EXTRACTED_APP}"
  spctl --assess --type execute --verbose=4 "${EXTRACTED_APP}"
  for binary in "${VERIFY_DIR}/cli/barshelf" "${VERIFY_DIR}/cli/bsf"; do
    codesign --verify --strict --verbose=2 "${binary}"
    SIGNATURE_DETAILS=$(codesign -d --verbose=4 "${binary}" 2>&1)
    CDHASH=$(sed -n 's/^CDHash=//p' <<<"${SIGNATURE_DETAILS}" | head -n 1)
    if [[ -z "${CDHASH}" ]] || ! jq -e --arg cdhash "${CDHASH}" \
      '(.ticketContents // []) | any(.cdhash == $cdhash)' \
      "${CLI_NOTARY_LOG}" >/dev/null; then
      echo "error: final CLI CDHash is absent from the accepted notarization ticket: ${binary}" >&2
      exit 1
    fi
  done
  rm -rf "${VERIFY_DIR}"
  rm -f "${CLI_NOTARY_LOG}"
  trap - EXIT
fi

(cd "${RELEASE_DIR}" && shasum -a 256 ./*.zip ./*.tar.gz > SHA256SUMS)

# What is genuinely downloadable, recorded only for a notarized public
# release. `check-release-versions.py` holds the docs to it.
#
# This used to be a Homebrew cask kept in this repo, which turned out to be a
# second copy of one that also lives in Open330/homebrew-tap — and the two
# drifted three releases apart. The tap is the only cask now, and
# .github/workflows/tap-bump.yml bumps it from the published assets.
RELEASED="${PROJECT_ROOT}/RELEASED_VERSION"
if [[ "${NOTARIZE}" == "1" ]]; then
  echo "${VERSION}" > "${RELEASED}"
  echo "Recorded ${VERSION} in ${RELEASED}"

  # Keep a copy of the notes for the version just built, *before* the heading
  # is moved on. `gh release create --notes-file RELEASE_NOTES.md` would
  # otherwise publish the next version's heading against this release — which
  # it did once, caught only by reading the output.
  cp "${PROJECT_ROOT}/RELEASE_NOTES.md" "${RELEASE_DIR}/RELEASE_NOTES.md"
  echo "Kept this release's notes at ${RELEASE_DIR}/RELEASE_NOTES.md"

  # Move the tree onto the next patch straight away.
  #
  # Leaving it on the version just published means every following commit
  # builds something that calls itself a release it is not, and `barshelf
  # upgrade` answers "up to date" to anyone running it. That happened three
  # times in one afternoon — each caught by CI, which is the wrong place to
  # catch a thing a script can simply do.
  NEXT_VERSION="${VERSION%.*}.$(( ${VERSION##*.} + 1 ))"
  /usr/bin/sed -i '' \
    -e "s/^APP_VERSION=\${APP_VERSION:-.*}$/APP_VERSION=\${APP_VERSION:-${NEXT_VERSION}}/" \
    "${PROJECT_ROOT}/scripts/build_app.sh"
  /usr/bin/sed -i '' \
    -e "s/^    public static let version = \".*\"$/    public static let version = \"${NEXT_VERSION}\"/" \
    "${PROJECT_ROOT}/Sources/BarShelfCLI/BarShelfKit/BarShelfMain.swift"
  /usr/bin/sed -i '' \
    -e "1s/^# BarShelf .*$/# BarShelf ${NEXT_VERSION}/" \
    "${PROJECT_ROOT}/RELEASE_NOTES.md"
  echo "Opened ${NEXT_VERSION} in build_app.sh, BarShelfMain.swift and RELEASE_NOTES.md"
else
  echo "Skipped recording the released version for a local unnotarized package"
fi

echo "Release payload at ${RELEASE_DIR}:"
ls -la "${RELEASE_DIR}"

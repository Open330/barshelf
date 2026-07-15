#!/usr/bin/env bash

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)

PRODUCT_NAME=${PRODUCT_NAME:-barshelf-app}
EXECUTABLE_NAME=${EXECUTABLE_NAME:-barshelf-app}
APP_DISPLAY_NAME=${APP_DISPLAY_NAME:-BarShelf}
APP_BUNDLE_NAME=${APP_BUNDLE_NAME:-"${APP_DISPLAY_NAME}.app"}
BUILD_CONFIGURATION=${BUILD_CONFIGURATION:-release}
OUTPUT_DIR=${OUTPUT_DIR:-"${PROJECT_ROOT}/dist"}
BUNDLE_IDENTIFIER=${BUNDLE_IDENTIFIER:-com.barshelf.app}
APP_VERSION=${APP_VERSION:-0.1.3}
APP_BUILD=${APP_BUILD:-"$(date +%Y%m%d%H%M)"}
MINIMUM_SYSTEM_VERSION=${MINIMUM_SYSTEM_VERSION:-13.0}
APP_CATEGORY=${APP_CATEGORY:-public.app-category.utilities}
APP_COPYRIGHT=${APP_COPYRIGHT:-"Copyright (c) $(date +%Y) BarShelf contributors."}
INFO_PLIST_TEMPLATE=${INFO_PLIST_TEMPLATE:-"${SCRIPT_DIR}/Info.plist.template"}
APP_ICON_NAME=${APP_ICON_NAME:-AppIcon}
APP_ICON_SOURCE=${APP_ICON_SOURCE:-"${PROJECT_ROOT}/assets/${APP_ICON_NAME}.icns"}
WIDGETS_DIR=${WIDGETS_DIR:-"${PROJECT_ROOT}/widgets"}
# Prefer an installed Apple Development identity for local builds so macOS can
# recognize successive builds as the same app and preserve TCC grants. CI or
# contributor machines without one keep the previous ad-hoc behavior. Set
# SIGN_IDENTITY="-" explicitly to force ad-hoc signing, or provide a Developer
# ID / Distribution identity for release builds.
SIGN_IDENTITY=${SIGN_IDENTITY:-}
if [[ -z "${SIGN_IDENTITY}" ]] && command -v security >/dev/null 2>&1; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' \
    | head -n 1)
fi
SIGN_IDENTITY=${SIGN_IDENTITY:--}
APP_STORE_BUILD=${APP_STORE_BUILD:-0}
APP_STORE_ENTITLEMENTS=${APP_STORE_ENTITLEMENTS:-"${SCRIPT_DIR}/AppStore.entitlements"}
PROVISIONING_PROFILE=${PROVISIONING_PROFILE:-}
SIGN_KEYCHAIN=${SIGN_KEYCHAIN:-}
SIGN_ENTITLEMENTS_PATH=${APP_STORE_ENTITLEMENTS}

APP_BUNDLE_PATH="${OUTPUT_DIR}/${APP_BUNDLE_NAME}"
CONTENTS_DIR="${APP_BUNDLE_PATH}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

sed_escape() {
  printf '%s' "$1" | sed -e 's/[\/&|]/\\&/g'
}

render_info_plist() {
  local output_path=$1

  if [[ ! -f "${INFO_PLIST_TEMPLATE}" ]]; then
    echo "error: Info.plist template not found: ${INFO_PLIST_TEMPLATE}" >&2
    exit 1
  fi

  sed \
    -e "s|__APP_DISPLAY_NAME__|$(sed_escape "${APP_DISPLAY_NAME}")|g" \
    -e "s|__BUNDLE_IDENTIFIER__|$(sed_escape "${BUNDLE_IDENTIFIER}")|g" \
    -e "s|__APP_BUILD__|$(sed_escape "${APP_BUILD}")|g" \
    -e "s|__APP_VERSION__|$(sed_escape "${APP_VERSION}")|g" \
    -e "s|__EXECUTABLE_NAME__|$(sed_escape "${EXECUTABLE_NAME}")|g" \
    -e "s|__APP_ICON_NAME__|$(sed_escape "${APP_ICON_NAME}")|g" \
    -e "s|__MINIMUM_SYSTEM_VERSION__|$(sed_escape "${MINIMUM_SYSTEM_VERSION}")|g" \
    -e "s|__APP_CATEGORY__|$(sed_escape "${APP_CATEGORY}")|g" \
    -e "s|__APP_COPYRIGHT__|$(sed_escape "${APP_COPYRIGHT}")|g" \
    "${INFO_PLIST_TEMPLATE}" >"${output_path}"
}

echo "Building ${PRODUCT_NAME} (${BUILD_CONFIGURATION})"
swift build \
  --configuration "${BUILD_CONFIGURATION}" \
  --product "${PRODUCT_NAME}" \
  --package-path "${PROJECT_ROOT}"

EXECUTABLE_PATH="${PROJECT_ROOT}/.build/${BUILD_CONFIGURATION}/${EXECUTABLE_NAME}"
if [[ ! -f "${EXECUTABLE_PATH}" ]]; then
  EXECUTABLE_PATH=$(find "${PROJECT_ROOT}/.build" \
    -path "*/${BUILD_CONFIGURATION}/${EXECUTABLE_NAME}" \
    -type f \
    -perm -111 \
    2>/dev/null | head -n 1 || true)
fi

if [[ -z "${EXECUTABLE_PATH}" || ! -f "${EXECUTABLE_PATH}" ]]; then
  echo "error: expected executable not found for product ${PRODUCT_NAME}" >&2
  exit 1
fi

rm -rf "${APP_BUNDLE_PATH}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

render_info_plist "${CONTENTS_DIR}/Info.plist"

if [[ -f "${APP_ICON_SOURCE}" ]]; then
  cp "${APP_ICON_SOURCE}" "${RESOURCES_DIR}/${APP_ICON_NAME}.icns"
elif [[ "${APP_STORE_BUILD}" == "1" ]]; then
  echo "error: APP_STORE_BUILD=1 requires app icon: ${APP_ICON_SOURCE}" >&2
  exit 1
else
  echo "warning: app icon not found; skipping icon resource: ${APP_ICON_SOURCE}" >&2
fi

cp "${EXECUTABLE_PATH}" "${MACOS_DIR}/${EXECUTABLE_NAME}"
chmod +x "${MACOS_DIR}/${EXECUTABLE_NAME}"

if command -v strip >/dev/null 2>&1; then
  strip -x "${MACOS_DIR}/${EXECUTABLE_NAME}" 2>/dev/null || true
fi

if [[ -d "${WIDGETS_DIR}" ]]; then
  mkdir -p "${RESOURCES_DIR}/widgets"
  rsync -a --delete "${WIDGETS_DIR}/" "${RESOURCES_DIR}/widgets/"
else
  echo "warning: widgets directory not found; skipping widget resources: ${WIDGETS_DIR}" >&2
fi

# Deno TS SDK — script widgets import "barshelf" via an import map pointing
# here; without it every script widget fails with "SDK (sdk/mod.ts) not found".
SDK_DIR=${SDK_DIR:-"${PROJECT_ROOT}/sdk"}
if [[ -f "${SDK_DIR}/mod.ts" ]]; then
  mkdir -p "${RESOURCES_DIR}/sdk"
  rsync -a --delete "${SDK_DIR}/" "${RESOURCES_DIR}/sdk/"
else
  echo "warning: sdk/mod.ts not found; script widgets will not run: ${SDK_DIR}" >&2
fi

# Bundled registry fallback (offline/dev gallery)
REGISTRY_DIR=${REGISTRY_DIR:-"${PROJECT_ROOT}/registry"}
if [[ -d "${REGISTRY_DIR}" ]]; then
  mkdir -p "${RESOURCES_DIR}/registry"
  rsync -a --delete "${REGISTRY_DIR}/" "${RESOURCES_DIR}/registry/"
else
  echo "warning: registry directory not found; skipping registry resources: ${REGISTRY_DIR}" >&2
fi

if [[ "${APP_STORE_BUILD}" == "1" ]]; then
  if [[ -z "${PROVISIONING_PROFILE}" ]]; then
    echo "error: APP_STORE_BUILD=1 requires PROVISIONING_PROFILE" >&2
    exit 1
  fi
  if [[ ! -f "${PROVISIONING_PROFILE}" ]]; then
    echo "error: provisioning profile not found: ${PROVISIONING_PROFILE}" >&2
    exit 1
  fi
  if [[ ! -f "${APP_STORE_ENTITLEMENTS}" ]]; then
    echo "error: App Store entitlements not found: ${APP_STORE_ENTITLEMENTS}" >&2
    exit 1
  fi
  cp "${PROVISIONING_PROFILE}" "${CONTENTS_DIR}/embedded.provisionprofile"

  PROFILE_PLIST=$(mktemp "${OUTPUT_DIR}/barshelf-profile.XXXXXX.plist")
  SIGN_ENTITLEMENTS_PATH=$(mktemp "${OUTPUT_DIR}/barshelf-entitlements.XXXXXX.plist")
  security cms -D -i "${PROVISIONING_PROFILE}" >"${PROFILE_PLIST}"
  cp "${APP_STORE_ENTITLEMENTS}" "${SIGN_ENTITLEMENTS_PATH}"

  APP_IDENTIFIER=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "${PROFILE_PLIST}")
  TEAM_IDENTIFIER=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.team-identifier" "${PROFILE_PLIST}")
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string ${APP_IDENTIFIER}" "${SIGN_ENTITLEMENTS_PATH}" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :com.apple.application-identifier ${APP_IDENTIFIER}" "${SIGN_ENTITLEMENTS_PATH}"
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string ${TEAM_IDENTIFIER}" "${SIGN_ENTITLEMENTS_PATH}" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :com.apple.developer.team-identifier ${TEAM_IDENTIFIER}" "${SIGN_ENTITLEMENTS_PATH}"
  rm -f "${PROFILE_PLIST}"
fi

if command -v xattr >/dev/null 2>&1; then
  xattr -r -d com.apple.quarantine "${APP_BUNDLE_PATH}" 2>/dev/null || true
fi
chmod -R u+rwX,go+rX "${APP_BUNDLE_PATH}"

# --- BarShelf CLI binaries (standalone developer tools, shipped next to the .app) ---
CLI_PRODUCT_NAMES=${CLI_PRODUCT_NAMES:-"barshelf bsf"}

sign_cli_binary() {
  local binary_path=$1
  if command -v codesign >/dev/null 2>&1; then
    if [[ "${SIGN_IDENTITY}" == "-" ]]; then
      codesign --force --options runtime --sign - --timestamp=none "${binary_path}" >/dev/null
    elif [[ -n "${SIGN_KEYCHAIN}" ]]; then
      codesign --force --options runtime --sign "${SIGN_IDENTITY}" --keychain "${SIGN_KEYCHAIN}" "${binary_path}" >/dev/null
    else
      codesign --force --options runtime --sign "${SIGN_IDENTITY}" "${binary_path}" >/dev/null
    fi
  else
    echo "warning: codesign not found; ${binary_path} is unsigned" >&2
  fi
}

for CLI_PRODUCT_NAME in ${CLI_PRODUCT_NAMES}; do
  echo "Building ${CLI_PRODUCT_NAME} (${BUILD_CONFIGURATION})"
  swift build \
    --configuration "${BUILD_CONFIGURATION}" \
    --product "${CLI_PRODUCT_NAME}" \
    --package-path "${PROJECT_ROOT}"

  CLI_EXECUTABLE_PATH="${PROJECT_ROOT}/.build/${BUILD_CONFIGURATION}/${CLI_PRODUCT_NAME}"
  if [[ ! -f "${CLI_EXECUTABLE_PATH}" ]]; then
    CLI_EXECUTABLE_PATH=$(find "${PROJECT_ROOT}/.build" \
      -path "*/${BUILD_CONFIGURATION}/${CLI_PRODUCT_NAME}" \
      -type f \
      -perm -111 \
      2>/dev/null | head -n 1 || true)
  fi

  if [[ -z "${CLI_EXECUTABLE_PATH}" || ! -f "${CLI_EXECUTABLE_PATH}" ]]; then
    echo "error: expected executable not found for product ${CLI_PRODUCT_NAME}" >&2
    exit 1
  fi

  cp "${CLI_EXECUTABLE_PATH}" "${OUTPUT_DIR}/${CLI_PRODUCT_NAME}"
  chmod +x "${OUTPUT_DIR}/${CLI_PRODUCT_NAME}"

  if command -v strip >/dev/null 2>&1; then
    strip -x "${OUTPUT_DIR}/${CLI_PRODUCT_NAME}" 2>/dev/null || true
  fi

  sign_cli_binary "${OUTPUT_DIR}/${CLI_PRODUCT_NAME}"
  echo "BarShelf CLI copied to ${OUTPUT_DIR}/${CLI_PRODUCT_NAME}"
done

if command -v codesign >/dev/null 2>&1; then
  if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    echo "Ad-hoc signing ${APP_BUNDLE_PATH}"
    codesign --force --options runtime --sign - --timestamp=none --deep "${APP_BUNDLE_PATH}" >/dev/null
  elif [[ "${APP_STORE_BUILD}" == "1" ]]; then
    echo "Signing ${APP_BUNDLE_PATH} for Mac App Store with ${SIGN_IDENTITY}"
    if [[ -n "${SIGN_KEYCHAIN}" ]]; then
      codesign --force --options runtime --sign "${SIGN_IDENTITY}" \
        --keychain "${SIGN_KEYCHAIN}" \
        --entitlements "${SIGN_ENTITLEMENTS_PATH}" \
        --deep "${APP_BUNDLE_PATH}" >/dev/null
    else
      codesign --force --options runtime --sign "${SIGN_IDENTITY}" \
        --entitlements "${SIGN_ENTITLEMENTS_PATH}" \
        --deep "${APP_BUNDLE_PATH}" >/dev/null
    fi
  else
    echo "Signing ${APP_BUNDLE_PATH} with ${SIGN_IDENTITY}"
    if [[ -n "${SIGN_KEYCHAIN}" ]]; then
      codesign --force --options runtime --sign "${SIGN_IDENTITY}" --keychain "${SIGN_KEYCHAIN}" --deep "${APP_BUNDLE_PATH}" >/dev/null
    else
      codesign --force --options runtime --sign "${SIGN_IDENTITY}" --deep "${APP_BUNDLE_PATH}" >/dev/null
    fi
  fi
else
  echo "warning: codesign not found; app bundle is unsigned" >&2
fi

chmod -R u+rwX,go+rX "${APP_BUNDLE_PATH}"

if [[ "${SIGN_ENTITLEMENTS_PATH}" != "${APP_STORE_ENTITLEMENTS}" ]]; then
  rm -f "${SIGN_ENTITLEMENTS_PATH}"
fi

echo "App bundle created at ${APP_BUNDLE_PATH}"

#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)

PRODUCT_NAME=${PRODUCT_NAME:-menubucket}
EXECUTABLE_NAME=${EXECUTABLE_NAME:-menubucket}
APP_DISPLAY_NAME=${APP_DISPLAY_NAME:-MenuBucket}
APP_BUNDLE_NAME=${APP_BUNDLE_NAME:-"${APP_DISPLAY_NAME}.app"}
BUILD_CONFIGURATION=${BUILD_CONFIGURATION:-release}
OUTPUT_DIR=${OUTPUT_DIR:-"${PROJECT_ROOT}/dist"}
BUNDLE_IDENTIFIER=${BUNDLE_IDENTIFIER:-dev.menubucket.app}
APP_VERSION=${APP_VERSION:-0.1.0}
APP_BUILD=${APP_BUILD:-"$(date +%Y%m%d%H%M)"}
MINIMUM_SYSTEM_VERSION=${MINIMUM_SYSTEM_VERSION:-13.0}
APP_CATEGORY=${APP_CATEGORY:-public.app-category.utilities}
APP_COPYRIGHT=${APP_COPYRIGHT:-"Copyright (c) $(date +%Y) MenuBucket contributors."}
INFO_PLIST_TEMPLATE=${INFO_PLIST_TEMPLATE:-"${SCRIPT_DIR}/Info.plist.template"}
WIDGETS_DIR=${WIDGETS_DIR:-"${PROJECT_ROOT}/widgets"}
# "-" means ad-hoc signing. Use SIGN_IDENTITY="Developer ID Application: ..." for distribution builds.
SIGN_IDENTITY=${SIGN_IDENTITY:--}

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

# Bundled registry fallback (offline/dev gallery)
REGISTRY_DIR=${REGISTRY_DIR:-"${PROJECT_ROOT}/registry"}
if [[ -d "${REGISTRY_DIR}" ]]; then
  mkdir -p "${RESOURCES_DIR}/registry"
  rsync -a --delete "${REGISTRY_DIR}/" "${RESOURCES_DIR}/registry/"
else
  echo "warning: registry directory not found; skipping registry resources: ${REGISTRY_DIR}" >&2
fi

if command -v xattr >/dev/null 2>&1; then
  xattr -r -d com.apple.quarantine "${APP_BUNDLE_PATH}" 2>/dev/null || true
fi

# --- mbk CLI (standalone developer binary, shipped next to the .app) ---
MBK_PRODUCT_NAME=${MBK_PRODUCT_NAME:-mbk}

echo "Building ${MBK_PRODUCT_NAME} (${BUILD_CONFIGURATION})"
swift build \
  --configuration "${BUILD_CONFIGURATION}" \
  --product "${MBK_PRODUCT_NAME}" \
  --package-path "${PROJECT_ROOT}"

MBK_EXECUTABLE_PATH="${PROJECT_ROOT}/.build/${BUILD_CONFIGURATION}/${MBK_PRODUCT_NAME}"
if [[ ! -f "${MBK_EXECUTABLE_PATH}" ]]; then
  MBK_EXECUTABLE_PATH=$(find "${PROJECT_ROOT}/.build" \
    -path "*/${BUILD_CONFIGURATION}/${MBK_PRODUCT_NAME}" \
    -type f \
    -perm -111 \
    2>/dev/null | head -n 1 || true)
fi

if [[ -z "${MBK_EXECUTABLE_PATH}" || ! -f "${MBK_EXECUTABLE_PATH}" ]]; then
  echo "error: expected executable not found for product ${MBK_PRODUCT_NAME}" >&2
  exit 1
fi

cp "${MBK_EXECUTABLE_PATH}" "${OUTPUT_DIR}/${MBK_PRODUCT_NAME}"
chmod +x "${OUTPUT_DIR}/${MBK_PRODUCT_NAME}"

if command -v strip >/dev/null 2>&1; then
  strip -x "${OUTPUT_DIR}/${MBK_PRODUCT_NAME}" 2>/dev/null || true
fi

if command -v codesign >/dev/null 2>&1; then
  if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    codesign --force --options runtime --sign - --timestamp=none "${OUTPUT_DIR}/${MBK_PRODUCT_NAME}" >/dev/null
  else
    codesign --force --options runtime --sign "${SIGN_IDENTITY}" "${OUTPUT_DIR}/${MBK_PRODUCT_NAME}" >/dev/null
  fi
else
  echo "warning: codesign not found; mbk binary is unsigned" >&2
fi
echo "mbk CLI copied to ${OUTPUT_DIR}/${MBK_PRODUCT_NAME}"

if command -v codesign >/dev/null 2>&1; then
  if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    echo "Ad-hoc signing ${APP_BUNDLE_PATH}"
    codesign --force --options runtime --sign - --timestamp=none --deep "${APP_BUNDLE_PATH}" >/dev/null
  else
    echo "Signing ${APP_BUNDLE_PATH} with ${SIGN_IDENTITY}"
    codesign --force --options runtime --sign "${SIGN_IDENTITY}" --deep "${APP_BUNDLE_PATH}" >/dev/null
  fi
else
  echo "warning: codesign not found; app bundle is unsigned" >&2
fi

echo "App bundle created at ${APP_BUNDLE_PATH}"

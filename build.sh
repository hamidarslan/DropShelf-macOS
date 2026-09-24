#!/usr/bin/env bash
set -euo pipefail
SDK_PATH="${DROPSHELF_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
# CLT 27's default SDK requires SwiftUI macros supplied only by full Xcode.
if [[ -z "${DROPSHELF_SDK:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="DropShelf"
BUILD_ROOT="${DROPSHELF_BUILD_DIR:-${SCRIPT_DIR}}"
mkdir -p "$BUILD_ROOT"
APP_BUNDLE="${BUILD_ROOT}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "==> Building ${APP_NAME}.app..."

# Optional background-removal weights are installed only after an explicit user action.
# Fail closed if a model artifact is ever added to resources or a prior assembled bundle.
bash "${SCRIPT_DIR}/Tests/check-model-free.sh" "${SCRIPT_DIR}/Resources"

# 1. Clean previous build
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

# 2. Compile Swift sources with optimizations
echo "==> Compiling Swift sources..."
DEVELOPER_DIR=/Library/Developer/CommandLineTools swiftc \
  -O \
  -module-cache-path /tmp/dropshelf-swift-modules \
  -target arm64-apple-macosx13.0 \
  -sdk "$SDK_PATH" \
  -framework Cocoa \
  -framework SwiftUI \
  -framework UniformTypeIdentifiers \
  -framework QuickLookThumbnailing \
  -framework Quartz \
  -framework PDFKit -framework Vision -framework CoreML -framework CoreImage -framework ImageIO \
  -framework ServiceManagement \
  "${SCRIPT_DIR}"/Sources/Models/*.swift \
  "${SCRIPT_DIR}"/Sources/Services/*.swift \
  "${SCRIPT_DIR}"/Sources/UI/*.swift \
  "${SCRIPT_DIR}"/Sources/AppDelegate.swift \
  "${SCRIPT_DIR}"/Sources/main.swift \
  -o "${MACOS_DIR}/${APP_NAME}"

# 3. Copy Resources & Info.plist
echo "==> Copying Info.plist and Resources..."
cp "${SCRIPT_DIR}/Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"
cp -R "${SCRIPT_DIR}/Resources/"* "${RESOURCES_DIR}/" || true
# Keep developer artwork notes out of the application bundle.
rm -f "${RESOURCES_DIR}/RefinedIcons/README.md"
chmod +x "${RESOURCES_DIR}/dropshelf" || true
bash "${SCRIPT_DIR}/Tests/check-model-free.sh" "${APP_BUNDLE}"

# 4. Codesign the application with Hardened Runtime and Entitlements
echo "==> Codesigning ${APP_NAME}.app with Hardened Runtime..."
codesign --force --deep --sign - --options runtime --entitlements "${SCRIPT_DIR}/Resources/DropShelf.entitlements" "${APP_BUNDLE}"

echo "==> Successfully created ${APP_BUNDLE}!"

# 5. Create DMG disk image for drag-and-drop installation
echo "==> Packaging ${APP_NAME}.dmg..."
DMG_TMP="${BUILD_ROOT}/.dmg_temp"
rm -rf "${DMG_TMP}" "${BUILD_ROOT}/${APP_NAME}.dmg"
mkdir -p "${DMG_TMP}"
cp -R "${APP_BUNDLE}" "${DMG_TMP}/"
ln -s /Applications "${DMG_TMP}/Applications"
bash "${SCRIPT_DIR}/Tests/check-model-free.sh" "${DMG_TMP}"
hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_TMP}" -ov -format UDZO "${BUILD_ROOT}/${APP_NAME}.dmg"
rm -rf "${DMG_TMP}"

echo "==> Successfully created ${BUILD_ROOT}/${APP_NAME}.dmg!"

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
COMPRESSION_TOOL_NAMES=(qpdf jpegtran oxipng pdf-verify image-verify)
COMPRESSION_TOOL_VERSIONS=(12.4.2 3.2.0 10.2.1 1.0.0 1.0.0)
COMPRESSION_TOOL_SOURCES=("" "" "" "Sources/Compression/PDFVerifier.cpp" "Sources/Compression/ImageVerifier.cpp")

verify_compression_source_manifest() {
  local tools_root="$1"
  local manifest="${tools_root}/manifest.json"
  local index helper expected_name expected_path expected_version expected_sha actual_sha
  local expected_source_sha actual_source_sha schema
  [[ -f "$manifest" ]] || {
    echo "Missing compression helper manifest. Run script/build_compression_tools.sh." >&2
    return 1
  }
  schema="$(plutil -extract schemaVersion raw -o - "$manifest")"
  [[ "$schema" == 1 ]] || {
    echo "Unsupported compression helper manifest schema: $schema" >&2
    return 1
  }
  for index in "${!COMPRESSION_TOOL_NAMES[@]}"; do
    helper="${COMPRESSION_TOOL_NAMES[$index]}"
    expected_name="$(plutil -extract "tools.${index}.name" raw -o - "$manifest")"
    expected_path="$(plutil -extract "tools.${index}.path" raw -o - "$manifest")"
    expected_version="$(plutil -extract "tools.${index}.version" raw -o - "$manifest")"
    expected_sha="$(plutil -extract "tools.${index}.sha256" raw -o - "$manifest")"
    if [[ "$expected_name" != "$helper" || "$expected_path" != "bin/${helper}" || \
          "$expected_version" != "${COMPRESSION_TOOL_VERSIONS[$index]}" ]]; then
      echo "Compression helper manifest entry ${index} is invalid. Run script/build_compression_tools.sh." >&2
      return 1
    fi
    [[ -f "${tools_root}/${expected_path}" ]] || {
      echo "Missing compression helper: ${tools_root}/${expected_path}" >&2
      return 1
    }
    actual_sha="$(shasum -a 256 "${tools_root}/${expected_path}" | awk '{print $1}')"
    [[ "$actual_sha" == "$expected_sha" ]] || {
      echo "Compression helper ${helper} is stale. Run script/build_compression_tools.sh." >&2
      return 1
    }
    if [[ -n "${COMPRESSION_TOOL_SOURCES[$index]}" ]]; then
      expected_source_sha="$(plutil -extract "tools.${index}.sourceSha256" raw -o - "$manifest")"
      actual_source_sha="$(shasum -a 256 "${SCRIPT_DIR}/${COMPRESSION_TOOL_SOURCES[$index]}" | awk '{print $1}')"
      [[ "$actual_source_sha" == "$expected_source_sha" ]] || {
        echo "Compression helper source for ${helper} changed. Run script/build_compression_tools.sh." >&2
        return 1
      }
    fi
  done
}

write_compression_manifest() {
  local tools_root="$1"
  local bin_dir="${tools_root}/bin"
  local manifest_tmp="${tools_root}/manifest.json.tmp"
  local index helper sha comma source_field source_sha
  {
    echo '{'
    echo '  "schemaVersion": 1,'
    echo '  "tools": ['
    for index in "${!COMPRESSION_TOOL_NAMES[@]}"; do
      helper="${COMPRESSION_TOOL_NAMES[$index]}"
      [[ -x "${bin_dir}/${helper}" ]] || {
        echo "Missing compression helper: ${bin_dir}/${helper}" >&2
        return 1
      }
      sha="$(shasum -a 256 "${bin_dir}/${helper}" | awk '{print $1}')"
      source_field=''
      if [[ -n "${COMPRESSION_TOOL_SOURCES[$index]}" ]]; then
        source_sha="$(shasum -a 256 "${SCRIPT_DIR}/${COMPRESSION_TOOL_SOURCES[$index]}" | awk '{print $1}')"
        source_field=",\"sourceSha256\":\"${source_sha}\""
      fi
      comma=','
      if [[ "$index" -eq $((${#COMPRESSION_TOOL_NAMES[@]} - 1)) ]]; then
        comma=''
      fi
      printf '    {"name":"%s","path":"bin/%s","sha256":"%s","version":"%s"%s}%s\n' \
        "$helper" "$helper" "$sha" "${COMPRESSION_TOOL_VERSIONS[$index]}" "$source_field" "$comma"
    done
    echo '  ]'
    echo '}'
  } > "$manifest_tmp"
  mv "$manifest_tmp" "${tools_root}/manifest.json"
}

echo "==> Building ${APP_NAME}.app..."

# Optional background-removal weights are installed only after an explicit user action.
# Fail closed if a model artifact is ever added to resources or a prior assembled bundle.
bash "${SCRIPT_DIR}/Tests/check-model-free.sh" "${SCRIPT_DIR}/Resources"
verify_compression_source_manifest "${SCRIPT_DIR}/Resources/CompressionTools"

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
COMPRESSION_TOOLS_DIR="${RESOURCES_DIR}/CompressionTools"
for helper in "${COMPRESSION_TOOL_NAMES[@]}"; do
  chmod +x "${COMPRESSION_TOOLS_DIR}/bin/${helper}"
  codesign --force --sign - --options runtime "${COMPRESSION_TOOLS_DIR}/bin/${helper}"
  codesign --verify --strict "${COMPRESSION_TOOLS_DIR}/bin/${helper}"
done
# Code signing changes executable bytes. Generate the runtime integrity manifest
# from the final nested helper binaries before sealing the outer application.
write_compression_manifest "$COMPRESSION_TOOLS_DIR"
bash "${SCRIPT_DIR}/Tests/check-model-free.sh" "${APP_BUNDLE}"

# 4. Codesign the application with Hardened Runtime and Entitlements
echo "==> Codesigning ${APP_NAME}.app with Hardened Runtime..."
codesign --force --sign - --options runtime --entitlements "${SCRIPT_DIR}/Resources/DropShelf.entitlements" "${APP_BUNDLE}"
codesign --verify --deep --strict "${APP_BUNDLE}"

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

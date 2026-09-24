#!/usr/bin/env bash
set -euo pipefail
SDK_PATH="${DROPSHELF_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
# CLT 27's default SDK requires SwiftUI macros supplied only by full Xcode.
if [[ -z "${DROPSHELF_SDK:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/dropshelf-visual.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/DropShelfVisual.app"
mkdir -p "$APP/Contents/MacOS"
cp -R "$ROOT/Resources" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.dropshelf.visual-tests</string><key>CFBundleExecutable</key><string>Visual</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
xcrun swiftc -target arm64-apple-macosx13.0 -sdk "$SDK_PATH" -module-cache-path /tmp/dropshelf-swift-modules -o "$APP/Contents/MacOS/Visual" \
  "$ROOT"/Sources/Models/*.swift "$ROOT"/Sources/Services/*.swift \
  "$ROOT"/Sources/UI/*.swift "$ROOT"/Sources/AppDelegate.swift \
  "$ROOT"/Tests/Visual/main.swift \
  -framework Cocoa -framework SwiftUI -framework Quartz -framework QuickLookThumbnailing \
  -framework UniformTypeIdentifiers -framework PDFKit -framework Vision -framework CoreML -framework CoreImage -framework ImageIO -framework ServiceManagement
"$APP/Contents/MacOS/Visual" "$ROOT" "${1:-/tmp/dropshelf-visual-renders}"

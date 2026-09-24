#!/usr/bin/env bash
set -euo pipefail
SDK_PATH="${DROPSHELF_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
# CLT 27's default SDK requires SwiftUI macros supplied only by full Xcode.
if [[ -z "${DROPSHELF_SDK:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/dropshelf-clipboard.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -target arm64-apple-macosx13.0 -sdk "$SDK_PATH" -module-cache-path /tmp/dropshelf-swift-modules -o "$WORK/regression" \
  "$ROOT"/Sources/Models/*.swift "$ROOT"/Sources/Services/*.swift \
  "$ROOT"/Sources/UI/*.swift "$ROOT"/Sources/AppDelegate.swift \
  "$ROOT"/Tests/Clipboard/main.swift \
  -framework Cocoa -framework SwiftUI -framework Quartz -framework QuickLookThumbnailing \
  -framework UniformTypeIdentifiers -framework PDFKit -framework Vision -framework CoreML -framework CoreImage -framework ImageIO -framework ServiceManagement
"$WORK/regression"

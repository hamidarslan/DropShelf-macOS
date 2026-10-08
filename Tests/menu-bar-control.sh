#!/usr/bin/env bash
set -euo pipefail
SDK_PATH="${DROPSHELF_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
if [[ -z "${DROPSHELF_SDK:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/dropshelf-menu-bar-control.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -target arm64-apple-macosx13.0 -sdk "$SDK_PATH" \
    -module-cache-path /tmp/dropshelf-swift-modules \
    "$ROOT/Sources/Services/MenuBarControlMonitor.swift" \
    "$ROOT/Tests/MenuBarControlMonitor/main.swift" \
    -framework Cocoa -framework ApplicationServices -o "$WORK/tests"
"$WORK/tests"

#!/usr/bin/env bash
set -euo pipefail
SDK_PATH="${DROPSHELF_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
if [[ -z "${DROPSHELF_SDK:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$ROOT/Tests/check-compression-tools.sh" "$ROOT/DropShelf.app"
WORK="$(mktemp -d /tmp/dropshelf-compression-suite.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -target arm64-apple-macosx13.0 -sdk "$SDK_PATH" -module-cache-path /tmp/dropshelf-swift-modules \
    "$ROOT/Sources/Models/LosslessCompression.swift" \
    "$ROOT/Sources/Services/CompressionToolRunner.swift" \
    "$ROOT/Sources/Services/LosslessCompressionService.swift" \
    "$ROOT/Tests/Compression/main.swift" \
    -framework AppKit -framework PDFKit -framework ImageIO -framework CryptoKit \
    -o "$WORK/compression-tests"
"$WORK/compression-tests" "$ROOT"

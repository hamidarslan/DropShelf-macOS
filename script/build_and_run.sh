#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-run}"
case "$MODE" in run|--verify|--install) ;; *) echo "Usage: $0 [--verify|--install]" >&2; exit 2 ;; esac
# Stop the previous process before launching the freshly built app.
if pgrep -x DropShelf >/dev/null; then
    pkill -TERM -x DropShelf
    for attempt in {1..30}; do
        pgrep -x DropShelf >/dev/null || break
        sleep 0.1
    done
    if pgrep -x DropShelf >/dev/null; then echo "DropShelf did not quit" >&2; exit 1; fi
fi
bash "$ROOT/build.sh"
APP_PATH="$ROOT/DropShelf.app"
if [[ "$MODE" == --install ]]; then
    APP_PATH="/Applications/DropShelf.app"
    if [[ -d "$APP_PATH" ]]; then
        BACKUP_DIR="$ROOT/build/installed-backups/$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$BACKUP_DIR/DropShelf.zip"
    fi
    INSTALL_STAGING="/Applications/.DropShelf-install-$$.app"
    trap 'rm -rf "$INSTALL_STAGING"' EXIT
    ditto "$ROOT/DropShelf.app" "$INSTALL_STAGING"
    codesign --verify --deep --strict "$INSTALL_STAGING"
    # The prior bundle is archived above; replace it as a unit, avoiding stale resources.
    rm -rf "$APP_PATH"
    mv "$INSTALL_STAGING" "$APP_PATH"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_PATH"
fi
open -n "$APP_PATH"
if [[ "$MODE" == --verify || "$MODE" == --install ]]; then
    sleep 1
    pgrep -x DropShelf
fi

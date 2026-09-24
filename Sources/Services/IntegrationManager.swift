import Foundation
import Cocoa

public class IntegrationManager {
    public static let shared = IntegrationManager()

    private let servicesDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Services", isDirectory: true)
    }()

    public var quickActionURL: URL {
        servicesDirectory.appendingPathComponent("Send to DropShelf.workflow", isDirectory: true)
    }

    public var isQuickActionInstalled: Bool {
        FileManager.default.fileExists(atPath: quickActionURL.path)
    }

    public var cliToolPath: String {
        let localBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/dropshelf").path
        if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/dropshelf") {
            return "/usr/local/bin/dropshelf"
        }
        return localBin
    }

    public var isCLIInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/local/bin/dropshelf") ||
        FileManager.default.isExecutableFile(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/dropshelf").path)
    }

    // MARK: - Finder Quick Action Installation

    public func installQuickAction() -> (success: Bool, message: String) {
        do {
            try FileManager.default.createDirectory(at: servicesDirectory, withIntermediateDirectories: true)

            let workflowDir = quickActionURL
            let contentsDir = workflowDir.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)

            // 1. Info.plist for workflow
            let infoPlistContent = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSBackgroundColorName</key>
            <string>background</string>
            <key>NSIconName</key>
            <string>NSActionTemplate</string>
            <key>NSMenuItem</key>
            <dict>
                <key>default</key>
                <string>Send to DropShelf</string>
            </dict>
            <key>NSMessage</key>
            <string>runWorkflowAsService</string>
            <key>NSRequiredContext</key>
            <dict>
                <key>NSApplicationIdentifier</key>
                <string>com.apple.finder</string>
            </dict>
            <key>NSSendFileTypes</key>
            <array>
                <string>public.item</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
"""
            try infoPlistContent.write(to: contentsDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

            // 2. document.wflow for Quick Action
            let documentWflowContent = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AMApplicationBuild</key>
    <string>523</string>
    <key>AMApplicationVersion</key>
    <string>2.10</string>
    <key>AMDocumentVersion</key>
    <string>2</string>
    <key>actions</key>
    <array>
        <dict>
            <key>action</key>
            <dict>
                <key>AMAccepts</key>
                <dict>
                    <key>Container</key>
                    <string>List</string>
                    <key>Optional</key>
                    <true/>
                    <key>Types</key>
                    <array>
                        <string>com.apple.cocoa.path</string>
                    </array>
                </dict>
                <key>AMActionVersion</key>
                <string>2.0.3</string>
                <key>AMApplication</key>
                <array>
                    <string>Automator</string>
                </array>
                <key>AMParameterProperties</key>
                <dict>
                    <key>COMMAND_STRING</key>
                    <dict/>
                    <key>inputMethod</key>
                    <dict/>
                </dict>
                <key>AMProvides</key>
                <dict>
                    <key>Container</key>
                    <string>List</string>
                    <key>Types</key>
                    <array>
                        <string>com.apple.cocoa.path</string>
                    </array>
                </dict>
                <key>ActionBundlePath</key>
                <string>/System/Library/Automator/Run Shell Script.action</string>
                <key>ActionName</key>
                <string>Run Shell Script</string>
                <key>ActionParameters</key>
                <dict>
                    <key>COMMAND_STRING</key>
                    <string>for f in "$@"
do
    open -a DropShelf "$f"
done
</string>
                    <key>inputMethod</key>
                    <integer>1</integer>
                    <key>shell</key>
                    <string>/bin/zsh</string>
                    <key>source</key>
                    <string></string>
                </dict>
                <key>BundleIdentifier</key>
                <string>com.apple.RunShellScript</string>
                <key>CFBundleVersion</key>
                <string>2.0.3</string>
            </dict>
        </dict>
    </array>
    <key>connectors</key>
    <dict/>
    <key>workflowMetaData</key>
    <dict>
        <key>workflowTypeIdentifier</key>
        <string>com.apple.Automator.servicesMenu</string>
    </dict>
</dict>
</plist>
"""
            try documentWflowContent.write(to: workflowDir.appendingPathComponent("document.wflow"), atomically: true, encoding: .utf8)

            // Refresh macOS services database
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
            task.arguments = ["-update"]
            try? task.run()

            return (true, "Finder Quick Action installed! Right-click any file in Finder to Send to DropShelf.")
        } catch {
            return (false, "Failed to install Quick Action: \(error.localizedDescription)")
        }
    }

    public func removeQuickAction() -> (success: Bool, message: String) {
        do {
            if FileManager.default.fileExists(atPath: quickActionURL.path) {
                try FileManager.default.removeItem(at: quickActionURL)
            }
            return (true, "Quick Action removed.")
        } catch {
            return (false, "Failed to remove: \(error.localizedDescription)")
        }
    }

    // MARK: - CLI Tool Installation

    public func installCLITool() -> (success: Bool, message: String) {
        let script = """
#!/usr/bin/env bash
# DropShelf CLI Utility
# Control DropShelf and send files, links, or colors directly from terminal

set -e

SHOW_HELP() {
    cat << 'EOF'
DropShelf CLI Utility
Usage:
  dropshelf <files...>          Add one or more files to DropShelf
  dropshelf --text, -m <text>   Add text, URL, or color hex to DropShelf
  dropshelf --toggle, -t        Toggle DropShelf window visibility
  dropshelf --collapse          Collapse DropShelf to edge tab
  dropshelf --uncollapse        Uncollapse DropShelf
  dropshelf --stack             Combine all files into a single stack
  dropshelf --unstack           Separate stacked files into individual cards
  dropshelf --clear, -c         Clear all active items from shelf
  dropshelf --history, -h       Open Recent Drops History drawer
  dropshelf --theme <name>      Set appearance theme (dark, light, auto)
  dropshelf --mode <name>       Set transfer mode (copy, cut)
  dropshelf --grid              Toggle Quick Action Grid
  dropshelf --help              Show this help message

Examples:
  dropshelf document.pdf image.png
  dropshelf ~/Downloads/*.jpg
  dropshelf --text "#3B82F6"
  dropshelf --text "https://github.com/hamidarslan/DropShelf-macOS"
  echo "https://apple.com" | dropshelf
  echo "#FF5733" | dropshelf
  dropshelf --toggle
  dropshelf --theme light
  dropshelf --mode copy
  dropshelf --grid
  dropshelf --stack
EOF
    exit 0
}

urlencode() {
    python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$1"
}

if [ $# -eq 0 ]; then
    # Check if input is piped
    if [ ! -t 0 ]; then
        TMP_INPUT="$(cat)"
        if [ -n "$TMP_INPUT" ]; then
            # If input matches an existing file path
            if [ -e "$TMP_INPUT" ]; then
                FULL_PATH="$(cd "$(dirname "$TMP_INPUT")" && pwd)/$(basename "$TMP_INPUT")"
                open -a DropShelf "$FULL_PATH"
            else
                ENCODED=$(urlencode "$TMP_INPUT")
                open "dropshelf://add?text=${ENCODED}"
            fi
            exit 0
        fi
    fi
    SHOW_HELP
fi

case "$1" in
    -t|--toggle)
        open "dropshelf://toggle"
        ;;
    --collapse)
        open "dropshelf://collapse"
        ;;
    --uncollapse)
        open "dropshelf://uncollapse"
        ;;
    --stack)
        open "dropshelf://stack"
        ;;
    --unstack)
        open "dropshelf://unstack"
        ;;
    -c|--clear)
        open "dropshelf://clear"
        ;;
    -h|--history)
        open "dropshelf://history"
        ;;
    --theme)
        shift
        if [ $# -gt 0 ]; then
            open "dropshelf://theme?name=$1"
        else
            echo "Error: No theme specified (use: dark, light, auto)" >&2
            exit 1
        fi
        ;;
    --mode)
        shift
        if [ $# -gt 0 ]; then
            open "dropshelf://mode?name=$1"
        else
            echo "Error: No mode specified (use: copy, cut)" >&2
            exit 1
        fi
        ;;
    --grid)
        open "dropshelf://grid"
        ;;
    -m|--text)
        shift
        if [ $# -gt 0 ]; then
            ENCODED=$(urlencode "$*")
            open "dropshelf://add?text=${ENCODED}"
        else
            echo "Error: No text provided" >&2
            exit 1
        fi
        ;;
    --help)
        SHOW_HELP
        ;;
    *)
        for item in "$@"; do
            if [ -e "$item" ]; then
                FULL_PATH="$(cd "$(dirname "$item")" && pwd)/$(basename "$item")"
                open -a DropShelf "$FULL_PATH"
            else
                echo "Warning: File not found: $item" >&2
            fi
        done
        ;;
esac
"""
        let targetDirs = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
        ]

        var installedPath: String? = nil

        for dir in targetDirs {
            let fileURL = dir.appendingPathComponent("dropshelf")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try script.write(to: fileURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
                installedPath = fileURL.path
                break
            } catch {
                continue
            }
        }

        if let path = installedPath {
            return (true, "CLI tool installed at \(path). Run 'dropshelf --help' to use.")
        } else {
            return (false, "Could not write to ~/.local/bin or /usr/local/bin.")
        }
    }
}

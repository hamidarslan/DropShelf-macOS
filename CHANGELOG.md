# Changelog

## 1.4.3

- Updated release packaging.

## 1.4.2

- Keep the shelf available when a held file or folder drag leaves its drop area.
- Hide an empty shelf after a pause outside it, then reveal it again as soon as the same drag resumes moving.
- Preserve optional shake-only activation, populated shelves, and pending file deliveries.
- End drag tracking when AppKit cancels the drag, even if the mouse button is still held.

## 1.4.1

- Make the 496 MB BiRefNet quality model an explicit optional download from Preferences or Image Tools.
- Prevent background-removal processing from downloading or repairing a model automatically.
- Add removal controls for the locally installed quality model.
- Fail the app and disk-image build if Core ML packages, compiled models, or weight artifacts enter bundled resources.

## 1.4.0

- Add image resizing and runtime-discovered image conversion formats, with orientation, color-profile, transparency and bit-depth safeguards.
- Add local background removal with the full BiRefNet Core ML model and an explicitly selected Apple Vision alternative.
- Add PDF merging, ordered page extraction and images-to-PDF.
- Add operation progress and cancellation for ZIP, media tools, file transfers and Trash batches.
- Preserve the compact shelf with two rows of four actions and a separate native tools window.


All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] - 2026-09-17

### Added
- Opt-in Clipboard tab with memory-only text and link history, exact-byte copy-back, full-text viewing, drag export, pinning, pause and clear.
- One-hour default expiry with 5-minute, 15-minute, 1-hour, 4-hour and 24-hour settings. Pins expire too; history clears on disable, quit, session lock or sleep.
- Sensitive pasteboard marker exclusions, current-device-only copy-back, and ownership-checked clearing of expired exports.
- Precision and privacy tests for long passages, whitespace, Unicode, URL bytes, expiry, capacity refusal and clipboard ownership.

## [1.2.5] - 2026-09-17

### Fixed
- Extend dragging across file-card backgrounds, including the lower blank area, while retaining clickable action buttons.
- Start card drags after three points of movement and reuse loaded previews instead of reading file icons during drag startup.

## [1.2.4] - 2026-09-17

### Changed
- Make Classic Refined 210 points wide with two rows of quick actions.
- Reflow header, selection controls, history, and file-card buttons for the compact width.
- Open preferences separately and route quick-action drops using actual button frames.
- Preserve the Original design at its previous width.

## [1.2.3] - 2026-09-17

### Fixed
- Recognize archive/attachment file promises immediately during drag and receive their files after drop, including legacy multi-file promises used by WinZip.
- Keep the shelf visible with a receiving indicator during deferred extraction; report failures without running actions on a partial batch.
- Remove the 20-item recent-history cap. Shelf references and incoming batches have no fixed file-count or byte-size quota; available memory, disk space, and source-app limits still apply.

## [1.2.2] - 2026-09-17

### Fixed
- Keep Quick Look visible when another app gains focus, activate its window on opening, and show it across Spaces alongside the shelf.
- Make the full preview button clickable and label it for accessibility.

## [1.2.1] - 2026-09-17

### Fixed
- Make the full Copy and Cut button enclosures clickable, including their empty padding.
- Add a repeatable Applications install-and-restart mode to avoid launching an older development or disk-image copy.

## [1.2.0] - 2026-09-17

### Added
- Classic Refined appearance based on the approved compact design, enabled by default.
- Original appearance selector in Preferences, preserving the previous artwork and styling.
- Twenty bundled icon assets, with matching light/dark slate and blue palettes.
- Subtle hover, selection, and drag-target effects with Reduce Motion support.
- Native visual checks for compact layouts, icon loading, and appearance switching.

### Changed
- Keep all seven quick actions, Copy/Cut, history, selection, stacking, and native drag operations in the original compact layout.
- Keep file-row pin, contextual action, and remove buttons visible in Classic Refined.
- Match the floating panel's size to its 310 × 520 content to prevent clipping.

## [1.1.8] - 2026-09-17

### Changed
- Adopt the supplied wooden shelf app icon for the application bundle, shelf header, edge tab, Preferences, and fallback branding.
- Replace the menu bar artwork with adaptive monochrome 1x/2x template icons, including a live drag-state variant.
- Integrate supplied toolbar artwork for history, settings, copy, stacking, pinning, clearing, empty shelves, and dropping.
- Cache native image representations; preserve system file thumbnails and distinct action/state symbols.

## [1.1.7] - 2026-09-17

### Fixed
- Restore immediate shelf appearance when a supported content drag begins, without requiring shake or edge proximity.
- Keep normal window movement and stale drag pasteboard contents from triggering the shelf.
- Preserve temporary expansion and re-collapse when a drag opens a collapsed shelf.

### Added
- Optional "Require a shake to show the shelf" setting, disabled by default and saved across launches.
- Regression coverage for drag start, release, stale payloads, disabled automatic showing, and shake-only behavior.

## [1.1.6] - 2026-09-17

### Fixed
- Track generated ownership per file through stacking and splitting; automatic cleanup cannot delete original files in mixed stacks.
- Retain generated files for session history, clean them on eviction/clear, and reject stale restore entries.
- Preserve duplicate filenames from different folders in ZIP archives and fail on staging errors or nonzero ZIP exits.
- Use native Quick Look previews from the eye button and Space key.
- Make stack and unstack URL commands idempotent; preserve non-file and pinned items during stacking.
- Apply toolbar actions to the selected files and retain unprocessed stack members after partial actions.
- Correct stale version labels, Cut/ZIP tooltips, and overclaimed security documentation.
- Add executable regression checks.

## [1.1.5] - 2026-09-17

Historical release notes below describe claims made at release time. The current security policy supersedes the earlier sandbox, network-isolation, and compliance claims.

### Fixed
- Shake-to-Show Detection Engine:
  - Replaced the premature distance trigger with a dual-engine architecture combining pasteboard change detection and high-frequency cursor polling.
  - Implemented multi-axis directional reversal detection (both horizontal and vertical) over a rolling 400ms window, requiring at least 3 distinct directional reversals with amplitude > 10pt and cumulative travel > 55pt.
  - Added immediate audio feedback ("Pop") upon shake recognition.
  - Eliminated the requirement for invasive macOS Accessibility permissions (`AXIsProcessTrusted`), allowing shake detection to work seamlessly across Finder, Safari, and third-party apps out-of-the-box.

### Security
- Enterprise Gold-Standard Security and Privacy Hardening:
  - 100% Air-Gapped and Zero Network Connectivity: verified zero network imports (`Network`, `CFNetwork`, `URLSession`, sockets) and explicitly disabled socket creation at the OS entitlements level.
  - Official Apple Privacy Manifest: added `PrivacyInfo.xcprivacy` declaring zero data collection (`NSPrivacyCollectedDataTypes: []`) and zero tracking (`NSPrivacyTracking: false`).
  - Hardened Runtime: enabled Apple's Hardened Runtime (`--options runtime`) in codesigning to protect against JIT exploits, memory tampering, and unauthorized dynamic library loading.
  - Entitlements Lockdown: added `DropShelf.entitlements` strictly limiting sandbox access to user-selected files.
  - POSIX 0700 Staging Isolation: enforced `0700` (`rwx------`) file permissions on all temporary staging folders, preventing cross-user data leakage on shared systems.
  - IPC and URL Scheme Defense: added 64 KB bounds enforcement on text snippets and standardized path validation to prevent memory exhaustion and traversal vulnerabilities.
  - Published comprehensive `SECURITY.md` detailing security architecture, threat model, and vulnerability reporting protocols.

## [1.1.4] - 2026-09-17

### Changed
- Relocated Stack / Unstack Controls:
  - Moved the Stack All / Unstack button from the top header toolbar down directly between the Drag All pill and Select All button.
  - Placed batch actions together in one dedicated, accessible control row right above the file cards.
  - Styled Stack / Unstack as a clear, high-contrast capsule button with dynamic state switching: "Stack All" when items are separate, and active blue "Unstack" when items are grouped in a single stack.
  - Kept the control bar visible when items are collapsed into a single stack so users can unstack with a single click.
  - Uncluttered the top header toolbar, keeping it focused on title, history, action grid, settings, and collapse.

### Added
- Automation for Stacking:
  - Added `--stack` and `--unstack` commands to the `dropshelf` CLI utility.
  - Added `dropshelf://stack` and `dropshelf://unstack` URL scheme handling.
  - Added `com.dropshelf.toggleStack` distributed notification for scriptable toggling.

## [1.1.3] - 2026-09-17

### Added
- System-Adaptive Light Theme Contrast:
  - Enhanced `ShelfStore` with an effective appearance detector (`isEffectiveLightMode`) that properly evaluates Auto mode against macOS aqua and darkAqua appearances.
  - Redesigned Quick Action Grid tiles with dark labels, high-contrast borders, tinted icons, and dark subtle tile backgrounds when in Light mode.
  - Redesigned Shelf Item cards, thumbnail containers, text cards, badges, and the Drag All pill for crisp readability on Light backgrounds.
  - Added CLI options `--theme <dark|light|auto>`, `--mode <copy|cut>`, and `--grid` alongside matching `dropshelf://theme?name=...`, `dropshelf://mode?name=...`, and `dropshelf://grid` URL scheme endpoints.

### Fixed
- Copy and Cut Transfer Mechanics:
  - Fixed Copy mode to strictly advertise `[.copy]` dragging source operations to Finder, ensuring Finder duplicates items rather than moving source files when dragging to other folders on the same volume.
  - Eliminated manual trashing (`FileManager.trashItem`) on drag completion. In Cut mode, Finder's native move operation safely relocates files to their new destination.
  - Fixed dragging items back to their origin folder in Cut or Copy mode: files remain safely untouched without risk of accidental deletion.

### Changed
- Clarified Quick Action Grid:
  - Updated Downloads quick action tooltip and label semantics ("Send/copy files to Downloads (~/Downloads)") to clearly distinguish it from downloading remote content.

## [1.1.2] - 2026-09-17

### Changed
- Unified Collapse/Uncollapse Controls:
  - Replaced the confusing dual-button setup (separate Pin button and Collapse chevron) with a single, unified collapse and uncollapse control in the header toolbar.
  - When expanded, clicking the chevron button collapses the shelf into an edge tab.
  - When peeking from the edge tab, clicking the chevron button, clicking the edge tab itself, or clicking anywhere inside the shelf or cards uncollapses and locks the shelf open without collapsing on mouse exit.
  - Streamlined the menu bar context menu to display a single contextual action ("Collapse to Edge Tab" or "Uncollapse Shelf") only when items are stored.
  - Updated CLI command `--uncollapse` and URL scheme `dropshelf://uncollapse` to replace redundant pin actions.

### Fixed
- Auto-hide when empty:
  - Ensured that neither the shelf panel nor the collapsed edge tab icon remains visible on screen when empty.
  - When all items are dragged out, removed, or cleared, the shelf and edge tab immediately and cleanly hide.
  - Collapsing an empty shelf now triggers an immediate panel hide instead of leaving an empty edge tab stranded on the desktop.
  - Dragging items over and away from the shelf or cancelling drops without adding content immediately hides the shelf.

## [1.1.1] - 2026-09-17

### Added
- Intelligent Edge Collapse and Pin Management system:
  - Keep Open / Pin Open mode: introduced multi-point pinning controls ensuring the shelf remains uncollapsed and open on screen whenever desired.
  - Interactive "Keep Open" badge: hovering over the edge tab in peek mode displays a prominent animated "Keep Open" action badge in the header for single-click window locking.
  - Dedicated Pin button: added toolbar Pin toggle button (`pin` / `pin.fill`) with real-time visual feedback indicating whether the window is currently pinned open.
  - Gesture-based auto-pin: clicking anywhere inside the shelf, interacting with cards, selecting items, or dragging items while peeking automatically pins the window open to prevent unexpected collapse.
  - Explicit collapse action: clicking the collapse chevron (`chevron.right.2` / `chevron.left.2`) immediately collapses the shelf to the edge tab.
  - Context menu and Preferences controls: integrated "Keep Shelf Pinned Open", "Expand Shelf (Keep Open)", and "Collapse to Edge Tab" items into the menu bar right-click menu, along with a dedicated "Keep shelf pinned open" checkbox in Preferences.
  - CLI and URL scheme extensions: added `--pin`, `--collapse`, and `--expand` commands to the `dropshelf` CLI utility and custom URL scheme (`dropshelf://collapse`, `dropshelf://expand`, `dropshelf://pin`).

### Fixed
- Edge tab hover and peek behavior: resolved the issue where hovering over the collapsed edge tab opened the shelf but moving the cursor away always collapsed it back with no mechanism to keep the window open.

## [1.1.0] - 2026-09-17

### Added
- Light, Dark, and System Auto appearance themes: user-selectable themes dynamically adjusting NSPanel backing, visual effect materials, foreground colors, borders, and controls across the entire application.
- Window Opacity and Glass Density controls: configurable glass translucency from 40% to 100% opacity with adjustable visual effect materials (Regular Blur, Ultra Thin Material, and HUD Window) persisted across application restarts.
- Smart Content Cards:
  - Interactive Web URL cards: auto-detects dragged or shared web links, extracting root domains and providing single-click "Open in Browser" actions.
  - Interactive Color Hex cards: automatically parses 3-, 6-, and 8-character hex codes and RGB color strings into live color chips with "Copy Hex" clipboard actions.
  - Text snippet cards: dedicated "Copy Text" quick action for copied or dropped notes and code snippets.
- Recent Drops History drawer: an ephemeral restore drawer retaining recently cleared or dragged-out items, allowing one-click individual restoration or bulk recovery back onto the active shelf.
- Finder Context Menu Quick Action: introduced "Send to DropShelf" Automator service workflow with one-click installation from Preferences, enabling direct routing of selected Finder files to DropShelf.
- Command-line interface and URL automation: added `dropshelf` CLI executable supporting file additions, text snippets, visibility toggling (`--toggle`), shelf clearing (`--clear`), and history inspection (`--history`), backed by the `dropshelf://` custom URL scheme.

### Fixed
- Edge tab peek and auto-collapse coherence: hovering over the minimized edge tab smoothly expands the shelf for preview; moving the cursor away automatically collapses back to the edge tab without leaving the full panel stranded open.
- Header title typography: adjusted spacing, minimum width, and text wrapping constraints to ensure the DropShelf title remains crisply rendered on a single line regardless of badge counts or expanded toolbar buttons.

## [1.0.9] - 2026-09-17

### Added
- Sound effects configuration: introduced a preference to enable or disable audio feedback during drag-and-drop actions, available in Preferences, the right-click menu bar menu, and persisted in application defaults.
- Menu bar 3-second auto-dismiss timer: summoning an empty shelf via the menu bar icon arms a 3-second timer that automatically closes the shelf if no interaction occurs. Hovering the cursor over the panel, dragging items over it, or adding content immediately cancels the timer.
- Expanded menu bar context menu: right-clicking the status item provides comprehensive inline controls, including direct access to Preferences, Dock Position selection (Left/Right), Transfer Mode selection (Copy/Cut), Sound Effects toggle, Show on Drag toggle, Quick Action Grid toggle, and Auto-Stack toggle.
- Standalone Preferences window: added `PreferencesWindowController` enabling users to open DropShelf settings from the status bar menu or via standard `Command + ,` key equivalent.

### Fixed
- Menu bar icon click behavior: eliminated premature dismissal caused by global mouse-up handlers, allowing a single click on the menu bar icon to reliably open the shelf without requiring the mouse button to remain depressed.

## [1.0.8] - 2026-09-17

### Added
- Start at login configuration: native integration with macOS Service Management (`SMAppService.mainApp`), allowing users to toggle auto-start on system boot via Preferences and the menu bar status context menu.
- Standalone disk image packaging: automated creation of `DropShelf.dmg` containing a pre-configured drag-and-drop `/Applications` shortcut for instant, zero-setup installation without requiring Xcode, Swift compiler, or developer toolchains.

### Changed
- Build pipeline enhancement: updated `build.sh` to compile with `ServiceManagement.framework` and automatically assemble compressed distribution disk images.
- Documentation overhaul: restructured README to prominently guide users through direct prebuilt disk image installation, with developer source compilation maintained as a secondary reference.

## [1.0.7] - 2026-09-17

### Fixed
- Menu bar status item icon: replaced generic SF Symbol tray icon with the branded DropShelf glass shelf icon, including dedicated standard (18x18) and Retina @2x (36x36) bitmap assets optimized for contrast and sharpness in the macOS menu bar.

## [1.0.6] - 2026-09-17

### Fixed
- Application icon border elimination: cropped dark outer padding from Resources/icon.png and regenerated multi-resolution Resources/AppIcon.icns with standard anti-aliased macOS squircle geometry and transparent background, eliminating all excess dark margins across the system and UI.
- Replaced generic SF Symbol tray icons across the interface (floating shelf header, collapsed edge tab, and card thumbnail fallbacks) with the authentic DropShelf brand icon via the new AppIconView component.

### Changed
- Scaled window dimensions to fit 3 items simultaneously: adjusted panel dimensions to 316pt width and 480pt height with a 240pt scroll view container, providing a compact footprint for 3 visible items with continuous vertical scrolling for 4 or more items.

## [1.0.5] - 2026-09-17

### Fixed
- Multi-selection with Command and Shift keys: integrated CoreGraphics instantaneous hardware modifier state evaluation (`CGEventSource.flagsState`) and adjusted drag initiation threshold (8px) so clicks on trackpads and mice reliably register Command-click and Shift-click selection without prematurely triggering dragging sessions.
- Re-architected item card event layers: card content text and thumbnails no longer intercept mouse events, ensuring all clicks, selection gestures, and drag sessions are cleanly routed to the underlying AppKit interaction engine while preserving dedicated hit testing for card action buttons.

### Changed
- Increased panel window height from 460pt to 620pt (width to 320pt) with dynamic screen fitting, providing full visibility for up to 5 items simultaneously even with the Quick Action Grid expanded.
- Increased scroll view max height to 450pt with continuous vertical scrolling for 6 or more items.

## [1.0.4] - 2026-09-17

### Fixed
- Header stack control updated to a persistent bidirectional Stack / Unstack toggle that never disappears after combining items. When files are grouped into a single stack, the button remains active in the header bar with an unstack indicator, allowing users to separate the stack directly from the top bar.
- Resolved cramped toolbar layout below transfer toggle: eliminated the squished, multi-line wrapping text buttons for stack and separate.
- Streamlined item toolbar into a clean Drag All pill and selection management controls (Select All, Deselect, Stack Selected) with proper spacing and breathing room.

## [1.0.3] - 2026-09-17

### Fixed
- Drag detection strictly differentiates between window positioning and material drags: moving, organizing, or tiling Finder windows on screen no longer summons DropShelf.
- Real-time drag validation requires an active system drag pasteboard update with authentic draggable payload (files, folders, URLs, images, text) before triggering shelf presentation.

## [1.0.2] - 2026-09-16

### Added
- Dynamic drag-over auto-expansion for collapsed edge tab: dragging files onto the edge tab automatically expands the shelf to receive drops.
- Automatic re-collapse to edge tab mode immediately after drop completion or when the drag operation is exited/cancelled.

## [1.0.1] - 2026-09-16

### Added
- High-resolution application icon asset Resources/icon.png (1024x1024) embedded into repository documentation.
- Developer attribution for Arslan Hamid baked into application bundle metadata (Info.plist), Preferences window (SettingsView), and menu bar status item.
- Interactive link to the GitHub repository within application settings.

## [1.0.0] - 2026-09-16

### Added
- Floating edge-docked shelf window with AppKit non-activating panel architecture.
- Real-time global drag detection via CoreGraphics CGEventTap and NSEvent global monitors.
- Dynamic gesture detection including cursor shake and proximity edge targeting.
- Glassmorphic user interface built with SwiftUI and AppKit visual effect blurs.
- Two-mode transfer pipeline supporting Copy mode (file duplication) and Cut mode (file move with trash cleanup).
- Quick Action Grid providing instant execution for Archive (-9 compression), Copy Path, AirDrop, Desktop routing, Downloads routing, Lossless PNG conversion, and Trash.
- Native multi-file AppKit dragging session engine via NSDraggingSource and NSDraggingItem.
- Stack management with automated grouping, batch stacking, individual stack splitting, and separation controls.
- Keyboard navigation and shortcut handling including Command-A (Select All), Escape (Deselect), Delete/Backspace (Remove), and Space (Quick Look).
- Ephemeral file lifecycle manager ensuring generated archives and converted assets are purged from disk upon shelf dismissal or clearing.
- Edge tab minimization and auto-hide configuration options.

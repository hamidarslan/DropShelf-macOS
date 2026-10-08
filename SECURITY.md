# Security policy

DropShelf processes files locally and has no analytics or telemetry client in its source. It is not an air-gapped application or an enterprise security certification.

## Execution and signing

The current build runs outside App Sandbox with the current user's filesystem permissions, subject to macOS privacy controls. Network sandbox entitlements do not impose a network firewall on a non-sandboxed application. AirDrop uses macOS sharing services, and opening a link hands it to the default browser; these actions can use the network. The optional BiRefNet background model is downloaded over HTTPS from pinned Hugging Face URLs only after the user presses **Download Model**. Image contents are never included in those requests.

`build.sh` enables Hardened Runtime and uses an ad-hoc signature. This does not establish Developer ID identity or notarization, and does not guarantee Gatekeeper acceptance on another Mac. Hardened Runtime is distinct from App Sandbox and does not prevent every vulnerability.

## Menu bar verification

On macOS 27 and later, the organizer requests Accessibility permission only after the user presses its verification button in Settings. macOS grants broad access with this permission. The organizer's implementation uses read-only Accessibility queries to locate its arrow and divider in MenuBarAgent, check their frames, and verify the arrow at its on-screen position. It does not perform Accessibility actions, synthesize input, inspect document contents, record the screen, or upload menu-bar data.

Queries run off the main thread with node, depth, and time limits. Temporary overlays and brief query failures do not erase a verified layout. Repeated evidence of an unreachable arrow or prolonged uncertain verification restores icons and pauses hiding while retaining setup. Recovery does not start a timed test; only the explicit Settings test uses an auto-restore timer. Missing permission prevents hiding. Local system logs record verification reason codes and timing, without UI text or file contents. The organizer uses native status items, not assessment-mode restrictions or persistent unloading of other apps' icons. Ad-hoc signing means a new build can require a renewed Accessibility grant. These checks reduce the risk of losing the reveal control; they cannot guarantee compatibility with untested future macOS releases.

## Auto Quit

Auto Quit is off by default and requires user enablement. The module uses Accessibility window creation/destruction notifications, window roles, and typed window lists. It reads application identity and window lifecycle/state only, without window titles, document contents, screenshots, or uploads. Only preferences, the first-use explanation acknowledgement, and Keep running bundle identifiers are saved; window/process tracking stays in memory.

A known last-window destruction starts a one-second delay. A fresh successful empty-window check, unchanged process identity, valid permission, and current exception settings are required before sending `NSRunningApplication.terminate()`. Requests allow the target app's normal save prompts or refusal. The module never force-quits, sends kill signals, edits Dock preferences, or repeatedly requests quitting for the same event. Missing or failed reads remain uncertain, and unsupported apps are left running. Observer registration retries briefly while an app initializes, with bounded delays and process-lifetime checks. Local system diagnostics contain process IDs, notification kinds, window counts, and decision/error codes, without app titles, document contents, or uploads.

Finder, DropShelf, Dock, login/system services, and non-regular/background agents are excluded. Remaining window identities are retained until their destruction is observed, including minimized or hidden windows. Pending requests are canceled on disablement, exception changes, process exit, permission loss, and sleep. Normal quitting can still interrupt background work an app does not protect; the user must put these apps in Keep running. These checks do not prove that every app exposes complete Accessibility information or that an app's own quit implementation preserves all work.

## Files and history

Original file references are never eligible for automatic cleanup. Generated file ownership is recorded per URL and cleanup is restricted to the staging directory, including a resolved-path check. Stacking and splitting preserve that ownership.

Clear and dismiss retain generated files in the in-memory history, so Restore can work. Unreferenced generated files are removed when history is cleared or entries are evicted. Staging is also cleaned at application startup and normal termination. Crashes can leave temporary files until a later launch. Deletion is ordinary filesystem removal, not secure erasure. History is not a backup: originals moved or deleted externally may no longer be restorable.

Staging directories request owner-only `0700` permissions. These permissions do not exclude other processes running as the same user or an administrator. Explicit Cut and Trash actions can move original files.

## Media tools and model downloads

Image and PDF processing creates new outputs in private per-job staging directories. Cancellation removes incomplete outputs. An in-flight operation holds its generated inputs against history cleanup, and quitting waits for cancellation before staging is purged. Completed copies, moves and Trash actions cannot be treated as automatically undone.

The optional full BiRefNet Core ML package is pinned to a specific revision with byte counts and SHA-256 checks for every downloaded file. It is not included in DropShelf.app or DropShelf.dmg. The build fails if a Core ML package, compiled model, or weight artifact appears in bundled resources. The model is stored locally under Application Support and runs through Core ML; no model-provided Python or remote inference code is executed.

The model download is an explicit operation available in Preferences and **Images > Remove background**. Selecting Quality or starting background removal does not download or repair a missing model. Once installation succeeds, Quality processing loads the installed local model automatically. The same controls can remove the downloaded package and compiled cache. The separate Apple Vision engine also runs locally and needs no download. Both engines can make segmentation errors. Downloading weights is a network operation and is not an anonymity guarantee. User image processing does not create a cloud copy.

Filesystem permissions do not protect against a compromised process with the same user privileges. Models, media decoders and PDF parsers remain attack surfaces; package checksums verify the selected artifact, not absence of vulnerabilities.

## External input and processes

ZIP is invoked using `Process` with individual arguments and relative paths prefixed with `./`. Copy failures and nonzero ZIP exits fail the operation. Inputs from different directories use separate archive subdirectories to preserve identical filenames.

URL commands and local distributed notifications are automation interfaces, not authenticated security boundaries. File existence checks are not a filesystem access allowlist. The text URL handler limits snippets; this does not constitute comprehensive denial-of-service protection.

## Privacy manifest

`Resources/PrivacyInfo.xcprivacy` declares no tracking or collected data and lists required-reason API usage. The manifest is a developer declaration, not proof of independent compliance review.

## Reporting

Report a suspected vulnerability through the repository's private reporting feature, if enabled, at [GitHub Security](https://github.com/hamidarslan/DropShelf-macOS/security). Do not post sensitive files or exploit details in a public issue. Maintainer: Arslan Hamid. The GitHub noreply commit address is not a support inbox.

## Validation

Run `bash Tests/run.sh` for the regression checks. Passing checks cover the tested cases only; macOS drag destinations, sharing, permissions, and distribution still require validation on supported systems.

References: [Apple App Sandbox](https://developer.apple.com/documentation/security/app-sandbox), [network client entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client).

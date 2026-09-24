# Security policy

DropShelf processes files locally and has no analytics or telemetry client in its source. It is not an air-gapped application or an enterprise security certification.

## Execution and signing

The current build runs outside App Sandbox with the current user's filesystem permissions, subject to macOS privacy controls. Network sandbox entitlements do not impose a network firewall on a non-sandboxed application. AirDrop uses macOS sharing services, and opening a link hands it to the default browser; these actions can use the network. The optional BiRefNet background model is downloaded over HTTPS from pinned Hugging Face URLs only after the user presses **Download Model**. Image contents are never included in those requests.

`build.sh` enables Hardened Runtime and uses an ad-hoc signature. This does not establish Developer ID identity or notarization, and does not guarantee Gatekeeper acceptance on another Mac. Hardened Runtime is distinct from App Sandbox and does not prevent every vulnerability.

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

# Clipboard privacy and exact-text behavior

## What stays local

Clipboard history has no network client, sync service, analytics, remote link previews, or automatic URL opening. Entry contents are stored only in process memory. Preferences stores two non-content values: enablement and expiry duration. History is not serialized, logged, staged as files, or exposed through DropShelf URL schemes, CLI or distributed notifications.

The system clipboard is shared with other apps. DropShelf cannot stop the source app, macOS Universal Clipboard, another clipboard manager, malware, or a screen recorder from accessing content outside its private history. This feature is not a security boundary against a compromised Mac. Process memory can be subject to operating-system swap or crash dumps; clearing references is not a secure-memory-erasure guarantee.

## Capture controls

History is disabled by default. Enabling/resuming starts at the current clipboard change count; it does not import an old copy. New stable text copies are read on a background queue. Copies marked concealed, transient, auto-generated, restored, remote, or with supported legacy password-manager markers are skipped. Marker support depends on the source app, so pause before copying secrets that may not be marked. Unknown custom representations, file copies and images are not captured.

Clipboard monitoring samples changes approximately every 0.4 seconds. Extremely rapid intermediate copies or a source that changes the clipboard while it is being read can be skipped. A stored entry is complete for the supported textual representations; it is never intentionally truncated.

## Exact text

DropShelf retains the original Data for supported UTF-8/UTF-16 text and URL representations, including item boundaries. Copy and drag export write those original representations. It does not trim spaces, normalize Unicode, change line endings, parse/reserialize URLs, or cut text to the card preview. Rich styles, HTML and images are not part of this text-only feature. A destination app can still interpret pasted text according to its own rules.

Full-text viewing is read-only. Multiple clipboard items are separated visually in that window; their original boundaries are restored on export. The Copy Exact Original button exports original data, not displayed preview text. URLs are shown as literal text, without automatic fetching or opening.

Tests cover a 30,000-word passage with leading/trailing whitespace, CR/LF combinations, tabs, NULs, nonbreaking spaces, decomposed/composed Unicode and emoji; raw URL case, percent escapes and query strings; and UTF-16 and multiple-item copies.

## Expiry and capacity

Default expiry is one hour. Settings provides 5 minutes, 15 minutes, 1 hour, 4 hours and 24 hours. Pins expire too. Shorter settings apply immediately to existing entries; longer settings apply to future captures and do not extend existing deadlines. Exact duplicate copies from the source app update their capture time; exporting from history does not reset expiry.

Expiry checks use wall time and elapsed uptime to resist a backward clock change. Every export checks expiry, including while paused. History and open detail windows clear on disable, quit, session lock or sleep. Expiry removes inaccessible entries on the next timer tick or immediately before access; the operating system can delay timers while the app is suspended.

History retains at most 50 entries, 32 MiB per capture and 128 MiB of payloads in total. Old unpinned entries are evicted first. A copy that cannot fit is rejected as a whole with a generic status message; the original system clipboard is unchanged. There is no word-count truncation.

## Explicit export

Copy-back uses Apple's [currentHostOnly option](https://developer.apple.com/documentation/appkit/nspasteboard/contentsoptions/currenthostonly), so that write is not made available to other devices by Universal Clipboard. It adds concealed/transient/private markers to discourage other historians. DropShelf never injects paste keystrokes.

On entry expiry/removal, clear, disable, lock, sleep or quit, DropShelf clears a copy-back it still owns only when the pasteboard change count and private marker still match. Newer clipboard content from another app is left untouched. Once you paste or drag into another app, its copy and any in-flight drag payload are outside DropShelf's control. Private clipboard drags are excluded from DropShelf file staging and quick actions.

Marker conventions: [NSPasteboard.org](https://nspasteboard.org/). These are compatibility signals, not enforceable access control.

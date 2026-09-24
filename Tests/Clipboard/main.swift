import Cocoa

func check(_ value: @autoclosure () -> Bool, _ label: String) {
    precondition(value(), label)
    print("PASS: \(label)")
}
let type = NSPasteboard.PasteboardType.string.rawValue
let original = Data(("  \t" + String(repeating: "word ", count: 30_000) + "\r\n\nend  \t").utf8)
let payload = ClipboardPayload(items: [[type: original]])!
check(payload.items[0][type] == original, "30,000-word source bytes are unchanged")
var history = ClipboardHistory()
let now = Date(timeIntervalSince1970: 10000)
check(history.capture(payload, at: now, uptime: 100) == .stored, "capture full passage")
check(history.entries[0].payload.items[0][type] == original, "stored passage bytes remain exact")
history.prune(at: now.addingTimeInterval(3600), uptime: 3700)
check(history.entries.isEmpty, "one-hour exact expiry boundary")

func textPayload(_ text: String) -> ClipboardPayload { ClipboardPayload(items: [[type: Data(text.utf8)]])! }
let variants = [" leading and trailing  ", "\r\nline\nline\r", "\t\t  ", "é", "e\u{301}", "👩🏽‍💻\u{200B}\u{00A0}", "https://EXAMPLE.com/a%2Fb?q=a+b&x=%20#Case", "\0text\0"]
for text in variants {
    let data = Data(text.utf8)
    check(textPayload(text).items[0][type] == data, "exact whitespace, URL, or Unicode fixture")
}
history = ClipboardHistory()
_ = history.capture(textPayload("é"), at: now, uptime: 100)
_ = history.capture(textPayload("e\u{301}"), at: now, uptime: 100)
check(history.entries.count == 2, "canonically equivalent Unicode with different bytes remains distinct")
_ = history.capture(textPayload("é"), at: now, uptime: 100)
check(history.entries.count == 2, "byte-identical duplicates combine")
let pin = history.entries[0].id
history.togglePin(pin)
history.prune(at: now.addingTimeInterval(3599), uptime: 3699)
check(history.entries.count == 2, "entries remain just before deadline")
history.prune(at: now.addingTimeInterval(-100), uptime: 3700)
check(history.entries.isEmpty, "clock rollback cannot extend retention, including pins")
history = ClipboardHistory()
_ = history.capture(payload, at: now, uptime: 100)
history.retention = .fiveMinutes
history.prune(at: now.addingTimeInterval(300), uptime: 400)
check(history.entries.isEmpty, "shorter retention applies immediately")
history = ClipboardHistory()
_ = history.capture(payload, at: now, uptime: 100)
history.retention = .oneDay
history.prune(at: now.addingTimeInterval(3600), uptime: 3700)
check(history.entries.isEmpty, "longer setting cannot extend an existing deadline")
history = ClipboardHistory()
history.maximumEntries = 2
_ = history.capture(textPayload("one"), at: now, uptime: 100)
history.togglePin(history.entries[0].id)
_ = history.capture(textPayload("two"), at: now, uptime: 100)
history.togglePin(history.entries[0].id)
check(history.capture(textPayload("three"), at: now, uptime: 100) == .full, "all-pinned capacity refuses whole new entry")
check(history.entries.count == 2, "refusal does not remove pins")
history = ClipboardHistory()
history.maximumEntryBytes = 5
check(history.capture(textPayload("123456"), at: now, uptime: 100) == .tooLarge, "oversized entry refused without truncation")
check(history.entries.isEmpty, "no partial entry retained")

let board = NSPasteboard.withUniqueName()
defer { board.releaseGlobally() }
func put(_ payload: ClipboardPayload, marker: String? = nil) {
    board.clearContents()
    let objects = payload.items.map { dict -> NSPasteboardItem in
        let item = NSPasteboardItem()
        for (key, data) in dict { item.setData(data, forType: NSPasteboard.PasteboardType(key)) }
        if let marker = marker { item.setData(Data(), forType: NSPasteboard.PasteboardType(marker)) }
        return item
    }
    check(board.writeObjects(objects), "write isolated fixture")
}
for text in variants {
    let expected = textPayload(text)
    put(expected)
    guard case .captured(let captured) = ClipboardPasteboard.read(board) else { fatalError("Expected exact text capture") }
    check(captured.items[0][type] == Data(text.utf8), "special-character capture bytes match")
    check(ClipboardPasteboard.write(captured, to: board), "special-character export succeeds")
    check(board.data(forType: .string) == Data(text.utf8), "special-character pasteboard round trip is exact")
}
put(payload)
if case .captured(let read) = ClipboardPasteboard.read(board) { check(read == payload, "30,000-word named-pasteboard capture is exact") }
else { fatalError("Expected captured passage") }
check(ClipboardPasteboard.write(payload, to: board), "explicit local copy-back succeeds")
check(board.pasteboardItems![0].data(forType: .string) == original, "copy-back preserves all original bytes")
if case .ignored = ClipboardPasteboard.read(board) {} else { fatalError("Own exports must not be recaptured") }
for marker in ClipboardPasteboard.blockedTypes where !marker.contains(" ") {
    put(payload, marker: marker)
    if case .ignored = ClipboardPasteboard.read(board) {} else { fatalError("Sensitive marker was not excluded") }
}
print("PASS: all sensitive, transient, remote and own-copy markers excluded")
let urlBytes = Data("https://EXAMPLE.com/a%2Fb?x=a+b&y=%20#MixedCase".utf8)
let multi = ClipboardPayload(items: [[type: Data("  first\r\n".utf8)], [type: urlBytes, NSPasteboard.PasteboardType.URL.rawValue: urlBytes]])!
put(multi)
if case .captured(let read) = ClipboardPasteboard.read(board) { check(read == multi, "multiple items and raw URL representations preserved") }
else { fatalError("Expected multi-item capture") }
check(ClipboardPasteboard.write(multi, to: board), "multi-item copy-back succeeds")
for (actual, expected) in zip(board.pasteboardItems!, multi.items) {
    for (key, data) in expected { check(actual.data(forType: NSPasteboard.PasteboardType(key)) == data, "multi-item export bytes match") }
}
let utf16Type = "public.utf16-external-plain-text"
let utf16 = ClipboardPayload(items: [[utf16Type: "  é\r\n\t".data(using: .utf16)!]])!
put(utf16)
if case .captured(let read) = ClipboardPasteboard.read(board) { check(read.items[0][utf16Type] == utf16.items[0][utf16Type], "UTF-16 source bytes preserved") }
else { fatalError("Expected UTF-16 capture") }
check(ClipboardPasteboard.write(utf16, to: board), "UTF-16 export succeeds")
check(board.pasteboardItems![0].data(forType: NSPasteboard.PasteboardType(utf16Type)) == utf16.items[0][utf16Type], "UTF-16 export bytes match")
put(payload)
if case .tooLarge = ClipboardPasteboard.read(board, maximumBytes: 20) {} else { fatalError("Capture must refuse oversized payload whole") }

let suite = "com.dropshelf.clipboard.tests.\(UUID().uuidString)"
let preferences = UserDefaults(suiteName: suite)!
defer { preferences.removePersistentDomain(forName: suite) }
var clock = now
var ticks: TimeInterval = 100
let monitor = ClipboardStore(pasteboard: board, defaults: preferences, date: { clock }, uptime: { ticks })
func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
check(!monitor.enabled, "history defaults to opt-in")
check(monitor.retention == .oneHour, "retention defaults to one hour")
monitor.poll(); settle()
check(monitor.entries.isEmpty, "disabled monitor does not capture")
monitor.setEnabled(true)
monitor.poll(); settle()
check(monitor.entries.isEmpty, "enabling does not import old clipboard")
put(payload); monitor.poll(); settle()
check(monitor.entries.count == 1, "enabled monitor captures new copy")
let savedID = monitor.entries[0].id
check(monitor.copy(savedID), "saved entry can be copied")
check(board.data(forType: .string) == original, "monitor copy-back is byte-identical")
put(textPayload("newer external clipboard"))
monitor.clear()
check(board.string(forType: .string) == "newer external clipboard", "clear leaves newer external clipboard untouched")
put(payload); monitor.poll(); settle()
check(monitor.copy(monitor.entries[0].id), "owned copy prepared for expiry test")
monitor.setPaused(true)
clock = now.addingTimeInterval(3600); ticks = 3700
monitor.poll()
check(monitor.entries.isEmpty, "paused history still expires")
check(board.data(forType: .string) == nil, "expiry clears only the owned clipboard export")
check(!monitor.copy(savedID), "expired entry cannot be exported")
monitor.setPaused(false)
put(textPayload("discard in flight")); monitor.poll(); monitor.setPaused(true); settle()
check(monitor.entries.isEmpty, "pause invalidates in-flight capture")
monitor.setPaused(false)
put(payload); monitor.poll(); settle()
check(monitor.entries.count == 1, "resume captures fresh content")
monitor.setEnabled(false)
check(monitor.entries.isEmpty, "disable clears all history")
monitor.setEnabled(true)
put(payload); monitor.poll(); settle()
monitor.suspend()
check(monitor.entries.isEmpty, "session suspension clears all history")
put(textPayload("while locked")); monitor.resumeSession(); monitor.poll(); settle()
check(monitor.entries.isEmpty, "session resume ignores prior clipboard")
check(Set(preferences.persistentDomain(forName: suite)!.keys).isSubset(of: ["clipboardHistoryEnabled", "clipboardExpirySeconds"]), "only non-content preferences persisted")
monitor.lockScreen()
monitor.resumeSession()
put(textPayload("while still locked")); monitor.poll(); settle()
check(monitor.entries.isEmpty, "wake notification cannot resume capture while screen remains locked")
monitor.unlockScreen(); monitor.poll(); settle()
check(monitor.entries.isEmpty, "unlock starts with a fresh clipboard baseline")
put(textPayload("stale capture")); monitor.poll()
put(textPayload("replacement copy")); settle()
check(monitor.entries.isEmpty, "clipboard changes during capture discard the stale result")
monitor.poll(); settle()
check(monitor.entries.count == 1 && monitor.entries[0].payload.items[0][type] == Data("replacement copy".utf8), "next poll captures only the stable replacement")
monitor.stop()
print("PASS: clipboard security and precision suite complete")

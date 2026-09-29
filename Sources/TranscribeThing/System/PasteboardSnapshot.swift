import AppKit
import UniformTypeIdentifiers

/// What a pasteboard held, every item with every type's data, so it can be put back after a paste replaced it.
struct PasteboardSnapshot {
    struct Item {
        var entries: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    var items: [Item]

    /// The most a snapshot holds: a full-resolution screenshot of any Mac display, even as TIFF (a 6K display's is
    /// 81 MB). Sizes are only known once read, so an app that renders a huge canvas for the clipboard has done so by
    /// the time the snapshot gives up on it.
    static let maxBytes = 128 * 1024 * 1024

    /// How long a snapshot keeps reading. An ordinary clipboard takes milliseconds (a 5K screenshot as PNG and TIFF,
    /// 64 MB, reads from another app in 20 ms); thousands of Finder files or an app rendering several large types one
    /// after another take most of a second. One read can't be cut short: an app that hangs providing its data holds
    /// it up for as long as it hangs.
    static let timeLimit = Duration.seconds(1)

    /// Universal Clipboard: the data still lives on the other device.
    static let remoteClipboardType = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")

    /// A file promise can't be kept: its promising app would write the file when it's read, and the promise goes
    /// with the item. The item's other types still come back.
    private static let promiseTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData"),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type"),
    ]

    /// Reads every type of every item, which makes an app that provides its data lazily produce it now. Nil when what
    /// is there can't be kept: this app may not read other apps' clipboard (it would ask every time), it's larger
    /// than `maxBytes` or takes longer than `timeLimit` to read, or it's a Universal Clipboard image or file that would
    /// first come over from the other device. A clipboard marked concealed (a password manager's copy) is kept as
    /// empty, without reading it: put back, the secret would outlive the manager's own clearing, which stops once the
    /// clipboard has changed.
    static func capture(_ pasteboard: NSPasteboard, maxBytes: Int = Self.maxBytes,
                        timeLimit: Duration = Self.timeLimit) -> PasteboardSnapshot? {
        guard mayRead(pasteboard), let pasteboardItems = pasteboard.pasteboardItems else { return nil }
        let types = pasteboardItems.map(\.types)
        if types.contains(where: { $0.contains(PasteboardMarkers.concealedType) }) { return PasteboardSnapshot(items: []) }
        if isSlowRemote(types: types) { return nil }
        let deadline = ContinuousClock.now + timeLimit
        var total = 0
        var items: [Item] = []
        for item in pasteboardItems {
            var entries: [(type: NSPasteboard.PasteboardType, data: Data)] = []
            for type in item.types where !promiseTypes.contains(type) {
                guard ContinuousClock.now < deadline else { return nil }
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                if total > maxBytes { return nil }
                entries.append((type, data))
            }
            if !entries.isEmpty { items.append(Item(entries: entries)) }
        }
        return PasteboardSnapshot(items: items)
    }

    /// A Universal Clipboard photo or file is fetched from the other device when read, synchronously, for seconds.
    /// Remote text and web links are small and are still kept. Only type names are inspected, which reads no data.
    static func isSlowRemote(types: [[NSPasteboard.PasteboardType]]) -> Bool {
        let all = types.flatMap { $0 }
        guard all.contains(remoteClipboardType) else { return false }
        return all.contains { type in
            // Markers and legacy names aren't declared types and carry no payload worth the worry.
            guard let uti = UTType(type.rawValue), uti.isDeclared else { return false }
            // A file URL is a URL too, but its file is what would come over.
            if uti.conforms(to: .fileURL) { return true }
            return !(uti.conforms(to: .text) || uti.conforms(to: .url))
        }
    }

    /// Pasteboard privacy (macOS 15.4 and later): with this app set to ask before reading another app's clipboard,
    /// or never to, the snapshot is skipped rather than prompting at every paste. `.default` means macOS has never
    /// asked about this app, and reading is allowed today; once macOS enforces pasteboard privacy, the general
    /// pasteboard asks at the first read, and from then on it's whatever the user picked (`.ask` until they choose to
    /// always allow).
    static func mayRead(_ pasteboard: NSPasteboard) -> Bool {
        switch pasteboard.accessBehavior {
        case .alwaysAllow, .default: true
        case .ask, .alwaysDeny: false
        @unknown default: false
        }
    }

    /// Puts the items back as they were; an empty snapshot leaves the pasteboard empty.
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored: [NSPasteboardItem] = items.map { item in
            let copy = NSPasteboardItem()
            for entry in item.entries { copy.setData(entry.data, forType: entry.type) }
            return copy
        }
        _ = pasteboard.writeObjects(restored)
    }
}

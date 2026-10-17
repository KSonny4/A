import AppKit
import ApplicationServices
import FlareCore

extension Notification.Name {
    static let clipboardHistoryChanged = Notification.Name("FlareClipboardHistoryChanged")
}

/// Polls the general pasteboard and records every change, forever.
/// macOS has no pasteboard-changed notification, so polling `changeCount` is the standard approach.
@MainActor
final class ClipboardMonitor: NSObject {
    let store: ClipboardStore
    let queue = DispatchQueue(label: "flare.clipboard.store", qos: .userInitiated)

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var ignoredChangeCount: Int?
    private var timer: Timer?

    init(store: ClipboardStore) {
        self.store = store
        lastChangeCount = NSPasteboard.general.changeCount
        super.init()
    }

    func start() {
        guard timer == nil else { return }
        // Capture whatever is on the clipboard right now so history isn't empty on first launch.
        capture()
        let timer = Timer(timeInterval: 0.25, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Our own writes (paste from history) should not create a new entry.
    func ignoreCurrentChange() {
        ignoredChangeCount = pasteboard.changeCount
        lastChangeCount = pasteboard.changeCount
    }

    @objc private func tick() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        if count == ignoredChangeCount { return }
        capture()
    }

    private func capture() {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return }
        let allTypes = Set(items.flatMap { $0.types.map(\.rawValue) })
        guard allTypes.isDisjoint(with: PasteboardMarkers.skip) else { return }

        var payloadItems: [[ClipRepresentation]] = []
        for item in items {
            var reps: [ClipRepresentation] = []
            for type in item.types where !PasteboardMarkers.excludedTypes.contains(type.rawValue) {
                if let data = item.data(forType: type) {
                    reps.append(ClipRepresentation(type: type.rawValue, data: data))
                }
            }
            if !reps.isEmpty { payloadItems.append(reps) }
        }
        guard !payloadItems.isEmpty else { return }

        let string = pasteboard.string(forType: .string)
        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let front = NSWorkspace.shared.frontmostApplication
        let bundleID = front?.bundleIdentifier
        let appName = front?.localizedName
        let payload = ClipPayload(items: payloadItems)
        let store = self.store

        queue.async {
            var analysis = ClipAnalyzer.analyze(payload: payload, string: string, fileURLs: fileURLs)
            if analysis.kind == .image, let image = payload.firstData(ofTypes: PasteboardMarkers.imageTypes),
               let size = ImageDownsampler.pixelSize(data: image.data) {
                analysis.meta.imageWidth = size.0
                analysis.meta.imageHeight = size.1
            }
            do {
                try store.insert(payload: payload, analysis: analysis, sourceBundleID: bundleID, sourceAppName: appName)
                Task { @MainActor in
                    NotificationCenter.default.post(name: .clipboardHistoryChanged, object: nil)
                }
            } catch {
                NSLog("Flare: failed to save clipboard item: \(error)")
            }
        }
    }
}

/// Writes a history item back to the pasteboard and pastes it into the frontmost app (⌘V via CGEvent).
@MainActor
enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func copy(_ payload: ClipPayload, monitor: ClipboardMonitor) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = payload.items.map { reps in
            let item = NSPasteboardItem()
            for rep in reps {
                item.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.type))
            }
            return item
        }
        let ok = pasteboard.writeObjects(items)
        monitor.ignoreCurrentChange()
        return ok
    }

    /// Posts ⌘V to whatever app is frontmost.
    static func paste(into app: NSRunningApplication?) {
        let delay: TimeInterval
        if NSRunningApplication.current.isActive, let app {
            app.activate(options: [])
            delay = 0.15
        } else {
            delay = 0.05
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let vKey: CGKeyCode = 9
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
            down?.flags = .maskCommand
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }
}

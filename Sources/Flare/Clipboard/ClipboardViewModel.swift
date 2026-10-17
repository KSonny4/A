import AppKit
import FlareCore
import SwiftUI

private let clipPageSize = 100
private let detailTextLimit = 20_000

struct ClipDetail {
    let id: Int64
    var text: String?
    var isTruncated = false
    var image: NSImage?
    var isLoading = false
}

struct ClipSection: Identifiable {
    let id: String
    let title: String
    let records: [ClipRecord]
}

@MainActor
final class ClipboardViewModel: NSObject, ObservableObject, PanelKeyHandler {
    @Published var query = "" {
        didSet { if query != oldValue { reload() } }
    }
    @Published var filter: ClipKind? = nil {
        didSet { if filter != oldValue { reload() } }
    }
    @Published private(set) var records: [ClipRecord] = []
    @Published private(set) var sections: [ClipSection] = []
    @Published var selectedID: Int64? = nil {
        didSet { if selectedID != oldValue { loadDetail() } }
    }
    @Published private(set) var detail: ClipDetail?
    @Published var actionMenu = ActionMenuState()
    @Published private(set) var isTrusted = false
    @Published private(set) var totalCount = 0

    static let filters: [ClipKind?] = [nil, .text, .image, .file, .link, .color]

    weak var panel: PanelController?
    let monitor: ClipboardMonitor
    private var store: ClipboardStore { monitor.store }
    private var hasMore = false
    private var isLoadingMore = false
    private var generation = 0

    init(monitor: ClipboardMonitor) {
        self.monitor = monitor
        super.init()
        isTrusted = Paster.isTrusted
        NotificationCenter.default.addObserver(self, selector: #selector(historyChanged),
                                               name: .clipboardHistoryChanged, object: nil)
    }

    @objc private func historyChanged() {
        guard panel?.isVisible == true else { return }
        reload(keepSelection: true)
    }

    // MARK: - Panel

    func registerField(_ field: NSTextField) {
        panel?.searchField = field
    }

    func panelWillShow(resetState: Bool) {
        isTrusted = Paster.isTrusted
        actionMenu.close()
        if resetState {
            filter = nil
            if !query.isEmpty {
                query = ""
                return
            }
        }
        reload(keepSelection: !resetState)
    }

    func panelDidHide() {
        actionMenu.close()
    }

    // MARK: - Loading

    func reload(keepSelection: Bool = false) {
        generation += 1
        let gen = generation
        let q = query
        let kind = filter
        let store = self.store
        monitor.queue.async {
            let result = (try? store.fetch(query: q, kind: kind, limit: clipPageSize, offset: 0)) ?? []
            let total = (try? store.count()) ?? 0
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation else { return }
                self.records = result
                self.totalCount = total
                self.hasMore = result.count == clipPageSize
                if !(keepSelection && self.selectedID.map { id in result.contains { $0.id == id } } == true) {
                    self.selectedID = result.first?.id
                }
                self.rebuildSections()
                if keepSelection { self.loadDetail() }
            }
        }
    }

    func loadMoreIfNeeded(after record: ClipRecord) {
        guard hasMore, !isLoadingMore, record.id == records.last?.id else { return }
        isLoadingMore = true
        let gen = generation
        let q = query
        let kind = filter
        let offset = records.count
        let store = self.store
        monitor.queue.async {
            let more = (try? store.fetch(query: q, kind: kind, limit: clipPageSize, offset: offset)) ?? []
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLoadingMore = false
                guard gen == self.generation else { return }
                let existing = Set(self.records.map(\.id))
                self.records.append(contentsOf: more.filter { !existing.contains($0.id) })
                self.hasMore = more.count == clipPageSize
                self.rebuildSections()
            }
        }
    }

    private func rebuildSections() {
        let calendar = Calendar.current
        let now = Date()
        var order: [String] = []
        var groups: [String: [ClipRecord]] = [:]
        for record in records {
            let title: String
            if record.pinned {
                title = "Pinned"
            } else if calendar.isDateInToday(record.lastCopiedAt) {
                title = "Today"
            } else if calendar.isDateInYesterday(record.lastCopiedAt) {
                title = "Yesterday"
            } else if now.timeIntervalSince(record.lastCopiedAt) < 7 * 86_400 {
                title = "This Week"
            } else if now.timeIntervalSince(record.lastCopiedAt) < 31 * 86_400 {
                title = "This Month"
            } else {
                title = "Older"
            }
            if groups[title] == nil { order.append(title) }
            groups[title, default: []].append(record)
        }
        sections = order.map { ClipSection(id: $0, title: $0, records: groups[$0] ?? []) }
    }

    var selectedRecord: ClipRecord? {
        guard let selectedID else { return nil }
        return records.first { $0.id == selectedID }
    }

    private func loadDetail() {
        guard let record = selectedRecord else {
            detail = nil
            return
        }
        let id = record.id
        let kind = record.kind
        let store = self.store
        if detail?.id != id {
            detail = ClipDetail(id: id, isLoading: true)
        }
        monitor.queue.async {
            var text: String?
            var truncated = false
            var image: NSImage?
            switch kind {
            case .text, .link, .color:
                if let full = try? store.fullText(for: id) {
                    if full.utf16.count > detailTextLimit {
                        text = String(full.prefix(detailTextLimit))
                        truncated = true
                    } else {
                        text = full
                    }
                }
            case .image:
                if let data = try? store.imageData(for: id) {
                    image = ImageDownsampler.thumbnail(data: data, maxPixel: 1400)
                }
            case .file, .other:
                break
            }
            Task { @MainActor [weak self] in
                guard let self, self.selectedID == id else { return }
                self.detail = ClipDetail(id: id, text: text, isTruncated: truncated, image: image)
            }
        }
    }

    // MARK: - Keyboard

    func handleKey(_ event: NSEvent) -> Bool {
        if actionMenu.isOpen {
            let result = actionMenu.handle(event)
            if let action = result.run { action.perform() }
            if result.handled { return true }
        }
        let mods = event.shortcutModifiers
        switch Int(event.keyCode) {
        case 126:
            move(-1)
        case 125:
            move(1)
        case 35 where mods == .control:
            move(-1)
        case 45 where mods == .control:
            move(1)
        case 36, 76:
            if mods.contains(.command) { copySelected() } else { pasteSelected() }
        case 53:
            if query.isEmpty { panel?.hide() } else { query = "" }
        case 40 where mods == .command:
            if actionMenu.isOpen { actionMenu.close() } else { actionMenu.open(actions(for: selectedRecord)) }
        case 35 where mods == .command: // ⌘P cycles the type filter
            cycleFilter()
        case 35 where mods == [.command, .shift]: // ⇧⌘P pin
            togglePin()
        case 7 where mods == .control: // ⌃X delete
            deleteSelected()
        case 51 where mods == .command && query.isEmpty: // ⌘⌫ delete
            deleteSelected()
        default:
            return false
        }
        return true
    }

    func move(_ delta: Int) {
        guard !records.isEmpty else { return }
        let current = records.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(current + delta, 0), records.count - 1)
        selectedID = records[next].id
    }

    func cycleFilter() {
        let index = Self.filters.firstIndex(of: filter) ?? 0
        filter = Self.filters[(index + 1) % Self.filters.count]
    }

    // MARK: - Actions

    var targetAppName: String? {
        panel?.previousApp?.localizedName
    }

    var targetAppIcon: NSImage? {
        panel?.previousApp?.icon
    }

    func pasteSelected() {
        guard let record = selectedRecord else { return }
        writeToPasteboard(record) { [weak self] in
            guard let self else { return }
            let target = self.panel?.previousApp
            self.panel?.hide()
            if Paster.isTrusted {
                Paster.paste(into: target)
            } else {
                HUD.shared.show("Copied — allow Accessibility to paste directly", symbol: "doc.on.clipboard.fill")
            }
        }
    }

    func copySelected() {
        guard let record = selectedRecord else { return }
        writeToPasteboard(record) { [weak self] in
            self?.panel?.hide()
            HUD.shared.show("Copied to Clipboard")
        }
    }

    private func writeToPasteboard(_ record: ClipRecord, then completion: @escaping () -> Void) {
        let store = self.store
        let id = record.id
        monitor.queue.async {
            guard let payload = try? store.payload(for: id) else { return }
            try? store.touch(id: id)
            Task { @MainActor [weak self] in
                guard let self else { return }
                Paster.copy(payload, monitor: self.monitor)
                completion()
            }
        }
    }

    func togglePin() {
        guard let record = selectedRecord else { return }
        let store = self.store
        monitor.queue.async {
            try? store.setPinned(!record.pinned, id: record.id)
            Task { @MainActor [weak self] in
                HUD.shared.show(record.pinned ? "Unpinned" : "Pinned", symbol: "pin.fill")
                self?.reload(keepSelection: true)
            }
        }
    }

    func deleteSelected() {
        guard let record = selectedRecord else { return }
        let index = records.firstIndex { $0.id == record.id } ?? 0
        records.removeAll { $0.id == record.id }
        selectedID = records.isEmpty ? nil : records[min(index, records.count - 1)].id
        rebuildSections()
        let store = self.store
        monitor.queue.async {
            try? store.delete(id: record.id)
        }
    }

    func deleteAll() {
        panel?.hide()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Delete all clipboard history?"
        alert.informativeText = "Pinned entries are kept. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let store = self.store
        monitor.queue.async {
            try? store.deleteAll()
            Task { @MainActor in HUD.shared.show("Clipboard history cleared", symbol: "trash.fill") }
        }
    }

    func requestAccessibility() {
        Paster.requestAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        panel?.hide()
    }

    func actions(for record: ClipRecord?) -> [PanelAction] {
        guard let record else { return [] }
        var actions: [PanelAction] = [
            PanelAction(title: "Paste to \(targetAppName ?? "Active App")", symbol: "doc.on.clipboard", keys: ["↩"]) { [weak self] in self?.pasteSelected() },
            PanelAction(title: "Copy to Clipboard", symbol: "doc.on.doc", keys: ["⌘", "↩"]) { [weak self] in self?.copySelected() },
        ]
        if record.kind == .link, let link = record.meta.url, let url = URL(string: link) {
            actions.append(PanelAction(title: "Open in Browser", symbol: "safari") { [weak self] in
                self?.panel?.hide()
                NSWorkspace.shared.open(url)
            })
        }
        if record.kind == .file, let path = record.meta.filePaths?.first {
            actions.append(PanelAction(title: "Show in Finder", symbol: "folder") { [weak self] in
                self?.panel?.hide()
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            })
        }
        actions.append(PanelAction(title: record.pinned ? "Unpin Entry" : "Pin Entry", symbol: "pin", keys: ["⇧", "⌘", "P"]) { [weak self] in self?.togglePin() })
        actions.append(PanelAction(title: "Delete Entry", symbol: "trash", keys: ["⌃", "X"], destructive: true) { [weak self] in self?.deleteSelected() })
        actions.append(PanelAction(title: "Delete All Entries…", symbol: "trash.slash", destructive: true) { [weak self] in self?.deleteAll() })
        return actions
    }
}

import AppKit
import CoreServices
import FlareCore

/// Watches directories with FSEvents and calls `onChange` (on a background queue), coalesced by `latency`.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "flare.fsevents", qos: .utility)

    init(paths: [String], latency: TimeInterval = 1.0, onChange: @escaping () -> Void) {
        self.onChange = onChange
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, existing as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

/// Base class for a thread-safe, periodically rebuilt list of search entries.
class EntryIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [SearchEntry] = []
    private var rebuilding = false
    private var rebuildAgain = false
    let queue: DispatchQueue
    var onUpdate: (() -> Void)?

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func snapshot() -> [SearchEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    /// Subclasses override to produce the entries (called off the main thread).
    func build() -> [SearchEntry] { [] }

    func rebuild() {
        lock.lock()
        if rebuilding {
            rebuildAgain = true
            lock.unlock()
            return
        }
        rebuilding = true
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            while true {
                let built = self.build()
                self.lock.lock()
                self.entries = built
                if self.rebuildAgain {
                    self.rebuildAgain = false
                    self.lock.unlock()
                    continue
                }
                self.rebuilding = false
                self.lock.unlock()
                break
            }
            let callback = self.onUpdate
            DispatchQueue.main.async { callback?() }
        }
    }
}

/// Every installed application (like Raycast's root search).
final class AppIndex: EntryIndex {
    static let searchRoots: [String] = [
        "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
        "/System/Library/CoreServices/Applications",
        "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
    ]

    static let extraApps: [String] = [
        "/System/Library/CoreServices/Finder.app",
    ]

    private var watcher: DirectoryWatcher?

    init() {
        super.init(label: "flare.appindex")
        watcher = DirectoryWatcher(paths: Self.searchRoots, latency: 2.0) { [weak self] in self?.rebuild() }
    }

    override func build() -> [SearchEntry] {
        let fm = FileManager.default
        var seenPaths = Set<String>()
        var seenBundleIDs = Set<String>()
        var entries: [SearchEntry] = []

        func add(_ url: URL) {
            let path = url.resolvingSymlinksInPath().path
            guard seenPaths.insert(path).inserted else { return }
            let bundle = Bundle(url: url)
            let info = bundle?.infoDictionary ?? [:]
            if let id = bundle?.bundleIdentifier {
                guard seenBundleIDs.insert(id).inserted else { return }
            }
            var title = fm.displayName(atPath: url.path)
            if title.hasSuffix(".app") { title = String(title.dropLast(4)) }
            var keywords: [String] = []
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let value = info[key] as? String { keywords.append(value) }
            }
            keywords.append(url.deletingPathExtension().lastPathComponent)
            entries.append(SearchEntry(id: "app:" + url.path, kind: .application, title: title,
                                       path: url.path, keywords: keywords))
        }

        func scan(_ dir: URL, depth: Int) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { return }
            for item in items {
                if item.pathExtension == "app" {
                    add(item)
                } else if depth > 0, (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    scan(item, depth: depth - 1)
                }
            }
        }

        for root in Self.searchRoots {
            scan(URL(fileURLWithPath: root, isDirectory: true), depth: 1)
        }
        for path in Self.extraApps where fm.fileExists(atPath: path) {
            add(URL(fileURLWithPath: path))
        }
        return entries
    }
}

/// Files and folders inside ~/Downloads (recursive), kept live with FSEvents.
final class DownloadsIndex: EntryIndex {
    static let maxEntries = 250_000
    let root: URL
    private var watcher: DirectoryWatcher?
    private(set) var isAccessible = true

    init(root: URL = AppInfo.downloadsDirectory) {
        self.root = root
        super.init(label: "flare.downloadsindex")
    }

    /// Starts indexing. Touching ~/Downloads triggers macOS's privacy prompt the first time.
    func start() {
        guard watcher == nil else { return }
        watcher = DirectoryWatcher(paths: [root.path], latency: 1.0) { [weak self] in self?.rebuild() }
        rebuild()
    }

    override func build() -> [SearchEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .addedToDirectoryDateKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            isAccessible = false
            return []
        }
        isAccessible = true
        let home = NSHomeDirectory()
        var entries: [SearchEntry] = []
        for case let url as URL in enumerator {
            if entries.count >= Self.maxEntries { break }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isFolder = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            let parent = url.deletingLastPathComponent().path
            let subtitle = parent.hasPrefix(home) ? "~" + parent.dropFirst(home.count) : parent
            entries.append(SearchEntry(
                id: "file:" + url.path,
                kind: isFolder ? .folder : .file,
                title: url.lastPathComponent,
                subtitle: subtitle,
                path: url.path,
                date: values?.addedToDirectoryDate ?? values?.contentModificationDate
            ))
        }
        return entries
    }
}

import AppKit
import Combine
import ServiceManagement

enum AppInfo {
    static let name = "Flare"

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var downloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// User settings persisted in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    @Published var launcherHotKey: KeyCombo {
        didSet { save(launcherHotKey, key: "launcherHotKey") }
    }

    @Published var clipboardHotKey: KeyCombo {
        didSet { save(clipboardHotKey, key: "clipboardHotKey") }
    }

    @Published var homeCurrency: String {
        didSet { defaults.set(homeCurrency, forKey: "homeCurrency") }
    }

    @Published var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: "onboardingCompleted") }
    }

    private init() {
        let defaults = UserDefaults.standard
        launcherHotKey = Self.load(key: "launcherHotKey", from: defaults) ?? .commandSpace
        clipboardHotKey = Self.load(key: "clipboardHotKey", from: defaults) ?? .optionCommandV
        let localeCurrency = Locale.current.currency?.identifier ?? "USD"
        homeCurrency = defaults.string(forKey: "homeCurrency") ?? localeCurrency
        onboardingCompleted = defaults.bool(forKey: "onboardingCompleted")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Flare: launch at login change failed: \(error)")
            }
        }
    }

    /// Currencies shown when a query has no explicit target ("100 usd").
    var defaultCurrencyTargets: [String] {
        var targets = [homeCurrency]
        for code in ["USD", "EUR"] where !targets.contains(code) { targets.append(code) }
        return targets
    }

    private func save(_ combo: KeyCombo, key: String) {
        if let data = try? JSONEncoder().encode(combo) { defaults.set(data, forKey: key) }
    }

    private static func load(key: String, from defaults: UserDefaults) -> KeyCombo? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }
}

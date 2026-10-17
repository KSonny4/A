import AppKit
import FlareCore
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    private enum HotKeyID: UInt32 {
        case launcher = 1
        case clipboard = 2
    }

    private var preferences: Preferences { Preferences.shared }
    private var store: ClipboardStore!
    private var monitor: ClipboardMonitor!
    private var currency: CurrencyService!
    private var usage: UsageStore!
    private var appIndex: AppIndex!
    private var downloadsIndex: DownloadsIndex!

    private var launcherModel: LauncherViewModel!
    private var launcherPanel: PanelController!
    private var clipboardModel: ClipboardViewModel!
    private var clipboardPanel: PanelController!

    private var onboarding: OnboardingWindowController!
    private var settings: SettingsWindowController!
    private var statusItem: NSStatusItem!
    private var currencyTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let support = AppInfo.supportDirectory
        do {
            store = try ClipboardStore(directory: support.appendingPathComponent("Clipboard", isDirectory: true))
        } catch {
            fatalError("Flare could not open its clipboard database: \(error)")
        }
        monitor = ClipboardMonitor(store: store)
        currency = CurrencyService(cacheURL: support.appendingPathComponent("rates.json"))
        usage = UsageStore(url: support.appendingPathComponent("usage.json"))
        appIndex = AppIndex()
        downloadsIndex = DownloadsIndex()

        let store = self.store!
        Thumbnails.clipLoader = { id in try? store.imageData(for: id) }

        setUpMainMenu()
        setUpLauncher()
        setUpClipboard()
        setUpOnboardingAndSettings()
        setUpStatusItem()
        registerHotKeys()

        monitor.start()
        appIndex.rebuild()
        currency.refreshIfNeeded()
        let timer = Timer(timeInterval: 60 * 60, target: self, selector: #selector(refreshRates), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        currencyTimer = timer

        if preferences.onboardingCompleted {
            // Only touch ~/Downloads after onboarding so the privacy prompt appears in context.
            downloadsIndex.start()
            if preferences.launcherHotKey == .commandSpace && PermissionsService.spotlightOwnsCommandSpace() {
                onboarding.show(step: .hotkey)
            }
        } else {
            onboarding.show(step: .welcome)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launcherPanel.show()
        return false
    }

    // MARK: - Setup

    private func setUpLauncher() {
        launcherModel = LauncherViewModel(apps: appIndex, downloads: downloadsIndex, usage: usage,
                                          currency: currency, preferences: preferences)
        launcherPanel = PanelController(rootView: LauncherView(model: launcherModel))
        launcherPanel.keyHandler = launcherModel
        launcherModel.panel = launcherPanel
        launcherModel.onCommand = { [weak self] command in self?.run(command) }
    }

    private func setUpClipboard() {
        clipboardModel = ClipboardViewModel(monitor: monitor)
        clipboardPanel = PanelController(rootView: ClipboardView(model: clipboardModel))
        clipboardPanel.keyHandler = clipboardModel
        clipboardModel.panel = clipboardPanel
    }

    private func setUpOnboardingAndSettings() {
        let model = OnboardingModel(preferences: preferences)
        model.onFinish = { [weak self] in
            guard let self else { return }
            self.onboarding.close()
            self.downloadsIndex.start()
        }
        model.onHotKeyChanged = { [weak self] in self?.registerHotKeys() }
        model.onDownloadsGranted = { [weak self] in self?.downloadsIndex.start() }
        onboarding = OnboardingWindowController(model: model)

        let context = SettingsContext(preferences: preferences, store: store, storeQueue: monitor.queue, currency: currency)
        context.onHotKeysChanged = { [weak self] in self?.registerHotKeys() }
        context.onShowWelcome = { [weak self] in self?.onboarding.show(step: .welcome) }
        context.onClearHistory = { [weak self] in
            self?.clipboardModel.deleteAll()
            context.refreshStats()
        }
        settings = SettingsWindowController(context: context)
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Flare")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Flare", action: #selector(showLauncher), keyEquivalent: "")
        menu.addItem(withTitle: "Clipboard History", action: #selector(showClipboard), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Welcome Guide…", action: #selector(showWelcome), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Flare", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    /// Accessory apps have no visible menu bar, but a main menu still provides standard
    /// key equivalents (copy/paste/undo) in Settings and Onboarding windows.
    private func setUpMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Quit Flare", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    private func registerHotKeys() {
        let center = HotKeyCenter.shared
        let launcherOK = center.register(id: HotKeyID.launcher.rawValue, combo: preferences.launcherHotKey) { [weak self] in
            self?.toggleLauncher()
        }
        let clipboardOK = center.register(id: HotKeyID.clipboard.rawValue, combo: preferences.clipboardHotKey) { [weak self] in
            self?.toggleClipboard()
        }
        if !launcherOK { NSLog("Flare: could not register launcher hotkey \(preferences.launcherHotKey.displayString)") }
        if !clipboardOK { NSLog("Flare: could not register clipboard hotkey \(preferences.clipboardHotKey.displayString)") }
    }

    // MARK: - Actions

    private func toggleLauncher() {
        if onboarding.isVisible && onboarding.model.step == .tryIt {
            onboarding.model.finish()
        }
        if launcherPanel.isVisible {
            launcherPanel.hide()
        } else {
            clipboardPanel.hide()
            launcherPanel.show()
        }
    }

    private func toggleClipboard() {
        if clipboardPanel.isVisible {
            clipboardPanel.hide()
        } else {
            launcherPanel.hide()
            clipboardPanel.show()
        }
    }

    private func run(_ command: LauncherCommand) {
        switch command {
        case .clipboardHistory:
            clipboardPanel.show()
        case .settings:
            settings.show()
        case .welcome:
            onboarding.show(step: .welcome)
        case .quit:
            NSApp.terminate(nil)
        }
    }

    @objc private func showLauncher() { launcherPanel.show() }
    @objc private func showClipboard() { clipboardPanel.show() }
    @objc private func showSettings() { settings.show() }
    @objc private func showWelcome() { onboarding.show(step: .welcome) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func refreshRates() { currency.refreshIfNeeded() }
}

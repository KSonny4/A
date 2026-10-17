import AppKit
import ApplicationServices

/// Checks and requests the bits of system access Flare needs.
enum PermissionsService {
    static let spotlightHotKeyID = "64"

    /// Whether Spotlight's "Show Spotlight search" shortcut (⌘Space) is still enabled.
    static func spotlightOwnsCommandSpace() -> Bool {
        CFPreferencesAppSynchronize("com.apple.symbolichotkeys" as CFString)
        guard let hotkeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any],
              let spotlight = hotkeys[spotlightHotKeyID] as? [String: Any] else {
            return true // Not customised: enabled by default.
        }
        if let enabled = spotlight["enabled"] as? Bool { return enabled }
        if let enabled = spotlight["enabled"] as? Int { return enabled != 0 }
        return true
    }

    /// Turns off Spotlight's ⌘Space shortcut, the same way unticking it in System Settings does.
    /// Returns true when the change was applied live.
    @discardableResult
    static func disableSpotlightShortcut() -> Bool {
        let value = """
        <dict><key>enabled</key><false/><key>value</key><dict><key>parameters</key><array>\
        <integer>32</integer><integer>49</integer><integer>1048576</integer></array>\
        <key>type</key><string>standard</string></dict></dict>
        """
        guard run("/usr/bin/defaults", ["write", "com.apple.symbolichotkeys", "AppleSymbolicHotKeys", "-dict-add", spotlightHotKeyID, value]) else {
            return false
        }
        let activate = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
        guard FileManager.default.isExecutableFile(atPath: activate) else { return false }
        return run(activate, ["-u"])
    }

    static func openKeyboardShortcutsSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }

    static func openFilesAndFoldersSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
    }

    /// Reading ~/Downloads triggers macOS's one-time privacy prompt. Call off the main thread.
    static func probeDownloads() -> Int? {
        let path = AppInfo.downloadsDirectory.path
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        return items.filter { !$0.hasPrefix(".") }.count
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

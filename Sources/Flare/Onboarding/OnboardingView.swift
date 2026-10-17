import AppKit
import SwiftUI

@MainActor
final class OnboardingModel: NSObject, ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, hotkey, accessibility, downloads, login, tryIt
    }

    enum DownloadsAccess: Equatable {
        case unknown, checking, granted(Int), denied
    }

    @Published var step: Step = .welcome
    @Published var forward = true
    @Published private(set) var spotlightConflict = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var downloads: DownloadsAccess = .unknown
    @Published var launchAtLogin = true
    @Published private(set) var autoDisableFailed = false

    let preferences: Preferences
    var onFinish: (() -> Void)?
    var onHotKeyChanged: (() -> Void)?
    var onDownloadsGranted: (() -> Void)?

    private var timer: Timer?

    init(preferences: Preferences) {
        self.preferences = preferences
        super.init()
        refresh()
    }

    var usesCommandSpace: Bool { preferences.launcherHotKey == .commandSpace }
    var hotKeyReady: Bool { !(usesCommandSpace && spotlightConflict) }

    func startPolling() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(poll), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func poll() {
        let wasReady = hotKeyReady
        let wasTrusted = accessibilityGranted
        refresh()
        // Auto-advance the moment the user completes a step in System Settings.
        if step == .hotkey, !wasReady, hotKeyReady { advanceSoon(from: .hotkey) }
        if step == .accessibility, !wasTrusted, accessibilityGranted { advanceSoon(from: .accessibility) }
    }

    private func refresh() {
        spotlightConflict = PermissionsService.spotlightOwnsCommandSpace()
        accessibilityGranted = PermissionsService.isAccessibilityTrusted
    }

    private func advanceSoon(from step: Step) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            Task { @MainActor in
                guard let self, self.step == step else { return }
                self.next()
            }
        }
    }

    // MARK: Navigation

    func next() {
        if step == .login { preferences.launchAtLogin = launchAtLogin }
        guard let next = Step(rawValue: step.rawValue + 1) else {
            finish()
            return
        }
        forward = true
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { step = next }
        if next == .downloads, downloads == .unknown { checkDownloads(prompt: false) }
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        forward = false
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { step = previous }
    }

    func jump(to target: Step) {
        forward = target.rawValue >= step.rawValue
        step = target
    }

    func finish() {
        stopPolling()
        preferences.onboardingCompleted = true
        onFinish?()
    }

    // MARK: Actions

    func disableSpotlight() {
        autoDisableFailed = false
        if !PermissionsService.disableSpotlightShortcut() {
            autoDisableFailed = true
            PermissionsService.openKeyboardShortcutsSettings()
        }
        poll()
    }

    func useOptionSpace() {
        preferences.launcherHotKey = .optionSpace
        onHotKeyChanged?()
        objectWillChange.send()
        advanceSoon(from: .hotkey)
    }

    func requestAccessibility() {
        PermissionsService.requestAccessibility()
    }

    func checkDownloads(prompt: Bool) {
        downloads = .checking
        DispatchQueue.global(qos: .userInitiated).async {
            let count = PermissionsService.probeDownloads()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let count {
                    self.downloads = .granted(count)
                    self.onDownloadsGranted?()
                } else {
                    self.downloads = prompt ? .denied : .unknown
                }
            }
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page(model.step)
                    .id(model.step)
                    .transition(.asymmetric(
                        insertion: .move(edge: model.forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: model.forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            footer
        }
        .frame(width: 640, height: 500)
        .background(VisualEffectBackground(material: .underWindowBackground, blending: .behindWindow).ignoresSafeArea())
    }

    @ViewBuilder
    private func page(_ step: OnboardingModel.Step) -> some View {
        switch step {
        case .welcome: WelcomePage()
        case .hotkey: HotKeyPage(model: model)
        case .accessibility: AccessibilityPage(model: model)
        case .downloads: DownloadsPage(model: model)
        case .login: LoginPage(model: model)
        case .tryIt: TryItPage(model: model)
        }
    }

    private var footer: some View {
        HStack {
            if model.step != .welcome && model.step != .tryIt {
                Button("Back") { model.back() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { step in
                    Capsule()
                        .fill(step == model.step ? Color.primary.opacity(0.75) : Color.primary.opacity(0.18))
                        .frame(width: step == model.step ? 18 : 7, height: 7)
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.step)
                }
            }
            Spacer()
            Button(primaryTitle) { model.next() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private var primaryTitle: String {
        switch model.step {
        case .welcome: return "Get Started"
        case .hotkey: return model.hotKeyReady ? "Continue" : "Skip for Now"
        case .accessibility: return model.accessibilityGranted ? "Continue" : "Skip"
        case .downloads:
            if case .granted = model.downloads { return "Continue" }
            return "Skip"
        case .login: return "Continue"
        case .tryIt: return "Start Using Flare"
        }
    }
}

// MARK: - Pages

private struct PageLayout<Hero: View, Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var hero: () -> Hero
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 10)
            hero()
                .frame(height: 120)
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 26, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
                .frame(maxWidth: 440)
            Spacer(minLength: 10)
        }
        .padding(.horizontal, 40)
    }
}

private struct WelcomePage: View {
    @State private var appear = false

    var body: some View {
        PageLayout(title: "Welcome to Flare",
                   subtitle: "Your shortcut to everything. Launch apps, find files, convert currencies and keep every single thing you copy — forever.",
                   hero: {
                       Image(nsImage: NSApp.applicationIconImage)
                           .resizable()
                           .frame(width: 112, height: 112)
                           .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                           .scaleEffect(appear ? 1 : 0.8)
                           .opacity(appear ? 1 : 0)
                           .onAppear {
                               withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.1)) { appear = true }
                           }
                   }, content: {
                       HStack(spacing: 12) {
                           FeaturePill(symbol: "magnifyingglass", title: "Search")
                           FeaturePill(symbol: "doc.on.clipboard", title: "Clipboard")
                           FeaturePill(symbol: "dollarsign.arrow.circlepath", title: "Currency")
                       }
                   })
    }
}

private struct FeaturePill: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(title)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Theme.keycapFill))
    }
}

private struct HotKeyPage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        PageLayout(title: "Summon Flare from anywhere",
                   subtitle: model.usesCommandSpace
                       ? "Flare opens with ⌘ Space, just like Spotlight did. Spotlight needs to let go of the shortcut first."
                       : "Flare opens with \(model.preferences.launcherHotKey.displayString). You can change it any time in Settings.",
                   hero: {
                       KeycapRow(keys: model.preferences.launcherHotKey.keycaps, size: 30)
                   }, content: {
                       VStack(spacing: 12) {
                           if model.hotKeyReady {
                               StatusBadge(ok: true, text: "\(model.preferences.launcherHotKey.displayString) is ready")
                           } else {
                               StatusBadge(ok: false, text: "Spotlight is using ⌘ Space")
                               Button("Disable Spotlight Shortcut") { model.disableSpotlight() }
                                   .buttonStyle(PrimaryButtonStyle())
                               if model.autoDisableFailed {
                                   Text("In Keyboard Shortcuts → Spotlight, untick “Show Spotlight search”.")
                                       .font(.system(size: 12))
                                       .foregroundStyle(.secondary)
                                       .multilineTextAlignment(.center)
                               }
                               HStack(spacing: 16) {
                                   Button("Open Keyboard Shortcuts…") { PermissionsService.openKeyboardShortcutsSettings() }
                                   Button("Use ⌥ Space Instead") { model.useOptionSpace() }
                               }
                               .buttonStyle(.link)
                               .font(.system(size: 12))
                           }
                       }
                   })
    }
}

private struct AccessibilityPage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        PageLayout(title: "Paste straight into any app",
                   subtitle: "Pick something from your clipboard history and Flare types ⌘V for you. macOS asks you to allow this once in Accessibility settings.",
                   hero: {
                       IconBadge(symbol: "hand.raised.fill", tint: .blue)
                   }, content: {
                       VStack(spacing: 12) {
                           if model.accessibilityGranted {
                               StatusBadge(ok: true, text: "Accessibility access granted")
                           } else {
                               Button("Allow Accessibility Access") { model.requestAccessibility() }
                                   .buttonStyle(PrimaryButtonStyle())
                               Text("Turn on Flare in the list. This page updates automatically.")
                                   .font(.system(size: 12))
                                   .foregroundStyle(.secondary)
                           }
                       }
                   })
    }
}

private struct DownloadsPage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        PageLayout(title: "Find files in Downloads",
                   subtitle: "Type a file name to open it, or press ⌘↩ to reveal it in Finder. Flare indexes your Downloads folder on this Mac only.",
                   hero: {
                       Image(nsImage: NSWorkspace.shared.icon(forFile: AppInfo.downloadsDirectory.path))
                           .resizable()
                           .frame(width: 110, height: 110)
                   }, content: {
                       VStack(spacing: 12) {
                           switch model.downloads {
                           case .granted(let count):
                               StatusBadge(ok: true, text: "Indexing \(count.formatted()) items in Downloads")
                           case .checking:
                               ProgressView().controlSize(.small)
                           case .denied:
                               StatusBadge(ok: false, text: "Flare can't read your Downloads folder")
                               Button("Open Privacy Settings…") { PermissionsService.openFilesAndFoldersSettings() }
                                   .buttonStyle(.link)
                               Button("Try Again") { model.checkDownloads(prompt: true) }
                                   .buttonStyle(PrimaryButtonStyle())
                           case .unknown:
                               Button("Allow Access to Downloads") { model.checkDownloads(prompt: true) }
                                   .buttonStyle(PrimaryButtonStyle())
                           }
                       }
                   })
    }
}

private struct LoginPage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        PageLayout(title: "Always ready",
                   subtitle: "Start Flare when you log in so your launcher and clipboard history are always there.",
                   hero: {
                       IconBadge(symbol: "power", tint: .green)
                   }, content: {
                       Toggle(isOn: $model.launchAtLogin) {
                           Text("Launch Flare at login")
                               .font(.system(size: 13, weight: .medium))
                       }
                       .toggleStyle(.switch)
                       .padding(.horizontal, 18)
                       .padding(.vertical, 12)
                       .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardFill))
                   })
    }
}

private struct TryItPage: View {
    @ObservedObject var model: OnboardingModel
    @State private var pulse = false

    var body: some View {
        PageLayout(title: "You're all set",
                   subtitle: "Press \(model.preferences.launcherHotKey.displayString) now to open Flare. Use \(model.preferences.clipboardHotKey.displayString) for your clipboard history.",
                   hero: {
                       KeycapRow(keys: model.preferences.launcherHotKey.keycaps, size: 30)
                           .scaleEffect(pulse ? 1.06 : 1)
                           .onAppear {
                               withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
                           }
                   }, content: {
                       VStack(alignment: .leading, spacing: 8) {
                           TipRow(keys: ["↩"], text: "Open the selected app or file")
                           TipRow(keys: ["⌘", "↩"], text: "Show a file in Finder")
                           TipRow(keys: ["⌘", "K"], text: "See all actions")
                           TipRow(keys: model.preferences.clipboardHotKey.keycaps, text: "Clipboard history")
                       }
                       .padding(14)
                       .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardFill))
                   })
    }
}

private struct TipRow: View {
    let keys: [String]
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            KeycapRow(keys: keys)
                .frame(width: 90, alignment: .leading)
            Text(text).font(.system(size: 13))
        }
    }
}

private struct IconBadge: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 44, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 96, height: 96)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(tint.gradient))
            .shadow(color: tint.opacity(0.35), radius: 14, y: 6)
    }
}

private struct StatusBadge: View {
    let ok: Bool
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
                .transition(.scale.combined(with: .opacity))
            Text(text)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill((ok ? Color.green : Color.orange).opacity(0.12)))
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: ok)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1)))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// Hosts the onboarding in a standard, vibrancy-backed macOS window.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    let model: OnboardingModel
    private var window: NSWindow?

    init(model: OnboardingModel) {
        self.model = model
        super.init()
    }

    func show(step: OnboardingModel.Step = .welcome) {
        model.jump(to: step)
        model.startPolling()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
                                  styleMask: [.titled, .closable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.contentView = NSHostingView(rootView: OnboardingView(model: model))
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        model.stopPolling()
        window?.close()
    }

    var isVisible: Bool { window?.isVisible == true }

    func windowWillClose(_ notification: Notification) {
        model.stopPolling()
    }
}

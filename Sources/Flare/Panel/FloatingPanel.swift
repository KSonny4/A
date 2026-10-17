import AppKit
import SwiftUI

/// Keyboard routing for content hosted in a `PanelController`.
@MainActor
protocol PanelKeyHandler: AnyObject {
    /// Return true to swallow the event.
    func handleKey(_ event: NSEvent) -> Bool
    func panelWillShow(resetState: Bool)
    func panelDidHide()
}

/// Borderless, non-activating floating panel – like Raycast/Spotlight. It takes keyboard focus without
/// activating Flare, so the app you were using stays frontmost (which makes paste-back trivial).
final class FloatingPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
        worksWhenModal = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Escape is handled by the key handler; prevent the default "cancel" beep.
    override func cancelOperation(_ sender: Any?) {}
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let panel: FloatingPanel
    weak var keyHandler: PanelKeyHandler?
    weak var searchField: NSTextField?

    /// App that was frontmost before the panel opened (target for paste).
    private(set) var previousApp: NSRunningApplication?
    private var lastHidden: Date?
    private var keyMonitor: Any?

    /// Raycast pops back to root after 90 s; within that window the previous query is kept.
    var stateRetention: TimeInterval = 90

    init<Content: View>(rootView: Content, size: NSSize = Theme.panelSize) {
        panel = FloatingPanel(size: size)
        super.init()

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: Theme.cornerRadius)
        effect.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = []
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)

        panel.contentView = effect
        panel.delegate = self

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self.panel, self.panel.isVisible else { return false }
                return self.route(event)
            }
            return handled ? nil : event
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != NSRunningApplication.current.processIdentifier {
            previousApp = front
        }
        let reset = lastHidden.map { Date().timeIntervalSince($0) > stateRetention } ?? true
        keyHandler?.panelWillShow(resetState: reset)
        position()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        focusSearchField()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.panel.animator().alphaValue = 1
        }
        Task { @MainActor in
            self.panel.invalidateShadow()
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        lastHidden = Date()
        keyHandler?.panelDidHide()
    }

    /// Forgets state so the next show starts fresh.
    func resetOnNextShow() {
        lastHidden = nil
    }

    func focusSearchField() {
        guard let field = searchField else { return }
        panel.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - visible.height * 0.2 - size.height
        panel.setFrameOrigin(NSPoint(x: round(x), y: round(max(y, visible.minY + 20))))
    }

    private func route(_ event: NSEvent) -> Bool {
        // Never interfere with input-method composition (e.g. Japanese, Chinese).
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() {
            return false
        }
        if keyHandler?.handleKey(event) == true { return true }

        // Accessory apps have no Edit menu, so wire up the standard text editing shortcuts ourselves.
        if event.shortcutModifiers == .command, let chars = event.charactersIgnoringModifiers?.lowercased() {
            let selector: Selector?
            switch chars {
            case "a": selector = #selector(NSText.selectAll(_:))
            case "c": selector = #selector(NSText.copy(_:))
            case "v": selector = #selector(NSText.paste(_:))
            case "x": selector = #selector(NSText.cut(_:))
            case "z": selector = Selector(("undo:"))
            default: selector = nil
            }
            if let selector {
                NSApp.sendAction(selector, to: nil, from: panel)
                return true
            }
        }
        return false
    }

    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

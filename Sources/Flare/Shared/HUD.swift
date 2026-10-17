import AppKit
import SwiftUI

/// Raycast-style transient HUD ("Copied to Clipboard") shown near the bottom of the screen.
@MainActor
final class HUD {
    static let shared = HUD()

    private var window: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var generation = 0

    func show(_ message: String, symbol: String = "checkmark.circle.fill") {
        let view = HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
            Text(message)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(VisualEffectBackground(material: .hudWindow, blending: .behindWindow))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
        .fixedSize()

        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let panel = window ?? makeWindow()
        panel.contentView = hosting
        panel.setContentSize(size)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: round(frame.midX - size.width / 2), y: frame.minY + 90))
        }
        generation += 1
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        window = panel

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.fadeOut() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    private func fadeOut() {
        guard let panel = window else { return }
        let current = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                if self.generation == current { panel.orderOut(nil) }
            }
        })
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        return panel
    }
}

import AppKit
import SwiftUI

/// Raycast-matched metrics and colours. All colours adapt to light/dark mode.
enum Theme {
    static let panelSize = NSSize(width: 750, height: 474)
    static let cornerRadius: CGFloat = 12
    static let searchBarHeight: CGFloat = 56
    static let actionBarHeight: CGFloat = 40
    static let rowHeight: CGFloat = 40
    static let rowCorner: CGFloat = 8
    static let listInset: CGFloat = 8

    static let searchFont = NSFont.systemFont(ofSize: 18, weight: .regular)

    static let panelTint = Color(nsColor: dynamic(light: NSColor(white: 1, alpha: 0.55), dark: NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.72)))
    static let selection = Color(nsColor: dynamic(light: NSColor(white: 0, alpha: 0.075), dark: NSColor(white: 1, alpha: 0.10)))
    static let hover = Color(nsColor: dynamic(light: NSColor(white: 0, alpha: 0.04), dark: NSColor(white: 1, alpha: 0.05)))
    static let border = Color(nsColor: dynamic(light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.13)))
    static let divider = Color(nsColor: dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08)))
    static let barFill = Color(nsColor: dynamic(light: NSColor(white: 0, alpha: 0.025), dark: NSColor(white: 1, alpha: 0.03)))
    static let keycapFill = Color(nsColor: dynamic(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.11)))
    static let cardFill = Color(nsColor: dynamic(light: NSColor(white: 0, alpha: 0.035), dark: NSColor(white: 1, alpha: 0.05)))
    static let accent = Color(nsColor: NSColor(calibratedRed: 1.0, green: 0.39, blue: 0.29, alpha: 1))

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

/// NSVisualEffectView for SwiftUI backgrounds.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// A small rounded key label like Raycast's shortcut hints.
struct Keycap: View {
    let label: String
    var size: CGFloat = 11

    var body: some View {
        Text(label)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(minWidth: size + 9, minHeight: size + 9)
            .padding(.horizontal, label.count > 1 ? 4 : 0)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.keycapFill))
    }
}

struct KeycapRow: View {
    let keys: [String]
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Keycap(label: key, size: size)
            }
        }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension NSEvent {
    /// Modifier flags relevant for shortcuts (ignores caps lock, fn, numeric pad).
    var shortcutModifiers: NSEvent.ModifierFlags {
        modifierFlags.intersection([.command, .option, .control, .shift])
    }
}

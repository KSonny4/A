import AppKit
import ImageIO
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Search field

/// Borderless AppKit text field so focus works reliably inside a non-activating panel.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onCreate: (NSTextField) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.searchFont
        field.textColor = .labelColor
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: Theme.searchFont,
        ])
        field.delegate = context.coordinator
        field.stringValue = text
        onCreate(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField

        init(parent: SearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}

struct SearchBar<Accessory: View>: View {
    @Binding var text: String
    var placeholder: String
    var showsBack: Bool = false
    var onCreate: (NSTextField) -> Void
    var onBack: () -> Void = {}
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            if showsBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.keycapFill))
                }
                .buttonStyle(.plain)
            }
            SearchField(text: $text, placeholder: placeholder, onCreate: onCreate)
                .frame(height: 24)
            accessory()
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.searchBarHeight)
    }
}

extension SearchBar where Accessory == EmptyView {
    init(text: Binding<String>, placeholder: String, showsBack: Bool = false,
         onCreate: @escaping (NSTextField) -> Void, onBack: @escaping () -> Void = {}) {
        self.init(text: text, placeholder: placeholder, showsBack: showsBack, onCreate: onCreate, onBack: onBack,
                  accessory: { EmptyView() })
    }
}

struct PanelDivider: View {
    var body: some View {
        Rectangle().fill(Theme.divider).frame(height: 1)
    }
}

// MARK: - Icons

enum RowIcon: Equatable {
    case path(String)
    case thumbnail(String)
    case symbol(String, Color)
    case image(NSImage)
    case color(NSColor)
    case clip(Int64)
}

@MainActor
final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()

    func icon(forPath path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 32, height: 32)
        cache.setObject(image, forKey: path as NSString)
        return image
    }

    func cached(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }
    func store(_ image: NSImage, key: String) { cache.setObject(image, forKey: key as NSString) }
}

struct IconView: View {
    let icon: RowIcon
    var size: CGFloat = 20
    @State private var loaded: NSImage?

    var body: some View {
        Group {
            switch icon {
            case .path(let path):
                Image(nsImage: IconCache.shared.icon(forPath: path)).resizable().interpolation(.high)
            case .thumbnail(let path):
                Image(nsImage: loaded ?? IconCache.shared.icon(forPath: path)).resizable().interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .task(id: path) { loaded = await Thumbnails.file(path) }
            case .symbol(let name, let tint):
                Image(systemName: name)
                    .font(.system(size: size * 0.62, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(tint.opacity(0.16)))
            case .image(let image):
                Image(nsImage: image).resizable().interpolation(.high)
            case .color(let color):
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(Color(nsColor: color))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                    .padding(1)
            case .clip(let id):
                Group {
                    if let loaded {
                        Image(nsImage: loaded).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                            .frame(width: size, height: size)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    } else {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                }
                .task(id: id) { loaded = await Thumbnails.clip(id) }
            }
        }
        .frame(width: size, height: size)
    }
}

/// Async thumbnail loading with an in-memory cache.
@MainActor
enum Thumbnails {
    static var clipLoader: ((Int64) -> Data?)?

    static func file(_ path: String) async -> NSImage? {
        let key = "ql:" + path
        if let cached = IconCache.shared.cached(key) { return cached }
        let url = URL(fileURLWithPath: path)
        guard let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .movie) else { return nil }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 40, height: 40),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = rep.nsImage
        IconCache.shared.store(image, key: key)
        return image
    }

    static func clip(_ id: Int64) async -> NSImage? {
        let key = "clip:\(id)"
        if let cached = IconCache.shared.cached(key) { return cached }
        guard let loader = clipLoader else { return nil }
        let image: NSImage? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let data = loader(id) else { return continuation.resume(returning: nil) }
                continuation.resume(returning: ImageDownsampler.thumbnail(data: data, maxPixel: 96))
            }
        }
        if let image { IconCache.shared.store(image, key: key) }
        return image
    }
}

enum ImageDownsampler {
    static func thumbnail(data: Data, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    static func pixelSize(data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }
}

// MARK: - Rows

struct ResultRow: View {
    let icon: RowIcon
    let title: String
    var subtitle: String?
    var accessory: String?
    var accessoryKeys: [String] = []
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            IconView(icon: icon)
            Text(title)
                .font(.system(size: 13.5))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if !accessoryKeys.isEmpty {
                KeycapRow(keys: accessoryKeys, size: 10)
            }
            if let accessory {
                Text(accessory)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                .fill(isSelected ? Theme.selection : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Bottom action bar

struct ActionBar: View {
    var leadingIcon: RowIcon?
    var leadingText: String
    var toast: String?
    var primaryTitle: String?
    var primaryKeys: [String] = ["↩"]
    var showsActions: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            if let toast {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(toast).font(.system(size: 12.5, weight: .medium))
            } else {
                if let leadingIcon { IconView(icon: leadingIcon, size: 16) }
                Text(leadingText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let primaryTitle {
                Text(primaryTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                KeycapRow(keys: primaryKeys)
            }
            if showsActions {
                Rectangle().fill(Theme.divider).frame(width: 1, height: 16).padding(.horizontal, 4)
                Text("Actions")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                KeycapRow(keys: ["⌘", "K"])
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Theme.actionBarHeight)
        .background(Theme.barFill)
    }
}

// MARK: - ⌘K action panel

struct PanelAction: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    var keys: [String] = []
    var destructive = false
    let perform: () -> Void
}

struct ActionPanelView: View {
    let title: String
    let actions: [PanelAction]
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                HStack(spacing: 10) {
                    Image(systemName: action.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(action.destructive ? Color.red : Color.secondary)
                        .frame(width: 18)
                    Text(action.title)
                        .font(.system(size: 13))
                        .foregroundStyle(action.destructive ? Color.red : Color.primary)
                    Spacer(minLength: 12)
                    KeycapRow(keys: action.keys, size: 10)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(index == selectedIndex ? Theme.selection : Color.clear))
                .contentShape(Rectangle())
                .onTapGesture { onSelect(index) }
            }
        }
        .padding(6)
        .frame(width: 320)
        .background(VisualEffectBackground(material: .menu, blending: .withinWindow))
        .background(Theme.panelTint)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }
}

/// Shared state + keyboard handling for the ⌘K panel.
struct ActionMenuState {
    var isOpen = false
    var index = 0
    var actions: [PanelAction] = []

    mutating func open(_ actions: [PanelAction]) {
        guard !actions.isEmpty else { return }
        self.actions = actions
        index = 0
        isOpen = true
    }

    mutating func close() {
        isOpen = false
    }

    /// Returns the action to run, if Enter was pressed.
    mutating func handle(_ event: NSEvent) -> (handled: Bool, run: PanelAction?) {
        switch Int(event.keyCode) {
        case 126: // up
            index = (index - 1 + actions.count) % actions.count
            return (true, nil)
        case 125: // down
            index = (index + 1) % actions.count
            return (true, nil)
        case 36, 76: // return
            let action = actions[index]
            isOpen = false
            return (true, action)
        case 53: // escape
            isOpen = false
            return (true, nil)
        case 40 where event.shortcutModifiers == .command: // ⌘K
            isOpen = false
            return (true, nil)
        default:
            // Allow shortcuts listed in the panel to fire directly.
            return (false, nil)
        }
    }
}

import AppKit
import FlareCore
import SwiftUI

struct ClipboardView: View {
    @ObservedObject var model: ClipboardViewModel

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(text: $model.query, placeholder: "Type to filter entries…",
                      onCreate: { model.registerField($0) },
                      accessory: { FilterMenu(model: model) })
            PanelDivider()
            HStack(spacing: 0) {
                list
                    .frame(width: 290)
                Rectangle().fill(Theme.divider).frame(width: 1)
                ClipDetailView(record: model.selectedRecord, detail: model.detail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            PanelDivider()
            ActionBar(leadingIcon: .symbol("doc.on.clipboard", .orange),
                      leadingText: footer,
                      primaryTitle: model.selectedRecord == nil ? nil : "Paste to \(model.targetAppName ?? "Active App")")
        }
        .overlay(alignment: .bottomTrailing) {
            if model.actionMenu.isOpen {
                ActionPanelView(title: model.selectedRecord?.title ?? "Actions", actions: model.actionMenu.actions,
                                selectedIndex: model.actionMenu.index) { index in
                    let action = model.actionMenu.actions[index]
                    model.actionMenu.close()
                    action.perform()
                }
                .padding(.trailing, 10)
                .padding(.bottom, Theme.actionBarHeight + 6)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottomTrailing)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.actionMenu.isOpen)
        .background(Theme.panelTint)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var footer: String {
        let count = model.totalCount
        return count == 1 ? "Clipboard History · 1 entry" : "Clipboard History · \(count.formatted()) entries"
    }

    private var list: some View {
        VStack(spacing: 0) {
            if !model.isTrusted {
                AccessibilityBanner { model.requestAccessibility() }
            }
            if model.records.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(model.query.isEmpty && model.filter == nil ? "Nothing copied yet" : "No matching entries")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.sections) { section in
                                SectionHeader(title: section.title)
                                ForEach(section.records) { record in
                                    ClipRow(record: record, isSelected: record.id == model.selectedID)
                                        .id(record.id)
                                        .onTapGesture { model.selectedID = record.id }
                                        .onAppear { model.loadMoreIfNeeded(after: record) }
                                }
                            }
                        }
                        .padding(.horizontal, Theme.listInset)
                        .padding(.bottom, Theme.listInset)
                    }
                    .onChange(of: model.selectedID) { id in
                        guard let id else { return }
                        proxy.scrollTo(id)
                    }
                }
            }
        }
    }
}

private struct FilterMenu: View {
    @ObservedObject var model: ClipboardViewModel

    var body: some View {
        Menu {
            ForEach(Array(ClipboardViewModel.filters.enumerated()), id: \.offset) { _, kind in
                Button(title(kind)) { model.filter = kind }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title(model.filter))
                    .font(.system(size: 12.5, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.keycapFill))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by type (⌘P)")
    }

    private func title(_ kind: ClipKind?) -> String {
        guard let kind else { return "All Types" }
        switch kind {
        case .text: return "Text"
        case .image: return "Images"
        case .file: return "Files"
        case .link: return "Links"
        case .color: return "Colors"
        case .other: return "Other"
        }
    }
}

private struct AccessibilityBanner: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Allow Flare to paste")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Enable in Accessibility settings")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.listInset)
        .padding(.top, 8)
    }
}

struct ClipRow: View {
    let record: ClipRecord
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            IconView(icon: icon)
            Text(record.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if record.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.rowHeight)
        .background(RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
            .fill(isSelected ? Theme.selection : Color.clear))
        .contentShape(Rectangle())
    }

    private var icon: RowIcon {
        switch record.kind {
        case .text: return .symbol("text.alignleft", .secondary)
        case .link: return .symbol("link", .blue)
        case .image: return .clip(record.id)
        case .file:
            if let path = record.meta.filePaths?.first { return .path(path) }
            return .symbol("doc", .secondary)
        case .color:
            if let hex = record.meta.colorHex, let color = NSColor(hex: hex) { return .color(color) }
            return .symbol("paintpalette", .purple)
        case .other: return .symbol("shippingbox", .secondary)
        }
    }
}

struct ClipDetailView: View {
    let record: ClipRecord?
    let detail: ClipDetail?

    var body: some View {
        if let record {
            VStack(spacing: 0) {
                preview(record)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                PanelDivider()
                metadata(record)
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func preview(_ record: ClipRecord) -> some View {
        switch record.kind {
        case .text, .link:
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(detail?.id == record.id ? (detail?.text ?? record.preview) : record.preview)
                        .font(.system(size: 13, design: looksLikeCode(record.preview) ? .monospaced : .default))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if detail?.id == record.id, detail?.isTruncated == true {
                        Text("Preview shows the first 20,000 characters. The full \(record.charCount.formatted())-character entry is stored and will be pasted.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(14)
            }
        case .color:
            let color = record.meta.colorHex.flatMap { NSColor(hex: $0) } ?? NSColor.gray
            VStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: color))
                    .frame(width: 120, height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
                Text(record.meta.colorHex ?? record.preview)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
            }
        case .image:
            Group {
                if detail?.id == record.id, let image = detail?.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(14)
        case .file:
            let paths = record.meta.filePaths ?? []
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(paths, id: \.self) { path in
                        HStack(spacing: 10) {
                            IconView(icon: .path(path), size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text((path as NSString).lastPathComponent)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                Text((path as NSString).deletingLastPathComponent)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        case .other:
            VStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
                Text((record.meta.types ?? []).joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(14)
        }
    }

    private func metadata(_ record: ClipRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Information")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            if let name = record.sourceAppName {
                MetaRow(label: "Application") {
                    HStack(spacing: 5) {
                        if let icon = appIcon(record.sourceBundleID) {
                            Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                        }
                        Text(name)
                    }
                }
            }
            MetaRow(label: "Content type") { Text(record.kind.displayName) }
            switch record.kind {
            case .text, .link, .color:
                MetaRow(label: "Characters") { Text(record.charCount.formatted()) }
                if let words = record.meta.wordCount {
                    MetaRow(label: "Words") { Text(words.formatted()) }
                }
            case .image:
                if let w = record.meta.imageWidth, let h = record.meta.imageHeight {
                    MetaRow(label: "Dimensions") { Text("\(w)×\(h)") }
                }
                MetaRow(label: "Image size") { Text(ByteCountFormatter.string(fromByteCount: Int64(record.byteSize), countStyle: .file)) }
            case .file:
                MetaRow(label: "Files") { Text("\(record.meta.filePaths?.count ?? 0)") }
            case .other:
                MetaRow(label: "Size") { Text(ByteCountFormatter.string(fromByteCount: Int64(record.byteSize), countStyle: .file)) }
            }
            if record.copyCount > 1 {
                MetaRow(label: "Times copied") { Text("\(record.copyCount)") }
            }
            MetaRow(label: "Last copied") { Text(Self.dateFormatter.string(from: record.lastCopiedAt)) }
            if record.copyCount > 1 {
                MetaRow(label: "First copied") { Text(Self.dateFormatter.string(from: record.createdAt)) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func appIcon(_ bundleID: String?) -> NSImage? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return IconCache.shared.icon(forPath: url.path)
    }

    private func looksLikeCode(_ text: String) -> Bool {
        let sample = text.prefix(600)
        let codeChars = sample.filter { "{}();=<>[]$#".contains($0) }.count
        return codeChars > max(6, sample.count / 25) || sample.hasPrefix("    ") || sample.hasPrefix("\t")
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()
}

private struct MetaRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: () -> Value

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            value()
                .lineLimit(1)
        }
        .font(.system(size: 12))
        .frame(height: 22)
    }
}

extension NSColor {
    /// Parses #RGB, #RRGGBB and #RRGGBBAA.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

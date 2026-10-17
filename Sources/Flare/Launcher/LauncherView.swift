import AppKit
import FlareCore
import SwiftUI

struct LauncherView: View {
    @ObservedObject var model: LauncherViewModel

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(text: $model.query, placeholder: "Search for apps, files and currencies…",
                      onCreate: { model.registerField($0) })
            PanelDivider()
            ZStack {
                if model.hasResults {
                    results
                } else {
                    EmptyResultsView(query: model.query)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            PanelDivider()
            ActionBar(leadingIcon: .image(NSApp.applicationIconImage),
                      leadingText: model.footerText,
                      primaryTitle: model.primaryActionTitle)
        }
        .overlay(alignment: .bottomTrailing) {
            if model.actionMenu.isOpen {
                ActionPanelView(title: actionTitle, actions: model.actionMenu.actions,
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

    private var actionTitle: String {
        guard let item = model.selectedItem else { return "Actions" }
        switch item.payload {
        case .entry(let entry): return entry.title
        case .currency(let c, _): return "\(c.from) → \(c.to)"
        case .currencyLoading: return "Actions"
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.sections) { section in
                        SectionHeader(title: section.title)
                        ForEach(section.items) { item in
                            row(for: item)
                                .id(item.id)
                                .onTapGesture { model.activate(item) }
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

    @ViewBuilder
    private func row(for item: LauncherItem) -> some View {
        let selected = item.id == model.selectedID
        switch item.payload {
        case .currency(let conversion, let isPrimary):
            if isPrimary {
                CurrencyCard(conversion: conversion, isSelected: selected)
            } else {
                ResultRow(icon: .symbol("dollarsign.circle.fill", .green),
                          title: CurrencyFormat.amount(conversion.result, code: conversion.to),
                          subtitle: CurrencyFormat.name(conversion.to),
                          accessory: "Currency", isSelected: selected)
            }
        case .currencyLoading(let query):
            ResultRow(icon: .symbol("arrow.triangle.2.circlepath", .green),
                      title: "Fetching exchange rates…",
                      subtitle: "\(CurrencyFormat.amount(query.amount)) \(query.from)",
                      accessory: "Currency", isSelected: selected)
        case .entry(let entry):
            ResultRow(icon: icon(for: entry), title: entry.title, subtitle: entry.subtitle,
                      accessory: accessory(for: entry), accessoryKeys: keys(for: entry), isSelected: selected)
        }
    }

    private func icon(for entry: SearchEntry) -> RowIcon {
        if let command = LauncherCommand.from(id: entry.id) {
            return .symbol(command.symbol, command.tint)
        }
        guard let path = entry.path else { return .symbol("questionmark", .gray) }
        return entry.kind == .file ? .thumbnail(path) : .path(path)
    }

    private func accessory(for entry: SearchEntry) -> String {
        switch entry.kind {
        case .application: return "Application"
        case .file: return "File"
        case .folder: return "Folder"
        case .command: return "Command"
        }
    }

    private func keys(for entry: SearchEntry) -> [String] {
        if entry.id == "cmd:" + LauncherCommand.clipboardHistory.rawValue {
            return Preferences.shared.clipboardHotKey.keycaps
        }
        return []
    }
}

/// Raycast's calculator-style card: big "from" on the left, big "to" on the right.
struct CurrencyCard: View {
    let conversion: CurrencyConversion
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 0) {
            side(amount: CurrencyFormat.amount(conversion.amount), code: conversion.from)
            Image(systemName: "arrow.right")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
            side(amount: CurrencyFormat.amount(conversion.result), code: conversion.to)
        }
        .frame(height: 104)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Theme.selection : Theme.cardFill)
        )
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private func side(amount: String, code: String) -> some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(amount)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(code)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Text(CurrencyFormat.name(code))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.keycapFill))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }
}

struct EmptyResultsView: View {
    let query: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "Start typing to search" : "No Results")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            if !query.isEmpty {
                Text("Searched apps and your Downloads folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

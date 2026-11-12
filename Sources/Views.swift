import AppKit
import SwiftUI

struct Keycap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 17)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// Title with the typed words in bold (Slack-style match highlighting).
func highlighted(_ text: String, _ tokens: [String]) -> AttributedString {
    var a = AttributedString(text)
    guard !tokens.isEmpty else { return a }
    let lower = text.lowercased()
    for t in tokens where !t.isEmpty {
        var from = lower.startIndex
        while let r = lower.range(of: t, range: from..<lower.endIndex) {
            if let lo = AttributedString.Index(r.lowerBound, within: a), let hi = AttributedString.Index(r.upperBound, within: a) {
                a[lo..<hi].font = .system(size: 13, weight: .bold)
                a[lo..<hi].foregroundColor = .primary
            }
            from = r.upperBound
        }
    }
    return a
}

struct RowView: View {
    let row: Row
    let selected: Bool
    let tokens: [String]
    @State private var hover = false

    var body: some View {
        HStack(spacing: 11) {
            iconView.frame(width: row.prominent ? 34 : 26, height: row.prominent ? 34 : 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.highlight ? highlighted(row.title, tokens) : AttributedString(row.title))
                    .font(.system(size: row.prominent ? 14 : 13, weight: .medium))
                    .foregroundStyle(row.highlight ? Color.primary.opacity(0.82) : Color.primary)
                    .lineLimit(1).truncationMode(.middle)
                Text(row.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if selected {
                HStack(spacing: 6) {
                    Text(row.verb).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Keycap(text: "↵")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, row.prominent ? 8 : 5)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.16) : (hover ? Color.primary.opacity(0.05) : .clear))
        )
        .overlay(alignment: .leading) {
            if selected { Capsule().fill(Color.accentColor).frame(width: 3, height: 18).offset(x: 1) }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    @ViewBuilder var iconView: some View {
        switch row.icon {
        case .file(let u):
            Image(nsImage: FileInfo.icon(u)).resizable().interpolation(.high)
        case .symbol(let name, let color):
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color.opacity(0.14))
                .overlay(Image(systemName: name).font(.system(size: 14, weight: .semibold)).foregroundStyle(color))
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: Store
    @FocusState private var focused: Bool

    var leadingIcon: (String, Color) {
        switch store.mode {
        case .empty, .search: return ("magnifyingglass", .secondary)
        case .path:
            switch store.result {
            case .found(_, let isFolder): return (isFolder ? "folder.fill" : "doc.fill", .accentColor)
            case .missing: return ("exclamationmark.triangle.fill", .orange)
            case .empty: return ("magnifyingglass", .secondary)
            }
        }
    }

    var body: some View {
        let rows = store.rows
        let tokens = store.tokens
        VStack(spacing: 0) {
            // Input
            HStack(spacing: 10) {
                Image(systemName: leadingIcon.0)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(leadingIcon.1)
                    .frame(width: 20)
                    .contentTransition(.symbolEffect(.replace))
                TextField("Search, or paste a path…", text: $store.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit { store.activate(reveal: false) }
                    .onKeyPress(.downArrow) { store.move(1); return .handled }
                    .onKeyPress(.upArrow) { store.move(-1); return .handled }
                    .onKeyPress(.tab) { store.cycleFilter(); return .handled }
                    .onKeyPress(.escape) {
                        if store.query.isEmpty { store.close() } else { store.query = "" }
                        return .handled
                    }
                if store.searching {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                }
                if !store.query.isEmpty {
                    Button { store.query = ""; focused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }.buttonStyle(.plain).help("Clear")
                } else {
                    HStack(spacing: 3) { Keycap(text: "⌘"); Keycap(text: "V") }
                }
            }
            .padding(.horizontal, 16).frame(height: 54)

            if store.mode == .search { filterBar }

            Divider().opacity(0.6)

            // Results
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if store.mode == .path, case .missing = store.result {
                            statusLine("exclamationmark.triangle.fill", .orange,
                                       "Nothing at this path. Check the spelling, or open the closest folder that exists.")
                        }
                        if let flash = store.flash { statusLine("exclamationmark.circle.fill", .orange, flash) }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            if i == 0 || rows[i - 1].section != row.section { sectionHeader(row.section) }
                            RowView(row: row, selected: i == store.selected, tokens: tokens)
                                .id(row.id)
                                .onTapGesture { store.activate(reveal: false, row: row) }
                                .contextMenu { menu(for: row) }
                        }
                        if rows.isEmpty && store.flash == nil {
                            if store.mode == .empty { emptyState }
                            else if store.mode == .search && !store.searching { noResults }
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 8)
                }
                .onChange(of: store.selected) {
                    if rows.indices.contains(store.selected) { proxy.scrollTo(rows[store.selected].id) }
                }
            }
            .frame(height: 380)

            Divider().opacity(0.6)
            footer

            Button("") { store.activate(reveal: true) }
                .keyboardShortcut(.return, modifiers: .command)
                .frame(width: 0, height: 0).opacity(0)
        }
        .frame(width: 640)
        .onChange(of: store.focusTick) { focused = true }
        .onAppear { focused = true }
    }

    // MARK: pieces

    var filterBar: some View {
        let c = store.counts()
        return HStack(spacing: 6) {
            ForEach(Filter.allCases) { f in
                let on = store.filter == f
                Button { store.filter = f } label: {
                    HStack(spacing: 5) {
                        Text(f.rawValue)
                        if let n = c[f], n > 0, f != .all {
                            Text(n >= 200 ? "200+" : "\(n)").foregroundStyle(on ? .primary : .tertiary)
                        }
                    }
                    .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(Capsule().fill(on ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
                    .overlay(Capsule().strokeBorder(on ? Color.accentColor.opacity(0.35) : .clear, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.bottom, 10)
    }

    @ViewBuilder func menu(for row: Row) -> some View {
        Button(row.verb) { store.activate(reveal: false, row: row) }
        if row.fileURL != nil {
            Button("Show in Finder") { store.activate(reveal: true, row: row) }
            Button("Copy Path") { store.copyPath(row) }
            if row.section == "Recents" {
                Divider()
                Button("Remove from Recents") { if let u = row.fileURL { store.forget(u.path) } }
            }
        }
    }

    var footer: some View {
        HStack(spacing: 14) {
            hint(["↑", "↓"], "Navigate")
            hint(["↵"], "Open")
            hint(["⌘", "↵"], "Show in Finder")
            if store.mode == .search { hint(["⇥"], "Filter") }
            hint(["esc"], store.query.isEmpty ? "Close" : "Clear")
            Spacer()
            Text(HotKey.current.label).font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
                .help("Global shortcut for Path Opener")
            Button { store.showSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).help("Settings")
        }
        .padding(.horizontal, 14).frame(height: 34)
        .background(Color.primary.opacity(0.025))
    }

    func sectionHeader(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 3)
    }

    func statusLine(_ icon: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 12))
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(color.opacity(0.08)))
        .padding(.bottom, 4)
    }

    var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
                    .foregroundStyle(.quaternary)
                    .frame(width: 64, height: 64)
                Image(systemName: "arrow.up.forward.square").font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
            }
            Text("Search anything, or paste a path").font(.system(size: 14, weight: .semibold))
            Text("Apps, files, folders and what's inside your documents.\nPaste a path and it opens. Type 24*7 for a quick sum.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 70)
    }

    var noResults: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .light)).foregroundStyle(.tertiary)
            Text("No \(store.filter == .all ? "results" : store.filter.rawValue.lowercased()) for “\(store.query)”")
                .font(.system(size: 13, weight: .medium))
            if store.filter != .all {
                Text("Press ⇥ to try another filter").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 90)
    }

    func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { Keycap(text: $0) }
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

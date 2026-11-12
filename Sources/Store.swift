import AppKit
import SwiftUI

enum RowIcon: Equatable {
    case file(URL)
    case symbol(String, Color)
}

struct Row: Identifiable, Equatable {
    enum Action: Equatable {
        case open(URL)           // file, folder or app
        case copy(String)        // calculator result
        case web(URL)            // website or web search
    }
    let id: String
    let section: String
    let title: String
    let subtitle: String
    let icon: RowIcon
    let action: Action
    var prominent = false
    var highlight = true          // bold the matched words in the title
    var verb = "Open"

    var fileURL: URL? { if case .open(let u) = action { return u }; return nil }
}

enum Filter: String, CaseIterable, Identifiable {
    case all = "All", apps = "Applications", folders = "Folders", files = "Files", contents = "Contents"
    var id: String { rawValue }
}

final class Store: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { queryChanged(from: oldValue) } } }
    @Published private(set) var result: PathParser.Result = .empty
    @Published private(set) var hits: [Hit] = []
    @Published private(set) var searching = false
    @Published private(set) var recents: [String] = UserDefaults.standard.stringArray(forKey: "recents") ?? []
    @Published var filter: Filter = .all { didSet { selected = 0 } }
    @Published var selected = 0
    @Published var focusTick = 0
    @Published var flash: String? = nil
    @Published var openOnPaste: Bool = UserDefaults.standard.object(forKey: "openOnPaste") as? Bool ?? true {
        didSet { UserDefaults.standard.set(openOnPaste, forKey: "openOnPaste") }
    }
    var close: () -> Void = {}

    private let spotlight = SpotlightSearch()
    private var debounce: DispatchWorkItem?
    private var suppressAutoOpen = false

    init() {
        spotlight.onResults = { [weak self] h in self?.hits = h }
        spotlight.onBusy = { [weak self] b in self?.searching = b }
        spotlight.boost = { [weak self] p in (self?.recents.firstIndex(of: p)).map { 30 - Double($0) } ?? 0 }
    }

    enum Mode { case empty, path, search }
    var mode: Mode {
        let t = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .empty }
        return PathParser.looksLikePath(t) ? .path : .search
    }

    var tokens: [String] {
        mode == .search ? query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) : []
    }

    func counts() -> [Filter: Int] {
        var c: [Filter: Int] = [.all: hits.count]
        c[.apps] = hits.filter { $0.kind == .app }.count
        c[.folders] = hits.filter { $0.kind == .folder && $0.nameMatch }.count
        c[.files] = hits.filter { $0.kind == .file && $0.nameMatch }.count
        c[.contents] = hits.filter { !$0.nameMatch }.count
        return c
    }

    // MARK: rows

    var rows: [Row] {
        switch mode {
        case .empty: return recentRows(matching: "")
        case .path: return pathRows()
        case .search: return searchRows()
        }
    }

    private func recentRows(matching q: String) -> [Row] {
        let existing = recents.filter { FileManager.default.fileExists(atPath: $0) }
        let f = q.isEmpty ? existing : existing.filter { $0.lowercased().contains(q) || q.contains($0.lowercased()) }
        return f.prefix(8).map { p in
            let u = URL(fileURLWithPath: p)
            return Row(id: "r:" + p, section: "Recents", title: displayName(u), subtitle: FileInfo.prettyParent(u),
                       icon: .file(u), action: .open(u), highlight: false)
        }
    }

    private func pathRows() -> [Row] {
        var r: [Row] = []
        switch result {
        case .found(let u, let isFolder):
            r.append(Row(id: "t:" + u.path, section: isFolder ? "Folder" : "File", title: displayName(u),
                         subtitle: FileInfo.detail(u) + "  ·  " + FileInfo.prettyParent(u),
                         icon: .file(u), action: .open(u), prominent: true, highlight: false,
                         verb: isFolder ? "Open in Finder" : "Open"))
        case .missing(let n?):
            r.append(Row(id: "n:" + n.path, section: "Closest folder that exists", title: displayName(n),
                         subtitle: FileInfo.prettyParent(n), icon: .file(n), action: .open(n), highlight: false,
                         verb: "Open in Finder"))
        default: break
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        for row in recentRows(matching: q) where !r.contains(where: { $0.fileURL == row.fileURL }) { r.append(row) }
        return r
    }

    private func searchRows() -> [Row] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var r: [Row] = []

        if filter == .all, let v = Calculator.evaluate(q) {
            let s = Calculator.format(v)
            r.append(Row(id: "calc", section: "Calculator", title: s, subtitle: q + " =",
                         icon: .symbol("equal.square.fill", .orange), action: .copy(s), prominent: true,
                         highlight: false, verb: "Copy"))
        }
        if filter == .all, let link = LinkDetector.url(from: q) {
            r.append(Row(id: "link", section: "Website", title: link.absoluteString, subtitle: "Open in your browser",
                         icon: .symbol("safari.fill", .blue), action: .web(link), highlight: false))
        }

        func row(_ h: Hit, _ section: String, prominent: Bool = false) -> Row {
            let sub = h.nameMatch ? FileInfo.prettyParent(h.url) : "Mentions “\(q)” · " + FileInfo.prettyParent(h.url)
            return Row(id: h.id, section: section, title: h.name, subtitle: sub, icon: .file(h.url),
                       action: .open(h.url), prominent: prominent,
                       verb: h.kind == .app ? "Launch" : (h.kind == .folder ? "Open in Finder" : "Open"))
        }

        switch filter {
        case .all:
            var used = Set<String>()
            if let top = hits.first {
                r.append(row(top, "Top Hit", prominent: true)); used.insert(top.id)
            }
            let groups: [(String, (Hit) -> Bool, Int)] = [
                ("Applications", { $0.kind == .app }, 5),
                ("Folders", { $0.kind == .folder && $0.nameMatch }, 6),
                ("Files", { $0.kind == .file && $0.nameMatch }, 14),
                ("Contents", { !$0.nameMatch && $0.kind != .app }, 6),
            ]
            for (name, test, cap) in groups {
                for h in hits.filter({ test($0) && !used.contains($0.id) }).prefix(cap) {
                    r.append(row(h, name)); used.insert(h.id)
                }
            }
        case .apps: r += hits.filter { $0.kind == .app }.prefix(60).map { row($0, "Applications") }
        case .folders: r += hits.filter { $0.kind == .folder && $0.nameMatch }.prefix(60).map { row($0, "Folders") }
        case .files: r += hits.filter { $0.kind == .file && $0.nameMatch }.prefix(60).map { row($0, "Files") }
        case .contents: r += hits.filter { !$0.nameMatch }.prefix(60).map { row($0, "Contents") }
        }

        if filter == .all, let url = URL(string: "https://www.google.com/search?q=" + (q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)) {
            r.append(Row(id: "web", section: "Web", title: "Search the web for “\(q)”", subtitle: "Google",
                         icon: .symbol("globe", .secondary), action: .web(url), highlight: false))
        }
        return r
    }

    private func displayName(_ u: URL) -> String {
        u.lastPathComponent.isEmpty ? u.path : u.lastPathComponent
    }

    // MARK: input

    private func queryChanged(from old: String) {
        selected = 0
        flash = nil
        debounce?.cancel()
        switch mode {
        case .empty:
            result = .empty; hits = []; spotlight.stop(); searching = false
        case .path:
            spotlight.stop(); hits = []; searching = false
            result = PathParser.resolve(query)
            // A whole path pasted into an empty field opens straight away.
            if old.isEmpty, query.count > 2, openOnPaste, !suppressAutoOpen, case .found = result {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in self?.activate(reveal: false) }
            }
        case .search:
            result = .empty
            // Never show results for a different query: narrow the old ones while Spotlight works.
            let toks = tokens
            hits = hits.filter { h in h.nameMatch && toks.allSatisfy { h.name.lowercased().contains($0) } }
            let q = query
            let work = DispatchWorkItem { [weak self] in self?.spotlight.search(q) }
            debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
        }
        suppressAutoOpen = false
    }

    #if DEBUG
    /// Screenshot builds only: show fixed results instead of querying Spotlight.
    func previewSearch(_ q: String, hits fixed: [Hit]) {
        query = q
        debounce?.cancel(); spotlight.stop()
        hits = fixed; searching = false
    }
    #endif

    func prepareForShow() {
        flash = nil
        filter = .all
        let clip = (NSPasteboard.general.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        suppressAutoOpen = true
        if clip.count < 2000, PathParser.looksLikePath(clip), case .found = PathParser.resolve(clip) {
            query = clip
        } else {
            query = ""
        }
        suppressAutoOpen = false
        focusTick += 1
    }

    func move(_ d: Int) {
        let n = rows.count
        guard n > 0 else { return }
        selected = (selected + d + n) % n
    }

    func cycleFilter() {
        guard mode == .search else { return }
        let all = Filter.allCases
        filter = all[(all.firstIndex(of: filter)! + 1) % all.count]
    }

    func activate(reveal: Bool, row: Row? = nil) {
        let rs = rows
        guard let row = row ?? (rs.indices.contains(selected) ? rs[selected] : nil) else {
            if !query.isEmpty { flash = mode == .path ? "Nothing at that path" : "No results yet" }
            return
        }
        switch row.action {
        case .open(let url):
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.open(url) }
            remember(url.path)
        case .copy(let s):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        case .web(let url):
            NSWorkspace.shared.open(url)
        }
        close()
    }

    func copyPath(_ row: Row) {
        guard let u = row.fileURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u.path, forType: .string)
    }

    func remember(_ path: String) {
        var r = recents.filter { $0 != path }
        r.insert(path, at: 0)
        recents = Array(r.prefix(30))
        UserDefaults.standard.set(recents, forKey: "recents")
    }

    func forget(_ path: String) {
        recents.removeAll { $0 == path }
        UserDefaults.standard.set(recents, forKey: "recents")
    }

    func clearRecents() {
        recents = []
        UserDefaults.standard.set(recents, forKey: "recents")
    }
}

// MARK: - File info

enum FileInfo {
    private static let iconCache = NSCache<NSString, NSImage>()

    static func icon(_ url: URL) -> NSImage {
        if let i = iconCache.object(forKey: url.path as NSString) { return i }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        iconCache.setObject(i, forKey: url.path as NSString)
        return i
    }

    static func detail(_ url: URL) -> String {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .localizedTypeDescriptionKey, .contentModificationDateKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return "" }
        var parts: [String] = []
        if v.isDirectory == true && v.isPackage != true {
            let n = (try? FileManager.default.contentsOfDirectory(atPath: url.path).filter { !$0.hasPrefix(".") }.count) ?? 0
            parts.append("Folder · \(n) item\(n == 1 ? "" : "s")")
        } else {
            parts.append(v.localizedTypeDescription ?? "File")
            if let s = v.fileSize, v.isPackage != true { parts.append(ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file)) }
        }
        if let d = v.contentModificationDate {
            let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
            parts.append("edited " + f.localizedString(for: d, relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }

    static func prettyParent(_ url: URL) -> String {
        let parent = url.deletingLastPathComponent().path
        let home = NSHomeDirectory()
        if parent.hasPrefix(home) { return "~" + parent.dropFirst(home.count) }
        return parent
    }
}

import AppKit

/// One thing Spotlight found.
struct Hit: Identifiable, Equatable {
    enum Kind: Int { case app, folder, file }
    let id: String          // full path
    let url: URL
    let name: String
    let kind: Kind
    let nameMatch: Bool     // false = matched on file contents only
    let score: Double
}

/// Keyword search over the macOS Spotlight index (the same index Spotlight uses).
/// Runs two queries: one on names (fast, ranked) and one on file contents.
final class SpotlightSearch: NSObject {
    var onResults: ([Hit]) -> Void = { _ in }
    var onBusy: (Bool) -> Void = { _ in }
    /// Extra score for a path (used to lift recently opened items).
    var boost: (String) -> Double = { _ in 0 }

    private var nameQuery: NSMetadataQuery?
    private var contentQuery: NSMetadataQuery?
    private var tokens: [String] = []
    private var nameHits: [Hit] = []
    private var contentHits: [Hit] = []
    private var pending = 0
    private var generation = 0

    private let nameCap = 700
    private let contentCap = 200

    func search(_ text: String) {
        stop()
        generation += 1
        tokens = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        nameHits = []; contentHits = []
        guard !tokens.isEmpty else { onResults([]); onBusy(false); return }

        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
             .replacingOccurrences(of: "*", with: "\\*")
        }
        let nameQS = tokens.map { t in
            "(kMDItemDisplayName == \"*\(esc(t))*\"cd || kMDItemFSName == \"*\(esc(t))*\"cd)"
        }.joined(separator: " && ")
        pending = 0
        if let p = NSPredicate(fromMetadataQueryString: nameQS) {
            nameQuery = makeQuery(p); pending += 1
        }
        if tokens.joined().count >= 3 {
            let contentQS = tokens.map { "kMDItemTextContent == \"\(esc($0))*\"cdw" }.joined(separator: " && ")
            if let p = NSPredicate(fromMetadataQueryString: contentQS) {
                contentQuery = makeQuery(p); pending += 1
            }
        }
        onBusy(pending > 0)
        nameQuery?.start()
        contentQuery?.start()
        // Content search across a big disk can run for many seconds: keep what we have by then.
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, gen == self.generation, let q = self.contentQuery else { return }
            self.finish(q)
        }
    }

    func stop() {
        for q in [nameQuery, contentQuery].compactMap({ $0 }) {
            q.stop()
            NotificationCenter.default.removeObserver(self, name: nil, object: q)
        }
        nameQuery = nil; contentQuery = nil
    }

    private func makeQuery(_ p: NSPredicate) -> NSMetadataQuery {
        let q = NSMetadataQuery()
        q.predicate = p
        q.searchScopes = [NSMetadataQueryLocalComputerScope]
        q.notificationBatchingInterval = 0.06
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(progress(_:)), name: .NSMetadataQueryGatheringProgress, object: q)
        nc.addObserver(self, selector: #selector(finished(_:)), name: .NSMetadataQueryDidFinishGathering, object: q)
        return q
    }

    @objc private func progress(_ n: Notification) {
        guard let q = n.object as? NSMetadataQuery else { return }
        let cap = q === nameQuery ? nameCap : contentCap
        if q.resultCount >= cap { finish(q) } else { collect(q, final: false) }
    }

    @objc private func finished(_ n: Notification) {
        guard let q = n.object as? NSMetadataQuery else { return }
        finish(q)
    }

    private func finish(_ q: NSMetadataQuery) {
        guard q === nameQuery || q === contentQuery, q.isStarted else { return }
        collect(q, final: true)
        q.stop()
        NotificationCenter.default.removeObserver(self, name: nil, object: q)
        pending -= 1
        if pending <= 0 { onBusy(false) }
    }

    private func collect(_ q: NSMetadataQuery, final: Bool) {
        let isName = q === nameQuery
        q.disableUpdates()
        let n = min(q.resultCount, isName ? nameCap : contentCap)
        var out: [Hit] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !Self.isNoise(path) else { continue }
            let display = (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String)
                ?? (path as NSString).lastPathComponent
            let tree = item.value(forAttribute: "kMDItemContentTypeTree") as? [String] ?? []
            let kind: Hit.Kind = tree.contains("com.apple.application-bundle") || path.hasSuffix(".app") ? .app
                : (tree.contains("public.folder") ? .folder : .file)
            let used = item.value(forAttribute: "kMDItemLastUsedDate") as? Date
            let score = rank(name: display, path: path, kind: kind, nameMatch: isName, lastUsed: used)
            out.append(Hit(id: path, url: URL(fileURLWithPath: path), name: display, kind: kind, nameMatch: isName, score: score))
        }
        q.enableUpdates()
        if isName { nameHits = out } else { contentHits = out }
        publish()
    }

    private func publish() {
        var seen = Set<String>()
        var merged: [Hit] = []
        for h in (nameHits + contentHits).sorted(by: { $0.score > $1.score }) where seen.insert(h.id).inserted {
            merged.append(h)
        }
        onResults(merged)
    }

    private func rank(name: String, path: String, kind: Hit.Kind, nameMatch: Bool, lastUsed: Date?) -> Double {
        let full = tokens.joined(separator: " ")
        let lower = name.lowercased()
        let base = (lower as NSString).deletingPathExtension
        var s: Double = 0
        if nameMatch {
            if base == full || lower == full { s += 100 }
            else if lower.hasPrefix(full) { s += 80 }
            else {
                let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                let wordHits = tokens.filter { t in words.contains { $0.hasPrefix(t) } }.count
                s += 40 + Double(wordHits) / Double(max(tokens.count, 1)) * 25
            }
            s -= Double(max(0, lower.count - full.count)) * 0.15   // shorter names that match are better
        } else {
            s += 12
        }
        if kind == .app {
            s += (path.hasPrefix("/Applications") || path.hasPrefix("/System/Applications")) ? 35 : 15
        }
        if let d = lastUsed {
            let days = -d.timeIntervalSinceNow / 86_400
            s += max(0, 20 - days * 0.7)
        }
        s -= Double(path.split(separator: "/").count) * 0.6
        s += boost(path)
        return s
    }

    /// Paths nobody wants in launcher results.
    static func isNoise(_ path: String) -> Bool {
        let comps = path.split(separator: "/")
        if comps.contains(where: { $0.hasPrefix(".") }) { return true }
        let bad: Set<String> = ["node_modules", "deriveddata", "__pycache__", "site-packages", "dist-packages", "venv", "venvs",
                                "vendor", "_vendor", "pods", "build", "caches", "cache", "library", "target", "bower_components"]
        if comps.contains(where: { bad.contains($0.lowercased()) && $0 != "Library" }) { return true }
        if path.contains("/Library/") && !path.contains("/Library/Mobile Documents/")
            && !path.hasPrefix("/System/Library/CoreServices/") { return true }
        if path.hasPrefix("/System/") && !path.hasPrefix("/System/Applications") && !path.hasPrefix("/System/Library/CoreServices/") { return true }
        if path.hasPrefix("/Library/") || path.hasPrefix("/private/") || path.hasPrefix("/usr/") || path.hasPrefix("/opt/") { return true }
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/Library/") && !path.hasPrefix(home + "/Library/Mobile Documents/") { return true }
        if path.contains(".app/") { return true }   // insides of app bundles
        if path.hasPrefix("/System/Library/CoreServices/") && !path.hasSuffix(".app") { return true }
        return false
    }
}

/// A tiny, safe arithmetic evaluator: + − × ÷ ^ % and parentheses.
enum Calculator {
    static func evaluate(_ raw: String) -> Double? {
        let s = raw.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "x", with: "*")
                   .replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: "−", with: "-")
                   .replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty, s.allSatisfy({ "0123456789.+-*/^%()".contains($0) }),
              s.contains(where: { "+-*/^%".contains($0) }), s.contains(where: \.isNumber) else { return nil }
        var p = Parser(chars: Array(s))
        guard let v = p.expr(), p.i == p.chars.count, v.isFinite else { return nil }
        // "-5" alone is not a calculation
        if let lone = Double(s), lone == v { return nil }
        return v
    }

    static func format(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 10
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    private struct Parser {
        let chars: [Character]
        var i = 0
        var lastWasPercent = false
        init(chars: [Character]) { self.chars = chars }
        mutating func peek() -> Character? { i < chars.count ? chars[i] : nil }
        mutating func expr() -> Double? {
            guard var v = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                i += 1; guard var r = term() else { return nil }
                if lastWasPercent { r *= v }          // 200 + 15% = 230, like Spotlight
                v = c == "+" ? v + r : v - r
            }
            return v
        }
        mutating func term() -> Double? {
            lastWasPercent = false
            guard var v = power() else { return nil }
            while let c = peek(), c == "*" || c == "/" || c == "%" {
                i += 1
                if c == "%" && (peek() == nil || "+-*/)".contains(peek()!)) { v /= 100; lastWasPercent = true; continue }
                lastWasPercent = false
                guard let r = power() else { return nil }
                v = c == "*" ? v * r : (c == "/" ? v / r : v.truncatingRemainder(dividingBy: r))
            }
            return v
        }
        mutating func power() -> Double? {
            guard let b = unary() else { return nil }
            if peek() == "^" { i += 1; guard let e = power() else { return nil }; return pow(b, e) }
            return b
        }
        mutating func unary() -> Double? {
            if peek() == "-" { i += 1; return unary().map { -$0 } }
            if peek() == "+" { i += 1; return unary() }
            return atom()
        }
        mutating func atom() -> Double? {
            if peek() == "(" {
                i += 1; let v = expr()
                guard peek() == ")" else { return nil }
                i += 1; return v
            }
            let start = i
            while let c = peek(), c.isNumber || c == "." { i += 1 }
            return start == i ? nil : Double(String(chars[start..<i]))
        }
    }
}

enum LinkDetector {
    /// "github.com", "https://x.y/z" → URL. Plain words → nil.
    static func url(from raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return URL(string: s) }
        let host = String(lower.split(separator: "/").first ?? "")
        let parts = host.split(separator: ".")
        guard parts.count >= 2, let tld = parts.last, tld.count >= 2, tld.allSatisfy(\.isLetter),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }) else { return nil }
        // Avoid treating "report.pdf" as a website
        let fileExts: Set<String> = ["pdf", "doc", "docx", "txt", "md", "png", "jpg", "jpeg", "mp4", "mov", "zip", "html", "swift", "py", "js", "ts", "json", "csv", "xlsx", "pptx", "srt", "vtt", "key", "pages", "numbers", "app", "sh"]
        if fileExts.contains(String(tld)) { return nil }
        return URL(string: "https://" + s)
    }
}

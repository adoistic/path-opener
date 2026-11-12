import AppKit

enum PathParser {
    /// True when the input is clearly meant as a path rather than search keywords.
    static func looksLikePath(_ raw: String) -> Bool {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let f = s.first, "\"'`<“‘".contains(f) { s.removeFirst() }
        return s.hasPrefix("/") || s.hasPrefix("~") || s.lowercased().hasPrefix("file://")
    }

    /// Turns whatever was pasted into a real filesystem path, or nil.
    static func candidates(from raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstLine = s.split(whereSeparator: \.isNewline).first { s = String(firstLine) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip wrapping quotes / backticks / angle brackets
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("`", "`"), ("<", ">"), ("“", "”"), ("‘", "’")]
        var changed = true
        while changed && s.count >= 2 {
            changed = false
            for (a, b) in pairs where s.first == a && s.last == b {
                s = String(s.dropFirst().dropLast()); changed = true
            }
        }
        if s.isEmpty { return [] }
        // file:// URLs
        if s.lowercased().hasPrefix("file://"), let url = URL(string: s) ?? URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") {
            s = url.path
        }
        var out: [String] = []
        func add(_ p: String) {
            var p = (p as NSString).expandingTildeInPath
            if !p.hasPrefix("/") { p = (NSHomeDirectory() as NSString).appendingPathComponent(p) }
            if p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            if !out.contains(p) { out.append(p) }
        }
        add(s)
        // Shell-escaped ("My\ File.pdf")
        if s.contains("\\") {
            var unescaped = ""; var esc = false
            for ch in s { if esc { unescaped.append(ch); esc = false } else if ch == "\\" { esc = true } else { unescaped.append(ch) } }
            add(unescaped)
        }
        // Percent-encoded
        if s.contains("%"), let decoded = s.removingPercentEncoding { add(decoded) }
        return out
    }

    enum Result: Equatable {
        case empty
        case found(URL, isFolder: Bool)
        case missing(nearest: URL?)
    }

    static func resolve(_ raw: String) -> Result {
        let cands = candidates(from: raw)
        if cands.isEmpty { return .empty }
        let fm = FileManager.default
        for c in cands {
            var dir: ObjCBool = false
            if fm.fileExists(atPath: c, isDirectory: &dir) {
                let url = URL(fileURLWithPath: c)
                let isPackage = NSWorkspace.shared.isFilePackage(atPath: url.resolvingSymlinksInPath().path)
                return .found(url, isFolder: dir.boolValue && !isPackage)
            }
        }
        // Walk up to the closest folder that exists
        var p = cands[0]
        while p != "/" && !p.isEmpty {
            p = (p as NSString).deletingLastPathComponent
            var dir: ObjCBool = false
            if fm.fileExists(atPath: p, isDirectory: &dir), dir.boolValue, p != "/" {
                return .missing(nearest: URL(fileURLWithPath: p))
            }
        }
        return .missing(nearest: nil)
    }
}


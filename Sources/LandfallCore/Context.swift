import AppKit
import Foundation
import Vision

// MARK: - Calendar context

/// A calendar event around the time a file arrived.
public struct Meeting: Equatable {
    public var title: String
    /// Attendee names and email addresses.
    public var attendees: [String]

    public init(title: String, attendees: [String]) {
        self.title = title
        self.attendees = attendees
    }
}

/// Supplies meetings (EventKit in the app; nothing in the CLI or tests).
public protocol MeetingProvider: AnyObject {
    func meetings(around date: Date) -> [Meeting]
}

// MARK: - OCR

public enum OCR {
    /// Text in an image, best effort, nil if there is none.
    public static func text(_ url: URL, maxBytes: Int64 = 25 << 20) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) <= maxBytes,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil else { return nil }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(8000))
    }
}

// MARK: - Better names

public enum Renamer {
    /// A cleaner name for an item being filed, or nil to keep it.
    public static func suggest(_ f: ItemFacts) -> String? {
        let ext = f.url.pathExtension
        var base = f.base
        var changed = false

        // "Report (2)" / "Report(1)" — the copy suffix means nothing once it's filed.
        if let c = base.captures("^(.+?) ?\\((\\d+)\\)$") {
            base = c[1]
            changed = true
        }
        // Punctuation typed in the middle of a word: "Resu,e" → "Resume".
        if let fixed = fixTypos(base), fixed != base {
            base = fixed
            changed = true
        }
        // Meaningless names: hashes, "download", "document", "untitled".
        if isMeaningless(base), let better = meaningfulName(f) {
            base = better
            changed = true
        }
        guard changed, !base.isEmpty else { return nil }
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    static func isMeaningless(_ base: String) -> Bool {
        if base.matches("(?i)^(download|document|file|untitled|image|img|scan|attachment)[ _-]?\\d*$") { return true }
        // Hash-ish: long, no spaces, mixes letters and digits, few vowels.
        guard base.count >= 10, !base.contains(" "), base.matches("^[A-Za-z0-9_-]+$"),
              base.matches("[0-9]"), base.matches("[A-Za-z]") else { return false }
        let vowels = base.lowercased().filter { "aeiou".contains($0) }.count
        return Double(vowels) / Double(base.count) < 0.2
    }

    static func meaningfulName(_ f: ItemFacts) -> String? {
        if let t = f.title?.trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 4, t != f.name, t != f.base,
           !isMeaningless((t as NSString).deletingPathExtension) {
            return clean(t)
        }
        if let text = f.textHead {
            // First line that reads like a heading.
            for line in text.split(separator: "\n").prefix(8) {
                let words = line.split(separator: " ").filter { $0.contains(where: \.isLetter) }
                if words.count >= 2 && words.count <= 8 && line.count <= 60 { return clean(String(line)) }
            }
        }
        let date = f.added ?? f.modified ?? Date()
        let kind = Classifier.imageExts.contains(f.ext) ? "Image" : "File"
        return "\(kind) \(formatDate(date, "yyyy-MM-dd HHmm"))"
    }

    static func clean(_ s: String) -> String {
        String(s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).prefix(80))
    }

    /// Replace a stray punctuation mark inside a word with the letter that makes it a real word.
    static func fixTypos(_ base: String) -> String? {
        guard base.matches("[A-Za-z][,.;'`][A-Za-z]") else { return nil }
        var out = base
        let ns = base as NSString
        guard let re = try? NSRegularExpression(pattern: "\\b[A-Za-z]*[A-Za-z][,;`][A-Za-z][A-Za-z]*\\b") else { return nil }
        for m in re.matches(in: base, range: NSRange(location: 0, length: ns.length)).reversed() {
            let word = ns.substring(with: m.range)
            guard let fixed = respell(word) else { continue }
            out = (out as NSString).replacingCharacters(in: m.range, with: fixed)
        }
        return out == base ? nil : out
    }

    /// The letter-for-punctuation swap that is both a real word and one the spell checker would suggest.
    static func respell(_ word: String) -> String? {
        guard let punct = word.firstIndex(where: { ",;`".contains($0) }) else { return nil }
        let checker = NSSpellChecker.shared
        var stripped = word
        stripped.remove(at: punct)
        let guesses = Set((checker.guesses(forWordRange: NSRange(location: 0, length: (stripped as NSString).length),
                                           in: stripped, language: "en", inSpellDocumentWithTag: 0) ?? []).map { $0.lowercased() })
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            var candidate = word
            candidate.replaceSubrange(punct...punct, with: String(letter))
            if guesses.contains(candidate.lowercased()) { return candidate }
        }
        return nil
    }
}

// MARK: - Learning rules from corrections

public enum RuleLearner {
    public struct Proposal {
        public var key: String
        public var rule: RuleConfig
        public var count: Int
        public var summary: String
    }

    /// When you've moved two or more filed items into the same folder, find what they share.
    public static func propose(corrected: [ItemFacts], folder: String, config: Config) -> Proposal? {
        guard corrected.count >= 2 else { return nil }
        let lib = config.libraryURL.path + "/"
        guard folder.hasPrefix(lib) else { return nil }
        var rel = String(folder.dropFirst(lib.count))
        if let last = rel.split(separator: "/").last, String(last).matches("^\\d{4}-\\d{2}$") {
            rel = rel.split(separator: "/").dropLast().joined(separator: "/") + "/{yyyy-mm}"
        }
        let name = "Learned: \(rel.replacingOccurrences(of: "/{yyyy-mm}", with: ""))"
        var rule = RuleConfig(name: name, to: rel)
        var because: String

        let transcripts = corrected.compactMap { $0.textHead.flatMap(Transcript.parse) }
        let owners = Set(config.ownerNames.map { $0.lowercased() })
        let common: Set<String>? = transcripts.count == corrected.count
            ? transcripts.map { Set($0.participants.map { $0.lowercased() }).subtracting(owners) }
                .reduce(nil) { acc, s in acc.map { $0.intersection(s) } ?? s }
            : nil
        let hosts = corrected.map { $0.origins.lazy.compactMap(Trust.host).first }
        let words = corrected.map { Set(tokens($0.base)) }.reduce(nil as Set<String>?) { acc, s in acc.map { $0.intersection(s) } ?? s } ?? []
        let exts = Set(corrected.map(\.ext))

        if let people = common, let person = people.sorted().first {
            let display = transcripts[0].participants.first { $0.lowercased() == person } ?? person
            rule.participantsAny = [display]
            because = "meetings with \(display)"
        } else if let h = hosts.first ?? nil, hosts.allSatisfy({ $0 == h }) {
            rule.originRegex = "^https?://([^/]*\\.)?" + NSRegularExpression.escapedPattern(for: h) + "/"
            because = "downloads from \(h)"
        } else if let w = words.sorted(by: { $0.count > $1.count }).first {
            rule.nameRegex = "(?i)\\b" + NSRegularExpression.escapedPattern(for: w) + "\\b"
            because = "names containing “\(w)”"
        } else {
            return nil
        }
        if exts.count == 1, let e = exts.first, !e.isEmpty {
            rule.extensions = [e]
            because += " (.\(e))"
        }
        let key = "\(rule.participantsAny ?? [])|\(rule.originRegex ?? "")|\(rule.nameRegex ?? "")|\(rel)"
        return Proposal(key: key, rule: rule, count: corrected.count,
                        summary: "You moved \(corrected.count) \(because) to \(rel.replacingOccurrences(of: "/{yyyy-mm}", with: "")).")
    }

    static let stopwords: Set<String> = ["the", "and", "for", "with", "from", "copy", "final", "draft", "file", "document", "image", "screenshot", "meeting", "notes"]

    static func tokens(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            .filter { $0.count >= 4 && !stopwords.contains($0) }
    }
}

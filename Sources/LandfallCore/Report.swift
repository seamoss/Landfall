import Foundation

public enum Report {
    public static func digest(_ ledger: Ledger, config: Config, since: Date) -> String {
        let items = ledger.recent(since: since)
        guard !items.isEmpty else { return "Nothing landed since \(formatDate(since, "MMM d"))." }

        func counts<T: Hashable>(_ xs: [T]) -> [(T, Int)] {
            Dictionary(grouping: xs, by: { $0 }).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
        }
        let byRoot = counts(items.map(\.root)).map { "\($0.1) in \($0.0)" }.joined(separator: ", ")
        let byKind = counts(items.compactMap { $0.decision?.rule }.filter { $0 != "fallback" })
            .prefix(6).map { "\($0.1) \($0.0)" }.joined(separator: ", ")

        let lib = config.libraryURL.path
        let clientNames: [String] = items.compactMap { it in
            guard it.status == "filed" else { return nil }
            return config.clients.first { c in
                it.path.hasPrefix(lib + "/" + c.folderPath + "/")
                    || it.path.hasPrefix(lib + "/" + config.folders.meetings + "/" + c.name + "/")
            }?.name
        }
        let byClient = counts(clientNames).map { "\($0.0) \($0.1)" }.joined(separator: ", ")

        let filed = items.filter { $0.status == "filed" }.count
        let trashed = items.filter { $0.status == "trashed" }
        let review = ledger.count(status: "proposed")
        let held = ledger.count(status: "held")
        let sensitive = items.filter { $0.decision?.flags.contains("sensitive") == true && $0.status != "trashed" }
        let corrected = ledger.events(since: since, types: ["corrected"]).count

        var lines = ["\(items.count) arrivals since \(formatDate(since, "MMM d")) — \(byRoot)."]
        if !byKind.isEmpty { lines.append("Kinds: \(byKind).") }
        if !byClient.isEmpty { lines.append("Clients: \(byClient).") }
        let trashedBytes = trashed.reduce(0) { $0 + $1.size }
        lines.append("Filed \(filed) · trashed \(trashed.count)" + (trashedBytes > 0 ? " (\(formatBytes(trashedBytes)))" : "")
            + " · \(review) awaiting review · \(held) held.")
        if !sensitive.isEmpty {
            lines.append("⚠️ \(sensitive.count) sensitive: " + sensitive.map(\.name).joined(separator: ", "))
        }
        if corrected > 0 { lines.append("You corrected \(corrected) filings — run `landfall suggest` for new rules.") }
        return lines.joined(separator: "\n")
    }

    /// Repeated corrections of the same rule to the same folder become rule suggestions.
    public static func suggestions(_ ledger: Ledger, config: Config) -> [(rule: String, folder: String, count: Int, examples: [String])] {
        let evs = ledger.events(since: Date(timeIntervalSince1970: 0), types: ["corrected"])
        var groups: [String: (String, String, [String])] = [:]
        for e in evs {
            guard let dst = e.dst else { continue }
            let folder = (dst as NSString).deletingLastPathComponent
            let key = "\(e.rule ?? "?")|\(folder)"
            var g = groups[key] ?? (e.rule ?? "?", folder, [])
            g.2.append((dst as NSString).lastPathComponent)
            groups[key] = g
        }
        return groups.values.filter { $0.2.count >= 2 }
            .map { ($0.0, $0.1, $0.2.count, Array($0.2.prefix(3))) }
            .sorted { $0.count > $1.count }
    }
}

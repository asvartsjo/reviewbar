import Foundation

/// Reviews live in ~/Library/Application Support/ReviewBar/
///   reviews.json   – everything the app reloads on launch
///   markdown/*.md  – one readable file per review (grep-able, open in any editor)
enum Store {
    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReviewBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static var jsonURL: URL { dir.appendingPathComponent("reviews.json") }

    static func load() -> [SavedReview] {
        if DemoData.isOn { return DemoData.saved }
        guard let data = try? Data(contentsOf: jsonURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([SavedReview].self, from: data)) ?? []
    }

    static func save(_ reviews: [SavedReview]) {
        guard !DemoData.isOn else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(reviews) { try? data.write(to: jsonURL, options: .atomic) }
    }

    /// One file per reviewed version, so a newer review never overwrites an older one.
    private static func markdownURL(_ pr: PR) -> URL {
        let name = pr.repository.nameWithOwner.replacingOccurrences(of: "/", with: "-")
            + "-\(pr.number)-\(pr.versionLabel).md"
        return dir.appendingPathComponent("markdown", isDirectory: true).appendingPathComponent(name)
    }

    static func writeMarkdown(_ pr: PR, _ text: String) {
        guard !DemoData.isOn else { return }
        let url = markdownURL(pr)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let body = "# \(pr.title)\n\(pr.url)\nAuthor: \(pr.author.login) · reviewed \(Date())\n\n\(text)\n"
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    static func deleteMarkdown(_ pr: PR) {
        guard !DemoData.isOn else { return }
        try? FileManager.default.removeItem(at: markdownURL(pr))
    }
}

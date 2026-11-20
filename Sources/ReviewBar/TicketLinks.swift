import Foundation

/// Linear ticket ids mentioned in a PR's title or description, linked to your Linear workspace.
/// Off until turned on in Settings, where the workspace URL (and optionally the team keys) go.
enum TicketLinks {
    static let enabledKey = "ticketLinks", workspaceKey = "ticketLinksWorkspace", teamKeysKey = "ticketLinksTeamKeys"

    struct Ticket: Equatable {
        let id: String
        let url: String
    }

    struct Config: Equatable {
        /// The workspace's URL name: the `acme` in linear.app/acme.
        let workspace: String
        /// Team keys to look for, upper-case. Empty means any KEY-123 written in capitals.
        let teamKeys: [String]

        /// Nil unless the feature is on and the workspace is a usable URL or name.
        static var current: Config? {
            let d = UserDefaults.standard
            guard d.bool(forKey: enabledKey),
                  let workspace = TicketLinks.workspace(from: d.string(forKey: workspaceKey) ?? "") else { return nil }
            return Config(workspace: workspace, teamKeys: TicketLinks.teamKeys(from: d.string(forKey: teamKeysKey) ?? ""))
        }
    }

    /// "https://linear.app/acme/team/ENG/active", "linear.app/acme" or "acme" → "acme". Pure, for tests.
    static func workspace(from input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["https://", "http://"] where s.lowercased().hasPrefix(scheme) { s = String(s.dropFirst(scheme.count)) }
        if s.lowercased().hasPrefix("linear.app/") { s = String(s.dropFirst("linear.app/".count)) }
        let name = s.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." })
        else { return nil }
        return String(name)
    }

    /// "eng, KM sec" → ["ENG", "KM", "SEC"]; anything that is not a plain key is dropped. Pure, for tests.
    static func teamKeys(from input: String) -> [String] {
        input.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map { $0.uppercased() }
            .filter { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }
    }

    private static let anyKey = "[A-Z][A-Z0-9]{1,9}"

    /// Distinct tickets in `texts` (title first, then description), in order of appearance, ids
    /// upper-cased. Pure, for tests.
    static func find(in texts: [String], config: Config) -> [Ticket] {
        let keys = config.teamKeys.map(NSRegularExpression.escapedPattern(for:))
        let listed = !keys.isEmpty
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9])(?:\(listed ? keys.joined(separator: "|") : anyKey))-\\d+(?![A-Za-z0-9])",
            options: listed ? [.caseInsensitive] : []) else { return [] }
        var seen = Set<String>()
        return texts.flatMap { text -> [Ticket] in
            let ns = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
                let id = ns.substring(with: $0.range).uppercased()
                return seen.insert(id).inserted
                    ? Ticket(id: id, url: "https://linear.app/\(config.workspace)/issue/\(id)") : nil
            }
        }
    }

    /// The tickets of `pr`, or none while the feature is off.
    static func tickets(for pr: PR) -> [Ticket] {
        guard let config = Config.current else { return [] }
        return find(in: [pr.title, pr.body ?? ""], config: config)
    }
}

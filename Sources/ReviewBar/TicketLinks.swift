import Foundation

/// Linear ticket ids (EXA-, KM-, SEC-) mentioned in a PR, linked to the Teachiq workspace.
enum TicketLinks {
    static let workspace = "teachiq"
    static let prefixes = ["EXA", "KM", "SEC"]

    struct Ticket: Equatable {
        let id: String
        var url: String { "https://linear.app/\(TicketLinks.workspace)/issue/\(id)" }
    }

    private static let pattern = try! NSRegularExpression(
        pattern: "(?<![A-Za-z0-9])(?:\(prefixes.joined(separator: "|")))-\\d+(?![A-Za-z0-9])",
        options: [.caseInsensitive])

    /// Distinct tickets in `texts` (title first, then description), in order of appearance,
    /// ids upper-cased. Pure, for tests.
    static func find(in texts: String...) -> [Ticket] {
        var seen = Set<String>()
        return texts.flatMap { find($0, seen: &seen) }
    }

    private static func find(_ text: String, seen: inout Set<String>) -> [Ticket] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            let id = ns.substring(with: $0.range).uppercased()
            return seen.insert(id).inserted ? Ticket(id: id) : nil
        }
    }
}

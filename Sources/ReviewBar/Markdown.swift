import SwiftUI
import AppKit

/// The block-level markdown Claude writes in reviews: headings, lists, fenced code, quotes and
/// paragraphs. Inline formatting (bold, `code`, links) is left to AttributedString.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case bullet(indent: Int, text: String)
    case numbered(indent: Int, number: String, text: String)
    case code(language: String, text: String)
    case quote(String)
    case paragraph(String)
    case rule

    /// Splits markdown into blocks. Pure, for tests.
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        var language = ""

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if var lines = code {
                if line.hasPrefix("```") {
                    blocks.append(.code(language: language, text: lines.joined(separator: "\n")))
                    code = nil
                } else {
                    lines.append(raw)
                    code = lines
                }
                continue
            }
            if line.hasPrefix("```") {
                flushParagraph()
                language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                code = []
                continue
            }
            if line.isEmpty { flushParagraph(); continue }

            let indent = (raw.prefix { $0 == " " }.count) / 2
            if let h = heading(line) {
                flushParagraph(); blocks.append(h)
            } else if line == "---" || line == "***" || line == "___" {
                flushParagraph(); blocks.append(.rule)
            } else if let rest = strip(line, prefixes: ["- ", "* ", "+ "]) {
                flushParagraph(); blocks.append(.bullet(indent: indent, text: rest))
            } else if let (n, rest) = numbered(line) {
                flushParagraph(); blocks.append(.numbered(indent: indent, number: n, text: rest))
            } else if let rest = strip(line, prefixes: ["> ", ">"]) {
                flushParagraph(); blocks.append(.quote(rest))
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { blocks.append(.code(language: language, text: lines.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: String(line.dropFirst(hashes + 1)))
    }

    private static func strip(_ line: String, prefixes: [String]) -> String? {
        for p in prefixes where line.hasPrefix(p) { return String(line.dropFirst(p.count)) }
        return nil
    }

    private static func numbered(_ line: String) -> (String, String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (String(digits), String(rest.dropFirst(2)))
    }
}

/// Renders Claude's markdown notes: real headings, lists and code blocks, selectable text.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ReviewDoc.parse(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .verdict(let v, let reason): verdictBanner(v, reason)
                case .block(let block): view(for: block)
                case .finding(let sev, let title, let blocks): findingBox(sev, title, blocks)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func verdictBanner(_ v: ReviewDoc.Verdict, _ reason: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: v.symbol).foregroundStyle(v.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(v.title).font(.system(size: 14, weight: .bold))
                if !reason.isEmpty { Text(inline(reason)) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(v.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(v.color.opacity(0.6)))
    }

    private func findingBox(_ sev: ReviewDoc.Severity?, _ title: String, _ blocks: [MarkdownBlock]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let sev {
                    Text(sev.rawValue.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(sev.color.opacity(0.2), in: Capsule())
                        .foregroundStyle(sev.color)
                }
                Text(inline(title)).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                if let comment = ReviewDoc.postable(blocks) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(comment, forType: .string)
                    } label: { Label("Copy comment", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderless).font(.caption)
                    .help("Copies the suggested comment (and suggestion block) to paste on GitHub")
                }
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in view(for: b) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                .fill((sev?.color ?? .secondary)).frame(width: 3)
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let t):
            Text(inline(t))
                .font(level <= 2 ? .system(size: 15, weight: .bold) : .system(size: 13, weight: .semibold))
                .padding(.top, 4)
        case .bullet(let indent, let t):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("•").foregroundStyle(.primary.opacity(0.7))
                Text(inline(t))
            }
            .padding(.leading, CGFloat(indent) * 12)
        case .numbered(let indent, let n, let t):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(n).").foregroundStyle(.primary.opacity(0.7)).monospacedDigit()
                Text(inline(t))
            }
            .padding(.leading, CGFloat(indent) * 12)
        case .code(let lang, let t):
            if lang == "suggestion" {
                Text("Suggested change").font(.caption.bold()).foregroundStyle(.green)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(t).font(.system(size: 12, design: .monospaced)).fixedSize()
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15)))
        case .quote(let t):
            Text(inline(t))
                .foregroundStyle(.primary.opacity(0.8))
                .padding(.leading, 8)
                .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: 2) }
        case .paragraph(let t):
            Text(inline(t))
        case .rule:
            Divider()
        }
    }

    private func inline(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }
}

/// A review split into what gets drawn specially: the verdict banner and one box per finding.
enum ReviewDoc {
    enum Verdict: Equatable {
        case approve, comment, requestChanges
        var title: String {
            switch self { case .approve: "Approve"; case .comment: "Comment"; case .requestChanges: "Request changes" }
        }
    }

    enum Severity: String { case blocker, shouldFix = "should-fix", question, nit }

    enum Segment: Equatable {
        case verdict(Verdict, reason: String)
        case block(MarkdownBlock)
        case finding(severity: Severity?, title: String, blocks: [MarkdownBlock])
    }

    /// The text to paste on GitHub for a finding: its quoted comment(s) plus any suggestion block.
    static func postable(_ blocks: [MarkdownBlock]) -> String? {
        var parts: [String] = []
        for b in blocks {
            switch b {
            case .quote(let t): parts.append(t)
            case .code("suggestion", let t): parts.append("```suggestion\n\(t)\n```")
            default: break
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Pure, for tests. Findings are `###` headings; a finding runs until the next heading or rule.
    /// The verdict comes from a "VERDICT: …" line, or the first line under an old "## Lean" heading.
    static func parse(_ markdown: String) -> [Segment] {
        var out: [Segment] = []
        var finding: (Severity?, String, [MarkdownBlock])?
        var leanNext = false, haveVerdict = false
        func close() { if let f = finding { out.append(.finding(severity: f.0, title: f.1, blocks: f.2)); finding = nil } }

        for block in MarkdownBlock.parse(markdown) {
            if !haveVerdict, let v = verdict(in: block, afterLean: leanNext) {
                close(); out.append(.verdict(v.0, reason: v.1)); haveVerdict = true; leanNext = false
                continue
            }
            switch block {
            case .heading(let level, let t) where level >= 3:
                close()
                let (sev, title) = severity(t)
                finding = (sev, title, [])
            case .heading(_, let t):
                close()
                leanNext = ["lean", "verdict"].contains(t.lowercased())
                if !leanNext || haveVerdict { out.append(.block(block)) }
            case .rule:
                close(); out.append(.block(block))
            default:
                if finding != nil { finding!.2.append(block) } else { out.append(.block(block)) }
            }
        }
        close()
        return out
    }

    private static func verdict(in block: MarkdownBlock, afterLean: Bool) -> (Verdict, String)? {
        let text: String
        switch block {
        case .paragraph(let t), .bullet(_, let t): text = t
        default: return nil
        }
        var line = text.components(separatedBy: "\n")[0].replacingOccurrences(of: "*", with: "")
        if line.uppercased().hasPrefix("VERDICT:") {
            line = String(line.dropFirst("VERDICT:".count))
        } else if !afterLean {
            return nil
        }
        line = line.trimmingCharacters(in: .whitespaces)
        let lower = line.lowercased()
        let v: Verdict
        if lower.hasPrefix("request") { v = .requestChanges }
        else if lower.hasPrefix("approve") { v = .approve }
        else if lower.hasPrefix("comment") { v = .comment }
        else { return nil }
        var reason = line.drop { $0 != "—" && $0 != "-" && $0 != ":" && $0 != "," }.dropFirst()
            .trimmingCharacters(in: .whitespaces)
        if text.contains("\n") { reason += " " + text.components(separatedBy: "\n").dropFirst().joined(separator: " ") }
        return (v, reason)
    }

    /// "[blocker] `a.swift:3` Title" → (.blocker, "`a.swift:3` Title").
    private static func severity(_ t: String) -> (Severity?, String) {
        let s = t.trimmingCharacters(in: .whitespaces)
        for sev in [Severity.blocker, .shouldFix, .question, .nit] {
            for form in ["[\(sev.rawValue)]", "\(sev.rawValue):", "**\(sev.rawValue)**"]
            where s.lowercased().hasPrefix(form) {
                return (sev, s.dropFirst(form.count).trimmingCharacters(in: .whitespaces))
            }
        }
        return (nil, s)
    }
}

extension ReviewDoc.Verdict {
    var color: Color {
        switch self { case .approve: .green; case .comment: .yellow; case .requestChanges: .red }
    }
    var symbol: String {
        switch self {
        case .approve: "checkmark.circle.fill"; case .comment: "text.bubble.fill"
        case .requestChanges: "xmark.octagon.fill"
        }
    }
}

extension ReviewDoc.Severity {
    var color: Color {
        switch self { case .blocker: .red; case .shouldFix: .orange; case .question: .blue; case .nit: .gray }
    }
}

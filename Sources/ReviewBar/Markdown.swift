import SwiftUI

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
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        case .code(_, let t):
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

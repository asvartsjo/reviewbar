import AppKit

/// A review as a standalone web page: readable width, high contrast, light and dark, no network.
enum ReviewPage {
    /// Writes the page to a temporary file and opens it in the default browser.
    static func open(pr: PR, text: String, label: String?, date: Date?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(pr.repository.nameWithOwner.replacingOccurrences(of: "/", with: "-"))-\(pr.number).html"
        let file = dir.appendingPathComponent(name)
        do {
            try html(pr: pr, text: text, label: label, date: date).write(to: file, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(file)
        } catch {
            NSSound.beep()
        }
    }

    /// The full page. Pure, for tests.
    static func html(pr: PR, text: String, label: String?, date: Date?) -> String {
        var meta = ["\(esc(pr.repository.nameWithOwner)) #\(pr.number)", "by \(esc(pr.author.login))"]
        if let label { meta.append(esc(label)) }
        if let date {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            meta.append(esc(f.string(from: date)))
        }
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(pr.title)) · Review</title>
        <style>\(css)</style></head>
        <body><main>
        <header>
          <div class="meta">\(meta.joined(separator: " · "))</div>
          <h1>\(esc(pr.title))</h1>
          <nav><a class="primary" href="reviewbar://update?pr=\(query(pr.url))"
                  title="Fetch the PR again and review new commits since this review">Update review</a><a
                  href="reviewbar://rerun?pr=\(query(pr.url))" title="Full review of the current diff">Full re-review</a><a
                  href="\(esc(pr.url))">Open PR</a><a href="\(esc(pr.url))/files">Files changed</a></nav>
          <p class="hint">Update runs in ReviewBar and opens the new version here when it's done.</p>
        </header>
        <article>
        \(body(text))
        </article>
        <footer>Private notes from ReviewBar. Nothing was posted to GitHub.</footer>
        </main>
        <script>
        document.querySelectorAll("button.copy").forEach(b => b.addEventListener("click", async () => {
          try { await navigator.clipboard.writeText(b.dataset.comment); b.textContent = "Copied"; }
          catch { b.textContent = "Copy failed"; }
          setTimeout(() => b.textContent = "Copy comment", 1500);
        }));
        </script>
        </body></html>
        """
    }

    /// Review markdown to HTML: verdict banner, one card per finding, plain blocks otherwise.
    static func body(_ markdown: String) -> String {
        ReviewDoc.parse(markdown).map { segment in
            switch segment {
            case .verdict(let v, let reason):
                let cls = v == .approve ? "approve" : v == .comment ? "comment" : "changes"
                let icon = v == .approve ? "✓" : v == .comment ? "●" : "✕"
                return "<div class=\"verdict \(cls)\"><span class=\"icon\">\(icon)</span><div><strong>\(v.title)</strong>"
                    + (reason.isEmpty ? "" : "<div>\(inline(reason))</div>") + "</div></div>"
            case .block(let b):
                return blocks([b])
            case .finding(let sev, let title, let bs):
                let tag = sev.map { "<span class=\"sev \($0.rawValue)\">\($0.rawValue)</span>" } ?? ""
                let copy = ReviewDoc.postable(bs).map {
                    "<button class=\"copy\" data-comment=\"\(esc($0))\">Copy comment</button>"
                } ?? ""
                return "<section class=\"finding \(sev?.rawValue ?? "")\"><h3>\(tag)\(inline(title))\(copy)</h3>\n"
                    + blocks(bs) + "</section>"
            }
        }.joined(separator: "\n")
    }

    /// Markdown blocks to HTML, grouping consecutive list items into lists.
    static func blocks(_ input: [MarkdownBlock]) -> String {
        var out: [String] = []
        var openList: String?
        func close() { if let l = openList { out.append("</\(l)>"); openList = nil } }
        func list(_ tag: String) { if openList != tag { close(); out.append("<\(tag)>"); openList = tag } }

        for block in input {
            switch block {
            case .bullet(let indent, let t):
                list("ul"); out.append("<li style=\"margin-left:\(indent * 20)px\">\(inline(t))</li>")
            case .numbered(let indent, let n, let t):
                list("ol"); out.append("<li value=\"\(n)\" style=\"margin-left:\(indent * 20)px\">\(inline(t))</li>")
            default:
                close()
                switch block {
                case .heading(let level, let t):
                    let l = min(level + 1, 6)
                    out.append("<h\(l)>\(inline(t))</h\(l)>")
                case .code(let lang, let t):
                    if lang == "suggestion" {
                        out.append("<div class=\"suggestion\"><div class=\"label\">Suggested change</div>"
                                   + "<pre><code>\(esc(t))</code></pre></div>")
                    } else {
                        out.append("<pre><code>\(esc(t))</code></pre>")
                    }
                case .quote(let t): out.append("<blockquote>\(inline(t))</blockquote>")
                case .paragraph(let t): out.append("<p>\(inline(t).replacingOccurrences(of: "\n", with: "<br>"))</p>")
                case .rule: out.append("<hr>")
                default: break
                }
            }
        }
        close()
        return out.joined(separator: "\n")
    }

    /// Inline `code`, **bold**, *italic* and [links](https://…), after escaping.
    static func inline(_ s: String) -> String {
        var parts: [String] = []
        // Split on backticks so code spans are left untouched by the other rules.
        for (i, chunk) in s.components(separatedBy: "`").enumerated() {
            if i % 2 == 1 { parts.append("<code>\(esc(chunk))</code>"); continue }
            var t = esc(chunk)
            t = t.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
            t = t.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, with: "<em>$1</em>",
                                       options: .regularExpression)
            t = t.replacingOccurrences(of: #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#, with: "<a href=\"$2\">$1</a>",
                                       options: .regularExpression)
            parts.append(t)
        }
        return parts.joined()
    }

    /// "Review · Opus", "Changes since abc1234 · Opus", or the rebased fallback.
    static func label(_ s: SavedReview) -> String {
        var parts: [String] = []
        if let since = s.sinceCommit {
            parts.append(s.sinceFellBack == true ? "Since \(since), full diff (branch rebased)" : "Changes since \(since)")
        } else {
            parts.append("Review")
        }
        if let by = s.producedBy { parts.append(by) }
        return parts.joined(separator: " · ")
    }

    private static func query(_ s: String) -> String {
        esc(s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s)
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let css = """
    :root { --bg:#ffffff; --fg:#111418; --muted:#3d4450; --line:#d4d8de; --soft:#f2f4f7;
            --accent:#0b57d0; --code:#eef1f5;
            --green:#1a7f37; --yellow:#b58100; --red:#cf222e; --orange:#c2410c; }
    @media (prefers-color-scheme: dark) {
      :root { --bg:#0f1115; --fg:#f2f4f7; --muted:#c3c9d2; --line:#343a44; --soft:#181b21;
              --accent:#8ab4ff; --code:#1c2029;
              --green:#2ea043; --yellow:#d29922; --red:#f85149; --orange:#f0883e; } }
    * { box-sizing:border-box; }
    body { margin:0; background:var(--bg); color:var(--fg);
           font:17px/1.65 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
    main { max-width:780px; margin:0 auto; padding:48px 24px 64px; }
    header { border-bottom:1px solid var(--line); padding-bottom:20px; margin-bottom:28px; }
    .meta { color:var(--muted); font-size:14px; }
    h1 { font-size:30px; line-height:1.25; margin:8px 0 14px; letter-spacing:-0.01em; }
    nav a { display:inline-block; margin-right:10px; padding:6px 14px; border:1px solid var(--line);
            border-radius:8px; color:var(--fg); text-decoration:none; font-size:14px; font-weight:500; }
    nav a:hover { background:var(--soft); }
    nav a.primary { background:var(--accent); border-color:var(--accent); color:var(--bg); }
    .hint { color:var(--muted); font-size:13px; margin:10px 0 0; }
    h2 { font-size:22px; margin:36px 0 10px; padding-bottom:6px; border-bottom:1px solid var(--line); }
    h3 { font-size:18px; margin:28px 0 8px; }
    h4, h5, h6 { font-size:16px; margin:22px 0 6px; }
    p { margin:0 0 14px; }
    ul, ol { margin:0 0 14px; padding-left:26px; }
    li { margin:5px 0; }
    a { color:var(--accent); }
    strong { font-weight:650; }
    code { font:0.88em ui-monospace, "SF Mono", Menlo, monospace; background:var(--code);
           padding:2px 5px; border-radius:4px; }
    pre { background:var(--code); border:1px solid var(--line); border-radius:8px; padding:14px 16px;
          overflow-x:auto; line-height:1.5; }
    pre code { background:none; padding:0; font-size:14px; }
    blockquote { margin:0 0 14px; padding:4px 16px; border-left:3px solid var(--accent); color:var(--muted); }
    hr { border:0; border-top:1px solid var(--line); margin:28px 0; }
    .verdict { display:flex; gap:14px; align-items:flex-start; padding:16px 18px; border-radius:12px;
               border:1.5px solid var(--vc); background:color-mix(in srgb, var(--vc) 13%, var(--bg)); margin:0 0 24px; }
    .verdict strong { font-size:20px; display:block; margin-bottom:2px; }
    .verdict .icon { flex:none; width:32px; height:32px; border-radius:50%; background:var(--vc); color:#fff;
                     display:grid; place-items:center; font-weight:700; font-size:17px; }
    .verdict.approve { --vc:var(--green); } .verdict.comment { --vc:var(--yellow); } .verdict.changes { --vc:var(--red); }
    .finding { border:1px solid var(--line); border-left:4px solid var(--sc, var(--line)); border-radius:10px;
               padding:14px 18px 4px; margin:0 0 14px; background:var(--soft); }
    .finding h3 { margin:0 0 10px; font-size:16px; display:flex; gap:8px; align-items:baseline; flex-wrap:wrap; }
    .finding.blocker { --sc:var(--red); } .finding.should-fix { --sc:var(--orange); } .finding.nit { --sc:var(--muted); }
    .finding.question { --sc:var(--accent); }
    .suggestion .label { font-size:12px; font-weight:700; color:var(--green); margin:0 0 4px; }
    .suggestion pre { border-color:var(--green); }
    .finding pre { background:var(--bg); }
    .finding blockquote { border-left-color:var(--sc, var(--accent)); color:var(--fg); font-style:italic; }
    .copy { margin-left:auto; font:500 12px -apple-system, system-ui, sans-serif; padding:4px 10px; border-radius:6px;
            border:1px solid var(--line); background:var(--bg); color:var(--fg); cursor:pointer; }
    .copy:hover { background:var(--code); }
    .sev { font-size:11px; font-weight:700; text-transform:uppercase; letter-spacing:0.04em; padding:2px 8px;
           border-radius:99px; color:#fff; background:var(--sc); flex:none; }
    .finding.nit .sev { color:var(--bg); }
    footer { margin-top:48px; padding-top:16px; border-top:1px solid var(--line); color:var(--muted); font-size:13px; }
    """
}

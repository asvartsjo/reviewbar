import Foundation

/// The repos to watch, stored in UserDefaults "repos" as one `owner/repo` per line.
/// Owners can be mixed freely (orgs and users).
enum RepoList {
    static let key = "repos"
    /// Pre-list settings: one owner, applied to bare repo names or meaning "the whole org".
    static let legacyOwnerKey = "owner"

    /// Local checkout folder per repo (`owner/repo` → path), where Terminal sessions start.
    static let foldersKey = "repoFolders"

    /// The folder chosen in Settings, else a clone found in the usual places.
    static func folder(for repo: String) -> String? {
        chosenFolder(for: repo) ?? detectFolder(for: repo)
    }

    static func chosenFolder(for repo: String) -> String? {
        let all = UserDefaults.standard.dictionary(forKey: foldersKey) as? [String: String] ?? [:]
        guard let path = all[repo.lowercased()] else { return nil }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue ? path : nil
    }

    static let searchRoots = ["Projects", "Developer", "Code", "code", "src", "dev", "repos", "GitHub", "git", "Sites", "work"]

    /// A clone of `repo` one level below a usual projects folder, found by reading `.git/config`
    /// (no git process). A folder named like the repo wins over e.g. `gauss2`.
    static func detectFolder(for repo: String) -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let name = repo.split(separator: "/").last.map { String($0).lowercased() } ?? ""
        var found: [String] = []
        for root in searchRoots {
            let dir = home.appendingPathComponent(root)
            guard let kids = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for kid in kids {
                let path = dir.appendingPathComponent(kid).path
                guard let config = try? String(contentsOfFile: path + "/.git/config", encoding: .utf8),
                      configMatches(config, repo: repo) else { continue }
                found.append(path)
            }
        }
        return found.first { ($0 as NSString).lastPathComponent.lowercased() == name } ?? found.sorted().first
    }

    /// True if a `url = …` line in a git config points at `repo`. Pure, for tests.
    static func configMatches(_ config: String, repo: String) -> Bool {
        config.split(whereSeparator: \.isNewline).contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("url") , let eq = t.firstIndex(of: "=") else { return false }
            return normalize(String(t[t.index(after: eq)...]))?.lowercased() == repo.lowercased()
        }
    }

    static func setFolder(_ path: String?, for repo: String) {
        var all = UserDefaults.standard.dictionary(forKey: foldersKey) as? [String: String] ?? [:]
        all[repo.lowercased()] = path
        UserDefaults.standard.set(all, forKey: foldersKey)
    }

    /// True if a git remote in `folder` points at `repo`. Pure over `git remote -v` output, for tests.
    static func remotesMatch(_ remotes: String, repo: String) -> Bool {
        remotes.split(whereSeparator: \.isNewline).contains { line in
            line.split(whereSeparator: \.isWhitespace).dropFirst().first
                .flatMap { normalize(String($0)) }?.lowercased() == repo.lowercased()
        }
    }

    static func load() -> [String] {
        (UserDefaults.standard.string(forKey: key) ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func save(_ repos: [String]) {
        UserDefaults.standard.set(repos.joined(separator: "\n"), forKey: key)
    }

    /// `owner/repo` from `owner/repo`, `github.com/owner/repo`, a full URL (any path after
    /// the repo is ignored) or `git@github.com:owner/repo.git`. Nil if it isn't one.
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "git@github.com:", "www.", "github.com/"]
        where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        let parts = s.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        var name = parts[1]
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        let owner = parts[0]
        let ownerOK = owner.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$"#, options: .regularExpression) != nil
        let nameOK = name.range(of: #"^[A-Za-z0-9._-]{1,100}$"#, options: .regularExpression) != nil
        return ownerOK && nameOK ? "\(owner)/\(name)" : nil
    }

    /// Turns old owner + bare-name settings into full `owner/repo` entries. The old owner
    /// is only kept when the list is empty, where it still means "the whole org".
    static func migrateLegacySettings() {
        let d = UserDefaults.standard
        let owner = (d.string(forKey: legacyOwnerKey) ?? "").trimmingCharacters(in: .whitespaces)
        guard !owner.isEmpty else { return }
        let repos = load()
        guard !repos.isEmpty else { return }
        save(repos.map { $0.contains("/") ? $0 : "\(owner)/\($0)" })
        d.removeObject(forKey: legacyOwnerKey)
    }
}

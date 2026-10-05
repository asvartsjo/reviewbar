import Foundation
import AppKit

/// One Claude Code session on this machine, from `claude agents --json`.
struct CrewSession: Equatable, Identifiable {
    let id: String
    let name: String
    let cwd: String
    /// Started from agent view (`claude --bg`), not in a terminal window.
    let background: Bool
    /// Waiting on me: a terminal session's `waiting` (a question), or a background one's `blocked`.
    let needsMe: Bool
    /// Busy: a terminal session's `busy`, or a background one's `working`.
    let working: Bool
    let startedAt: Date
    /// The process, for stopping a terminal session (which has no agent view `id`).
    var pid: Int? = nil
    /// The app a terminal session runs in, from its parent processes; nil for agent view ones.
    var host: Crew.Host? = nil

    /// Neither waiting on me nor working: at its prompt, or a status this version doesn't know.
    var idle: Bool { !needsMe && !working }
}

/// A session in one of my watched repos, with the PR it works on when its folder says so.
struct CrewItem: Equatable, Identifiable {
    let session: CrewSession
    let repo: String
    let prNumber: Int?
    var id: String { session.id }
}

/// The crew: Claude sessions in my repos, the ones waiting on me first. Agent view is a research
/// preview, so everything here reads its output defensively and shows nothing rather than guess.
enum Crew {
    static let pollInterval: TimeInterval = 15

    /// `claude agents --json` → every session with a folder, idle ones too (Crew shows only the
    /// active ones; the second-session check needs them all). Only background sessions have an `id`
    /// (what `claude attach` takes); terminal ones have `sessionId` and `pid`. Fields or values it
    /// doesn't know are ignored, and an unknown status counts as idle. Pure, for tests.
    static func parseSessions(_ data: Data) -> [CrewSession] {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            let pid = row["pid"] as? Int
            guard let id = row["id"] as? String ?? row["sessionId"] as? String ?? pid.map(String.init),
                  let cwd = row["cwd"] as? String else { return nil }
            let background = row["kind"] as? String == "background"
            let status = row["status"] as? String, state = row["state"] as? String
            let needsMe = background ? state == "blocked" : status == "waiting"
            let working = background ? state == "working" : status == "busy"
            let started = (row["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
            return CrewSession(id: id, name: row["name"] as? String ?? id, cwd: cwd, background: background,
                               needsMe: needsMe, working: working, startedAt: started, pid: row["pid"] as? Int)
        }
    }

    /// One checkout of a watched repo: the clone or a worktree, and the PR it holds if known.
    struct Checkout: Equatable {
        let repo: String
        let path: String
        let prNumber: Int?
    }

    /// A repo's checkouts from `git worktree list`: one on a branch belongs to my PR on that branch,
    /// ReviewBar's detached `pr-<N>` worktree to PR N, any other (the clone, `.claude/worktrees/…`)
    /// to the repo only. Pure, for tests.
    static func checkouts(repo: String, repoFolder: String, listed: [TerminalApp.Worktree.Listed],
                          myPRs: [FeedbackPR]) -> [Checkout] {
        func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let ours = TerminalApp.Worktree.ours(listed, repo: repo, repoFolder: repoFolder)
        return listed.map { w in
            let branch = w.branch.map { $0.replacingOccurrences(of: "refs/heads/", with: "") }
            let mine = branch.flatMap { b in
                myPRs.first { $0.branch == b && $0.pr.repository.nameWithOwner.lowercased() == repo.lowercased() }
            }
            let review = ours.first { real($0.path) == real(w.path) }
            return Checkout(repo: repo, path: w.path, prNumber: mine?.pr.number ?? review?.number)
        }
    }

    /// Each session in one of the checkouts (the deepest one containing its folder), waiting on me
    /// first, then the newest. Sessions outside every watched repo are left out. Pure, for tests.
    static func link(_ sessions: [CrewSession], to checkouts: [Checkout]) -> [CrewItem] {
        sessions.compactMap { s in
            let home = checkouts
                .filter { s.cwd == $0.path || s.cwd.hasPrefix($0.path + "/") }
                .max { $0.path.count < $1.path.count }
            return home.map { CrewItem(session: s, repo: $0.repo, prNumber: $0.prNumber) }
        }
        .sorted { ($0.session.needsMe ? 0 : 1, -$0.session.startedAt.timeIntervalSince1970)
            < ($1.session.needsMe ? 0 : 1, -$1.session.startedAt.timeIntervalSince1970) }
    }
}

extension Crew {
    /// Where a terminal session lives: what Show session can bring to the front, and what its row says.
    enum Host: Equatable {
        case iterm, terminal, vscode, other

        var name: String {
            switch self {
            case .iterm: "iTerm2"
            case .terminal: "Terminal"
            case .vscode: "VS Code"
            case .other: "terminal"
            }
        }
    }

    /// `ps -axo pid=,ppid=,comm=` → pid → (parent, executable path). Paths may contain spaces.
    /// Pure, for tests.
    static func parseProcessTable(_ ps: String) -> [Int: (ppid: Int, comm: String)] {
        var table: [Int: (ppid: Int, comm: String)] = [:]
        for line in ps.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int(parts[0]), let ppid = Int(parts[1]) else { continue }
            table[pid] = (ppid, String(parts[2]))
        }
        return table
    }

    /// The first known app among `pid`'s parents (at most 20 up, so a loop can't hang it). Pure, for tests.
    static func host(of pid: Int, in table: [Int: (ppid: Int, comm: String)]) -> Host {
        var current = table[pid]?.ppid
        for _ in 0..<20 {
            guard let p = current, p > 1, let entry = table[p] else { break }
            if entry.comm.contains("/iTerm.app/") { return .iterm }
            if entry.comm.contains("/Terminal.app/") { return .terminal }
            if entry.comm.contains("/Visual Studio Code.app/") { return .vscode }
            current = entry.ppid
        }
        return .other
    }

    /// Sessions waiting on me now that weren't at the last poll (`before`: the ids that were). The
    /// first poll only sets the baseline (`before` nil), so launching never notifies. Pure, for tests.
    static func newlyWaiting(_ now: [CrewItem], before: Set<String>?) -> [CrewItem] {
        guard let before else { return [] }
        return now.filter { $0.session.needsMe && !before.contains($0.id) }
    }

    /// A launch less than this long ago counts as an open session: it may not be listed yet.
    static let launchGrace: TimeInterval = 60

    /// The first crew session on this PR, in any state. Pure, for tests.
    static func session(onPR number: Int, repo: String, crew: [CrewItem]) -> CrewItem? {
        crew.first { $0.prNumber == number && $0.repo.lowercased() == repo.lowercased() }
    }

    /// Why opening another session on this PR needs a second thought, or nil when nothing is open:
    /// a session on it (any state), or a launch from ReviewBar in the last `launchGrace`. Pure, for tests.
    static func openSession(onPR number: Int, repo: String, crew: [CrewItem], launchedAt: Date?,
                            now: Date = Date()) -> String? {
        if let s = session(onPR: number, repo: repo, crew: crew)?.session {
            let state = s.needsMe ? "waiting on you" : s.working ? "working" : "idle at its prompt"
            let home = (s.cwd as NSString).abbreviatingWithTildeInPath
            return "\(s.background ? "An agent view" : "A terminal") session (\(s.name)) is \(state) in \(home)."
        }
        if let launchedAt, now.timeIntervalSince(launchedAt) < launchGrace {
            return "You opened one less than a minute ago; it may still be starting."
        }
        return nil
    }

    /// "since 09:42" today, "since 2 Oct" before that. It's the process start, which resets when
    /// agent view restarts a session (after a reboot or sleep), so it never claims more than that.
    /// Pure, for tests.
    static func since(_ started: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = calendar.isDate(started, inSameDayAs: now) ? "HH:mm" : "d MMM"
        return "since \(f.string(from: started))"
    }
}

extension Backend {
    /// Where `claude` lives, looked up once through the login shell. The crew poll then runs it
    /// directly: a login shell costs about 0.6 s, too much every 15 s.
    private actor ClaudePath {
        private var path: String??
        func get() async -> String? {
            if let path { return path }
            let found = (try? await sh("command -v claude"))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let p = found.flatMap { $0.hasPrefix("/") ? $0 : nil }
            path = .some(p)
            return p
        }
    }
    private static let claudePath = ClaudePath()

    /// The crew in `repos`, or nil when `claude agents` can't be run or read. Local and read only.
    static func crew(repos: [String], myPRs: [FeedbackPR]) async -> [CrewItem]? {
        guard let claude = await claudePath.get(),
              let json = await run(claude, ["agents", "--json"]) else { return nil }
        let sessions = Crew.parseSessions(Data(json.utf8))
        guard !sessions.isEmpty else { return [] }
        var checkouts: [Crew.Checkout] = []
        for repo in repos {
            guard let folder = RepoList.folder(for: repo),
                  let list = await run("/usr/bin/git", ["-C", folder, "worktree", "list", "--porcelain"]) else { continue }
            let listed = TerminalApp.Worktree.parseList(list).map {
                TerminalApp.Worktree.Listed(path: URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path,
                                            detached: $0.detached, branch: $0.branch)
            }
            checkouts += Crew.checkouts(repo: repo, repoFolder: folder, listed: listed, myPRs: myPRs)
        }
        let table = Crew.parseProcessTable(await run("/bin/ps", ["-axo", "pid=,ppid=,comm="]) ?? "")
        let real = sessions.map {
            CrewSession(id: $0.id, name: $0.name, cwd: URL(fileURLWithPath: $0.cwd).resolvingSymlinksInPath().path,
                        background: $0.background, needsMe: $0.needsMe, working: $0.working, startedAt: $0.startedAt,
                        pid: $0.pid, host: $0.background ? nil : $0.pid.map { Crew.host(of: $0, in: table) })
        }
        return Crew.link(real, to: checkouts)
    }

    /// Opens a background session in the chosen terminal with `claude attach`. Returns the command
    /// instead when the terminal is "Copy command".
    static func attach(_ session: CrewSession) async throws -> String? {
        let command = "claude attach \(session.id)"
        let path = (try? await sh("print -r -- $PATH").trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        let launcher = FileManager.default.temporaryDirectory.appendingPathComponent("attach-\(session.id).sh")
        try """
            #!/bin/zsh
            \(path.isEmpty ? "" : "export PATH=\(q(path))")
            rm -f "$0"
            claude attach \(q(session.id))
            exec "${SHELL:-/bin/zsh}" -l

            """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let app = TerminalApp.chosen
        switch app.launch(launcher: launcher.path, app: app.appURL?.path ?? "") {
        case .copy:
            try? FileManager.default.removeItem(at: launcher)
            return command
        case .process(let exe, let args):
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            try p.run()
            return nil
        }
    }

    /// Stops a session; its conversation is kept either way. A background one with `claude stop`
    /// (`claude attach` resumes it); a terminal one by ending its `claude` process (`claude --resume`
    /// reopens it), which also covers one whose window is gone but whose process lives on. The pid is
    /// checked to still be `claude` first, so a reused pid is never signalled. False when it couldn't.
    static func stop(_ session: CrewSession) async -> Bool {
        if session.background {
            guard let claude = await claudePath.get() else { return false }
            return await run(claude, ["stop", session.id]) != nil
        }
        guard let pid = session.pid,
              let name = await run("/bin/ps", ["-o", "comm=", "-p", String(pid)]),
              (name.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent == "claude"
        else { return false }
        return kill(pid_t(pid), SIGTERM) == 0
    }

    /// Brings a terminal session's window to the front: in iTerm2 or Terminal its tab, found by its
    /// tty (from `ps`); in VS Code the window of its folder (the Claude panel inside can't be picked).
    /// False when it isn't found.
    static func reveal(_ session: CrewSession) async -> Bool {
        if session.host == .vscode {
            return await run("/usr/bin/open", ["-b", "com.microsoft.VSCode", session.cwd]) != nil
        }
        guard let pid = session.pid,
              let tty = await run("/bin/ps", ["-o", "tty=", "-p", String(pid)])?
                  .trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        for app in [TerminalApp.iterm, .terminal] {
            guard let id = app.bundleID, !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty,
                  let script = app.revealScript(tty: tty) else { continue }
            if await run("/usr/bin/osascript", ["-e", script])?.contains("found") == true { return true }
        }
        return false
    }

    /// Runs an executable directly (no shell) and returns its output, or nil if it fails.
    private static func run(_ exe: String, _ args: [String]) async -> String? {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return c.resume(returning: nil) }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                c.resume(returning: p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
            }
        }
    }
}

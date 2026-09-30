import Foundation

/// Single-quote a string for zsh.
func q(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

struct ShellError: LocalizedError {
    let code: Int32
    let stderr: String
    var errorDescription: String? {
        "Exit \(code): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

/// Printed right before the command so anything the shell's startup files print can be dropped.
private let outputMarker = "__REVIEWBAR_OUTPUT_START__"

/// Lets a Swift task cancellation stop the running command.
private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Returns false if cancel() already happened, so the caller doesn't start at all.
    func attach(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        process = p
        return !cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        guard let p, p.isRunning else { return }
        // The interactive zsh ignores SIGTERM, so stop its children (gh, claude) first.
        Self.pkill("TERM", parent: p.processIdentifier)
        p.terminate()
        // While zsh is still reading its startup files it has no children yet and ignores
        // SIGTERM itself, so it would go on to run the command. Kill it if it's still there.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { self.killIfStillRunning() }
    }

    private func killIfStillRunning() {
        lock.lock()
        let p = process
        lock.unlock()
        guard let p, p.isRunning else { return }
        Self.pkill("KILL", parent: p.processIdentifier)
        kill(p.processIdentifier, SIGKILL)
    }

    private static func pkill(_ signal: String, parent: pid_t) {
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = ["-\(signal)", "-P", String(parent)]
        try? k.run()
        k.waitUntilExit()
    }
}

/// Runs a command in an interactive login zsh so PATH (gh, claude) matches your Terminal.
/// Only the command's own output is returned, not what `.zshrc` and friends print.
/// Cancelling the calling task stops the command and throws CancellationError.
func sh(_ command: String, input: String? = nil) async throws -> String {
    let running = RunningProcess()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lic", "print -r -- \(outputMarker); " + command]
                let outP = Pipe(), errP = Pipe(), inP = Pipe()
                p.standardOutput = outP
                p.standardError = errP
                p.standardInput = inP

                guard running.attach(p) else { cont.resume(throwing: CancellationError()); return }
                do { try p.run() } catch { cont.resume(throwing: error); return }

                // Written on another queue; group.wait() below orders that write before the read.
                nonisolated(unsafe) var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = errP.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                DispatchQueue.global().async {
                    if let input { try? inP.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
                    try? inP.fileHandleForWriting.close()
                }

                let outData = outP.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                group.wait()

                var out = String(decoding: outData, as: UTF8.self)
                if let r = out.range(of: outputMarker + "\n") { out = String(out[r.upperBound...]) }
                if running.isCancelled {
                    cont.resume(throwing: CancellationError())
                } else if p.terminationStatus == 0 {
                    cont.resume(returning: out)
                } else {
                    // Some tools (claude among them) report errors on stdout; keep both.
                    let err = String(decoding: errData, as: UTF8.self)
                    let detail = err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? String(out.suffix(2000)) : err
                    cont.resume(throwing: ShellError(code: p.terminationStatus, stderr: detail))
                }
            }
        }
    } onCancel: {
        running.cancel()
    }
}

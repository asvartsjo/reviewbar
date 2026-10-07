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
/// `+m` turns off job control: an interactive zsh started from a terminal (`swift test`,
/// `swift run`) otherwise takes its own process group and stops itself on the terminal.
func sh(_ command: String, input: String? = nil) async throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["+m", "-lic", "print -r -- \(outputMarker); " + command]
    let outP = Pipe(), errP = Pipe(), inP = Pipe()
    // A cancelled command can exit before reading its input: fail the write, don't SIGPIPE the app.
    _ = fcntl(inP.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    p.standardOutput = outP
    p.standardError = errP
    p.standardInput = inP
    let (exit, exited) = AsyncStream.makeStream(of: Int32.self)
    p.terminationHandler = { exited.yield($0.terminationStatus); exited.finish() }

    let running = RunningProcess()
    return try await withTaskCancellationHandler {
        guard running.attach(p) else { throw CancellationError() }
        try p.run()
        // A cancel between attach and run found nothing running to stop.
        if running.isCancelled { running.cancel() }

        async let outData = blocking { outP.fileHandleForReading.readDataToEndOfFile() }
        async let errData = blocking { errP.fileHandleForReading.readDataToEndOfFile() }
        async let wroteInput: Void = blocking {
            if let input { try? inP.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
            try? inP.fileHandleForWriting.close()
        }
        var status: Int32 = -1
        for await s in exit { status = s }
        let (outBytes, errBytes, _) = await (outData, errData, wroteInput)

        var out = String(decoding: outBytes, as: UTF8.self)
        if let r = out.range(of: outputMarker + "\n") { out = String(out[r.upperBound...]) }
        if running.isCancelled { throw CancellationError() }
        guard status == 0 else {
            // Some tools (claude, gh api) report the reason on stdout; keep both, stderr first.
            // stderr is short in practice and kept whole; stdout only by its tail, for display
            // (it can start mid-JSON, so don't parse it).
            let err = String(decoding: errBytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = String(out.suffix(2000)).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ShellError(code: status, stderr: [err, tail].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        return out
    } onCancel: {
        running.cancel()
    }
}

/// Runs a blocking pipe read or write on a GCD thread, so it never ties up one of Swift
/// concurrency's few threads for as long as a command runs.
private func blocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { c in
        DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: work()) }
    }
}

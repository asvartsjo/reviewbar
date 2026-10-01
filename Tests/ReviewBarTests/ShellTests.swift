import Foundation
import Testing
@testable import ReviewBar

/// Runs real commands through `sh` (an interactive login zsh), so these need zsh, which every Mac has.
struct ShellTests {
    private func shellError(_ command: String) async -> ShellError? {
        do { _ = try await sh(command) } catch let e as ShellError { return e } catch {}
        return nil
    }

    @Test func returnsOnlyTheCommandsOutput() async throws {
        #expect(try await sh("print -r -- hello") == "hello\n")
    }

    @Test func passesInputOnStdin() async throws {
        #expect(try await sh("cat", input: "abc") == "abc")
    }

    @Test func failureCarriesExitCodeAndStderr() async throws {
        let e = try #require(await shellError("print -u2 boom; exit 3"))
        #expect(e.code == 3)
        #expect(e.stderr.contains("boom"))
    }

    /// Some tools (claude among them) report errors on stdout.
    @Test func failureWithoutStderrKeepsStdout() async throws {
        let e = try #require(await shellError("print -r -- out; exit 1"))
        #expect(e.stderr.contains("out"))
    }

    /// More than a pipe buffer each way at once, as with a large prompt or diff.
    @Test func largeInputAndOutputDontDeadlock() async throws {
        let big = String(repeating: "a", count: 1_000_000)
        #expect(try await sh("cat", input: big).count == big.count)
    }

    @Test func largeStderrAndStdoutTogetherDontDeadlock() async throws {
        let e = try #require(await shellError(
            "head -c 500000 /dev/zero | tr '\\0' e >&2; head -c 500000 /dev/zero | tr '\\0' o; exit 1"))
        #expect(e.stderr.filter { $0 == "e" }.count == 500_000)
    }

    /// Early enough that zsh is still reading its startup files.
    @Test func cancellingStopsTheCommand() async {
        await expectCancelStops(after: .milliseconds(500))
    }

    /// Late enough that the command itself is running.
    @Test func cancellingARunningCommandStopsIt() async {
        await expectCancelStops(after: .seconds(4))
    }

    /// Nothing has read the large input when the shell is killed, as with a slow `.zshrc`.
    @Test func cancellingBeforeTheInputIsReadDoesntCrash() async {
        await expectCancelStops(after: .milliseconds(300), command: "sleep 30; cat > /dev/null",
                                input: String(repeating: "a", count: 1_000_000))
    }

    private func expectCancelStops(after delay: Duration, command: String = "print started; sleep 30",
                                   input: String? = nil) async {
        let start = ContinuousClock.now
        let task = Task { try await sh(command, input: input) }
        try? await Task.sleep(for: delay)
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(ContinuousClock.now - start < delay + .seconds(5))
    }
}

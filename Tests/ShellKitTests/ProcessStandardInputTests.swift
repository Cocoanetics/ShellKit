import Darwin
import Foundation
import Testing
@testable import ShellKit

/// ``InputSource/processStandardInput()`` — the fd 0 source behind
/// ``Shell/processDefault``.
///
/// These swap a pipe onto fd 0 for the duration of a test, so they
/// run serially and put the real stdin back afterwards.
@Suite(.serialized) struct ProcessStandardInputTests {

    /// Constructing the source must not consume fd 0.
    ///
    /// `Shell.processDefault` is built the first time anything reads
    /// the `Shell.current` TaskLocal — including a host that uses fd 0
    /// for its own protocol and never asks the Shell for stdin. An
    /// eager reader there silently swallows that host's input.
    @Test func constructingTheSourceLeavesStdinUnread() async throws {
        try await withPipeOnStandardInput { write in
            write(Data("hello\n".utf8))
            _ = InputSource.processStandardInput()
            // Generous — an eager reader parks on fd 0 immediately,
            // but give the scheduler room to prove it.
            try await Task.sleep(for: .milliseconds(500))

            // Non-blocking, so a regression fails the expectation
            // instead of parking this test on an empty pipe forever.
            _ = fcntl(0, F_SETFL, fcntl(0, F_GETFL) | O_NONBLOCK)
            var buffer = [UInt8](repeating: 0, count: 64)
            let count = read(0, &buffer, buffer.count)
            #expect(count == 6)
            #expect(String(bytes: buffer[0..<max(0, count)], encoding: .utf8) == "hello\n")
        }
    }

    /// …and it still reads fd 0 once something actually pulls from it.
    @Test func consumingTheSourceReadsStandardInput() async throws {
        try await withPipeOnStandardInput { write in
            write(Data("first\nsecond\n".utf8))
            let source = InputSource.processStandardInput()
            #expect(await source.readLine() == "first")
            #expect(await source.readLine() == "second")
        }
    }

    /// Runs `body` with a fresh pipe as fd 0, handing it a closure that
    /// feeds bytes in. Restores the process's real stdin on the way out.
    private func withPipeOnStandardInput(
        _ body: (@escaping (Data) -> Void) async throws -> Void
    ) async throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let (readEnd, writeEnd) = (fds[0], fds[1])
        let saved = dup(0)
        #expect(saved >= 0)
        #expect(dup2(readEnd, 0) >= 0)
        defer {
            _ = dup2(saved, 0)
            close(saved)
            close(readEnd)
            close(writeEnd)
        }
        try await body { data in
            data.withUnsafeBytes { _ = Darwin.write(writeEnd, $0.baseAddress, $0.count) }
        }
    }
}

import Foundation
import Testing
@testable import ShellKit

#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Glibc)
import Glibc
#endif

// Swapping a pipe onto fd 0 is POSIX-shaped; Windows has no equivalent
// handle for `FileHandle.standardInput` to keep pointing at.
#if !os(Windows)

/// ``InputSource/processStandardInput()`` — the fd 0 source behind
/// ``Shell/processDefault``.
///
/// These swap a pipe onto fd 0 for the duration of a test, so they run
/// serially and put the process's real stdin back afterwards.
@Suite(.serialized) struct ProcessStandardInputTests {

    /// Constructing the source must not consume fd 0.
    ///
    /// `Shell.processDefault` is built the first time anything reads
    /// the `Shell.current` TaskLocal — including in a host that uses
    /// fd 0 for its own protocol and never asks the Shell for stdin.
    /// An eager reader there silently swallows that host's input.
    @Test func constructingTheSourceLeavesStdinUnread() async throws {
        try await withStandardInput("hello\n") {
            _ = InputSource.processStandardInput()
            // Generous — an eager reader parks on fd 0 immediately,
            // but give the scheduler room to prove it.
            try await Task.sleep(for: .milliseconds(500))

            let unread = FileHandle(fileDescriptor: 0, closeOnDealloc: false).availableData
            #expect(String(data: unread, encoding: .utf8) == "hello\n")
        }
    }

    /// …and it still reads fd 0 once something actually pulls from it.
    @Test func consumingTheSourceReadsStandardInput() async throws {
        try await withStandardInput("first\nsecond\n") {
            let source = InputSource.processStandardInput()
            #expect(await source.readLine() == "first")
            #expect(await source.readLine() == "second")
            #expect(await source.readLine() == nil)
        }
    }

    /// Runs `body` with a pipe carrying `text` as fd 0, restoring the
    /// process's real stdin afterwards.
    ///
    /// The write end is closed up front, so fd 0 holds exactly `text`
    /// followed by EOF. A read therefore never blocks: a regression
    /// surfaces as a clean empty read rather than hanging the suite.
    private func withStandardInput(_ text: String, _ body: () async throws -> Void) async throws {
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
        }
        let feed = FileHandle(fileDescriptor: writeEnd, closeOnDealloc: false)
        feed.write(Data(text.utf8))
        close(writeEnd)
        try await body()
    }
}

#endif

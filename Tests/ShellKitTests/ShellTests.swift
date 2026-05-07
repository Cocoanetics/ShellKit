import ArgumentParser
import Foundation
import Testing
@testable import ShellKit

@Suite struct ShellTests {

    @Test func defaultShellIsProcessBound() {
        // No embedder has bound a custom Shell — `current` returns
        // the lazy process-default singleton.
        #expect(Shell.current === Shell.processDefault)
    }

    @Test func processDefaultMirrorsHostEnvironment() {
        let shell = Shell.processDefault
        // `processDefault` snapshots `ProcessInfo.processInfo.environment`
        // at first access; the values match for a stable key like PATH
        // when present, otherwise both are nil.
        let host = ProcessInfo.processInfo.environment["PATH"]
        #expect(shell.environment.variables["PATH"] == host)
    }

    @Test func withCurrentBindsAndUnbinds() async throws {
        // Outside the binding, current is the default.
        #expect(Shell.current === Shell.processDefault)

        let custom = Shell()
        try await custom.withCurrent {
            #expect(Shell.current === custom)
            #expect(Shell.current !== Shell.processDefault)
        }

        // After the binding goes out of scope, we're back to default.
        #expect(Shell.current === Shell.processDefault)
    }

    @Test func customStdoutCapturesWrites() async throws {
        let captured = OutputSink()
        let shell = Shell(stdout: captured)

        try await shell.withCurrent {
            Shell.current.stdout("hello\n")
            Shell.current.stdout("world\n")
        }

        captured.finish()
        let output = await captured.readAllString()
        #expect(output == "hello\nworld\n")
    }

    @Test func customStdinFeedsCommands() async throws {
        let shell = Shell(stdin: .string("incoming line\n"))

        let read = try await shell.withCurrent {
            return await Shell.current.stdin.readAllString()
        }
        #expect(read == "incoming line\n")
    }

    @Test func copyProducesIndependentSubshell() async throws {
        let parent = Shell()
        parent.environment.variables["FOO"] = "parent"

        let sub = parent.copy()
        sub.environment.variables["FOO"] = "child"

        #expect(parent.environment.variables["FOO"] == "parent")
        #expect(sub.environment.variables["FOO"] == "child")
    }

    @Test func sandboxNilByDefault() {
        let shell = Shell()
        #expect(shell.sandbox == nil)
        #expect(Shell.processDefault.sandbox == nil)
    }

    @Test func rootedSandboxAllowsPathsUnderRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shellkit-test-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sandbox = Sandbox.rooted(at: root)
        let inside = root.appendingPathComponent("subdir/file.txt")
        let outside = URL(fileURLWithPath: "/etc/passwd")

        // Inside path: authorize succeeds even before file exists.
        try await sandbox.authorize(inside)

        // Outside path: throws Denial.
        do {
            try await sandbox.authorize(outside)
            Issue.record("expected Denial for /etc/passwd")
        } catch is Sandbox.Denial {
            // expected
        }
    }
}

@Suite struct ArgumentParserBridgeTests {

    /// A real `AsyncParsableCommand` — exactly the shape SwiftPorts
    /// CLIs use. The embedder registers this type via
    /// `Shell.register(_:)`; the body reads from / writes to
    /// `Shell.current` so the same code works standalone (via
    /// `await Echo.main()`) and embedded.
    struct Echo: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "shellkit-test-echo",
            abstract: "Smoke-test command for ShellKit.",
            version: "0.0.1-test")

        @Argument var words: [String] = []
        @Flag(name: .shortAndLong) var loud: Bool = false

        func run() async throws {
            let joined = words.joined(separator: " ")
            let line = (loud ? joined.uppercased() : joined) + "\n"
            Shell.current.stdout(line)
        }
    }

    @Test func registerAndDispatchAsync() async throws {
        let captured = OutputSink()
        let shell = Shell(stdout: captured)
        shell.register(Echo.self)

        try await shell.withCurrent {
            // The shell hands the bridge the FULL argv —
            // including argv[0] = command name. The bridge strips
            // argv[0] internally before parseAsRoot.
            let cmd = shell.commands["shellkit-test-echo"]
            #expect(cmd != nil)
            let status = try await cmd!.run(
                ["shellkit-test-echo", "hello", "world"])
            #expect(status == .success)
        }

        captured.finish()
        let out = await captured.readAllString()
        #expect(out == "hello world\n")
    }

    @Test func flagsParseInsideBridge() async throws {
        let captured = OutputSink()
        let shell = Shell(stdout: captured)
        shell.register(Echo.self)

        try await shell.withCurrent {
            let cmd = shell.commands["shellkit-test-echo"]!
            _ = try await cmd.run(["shellkit-test-echo", "-l", "alice"])
        }

        captured.finish()
        let out = await captured.readAllString()
        #expect(out == "ALICE\n")
    }

    @Test func parseErrorPrintsToStderr() async throws {
        struct Strict: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "shellkit-test-strict")
            @Argument var required: String
            mutating func run() throws {}
        }

        let stderr = OutputSink()
        let shell = Shell(stderr: stderr)
        shell.register(Strict.self)

        try await shell.withCurrent {
            let cmd = shell.commands["shellkit-test-strict"]!
            // Missing the required argument → parse error.
            let status = try await cmd.run(["shellkit-test-strict"])
            #expect(status.code != 0)
        }

        stderr.finish()
        let errText = await stderr.readAllString()
        #expect(!errText.isEmpty)  // ArgumentParser usage message
    }

    @Test func helpFlagPrintsToStdoutAndExitsZero() async throws {
        let stdout = OutputSink()
        let shell = Shell(stdout: stdout)
        shell.register(Echo.self)

        try await shell.withCurrent {
            let cmd = shell.commands["shellkit-test-echo"]!
            let status = try await cmd.run(["shellkit-test-echo", "--help"])
            #expect(status == .success)
        }

        stdout.finish()
        let out = await stdout.readAllString()
        // The full help text contains both abstract and usage.
        #expect(out.contains("Smoke-test command for ShellKit."))
        #expect(out.contains("USAGE:") || out.contains("shellkit-test-echo"))
    }

    @Test func versionFlagWorks() async throws {
        let stdout = OutputSink()
        let shell = Shell(stdout: stdout)
        shell.register(Echo.self)

        try await shell.withCurrent {
            let cmd = shell.commands["shellkit-test-echo"]!
            let status = try await cmd.run(["shellkit-test-echo", "--version"])
            #expect(status == .success)
        }

        stdout.finish()
        let out = await stdout.readAllString()
        #expect(out.contains("0.0.1-test"))
    }

    @Test func exitCodeThrownFromRunIsHonoured() async throws {
        struct Failer: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "shellkit-test-failer")
            func run() async throws {
                throw ExitCode(42)
            }
        }

        let shell = Shell()
        shell.register(Failer.self)

        try await shell.withCurrent {
            let cmd = shell.commands["shellkit-test-failer"]!
            let status = try await cmd.run(["shellkit-test-failer"])
            #expect(status.code == 42)
        }
    }
}

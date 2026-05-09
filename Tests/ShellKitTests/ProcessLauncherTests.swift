import Foundation
import Testing
@testable import ShellKit

/// Whether the host platform supports real subprocess exec. iOS /
/// tvOS / watchOS / visionOS forbid `posix_spawn` / `fork` and
/// ``DefaultProcessLauncher`` throws on those.
private let supportsRealExec: Bool = {
    #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    return false
    #else
    return true
    #endif
}()

@Suite struct ProcessLauncherWiringTests {

    @Test func processDefaultHasDefaultLauncher() {
        // Acceptance: `Shell.processLauncher` exists and the default
        // on `Shell.processDefault` is `DefaultProcessLauncher`.
        let shell = Shell.processDefault
        #expect(shell.processLauncher is DefaultProcessLauncher)
    }

    @Test func freshShellHasDefaultLauncher() {
        let shell = Shell()
        #expect(shell.processLauncher is DefaultProcessLauncher)
    }

    @Test func customLauncherSurvivesCopy() {
        let shell = Shell()
        shell.processLauncher = SandboxedDenyLauncher(reason: "test")
        let sub = shell.copy()
        #expect(sub.processLauncher is SandboxedDenyLauncher)
    }
}

@Suite struct DefaultProcessLauncherTests {

    @Test func standaloneRoundTripsEcho() async throws {
        try requireRealExec()

        let stdout = OutputSink()
        let stderr = OutputSink()
        let launcher = DefaultProcessLauncher()
        let env = Environment.current()

        let record = try await launcher.launch(
            .name("echo"),
            arguments: ["hi"],
            environment: env,
            workingDirectory: nil,
            input: .empty,
            output: stdout,
            error: stderr)

        #expect(record.terminationStatus.isSuccess)
        #expect(record.terminationStatus == .exited(0))

        let out = String(decoding: record.standardOutput, as: UTF8.self)
        // `echo hi` adds a trailing newline.
        #expect(out == "hi\n")

        // Sink received the same bytes the record captured.
        stdout.finish()
        let sinkOut = await stdout.readAllString()
        #expect(sinkOut == "hi\n")
    }

    @Test func capturesStderr() async throws {
        try requireRealExec()

        let stdout = OutputSink()
        let stderr = OutputSink()
        let launcher = DefaultProcessLauncher()
        let env = Environment.current()

        let record = try await launcher.launch(
            .path("/bin/sh"),
            arguments: ["-c", "echo to-err 1>&2"],
            environment: env,
            workingDirectory: nil,
            input: .empty,
            output: stdout,
            error: stderr)

        #expect(record.terminationStatus.isSuccess)
        let errText = String(decoding: record.standardError, as: UTF8.self)
        #expect(errText == "to-err\n")

        stderr.finish()
        let sinkErr = await stderr.readAllString()
        #expect(sinkErr == "to-err\n")
    }

    @Test func nonZeroExitStatusReported() async throws {
        try requireRealExec()

        let launcher = DefaultProcessLauncher()
        let env = Environment.current()

        let record = try await launcher.launch(
            .path("/bin/sh"),
            arguments: ["-c", "exit 7"],
            environment: env,
            workingDirectory: nil,
            input: .empty,
            output: OutputSink(),
            error: OutputSink())

        #expect(record.terminationStatus == .exited(7))
        #expect(record.terminationStatus.isSuccess == false)
    }

    @Test func environmentOverrideReachesSubprocess() async throws {
        try requireRealExec()

        var env = Environment.current()
        // Inject a custom variable; subprocess prints it back.
        env.variables["SHELLKIT_PROBE"] = "hello-from-shellkit"

        let launcher = DefaultProcessLauncher()
        let record = try await launcher.launch(
            .path("/bin/sh"),
            arguments: ["-c", "printf %s \"$SHELLKIT_PROBE\""],
            environment: env,
            workingDirectory: nil,
            input: .empty,
            output: OutputSink(),
            error: OutputSink())

        #expect(record.terminationStatus.isSuccess)
        let out = String(decoding: record.standardOutput, as: UTF8.self)
        #expect(out == "hello-from-shellkit")
    }

    @Test func workingDirectoryOverrideTakesEffect() async throws {
        try requireRealExec()

        let unique = "shellkit-cwd-\(UUID().uuidString)"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(unique, isDirectory: true)
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let launcher = DefaultProcessLauncher()
        let env = Environment.current()
        let record = try await launcher.launch(
            .path("/bin/sh"),
            arguments: ["-c", "pwd -P"],
            environment: env,
            workingDirectory: tmp.path,
            input: .empty,
            output: OutputSink(),
            error: OutputSink())

        #expect(record.terminationStatus.isSuccess)
        let out = String(decoding: record.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Bypass /var → /private/var canonicalisation pitfalls by
        // anchoring on the unique component we created.
        #expect(out.hasSuffix("/" + unique),
                "subprocess pwd \"\(out)\" should end with /\(unique)")
    }

    @Test func stdinPipedThrough() async throws {
        try requireRealExec()

        let launcher = DefaultProcessLauncher()
        let env = Environment.current()
        let record = try await launcher.launch(
            .path("/bin/cat"),
            arguments: [],
            environment: env,
            workingDirectory: nil,
            input: .string("piped-in"),
            output: OutputSink(),
            error: OutputSink())

        #expect(record.terminationStatus.isSuccess)
        let out = String(decoding: record.standardOutput, as: UTF8.self)
        #expect(out == "piped-in")
    }

    @Test func unsupportedPlatformThrowsTypedError() async throws {
        // Acceptance: on iOS / tvOS / watchOS the launcher exists but
        // throws. On supported platforms this test is a no-op (the
        // typed error path isn't reachable).
        guard !supportsRealExec else { return }
        let launcher = DefaultProcessLauncher()
        do {
            _ = try await launcher.launch(
                .name("echo"),
                arguments: [],
                environment: Environment(),
                workingDirectory: nil,
                input: .empty,
                output: OutputSink(),
                error: OutputSink())
            Issue.record("expected ProcessLaunchUnsupportedOnThisPlatform")
        } catch is ProcessLaunchUnsupportedOnThisPlatform {
            // expected
        }
    }
}

@Suite struct SandboxedDenyLauncherTests {

    @Test func deniesEveryLaunchWithTypedError() async throws {
        let launcher = SandboxedDenyLauncher(reason: "test deny")
        do {
            _ = try await launcher.launch(
                .name("echo"),
                arguments: ["hi"],
                environment: Environment(),
                workingDirectory: nil,
                input: .empty,
                output: OutputSink(),
                error: OutputSink())
            Issue.record("expected ProcessLaunchDenied")
        } catch let denial as ProcessLaunchDenied {
            #expect(denial.reason == "test deny")
            if case .name(let n) = denial.executable.storage {
                #expect(n == "echo")
            } else {
                Issue.record("unexpected executable storage")
            }
        }
    }

    @Test func denyAcceptanceWhenInstalledOnShell() async throws {
        // Acceptance: setting `Shell.current.sandbox` and replacing
        // the launcher with `SandboxedDenyLauncher` causes the same
        // `launch(...)` call to throw `ProcessLaunchDenied`.
        let shell = Shell()
        shell.sandbox = .rooted(
            at: FileManager.default.temporaryDirectory)
        shell.processLauncher = SandboxedDenyLauncher()

        await #expect(throws: ProcessLaunchDenied.self) {
            _ = try await shell.processLauncher.launch(
                .name("echo"),
                arguments: ["hi"],
                environment: shell.environment,
                workingDirectory: nil,
                input: .empty,
                output: OutputSink(),
                error: OutputSink())
        }
    }
}

@Suite struct ChainLauncherTests {

    /// A primary stage that resolves only `"foo"` — emitting a fixed
    /// record — and throws ``ProcessLaunchUnresolved`` for everything
    /// else, so ``ChainLauncher`` falls through to the tail.
    private struct OnlyFooLauncher: ProcessLauncher {
        func launch(
            _ executable: Executable,
            arguments: Arguments,
            environment: Environment,
            workingDirectory: String?,
            input: InputSource,
            output: OutputSink,
            error: OutputSink
        ) async throws -> ExecutionRecord {
            switch executable.storage {
            case .name("foo"):
                output.write("foo-builtin\n")
                return ExecutionRecord(
                    processIdentifier: 0,
                    terminationStatus: .exited(0),
                    standardOutput: Data("foo-builtin\n".utf8))
            default:
                throw ProcessLaunchUnresolved(executable: executable)
            }
        }
    }

    @Test func primaryHandlesItsOwnCommand() async throws {
        let chain = ChainLauncher(
            primary: OnlyFooLauncher(),
            fallback: SandboxedDenyLauncher(reason: "should-not-fire"))

        let stdout = OutputSink()
        let record = try await chain.launch(
            .name("foo"),
            arguments: [],
            environment: Environment(),
            workingDirectory: nil,
            input: .empty,
            output: stdout,
            error: OutputSink())

        #expect(record.terminationStatus == .exited(0))
        let out = String(decoding: record.standardOutput, as: UTF8.self)
        #expect(out == "foo-builtin\n")
    }

    @Test func unresolvedCommandFallsThroughToDefault() async throws {
        try requireRealExec()

        let chain = ChainLauncher(
            primary: OnlyFooLauncher(),
            fallback: DefaultProcessLauncher())

        // `foo` is intercepted by the primary.
        let fooOut = OutputSink()
        let fooRec = try await chain.launch(
            .name("foo"),
            arguments: [],
            environment: Environment.current(),
            workingDirectory: nil,
            input: .empty,
            output: fooOut,
            error: OutputSink())
        #expect(fooRec.terminationStatus == .exited(0))
        let fooText = String(decoding: fooRec.standardOutput, as: UTF8.self)
        #expect(fooText == "foo-builtin\n")

        // `echo` falls through to the real exec engine.
        let echoOut = OutputSink()
        let echoRec = try await chain.launch(
            .name("echo"),
            arguments: ["chained"],
            environment: Environment.current(),
            workingDirectory: nil,
            input: .empty,
            output: echoOut,
            error: OutputSink())
        #expect(echoRec.terminationStatus.isSuccess)
        let echoText = String(decoding: echoRec.standardOutput, as: UTF8.self)
        #expect(echoText == "chained\n")
    }

    @Test func deniedFallthroughSurfacesDenial() async throws {
        // Acceptance: ``ProcessLaunchDenied`` from a tail propagates
        // unchanged — only ``ProcessLaunchUnresolved`` is caught.
        let chain = ChainLauncher(
            primary: OnlyFooLauncher(),
            fallback: SandboxedDenyLauncher(reason: "tail deny"))

        await #expect(throws: ProcessLaunchDenied.self) {
            _ = try await chain.launch(
                .name("not-foo"),
                arguments: [],
                environment: Environment(),
                workingDirectory: nil,
                input: .empty,
                output: OutputSink(),
                error: OutputSink())
        }
    }
}

// MARK: - Helpers

/// Tests that exercise real exec (``DefaultProcessLauncher``) call
/// this to skip themselves on iOS / tvOS / watchOS / visionOS, where
/// `posix_spawn` is forbidden.
private func requireRealExec(file: String = #file, line: Int = #line) throws {
    if !supportsRealExec {
        throw SkipRealExec()
    }
}

private struct SkipRealExec: Error {}

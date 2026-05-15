import Foundation

/// The shared subprocess-dispatch primitive that every shell host
/// (SwiftBash, SwiftScript, a future JS runtime) runs through.
///
/// `ProcessLauncher` is what turns "run `/bin/git status` and capture
/// its output" from "reach for `Foundation.Process` directly" into "go
/// through ``Shell/processLauncher`` and let the embedder decide what
/// happens." Every Shell carries one — the default
/// ``DefaultProcessLauncher`` delegates to swift-subprocess; embedders
/// can install ``SandboxedDenyLauncher`` to refuse exec entirely, or
/// chain a builtin-aware launcher in front of the default with
/// ``ChainLauncher`` so registered builtins shadow real exec.
///
/// The protocol is shaped to mirror swift-subprocess's collected-output
/// `run(...)` overload: same parameter names, same types (lifted to
/// ShellKit's ``Executable`` / ``Arguments`` / ``ExecutionRecord`` so
/// consumers don't need a direct swift-subprocess dep). Closure-form
/// (`run(...) { execution, stdout in ... }`) is deferred to v2 along
/// with `AsyncSequence<Data>` streaming output.
public protocol ProcessLauncher: Sendable {

    /// Launch `executable` with the supplied parameters and return the
    /// outcome.
    ///
    /// - Parameters:
    ///   - executable: Program to run. Either ``Executable/name(_:)``
    ///     (resolved through `PATH`) or ``Executable/path(_:)``
    ///     (used as-is).
    ///   - arguments: argv[1...]. argv[0] is set by the launcher to
    ///     match `executable`.
    ///   - environment: Variables and CWD source. The launcher reads
    ///     ``Environment/variables`` for the subprocess's environ and
    ///     falls back to ``Environment/workingDirectory`` when
    ///     `workingDirectory` is `nil`.
    ///   - workingDirectory: Optional override for the subprocess's
    ///     CWD. `nil` means "use `environment.workingDirectory` if set,
    ///     else inherit the host's CWD".
    ///   - input: Bytes to feed to the subprocess's stdin. Drained
    ///     into a buffer before exec by ``DefaultProcessLauncher``;
    ///     streaming-stdin is a v2 concern.
    ///   - output: Sink that receives the subprocess's stdout. The
    ///     launcher writes each captured chunk *and* records a copy
    ///     in ``ExecutionRecord/standardOutput``.
    ///   - error: Sink that receives the subprocess's stderr.
    ///     Recorded in ``ExecutionRecord/standardError``.
    /// - Returns: A populated ``ExecutionRecord``.
    /// - Throws: ``ProcessLaunchDenied`` (sandbox policy refused),
    ///   ``ProcessLaunchUnresolved`` (the launcher doesn't handle this
    ///   command — used by chain launchers as a fall-through signal),
    ///   ``ProcessLaunchUnsupportedOnThisPlatform`` (real exec is
    ///   unavailable on iOS / tvOS / watchOS / visionOS), or any
    ///   transport error from the underlying engine.
    ///
    /// The 7-parameter signature mirrors the POSIX exec model
    /// (program + args + env + cwd + stdin + stdout + stderr).
    /// Bundling these into a struct would be a breaking protocol
    /// change for every ShellKit consumer for no behavioural gain.
    func launch( // swiftlint:disable:this function_parameter_count
        _ executable: Executable,
        arguments: Arguments,
        environment: Environment,
        workingDirectory: String?,
        input: InputSource,
        output: OutputSink,
        error: OutputSink
    ) async throws -> ExecutionRecord
}

// MARK: - Errors

/// Thrown by sandbox-bound launchers to refuse a launch.
public struct ProcessLaunchDenied: Error, Sendable, Equatable, CustomStringConvertible {
    public let executable: Executable
    public let reason: String

    public init(executable: Executable, reason: String) {
        self.executable = executable
        self.reason = reason
    }

    public var description: String {
        "ProcessLaunchDenied(\(executable.description)): \(reason)"
    }
}

/// Thrown by a launcher that doesn't know about this executable —
/// the ``ChainLauncher`` fall-through signal. A primary-stage launcher
/// throws this when it has no entry for the requested command, and the
/// chain catches it and tries the next launcher in line. Should NEVER
/// surface to the caller from a properly-composed chain whose tail is a
/// real exec engine (``DefaultProcessLauncher``) or an explicit deny
/// (``SandboxedDenyLauncher``).
public struct ProcessLaunchUnresolved: Error, Sendable, Equatable, CustomStringConvertible {
    public let executable: Executable

    public init(executable: Executable) {
        self.executable = executable
    }

    public var description: String {
        "ProcessLaunchUnresolved(\(executable.description))"
    }
}

/// Thrown by ``DefaultProcessLauncher`` on platforms where the kernel
/// prohibits `posix_spawn` / `fork` (iOS / tvOS / watchOS / visionOS).
/// Embedders that want a working launcher on those platforms install a
/// virtual one that uses only ``ProcessTable/spawn(command:body:)``
/// (closure-bodied virtual processes).
public struct ProcessLaunchUnsupportedOnThisPlatform: Error, Sendable, Equatable, CustomStringConvertible {
    public let executable: Executable

    public init(executable: Executable) {
        self.executable = executable
    }

    public var description: String {
        "ProcessLaunchUnsupportedOnThisPlatform(\(executable.description))"
    }
}

import Foundation

/// A ``ProcessLauncher`` that refuses every launch with
/// ``ProcessLaunchDenied``.
///
/// Suitable for embedders that bind a sandbox but provide no command
/// resolver of their own — e.g. an in-process script host that wants
/// callers to discover up-front that real exec is not available, with
/// a typed error rather than a sandbox-path violation surfaced from
/// somewhere downstream.
public struct SandboxedDenyLauncher: ProcessLauncher {

    public let reason: String

    public init(reason: String = "process launch denied by sandbox") {
        self.reason = reason
    }

    // Mirrors the ProcessLauncher protocol signature — see protocol
    // for why 7 parameters is the canonical exec contract.
    // swiftlint:disable:next function_parameter_count
    public func launch(
        _ executable: Executable,
        arguments: Arguments,
        environment: Environment,
        workingDirectory: String?,
        input: InputSource,
        output: OutputSink,
        error: OutputSink
    ) async throws -> ExecutionRecord {
        throw ProcessLaunchDenied(executable: executable, reason: reason)
    }
}

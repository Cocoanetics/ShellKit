import Foundation

/// A composing ``ProcessLauncher`` that consults `primary` first and
/// falls through to `fallback` only when `primary` throws
/// ``ProcessLaunchUnresolved``.
///
/// This is the composition primitive that lets SwiftBash say "consult
/// my builtins, else delegate to real exec":
///
/// ```swift
/// let bashLauncher = BashProcessLauncher(builtins: …)  // throws
///                                                      // ProcessLaunchUnresolved
///                                                      // for unknown names
/// shell.processLauncher = ChainLauncher(
///     primary: bashLauncher,
///     fallback: DefaultProcessLauncher())
/// ```
///
/// Other thrown errors (``ProcessLaunchDenied``, transport errors from
/// swift-subprocess, the body of a builtin throwing) propagate
/// unchanged. Only the specific "I don't know about this command"
/// signal is caught.
public struct ChainLauncher: ProcessLauncher {

    public let primary: any ProcessLauncher
    public let fallback: any ProcessLauncher

    public init(primary: any ProcessLauncher, fallback: any ProcessLauncher) {
        self.primary = primary
        self.fallback = fallback
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
        do {
            return try await primary.launch(
                executable,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                input: input,
                output: output,
                error: error)
        } catch is ProcessLaunchUnresolved {
            return try await fallback.launch(
                executable,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                input: input,
                output: output,
                error: error)
        }
    }
}

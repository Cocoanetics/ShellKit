import Foundation

/// How a launched subprocess ended. Mirrors swift-subprocess's
/// ``Subprocess.TerminationStatus`` (and POSIX `waitpid` semantics):
/// either an exit code, or — on POSIX — a delivering signal.
public enum TerminationStatus: Sendable, Hashable {
    /// The subprocess called `exit(code)` (or fell off `main`).
    case exited(Int32)
    /// The subprocess was killed by a signal. Not produced on Windows.
    case signaled(Int32)

    /// Exit-code 0 only. Signal terminations always count as failure.
    public var isSuccess: Bool {
        switch self {
        case .exited(let code): return code == 0
        case .signaled: return false
        }
    }
}

/// The collected outcome of a ``ProcessLauncher/launch(_:arguments:environment:workingDirectory:input:output:error:)``
/// call. Captures everything a caller needs to decide success / failure
/// and inspect what came out of stdout / stderr.
///
/// Stdout / stderr were ALSO streamed live through the
/// ``OutputSink``s passed in; the buffers here are a parallel record
/// for callers that prefer to consume the result inline. `BashProcessLauncher`
/// (SwiftBash) ignores the buffers and reads the sinks; the SwiftScript
/// `run(.string(limit:))` bridge reads the buffers and ignores the
/// sinks. Both styles work off the same record.
public struct ExecutionRecord: Sendable {
    /// Host PID of the launched subprocess. Real OS pid (not the
    /// virtual ``ProcessTable`` pid). On Windows the process ID is a
    /// `DWORD`; we widen to `Int64` to fit both cases without
    /// truncation.
    public let processIdentifier: Int64

    /// How the subprocess ended.
    public let terminationStatus: TerminationStatus

    /// Bytes written to stdout, capped by the launcher's buffer
    /// limit. May be empty if the launcher's policy was to stream the
    /// output through ``OutputSink`` and not retain a copy.
    public let standardOutput: Data

    /// Bytes written to stderr, capped by the launcher's buffer
    /// limit. May be empty for the same reason as ``standardOutput``.
    public let standardError: Data

    public init(
        processIdentifier: Int64,
        terminationStatus: TerminationStatus,
        standardOutput: Data = Data(),
        standardError: Data = Data()
    ) {
        self.processIdentifier = processIdentifier
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

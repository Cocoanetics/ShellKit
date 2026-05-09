import Foundation

#if canImport(Subprocess)
import Subprocess
#if canImport(System)
import System
#else
import SystemPackage
#endif
#endif

/// The default ``ProcessLauncher`` shipped with ShellKit. Delegates to
/// swift-subprocess's ``Subprocess.run(_:arguments:environment:workingDirectory:platformOptions:input:output:error:)``
/// with the collected-output overload — captures stdout / stderr into
/// ``Data`` buffers up to the configured limit and forwards each
/// captured chunk to the supplied ``OutputSink``s.
///
/// Installed on ``Shell/processDefault``; embedders that virtualise
/// the process table (SwiftBash) replace it with their own type
/// (typically a ``ChainLauncher`` whose primary stage is a
/// builtin-aware launcher and whose tail is this default).
///
/// ### Platform availability
///
/// swift-subprocess ships only on macOS / Linux / Windows / Android —
/// iOS / tvOS / watchOS / visionOS forbid `posix_spawn` / `fork`. On
/// those platforms ``launch(_:arguments:environment:workingDirectory:input:output:error:)``
/// throws ``ProcessLaunchUnsupportedOnThisPlatform`` and the embedder
/// is expected to install a virtual launcher that goes through
/// ``ProcessTable/spawn(command:body:)`` instead.
///
/// ### v1 limitations
///
/// - Stdin is fully drained into a buffer before exec. Streaming-stdin
///   is a v2 concern.
/// - Stdout / stderr are collected with a fixed
///   ``defaultBufferLimit``-byte cap. Subclass + override or call
///   swift-subprocess's closure-form `run` directly if you need the
///   `AsyncSequence<Data>` shape.
/// - No ``Subprocess.PlatformOptions`` (spawn attributes / file
///   actions). Subclass to inject them.
public struct DefaultProcessLauncher: ProcessLauncher {

    /// Maximum bytes captured per stream when the launcher reads
    /// stdout / stderr. Overrunning this limit throws an error from
    /// swift-subprocess. 4 MiB is enough for almost every script-run
    /// while remaining a sane safety stop for runaway producers.
    public static let defaultBufferLimit: Int = 4 * 1024 * 1024

    public let bufferLimit: Int

    public init(bufferLimit: Int = DefaultProcessLauncher.defaultBufferLimit) {
        self.bufferLimit = bufferLimit
    }

    public func launch(
        _ executable: Executable,
        arguments: Arguments,
        environment: Environment,
        workingDirectory: String?,
        input: InputSource,
        output: OutputSink,
        error: OutputSink
    ) async throws -> ExecutionRecord {
        #if canImport(Subprocess)
        // Drain stdin upfront. v1 doesn't stream — see type doc.
        var inputBytes: [UInt8] = []
        for await chunk in input.bytes {
            inputBytes.append(contentsOf: chunk)
        }

        let exe: Subprocess.Executable
        switch executable.storage {
        case .name(let name): exe = .name(name)
        case .path(let p):    exe = .path(FilePath(p))
        }

        let args = Subprocess.Arguments(arguments.values)

        // Mirror ShellKit's ``Environment/variables`` into a custom
        // subprocess environment. `.custom` rather than `.inherit`
        // because the embedder is the source of truth — anything that
        // should leak through from `ProcessInfo.processInfo.environment`
        // is already in `Shell.processDefault.environment.variables`.
        // ``Subprocess.Environment.Key.init(_:)`` is package-private;
        // the public path is its `ExpressibleByStringLiteral` init.
        var envMap: [Subprocess.Environment.Key: String] = [:]
        for (k, v) in environment.variables {
            envMap[Subprocess.Environment.Key(stringLiteral: k)] = v
        }
        let subprocessEnv = Subprocess.Environment.custom(envMap)

        // Resolve working directory. Explicit override wins; otherwise
        // fall back to the shell's `environment.workingDirectory` if
        // set; otherwise pass nil so the host's CWD is inherited.
        let cwd: FilePath? = {
            if let wd = workingDirectory, !wd.isEmpty {
                return FilePath(wd)
            }
            let envCwd = environment.workingDirectory
            if !envCwd.isEmpty { return FilePath(envCwd) }
            return nil
        }()

        let record = try await Subprocess.run(
            exe,
            arguments: args,
            environment: subprocessEnv,
            workingDirectory: cwd,
            input: .array(inputBytes),
            output: .bytes(limit: bufferLimit),
            error: .bytes(limit: bufferLimit)
        )

        let stdoutData = Data(record.standardOutput)
        let stderrData = Data(record.standardError)

        if !stdoutData.isEmpty { output.write(stdoutData) }
        if !stderrData.isEmpty { error.write(stderrData) }

        let termStatus: TerminationStatus
        switch record.terminationStatus {
        case .exited(let code):
            termStatus = .exited(Int32(code))
        #if !os(Windows)
        case .signaled(let sig):
            termStatus = .signaled(Int32(sig))
        #endif
        }

        return ExecutionRecord(
            processIdentifier: Int64(record.processIdentifier.value),
            terminationStatus: termStatus,
            standardOutput: stdoutData,
            standardError: stderrData
        )
        #else
        throw ProcessLaunchUnsupportedOnThisPlatform(executable: executable)
        #endif
    }
}

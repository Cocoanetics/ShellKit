import Foundation

/// The complete virtualised shell surface.
///
/// `Shell` is what command implementations read instead of reaching
/// for `FileHandle.standard*`, `ProcessInfo.processInfo`,
/// `FileManager.default.currentDirectoryPath`, and so on. By going
/// through `Shell.current`, the same code runs in two modes:
///
/// 1. **Virtualised** — an embedder (an in-process bash interpreter,
///    a JavaScript runtime invoking CLIs as builtins, a SwiftScript
///    host) constructs a `Shell` with custom sinks/sources, bound
///    `environment`, `sandbox`, and `networkConfig`, and pushes it
///    onto the task with ``withCurrent(_:)``. Everything inside
///    sees the embedder's plumbing.
///
/// 2. **Passthrough** — running standalone (`swift run gh ...`),
///    nobody binds anything. ``Shell/current`` returns
///    ``Shell/processDefault`` — a Shell whose stdio wraps the
///    real `FileHandle.standard*`, whose `environment` mirrors
///    `ProcessInfo.processInfo.environment` and the OS CWD, whose
///    `sandbox` is `nil` (no confinement), whose `networkConfig`
///    is `nil` (no policy), and whose `hostInfo` is ``HostInfo/real()``.
///
/// The same command body covers both. That's the contract.
///
/// ### Property ownership
///
/// `Shell` is a class because shell semantics are mutational: a
/// command runs `export FOO=bar` and the next command must see it.
/// Subshells (`( … )` in bash, separate pipeline stages, background
/// jobs spawned with `&`) are independent `Shell` instances cloned
/// off the parent and bound onto their own Task — clones don't
/// affect the parent. The class identity carries the mutation;
/// `@TaskLocal` carries the binding scope.
///
/// ### What lives here vs. on `Sandbox`
///
/// Anything *ambient process state* lives on `Shell`:
/// `environment` (vars + cwd + positional args), `stdin`/`stdout`/
/// `stderr`, `hostInfo`, `processTable`, command registry,
/// `lastExitStatus`. The `Sandbox` is purely the URL/path/host
/// **gate** plus typed region directories; it has no environment
/// or arguments closures of its own.
///
/// ### What does NOT live here
///
/// Bash-language state — `errexit` / `pipefail` / shopt / function
/// stack / process substitution / heredoc state — is the bash
/// interpreter's concern, not the abstraction's. SwiftBash holds
/// those alongside its `Shell`.
/// Subclass to extend the runtime context with language-specific
/// state (a bash interpreter adds `errexit` / `pipefail` / shopt /
/// trap tables / function-call depth on top; a JS runtime adds its
/// own bookkeeping). The TaskLocal stores the base type, so callers
/// who only know `ShellKit.Shell` see the runtime context; callers
/// who need the subclass-specific bits cast on demand.
open class Shell: @unchecked Sendable {

    // MARK: - Standard streams

    /// stdin made available to commands running under this Shell.
    /// Default for ``processDefault`` wraps `FileHandle.standardInput`.
    public var stdin: InputSource

    /// stdout sink. Default for ``processDefault`` forwards each
    /// write to `FileHandle.standardOutput`.
    public var stdout: OutputSink

    /// stderr sink. Default for ``processDefault`` forwards each
    /// write to `FileHandle.standardError`.
    public var stderr: OutputSink

    // MARK: - Environment

    /// Variables, working directory, positional parameters. Mutable —
    /// commands run `export`, `cd`, `set -- a b c` and the changes
    /// stick around for the duration of this Shell instance.
    public var environment: Environment

    /// Positional parameters. `$1` is `positionalParameters[0]`.
    public var positionalParameters: [String]

    /// `$0` — the script or shell name.
    public var scriptName: String

    /// `$?` — exit status of the most recently completed command.
    public var lastExitStatus: ExitStatus

    // MARK: - Confinement

    /// URL/path/host gate. `nil` = no confinement (every URL
    /// allowed). Embedders bind this to a ``Sandbox`` value built
    /// from ``Sandbox/rooted(at:allowedHosts:)`` /
    /// ``Sandbox/appContainer(id:allowedHosts:)`` /
    /// ``Sandbox/init(documentsDirectory:...)`` directly.
    public var sandbox: Sandbox?

    /// Network policy. `nil` = no policy enforcement; calls to
    /// network primitives go through whatever default fetcher the
    /// caller constructs (typically `URLSession`-backed, no allow-
    /// list, no method gate, no private-IP guard).
    public var networkConfig: NetworkConfig?

    // MARK: - Identity

    /// What `whoami` / `hostname` / `id` / `uname` report.
    /// Default for ``processDefault`` is ``HostInfo/real()``;
    /// embedders running untrusted scripts assign ``HostInfo/synthetic``.
    ///
    /// Declared `open` so a subclass (e.g. SwiftBash's bash
    /// interpreter) can attach a `didSet` observer that re-syncs
    /// the matching environment variables (`$HOSTNAME` / `$USER` /
    /// `$LOGNAME` / `$HOSTTYPE` / `$MACHTYPE`) when the identity
    /// changes.
    open var hostInfo: HostInfo

    // MARK: - Process state

    /// Virtual process table. Backgrounded tasks (`&` in bash, the
    /// equivalent in any other shell language) register here. `ps` /
    /// `kill` / `pgrep` / `pkill` operate against this table, NOT
    /// the host's real process table.
    public var processTable: ProcessTable

    /// `$$` — this shell's virtual PID. Synthetic, not the host's
    /// real PID.
    public var virtualPID: Int32

    // MARK: - Commands

    /// Registered commands keyed by name. The shell's dispatcher
    /// looks up `argv[0]` here. Anything not registered falls
    /// through to whatever resolution the embedder configured (e.g.
    /// SwiftBash's PATH walk).
    public var commands: [String: Command]

    // MARK: - TaskLocal binding

    /// The active Shell for the current Task scope.
    ///
    /// Defaults to ``processDefault`` when no embedder has bound a
    /// custom value via ``withCurrent(_:)``. Reads return the bound
    /// instance (if any) or the lazily-constructed process default.
    @TaskLocal public static var current: Shell = Shell.processDefault

    // MARK: - Init

    public required init(
        stdin: InputSource = .empty,
        stdout: OutputSink? = nil,
        stderr: OutputSink? = nil,
        environment: Environment = Environment(),
        positionalParameters: [String] = [],
        scriptName: String = "",
        lastExitStatus: ExitStatus = .success,
        sandbox: Sandbox? = nil,
        networkConfig: NetworkConfig? = nil,
        hostInfo: HostInfo = .synthetic,
        processTable: ProcessTable = ProcessTable(),
        virtualPID: Int32 = 1,
        commands: [String: Command] = [:]
    ) {
        self.stdin = stdin
        self.stdout = stdout ?? .discard
        self.stderr = stderr ?? .discard
        self.environment = environment
        self.positionalParameters = positionalParameters
        self.scriptName = scriptName
        self.lastExitStatus = lastExitStatus
        self.sandbox = sandbox
        self.networkConfig = networkConfig
        self.hostInfo = hostInfo
        self.processTable = processTable
        self.virtualPID = virtualPID
        self.commands = commands
    }

    // MARK: - Process default

    /// The lazy process-bound `Shell` returned when no embedder has
    /// installed a custom one. Stdio wraps real `FileHandle.standard*`,
    /// environment mirrors `ProcessInfo.processInfo.environment`,
    /// `hostInfo` is ``HostInfo/real()``, sandbox / networkConfig
    /// are `nil` (no policy), commands registry is empty.
    ///
    /// Constructed once at first access. A standalone CLI binary
    /// (`swift run gh ...`) never explicitly touches this — code
    /// just reads `Shell.current` and gets the default.
    public static let processDefault: Shell = {
        let env = Environment(
            variables: ProcessInfo.processInfo.environment,
            workingDirectory: FileManager.default.currentDirectoryPath)
        let argv = ProcessInfo.processInfo.arguments
        return Shell(
            stdin: InputSource.processStandardInput(),
            stdout: OutputSink.forwarding(to: FileHandle.standardOutput),
            stderr: OutputSink.forwarding(to: FileHandle.standardError),
            environment: env,
            positionalParameters: argv.count > 1 ? Array(argv.dropFirst()) : [],
            scriptName: argv.first ?? "",
            sandbox: nil,
            networkConfig: nil,
            hostInfo: HostInfo.real(),
            commands: [:])
    }()

    // MARK: - Subshell factory

    /// A fresh `Shell` suitable for running as a pipeline stage or
    /// a subshell `( … )`. Every property that should be inherited
    /// is cloned. Mutations on the returned shell don't affect the
    /// receiver; the two are fully independent (with reference-typed
    /// sinks like `stdout` / `stderr` shared so the subshell's
    /// output flows to the same destination by default).
    open func copy() -> Self {
        // Subclasses that add their own state override this and call
        // super.copy() then layer their fields onto the returned
        // instance. Use of `Self` makes a subclass's `copy()`
        // automatically return its own type when overridden.
        let sub = type(of: self).init(
            stdin: stdin,
            stdout: stdout,
            stderr: stderr,
            environment: environment,
            positionalParameters: positionalParameters,
            scriptName: scriptName,
            lastExitStatus: lastExitStatus,
            sandbox: sandbox,
            networkConfig: networkConfig,
            hostInfo: hostInfo,
            processTable: processTable,
            virtualPID: virtualPID,
            commands: commands)
        return sub
    }

    // MARK: - Binding helper

    /// Run `body` with this Shell installed as ``Shell/current``.
    /// Used by embedder dispatchers and by every subshell entry
    /// point. Public so embedders can do `Shell.current` lookups
    /// in their own helpers without going through their own
    /// dispatcher.
    ///
    /// Subclasses that bind additional TaskLocals (e.g. a bash
    /// interpreter binding its own `BashShell.current` alongside
    /// the base `Shell.current`) override this to nest the bindings.
    open func withCurrent<T: Sendable>(
        _ body: () async throws -> T
    ) async rethrows -> T {
        return try await Shell.$current.withValue(self) { try await body() }
    }

    // MARK: - Path resolution

    /// Resolve a (possibly relative) path string into an absolute
    /// `URL`, honouring the shell's current working directory.
    ///
    /// Absolute paths (`/foo/bar`, or `C:\foo` on Windows) come back
    /// unchanged. Relative paths resolve against
    /// ``environment``'s ``Environment/workingDirectory``.
    ///
    /// CLI commands resolving relative argv paths should use this
    /// instead of `URL(fileURLWithPath:)` / `FileManager.default.currentDirectoryPath`
    /// directly so embedders can confine path resolution to whatever
    /// CWD they bound (typically tracked via the script's own `cd`
    /// builtin updating `environment.workingDirectory`).
    ///
    /// The static counterpart ``resolve(_:)`` is the convenient
    /// call site for code that doesn't already have a `Shell`
    /// reference; it routes through ``current``.
    public func resolve(_ path: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        #if os(Windows)
        if path.count >= 2,
           let second = path.dropFirst().first, second == ":" {
            return URL(fileURLWithPath: path)
        }
        #endif
        let cwd = environment.workingDirectory
        if cwd.isEmpty {
            return URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true)
                .appendingPathComponent(path)
        }
        return URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent(path)
    }

    /// Resolve `path` against ``current``'s working directory.
    /// Equivalent to `Shell.current.resolve(path)`; provided for
    /// call-site convenience.
    public static func resolve(_ path: String) -> URL {
        current.resolve(path)
    }
}

// MARK: - InputSource process standard input

extension InputSource {
    /// Read-from-real-`FileHandle.standardInput` source used by
    /// ``Shell/processDefault``. Streams in 64 KiB chunks until EOF;
    /// the underlying read happens on a detached low-priority Task
    /// so the source itself is non-blocking.
    public static func processStandardInput() -> InputSource {
        let handle = FileHandle.standardInput
        let (stream, cont) = AsyncStream<Data>.makeStream()
        let task = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty {
                    cont.finish()
                    return
                }
                cont.yield(chunk)
            }
            cont.finish()
        }
        cont.onTermination = { _ in task.cancel() }
        return InputSource(bytes: stream)
    }
}

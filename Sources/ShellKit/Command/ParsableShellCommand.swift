import ArgumentParser
import Foundation

/// A shell command whose argv is parsed via Swift Argument Parser.
///
/// Conform to this when you want typed `@Argument` / `@Option` /
/// `@Flag` parsing for a command that runs under a ``Shell``. The
/// `execute()` body reads shell state via ``Shell/current`` —
/// `Shell.current.stdout(...)`, `Shell.current.environment[...]`,
/// `Shell.current.sandbox?.authorize(...)`, and so on — so the same
/// implementation works whether it's invoked virtualised under an
/// embedder or standalone via ``runAsRootCommand(_:)``.
///
/// ```swift
/// import ArgumentParser
/// import ShellKit
///
/// struct Greet: ParsableShellCommand {
///     static let configuration = CommandConfiguration(
///         commandName: "greet",
///         abstract: "Print a friendly hello.")
///
///     @Argument(help: "Who to greet.") var name: String = "world"
///     @Flag(name: .shortAndLong, help: "Shout it.") var loud = false
///
///     func execute() async throws -> ExitStatus {
///         let msg = loud ? "HELLO \(name.uppercased())" : "hello \(name)"
///         Shell.current.stdout(msg + "\n")
///         return .success
///     }
/// }
/// ```
public protocol ParsableShellCommand: ParsableCommand {
    /// Run this parsed command. Reads shell state via
    /// ``Shell/current``. Mutating so assignments to `@Option`
    /// properties inside the body behave as expected.
    mutating func execute() async throws -> ExitStatus
}

extension ParsableShellCommand {

    /// Parse `argv` (without the leading command name) and run.
    /// Returns the resulting ``ExitStatus``, mapping
    /// ArgumentParser's `--help` / `--version` clean-exits and
    /// usage errors to the same exit-code conventions as the
    /// stdlib `main()`.
    ///
    /// `--help` and `--version` print to ``Shell/current``'s
    /// `stdout` and return `.success`. Parse errors print to
    /// `stderr` with status `64` (BSD `EX_USAGE`).
    public static func runAsRootCommand(_ argv: [String]) async throws -> ExitStatus {
        do {
            var parsed = try Self.parseAsRoot(argv) as! Self
            return try await parsed.execute()
        } catch is CancellationError {
            // Cooperative cancellation must propagate so the
            // dispatcher / process table records the job as
            // cancelled; ArgumentParser's `fullMessage(for:)`
            // would otherwise render it as a stray usage diagnostic.
            throw CancellationError()
        } catch {
            let message = Self.fullMessage(for: error)
            let code = Self.exitCode(for: error).rawValue
            if !message.isEmpty {
                if code == 0 {
                    Shell.current.stdout(message + "\n")
                } else {
                    Shell.current.stderr(message + "\n")
                }
            }
            return ExitStatus(code)
        }
    }
}

/// Adapter that wraps a ``ParsableShellCommand`` type so it conforms
/// to ``Command``. Most embedders register via
/// ``Shell/register(_:)`` rather than constructing this directly.
public struct ParsableShellCommandBridge<Parsed: ParsableShellCommand>: Command {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    public func run(_ argv: [String]) async throws -> ExitStatus {
        // ArgumentParser expects argv without the command name.
        let args = Array(argv.dropFirst())
        return try await Parsed.runAsRootCommand(args)
    }
}

extension Shell {
    /// Register a ``ParsableShellCommand`` type with this Shell.
    /// The command name comes from `configuration.commandName`,
    /// falling back to the lowercased Swift type name.
    public func register<Parsed: ParsableShellCommand>(_ type: Parsed.Type) {
        let name = type.configuration.commandName
            ?? String(describing: type).lowercased()
        commands[name] = ParsableShellCommandBridge<Parsed>(name)
    }
}

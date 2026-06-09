import ArgumentParser
import Foundation
import ShellKit

/// Adapter that wraps any `ArgumentParser.ParsableCommand` (sync or
/// async — `AsyncParsableCommand` refines `ParsableCommand`) so it
/// conforms to ShellKit's ``Command`` protocol.
///
/// Embedders typically don't construct this directly; they call
/// ``Shell/register(_:)`` with the command's metatype and the
/// bridge is built and stored automatically.
///
/// ### What the bridge does
///
/// 1. Accepts the **full** argv (`argv[0]` is the command name —
///    set by the shell, just like a real `execve`). The shell
///    convention is that the command sees its own name; the bridge
///    drops it only when handing off to ArgumentParser, which by
///    convention parses argv minus the command name.
/// 2. Calls `parseAsRoot(args)` to walk the subcommand tree.
/// 3. If the parsed leaf is `AsyncParsableCommand`, awaits its
///    `run()`; otherwise calls the synchronous `run()`.
/// 4. Translates ArgumentParser's exit conventions to ``ExitStatus``:
///    - `ExitCode` thrown from `run()` → matching `ExitStatus`.
///    - `--help` / `--version` (clean exits with code 0) print the
///      message to ``Shell/current``'s `stdout` and return success.
///    - Usage errors (parse failures, validation) print to
///      `stderr` and return the code ArgumentParser computed
///      (typically 64 = `EX_USAGE`).
///    - `CancellationError` propagates so the embedder's process
///      table can record cancellation.
///
/// The bridge never calls `exit(_:)` — it always returns an
/// ``ExitStatus``. Standalone CLIs that want process termination
/// use `await Cmd.main()` directly (ArgumentParser-supplied), not
/// this bridge.
struct ParsableCommandBridge<P: ParsableCommand>: Command {
    let name: String

    func run(_ argv: [String]) async throws -> ExitStatus {
        // Shell convention: argv[0] is the command name. ArgumentParser
        // convention: parseAsRoot wants args without the command name.
        // The handoff point — and ONLY here — is where we drop it.
        let args = Array(argv.dropFirst())

        let parsed: ParsableCommand
        do {
            parsed = try P.parseAsRoot(args)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return formatAndReport(error: error)
        }

        do {
            // AsyncParsableCommand refines ParsableCommand; check at
            // runtime to dispatch the right run().
            if var asyncCommand = parsed as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                var sync = parsed
                try sync.run()
            }
            return .success
        } catch is CancellationError {
            throw CancellationError()
        } catch let exit as ExitCode {
            return ExitStatus(exit.rawValue)
        } catch {
            return formatAndReport(error: error)
        }
    }

    /// Mirror what ArgumentParser does in its own `main()` /
    /// `exit(withError:)` paths: ask the command type for a
    /// formatted message and an exit code, then route each to the
    /// right ``Shell/current`` stream.
    private func formatAndReport(error: Error) -> ExitStatus {
        let message = P.fullMessage(for: error)
        let code = P.exitCode(for: error).rawValue
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

extension Shell {

    /// Build — but do **not** register — a ``Command`` that bridges an
    /// `ArgumentParser` command type to ShellKit's command protocol.
    ///
    /// Use this when you maintain your own command registry rather than this
    /// shell's in-memory `commands` map — for example an installer that places
    /// commands into a filesystem-backed bin catalog (`/usr/bin/…`) so they're
    /// `PATH`-resolvable. ``register(_:)`` is the convenience built on top of
    /// this: it makes a bridge and stores it under the command's name.
    ///
    /// The command name is taken from `configuration.commandName` if set,
    /// otherwise the lowercased Swift type name — the same rule
    /// ``register(_:)`` uses, so a bridged instance carries the name the shell
    /// would have registered it under.
    ///
    /// ```swift
    /// // In a producer package that vends ready-to-install commands:
    /// let jq = Shell.parsableCommand(Jq.self)   // jq.name == "jq"
    ///
    /// // In a standalone executable target the bridge isn't involved:
    /// @main struct Entry {
    ///     static func main() async { await Jq.main() }   // ArgumentParser
    /// }
    /// ```
    public static func parsableCommand<P: ParsableCommand>(_ type: P.Type) -> Command {
        let name = type.configuration.commandName
            ?? String(describing: type).lowercased()
        return ParsableCommandBridge<P>(name: name)
    }

    /// Register an `AsyncParsableCommand` (or plain `ParsableCommand`)
    /// type with this Shell. Once registered, `commands[name].run(argv)`
    /// dispatches through ArgumentParser's parser and into the
    /// command's `run()` body.
    ///
    /// The command name comes from `configuration.commandName` if
    /// set, otherwise the lowercased Swift type name. A registered
    /// command body that wants its output to participate in the
    /// shell's plumbing reads from / writes to ``Shell/current``
    /// (`Shell.current.stdout(...)`, `Shell.current.environment[…]`,
    /// `Shell.current.sandbox?.authorize(...)` …) — the same
    /// reads work standalone (`await Cmd.main()`) because
    /// ``Shell/processDefault`` mirrors the host process.
    ///
    /// ```swift
    /// // In the embedder:
    /// shell.register(GlabCommand.self)
    ///
    /// // In a standalone executable target:
    /// @main struct Entry {
    ///     static func main() async {
    ///         await GlabCommand.main()    // ArgumentParser handles it
    ///     }
    /// }
    /// ```
    public func register<P: ParsableCommand>(_ type: P.Type) {
        let command = Shell.parsableCommand(type)
        commands[command.name] = command
    }
}

import Foundation

// Static convenience accessors on `Shell` that read from
// ``Shell/current``. They give consumers (SwiftPorts CLIs, embedders
// that don't already have a `Shell` reference in scope) a one-call
// lookup with sensible system fallthrough when nothing is bound —
// the same shape the SwiftPorts Sandbox previously offered through
// `Sandbox.authorize(_:)`, `Sandbox.env(_:)`, `Sandbox.documentsDirectory`,
// etc. Migrating away from those statics is now a `Sandbox.` →
// `Shell.` rename, no logic change.

public extension Shell {

    // MARK: - URL gate

    /// Authorize a URL against the bound sandbox if any, else
    /// no-op. Equivalent to `Shell.current.sandbox?.authorize(url)`.
    static func authorize(_ url: URL) async throws {
        try await current.sandbox?.authorize(url)
    }

    // MARK: - Ambient process state

    /// Single-key environment lookup. Faster than reading the whole
    /// `environment` snapshot when callers only want one variable.
    static func env(_ key: String) -> String? {
        current.environment.variables[key]
    }

    /// Snapshot of the active shell's positional parameters.
    /// Mirrors `CommandLine.arguments` semantics — the value
    /// embedders set via `Shell.positionalParameters`, falling
    /// through to the host process arguments when running
    /// standalone via ``Shell/processDefault``.
    static var arguments: [String] {
        current.positionalParameters
    }

    /// Current working directory. Honours
    /// ``Shell/current``'s `environment.workingDirectory` when set,
    /// otherwise falls back to the OS CWD via
    /// `FileManager.default.currentDirectoryPath`.
    static var currentDirectory: URL {
        let cwd = current.environment.workingDirectory
        if !cwd.isEmpty {
            return URL(fileURLWithPath: cwd, isDirectory: true)
        }
        return URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true)
    }

    // MARK: - Region directories
    //
    // Each accessor prefers the bound `Sandbox`'s region URL when
    // a sandbox is set, otherwise falls back to the matching
    // `FileManager.default.urls(for:in:)` lookup. The fallback is
    // the only sensible answer when no embedder has bound a custom
    // shell — a standalone CLI just wants the host's directories.

    static var homeDirectory: URL {
        if let sandbox = current.sandbox { return sandbox.homeDirectory }
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #else
        return FileManager.default.homeDirectoryForCurrentUser
        #endif
    }

    static var temporaryDirectory: URL {
        current.sandbox?.temporaryDirectory
            ?? FileManager.default.temporaryDirectory
    }

    static var cachesDirectory: URL {
        if let sandbox = current.sandbox { return sandbox.cachesDirectory }
        return FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    static var documentsDirectory: URL {
        if let sandbox = current.sandbox { return sandbox.documentsDirectory }
        return FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent(
                "Documents", isDirectory: true)
    }

    static var downloadsDirectory: URL {
        if let sandbox = current.sandbox { return sandbox.downloadsDirectory }
        return FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent(
                "Downloads", isDirectory: true)
    }

    static var libraryDirectory: URL {
        if let sandbox = current.sandbox { return sandbox.libraryDirectory }
        return FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent(
                "Library", isDirectory: true)
    }

    static var moviesDirectory: URL {
        if let sandbox = current.sandbox { return sandbox.moviesDirectory }
        return FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent(
                "Movies", isDirectory: true)
    }

    static var musicDirectory: URL {
        if let sandbox = current.sandbox { return sandbox.musicDirectory }
        return FileManager.default
            .urls(for: .musicDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent(
                "Music", isDirectory: true)
    }

    static var picturesDirectory: URL {
        if let sandbox = current.sandbox { return sandbox.picturesDirectory }
        return FileManager.default
            .urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent(
                "Pictures", isDirectory: true)
    }

    static var sharedPublicDirectory: URL {
        if let sandbox = current.sandbox { return sandbox.sharedPublicDirectory }
        return FileManager.default
            .urls(for: .sharedPublicDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent(
                "Public", isDirectory: true)
    }

    static var trashDirectory: URL {
        if let sandbox = current.sandbox { return sandbox.trashDirectory }
        return FileManager.default
            .urls(for: .trashDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent(
                ".Trash", isDirectory: true)
    }

    static var userDirectory: URL {
        if let sandbox = current.sandbox { return sandbox.userDirectory }
        return FileManager.default
            .urls(for: .userDirectory, in: .userDomainMask).first
            ?? homeDirectory
    }

    // MARK: - print(_:) replacement
    //
    // Swift's stdlib `print(_:separator:terminator:)` writes to
    // `FILE *stdout` (fd 1) directly via `_stdoutImp`, bypassing
    // `FileHandle.standardOutput` — and therefore bypassing the
    // bound shell's `stdout` sink. CLI bodies that want their
    // output to participate in a host's pipeline must use
    // ``Shell/print(_:separator:terminator:)`` instead.

    /// Drop-in replacement for stdlib
    /// `print(_:separator:terminator:)` that routes through
    /// ``current``'s `stdout` ``OutputSink``, so the bound shell's
    /// configuration applies. Migration from stdlib is mechanical:
    /// replace `print(` with `Shell.print(`.
    static func print(_ items: Any...,
                      separator: String = " ",
                      terminator: String = "\n") {
        var rendered = ""
        var first = true
        for item in items {
            if !first { rendered += separator }
            rendered += "\(item)"
            first = false
        }
        rendered += terminator
        current.stdout(rendered)
    }
}

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
        if let sb = current.sandbox { return sb.homeDirectory }
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
        if let sb = current.sandbox { return sb.cachesDirectory }
        return FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    static var documentsDirectory: URL {
        if let sb = current.sandbox { return sb.documentsDirectory }
        return FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent(
                "Documents", isDirectory: true)
    }

    static var downloadsDirectory: URL {
        if let sb = current.sandbox { return sb.downloadsDirectory }
        return FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent(
                "Downloads", isDirectory: true)
    }

    static var libraryDirectory: URL {
        if let sb = current.sandbox { return sb.libraryDirectory }
        return FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent(
                "Library", isDirectory: true)
    }

    static var moviesDirectory: URL {
        if let sb = current.sandbox { return sb.moviesDirectory }
        return FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent(
                "Movies", isDirectory: true)
    }

    static var musicDirectory: URL {
        if let sb = current.sandbox { return sb.musicDirectory }
        return FileManager.default
            .urls(for: .musicDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent(
                "Music", isDirectory: true)
    }

    static var picturesDirectory: URL {
        if let sb = current.sandbox { return sb.picturesDirectory }
        return FileManager.default
            .urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent(
                "Pictures", isDirectory: true)
    }

    static var sharedPublicDirectory: URL {
        if let sb = current.sandbox { return sb.sharedPublicDirectory }
        return FileManager.default
            .urls(for: .sharedPublicDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent(
                "Public", isDirectory: true)
    }

    static var trashDirectory: URL {
        if let sb = current.sandbox { return sb.trashDirectory }
        return FileManager.default
            .urls(for: .trashDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent(
                ".Trash", isDirectory: true)
    }

    static var userDirectory: URL {
        if let sb = current.sandbox { return sb.userDirectory }
        return FileManager.default
            .urls(for: .userDirectory, in: .userDomainMask).first
            ?? homeDirectory
    }
}

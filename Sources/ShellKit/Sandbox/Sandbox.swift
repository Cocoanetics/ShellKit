import Foundation

/// A per-task confinement policy: which file URLs and network hosts a
/// running command may touch.
///
/// `Sandbox` is one of the surfaces ``Shell`` carries — embedders set
/// it via `Shell.current.sandbox` (or via `Sandbox.$current` for the
/// orthogonal lookup pattern). When unset (`nil`), the gate is a
/// no-op: every URL handed to ``authorize(_:)`` succeeds.
///
/// ### Default-deny posture, when set
///
/// Once an embedder installs a `Sandbox`, the embedder is in charge
/// of what the task can reach. Every URL that gated SwiftPorts /
/// SwiftBash code touches passes through ``authorize(_:)``; the
/// closure decides yes/no. Built-in factories
/// ``rooted(at:allowedHosts:)`` (single-folder confinement) and
/// ``appContainer(id:allowedHosts:)`` (iOS / sandboxed-macOS
/// regions) cover the common cases; custom layouts construct the
/// initializer directly.
///
/// ### What `Sandbox` does NOT own
///
/// Environment variables, positional arguments, current working
/// directory — those belong on ``Shell`` (one source of truth for
/// "ambient process state"). The `Sandbox` here is purely about
/// **URL / path / host gating** plus the typed region directories
/// an embedder wants to expose.
///
/// ### Honest scope
///
/// The gate is enforced by code convention: gated SwiftPorts /
/// SwiftBash sites call ``authorize(_:)`` before doing I/O.
/// Foundation internals, libgit2's own `getenv()`, third-party Swift
/// packages, and any subprocess Claude doesn't see are unaffected.
/// Embedders needing stronger isolation should `unsetenv` sensitive
/// variables at process startup and use OS-level sandboxing (App
/// Sandbox / seccomp / etc.) for hard guarantees.
public struct Sandbox: Sendable {

    // MARK: - Region URLs (mirror Foundation's URL static-directory surface)

    public let documentsDirectory: URL
    public let downloadsDirectory: URL
    public let libraryDirectory: URL
    public let moviesDirectory: URL
    public let musicDirectory: URL
    public let picturesDirectory: URL
    public let sharedPublicDirectory: URL
    public let temporaryDirectory: URL
    public let trashDirectory: URL
    public let userDirectory: URL

    /// User home directory; defaults to `documentsDirectory` if not
    /// supplied to the initializer.
    public let homeDirectory: URL

    /// User caches directory.
    public let cachesDirectory: URL

    // MARK: - URL gate

    private let _authorize: @Sendable (URL) async throws -> Void

    /// Authorize a URL against this sandbox's policy. Throws ``Denial``
    /// to deny. Sync-throwing variants are not provided; every gated
    /// site is async-throws or trivially convertible.
    public func authorize(_ url: URL) async throws {
        try await _authorize(url)
    }

    // MARK: - Init

    /// Construct a sandbox with explicit values for every region and a
    /// custom authorize closure. Most callers should use
    /// ``rooted(at:allowedHosts:)`` or ``appContainer(id:allowedHosts:)``
    /// instead.
    public init(
        documentsDirectory: URL,
        downloadsDirectory: URL,
        libraryDirectory: URL,
        moviesDirectory: URL,
        musicDirectory: URL,
        picturesDirectory: URL,
        sharedPublicDirectory: URL,
        temporaryDirectory: URL,
        trashDirectory: URL,
        userDirectory: URL,
        cachesDirectory: URL,
        homeDirectory: URL? = nil,
        authorize: @escaping @Sendable (URL) async throws -> Void
    ) {
        self.documentsDirectory = documentsDirectory
        self.downloadsDirectory = downloadsDirectory
        self.libraryDirectory = libraryDirectory
        self.moviesDirectory = moviesDirectory
        self.musicDirectory = musicDirectory
        self.picturesDirectory = picturesDirectory
        self.sharedPublicDirectory = sharedPublicDirectory
        self.temporaryDirectory = temporaryDirectory
        self.trashDirectory = trashDirectory
        self.userDirectory = userDirectory
        self.cachesDirectory = cachesDirectory
        self.homeDirectory = homeDirectory ?? documentsDirectory
        self._authorize = authorize
    }

    // MARK: - Denial

    /// Thrown by ``authorize(_:)`` when policy denies a URL.
    ///
    /// `suggestion` is an *implementer-defined hint* and never a
    /// guarantee — re-calling `authorize(suggestion)` is not
    /// guaranteed to succeed. Callers MAY inspect it for diagnostics
    /// or opt-in recovery; ShellKit / SwiftPorts internals never
    /// inspect it and never retry.
    public struct Denial: Error, Sendable, CustomStringConvertible, LocalizedError {
        public let url: URL
        public let reason: String
        public let suggestion: URL?

        public init(url: URL, reason: String, suggestion: URL? = nil) {
            self.url = url
            self.reason = reason
            self.suggestion = suggestion
        }

        /// Human-readable description that intentionally omits both
        /// `url` and `suggestion`. The default `String(describing:)`
        /// dump (which ArgumentParser's `fullMessage(for:)` falls
        /// through to for unrecognised error types) would otherwise
        /// expose the embedder's host sandbox root — for an
        /// app-as-sandbox embedder that means the iOS container path
        /// (`/Users/.../Containers/.../Documents/Foo.bar/...`) ends
        /// up in user-visible stderr on a single denied call.
        ///
        /// Callers needing the URLs read `.url` and `.suggestion`
        /// directly. The reason is the only safe-to-display string.
        public var description: String { reason }

        /// Same surface for `LocalizedError` consumers — keeps
        /// `(error as NSError).localizedDescription` and
        /// `error.localizedDescription` in sync with `description`.
        public var errorDescription: String? { reason }
    }
}

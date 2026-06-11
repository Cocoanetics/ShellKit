import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Bionic)
import Bionic
#elseif canImport(WinSDK)
import WinSDK
#endif

extension Sandbox {

    // MARK: - rooted(at:)

    /// Single-folder confinement: every region is derived as a
    /// subpath of `root`, and the authorize closure denies any
    /// URL whose canonical path doesn't start with `root`'s
    /// canonical path. Network URLs are checked against
    /// `allowedHosts` (default: deny all non-file URLs).
    ///
    /// Layout under `root` mirrors a per-user home tree:
    /// ```
    /// <root>/Documents
    /// <root>/Downloads
    /// <root>/Library
    /// <root>/Library/Caches
    /// <root>/Movies
    /// <root>/Music
    /// <root>/Pictures
    /// <root>/Public          (sharedPublicDirectory)
    /// <root>/tmp             (temporaryDirectory)
    /// <root>/.Trash
    /// <root>                 (userDirectory)
    /// <root>/home            (homeDirectory)
    /// ```
    ///
    /// Cleanup of the on-disk root is the caller's responsibility;
    /// the factory neither creates nor deletes directories.
    ///
    /// To make `Shell.current.environment.workingDirectory` land at
    /// `root` for the simple case, the embedder is expected to set
    /// `PWD` after binding the sandbox.
    public static func rooted(
        at root: URL,
        allowedHosts: [String] = []
    ) -> Sandbox {
        let canonicalRoot = (canonicalizePath(root.path)
            ?? root.standardizedFileURL.path)
        let allowedHostSet = Set(allowedHosts)

        return Sandbox(
            documentsDirectory: root.appendingPathComponent("Documents", isDirectory: true),
            downloadsDirectory: root.appendingPathComponent("Downloads", isDirectory: true),
            libraryDirectory: root.appendingPathComponent("Library", isDirectory: true),
            moviesDirectory: root.appendingPathComponent("Movies", isDirectory: true),
            musicDirectory: root.appendingPathComponent("Music", isDirectory: true),
            picturesDirectory: root.appendingPathComponent("Pictures", isDirectory: true),
            sharedPublicDirectory: root.appendingPathComponent("Public", isDirectory: true),
            temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true),
            trashDirectory: root.appendingPathComponent(".Trash", isDirectory: true),
            userDirectory: root,
            cachesDirectory: root.appendingPathComponent("Library/Caches", isDirectory: true),
            homeDirectory: root.appendingPathComponent("home", isDirectory: true),
            authorize: { url in
                try authorizeUnderRoot(
                    url: url,
                    canonicalRoot: canonicalRoot,
                    allowedHosts: allowedHostSet)
            })
    }

    // MARK: - appContainer(id:)

    /// iOS / sandboxed-macOS: uses Apple's app-container regions
    /// verbatim. Optional `id` namespaces each writable region
    /// (Documents, Caches, tmp) under a per-instance subdirectory,
    /// giving Sandbox-instance isolation even though the OS
    /// containers are app-global.
    ///
    /// The authorize closure denies any URL whose canonical path
    /// doesn't fall under one of the writable regions
    /// (Documents / Caches / tmp). Read-only regions (Movies,
    /// Music, etc.) are populated for embedder API completeness
    /// but the gate denies writes there too — the embedder can
    /// supply a custom authorize closure if Apple-API-level
    /// access to those regions is needed.
    public static func appContainer(
        id: String? = nil,
        allowedHosts: [String] = []
    ) -> Sandbox {
        let docs = appleDocumentsDirectory()
        let caches = appleCachesDirectory()
        let tmp = FileManager.default.temporaryDirectory
        let lib = appleLibraryDirectory()
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

        let scope: (URL) -> URL
        if let id, !id.isEmpty {
            let component = "sandbox-\(id)"
            scope = { $0.appendingPathComponent(component, isDirectory: true) }
        } else {
            scope = { $0 }
        }

        let scopedDocs = scope(docs)
        let scopedCaches = scope(caches)
        let scopedTmp = scope(tmp)

        let canonicalDocs = canonicalizePath(scopedDocs.path) ?? scopedDocs.standardizedFileURL.path
        let canonicalCaches = canonicalizePath(scopedCaches.path) ?? scopedCaches.standardizedFileURL.path
        let canonicalTmp = canonicalizePath(scopedTmp.path) ?? scopedTmp.standardizedFileURL.path

        let allowedHostSet = Set(allowedHosts)

        return Sandbox(
            documentsDirectory: scopedDocs,
            downloadsDirectory: scopedDocs.appendingPathComponent("Downloads", isDirectory: true),
            libraryDirectory: lib,
            moviesDirectory: home.appendingPathComponent("Movies", isDirectory: true),
            musicDirectory: home.appendingPathComponent("Music", isDirectory: true),
            picturesDirectory: home.appendingPathComponent("Pictures", isDirectory: true),
            sharedPublicDirectory: home.appendingPathComponent("Public", isDirectory: true),
            temporaryDirectory: scopedTmp,
            trashDirectory: home.appendingPathComponent(".Trash", isDirectory: true),
            userDirectory: home,
            cachesDirectory: scopedCaches,
            homeDirectory: scopedDocs,
            authorize: { url in
                try authorizeUnderRoots(
                    url: url,
                    canonicalRoots: [canonicalDocs, canonicalCaches, canonicalTmp],
                    allowedHosts: allowedHostSet)
            })
    }

    // MARK: - confined(to:)

    /// Confinement over a virtual↔host ``PathMapping``: the gate
    /// authorizes a file URL iff its canonical (symlink-resolved)
    /// path lands inside one of the mapping's host roots.
    ///
    /// This is the Facade-B half of the cooperative sandbox. Callers
    /// that do real Foundation/C I/O — SwiftPorts CLIs, the JS
    /// runtime, SwiftScript — obtain host paths from
    /// ``Shell/resolve(_:)`` (which translates virtual spellings
    /// through this same mapping, because the sandbox carries it as
    /// ``Sandbox/pathMapping``) and authorize them here. A bash-side
    /// mounted filesystem built over the same mapping confines its
    /// own traffic identically, so both doors agree on what `/tmp/x`
    /// means and on where the boundary is.
    ///
    /// Symlink escapes are rejected by canonicalising both sides: a
    /// link planted inside a mount (`ln -s /etc/passwd "$TMPDIR/p"`)
    /// resolves outside every canonical host root and is denied.
    /// Conversely, a mount whose host root is itself reached through
    /// a symlink still authorizes — both the root and the candidate
    /// resolve to the same canonical prefix.
    ///
    /// The mapping's `readOnly` flag is *not* enforced here —
    /// `authorize(_:)` carries no read/write intent. Filesystem
    /// layers that know the intent enforce it.
    ///
    /// - Parameters:
    ///   - mapping: the mount table to confine to. The sandbox keeps
    ///     it as ``Sandbox/pathMapping`` so ``Shell/resolve(_:)`` and
    ///     ``Shell/displayPath(for:)-swift.method`` translate through
    ///     the very table the gate enforces.
    ///   - home: virtual path of the mount that anchors the region
    ///     directories (`homeDirectory`, `documentsDirectory`, …).
    ///     The regions are host-spelled — consumers hand them to
    ///     Foundation — and live under that mount's host root.
    ///   - temporaryDirectory: host dir reported as
    ///     ``Sandbox/temporaryDirectory``. Defaults to the host root
    ///     of the mapping's `/tmp` mount; an embedder that doesn't
    ///     mount `/tmp` gets the platform temp dir *reported* but not
    ///     *authorized* (nothing outside the mounts ever is — temp
    ///     access is the embedder's choice, made by mounting it).
    ///   - allowedHosts: network hosts the default non-file gate
    ///     admits (deny-all when empty).
    ///   - authorizeNetwork: embedder override for non-file URLs
    ///     (e.g. routing host access through a permission prompt).
    ///     When `nil`, non-file URLs go through `allowedHosts`.
    public static func confined(
        to mapping: PathMapping,
        home: String = "/",
        temporaryDirectory: URL? = nil,
        allowedHosts: [String] = [],
        authorizeNetwork: (@Sendable (URL) async throws -> Void)? = nil
    ) -> Sandbox {
        // Region anchor: the host root backing the virtual `home`.
        // (Falling back to the literal string only happens when the
        // embedder anchors regions outside its own mapping — a
        // misconfiguration that then fails closed at the gate.)
        let hostHome = mapping.hostPath(forVirtual: home)?.host ?? home
        let homeURL = URL(fileURLWithPath: hostHome, isDirectory: true)
        let tmpURL = temporaryDirectory
            ?? mapping.hostPath(forVirtual: "/tmp")
                .map { URL(fileURLWithPath: $0.host, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        // Canonicalise every mount's host root once, up front — same
        // strategy as `rooted(at:)`. Roots exist by the time the
        // sandbox is built (mounting a missing directory is the
        // embedder's bug and fails closed: nothing canonicalises
        // into a nonexistent root).
        let canonicalRoots = mapping.mounts.map {
            canonicalizePath($0.host)
                ?? URL(fileURLWithPath: $0.host).standardizedFileURL.path
        }
        let allowedHostSet = Set(allowedHosts)
        return Sandbox(
            documentsDirectory: homeURL.appendingPathComponent("Documents", isDirectory: true),
            downloadsDirectory: homeURL.appendingPathComponent("Downloads", isDirectory: true),
            libraryDirectory: homeURL.appendingPathComponent("Library", isDirectory: true),
            moviesDirectory: homeURL.appendingPathComponent("Movies", isDirectory: true),
            musicDirectory: homeURL.appendingPathComponent("Music", isDirectory: true),
            picturesDirectory: homeURL.appendingPathComponent("Pictures", isDirectory: true),
            sharedPublicDirectory: homeURL.appendingPathComponent("Public", isDirectory: true),
            temporaryDirectory: tmpURL,
            trashDirectory: homeURL.appendingPathComponent(".Trash", isDirectory: true),
            userDirectory: homeURL,
            cachesDirectory: homeURL.appendingPathComponent("Library/Caches", isDirectory: true),
            // The home mount IS the user's home — `cd` with no
            // argument and `~` both land at the workspace.
            homeDirectory: homeURL,
            pathMapping: mapping,
            authorize: { url in
                guard url.isFileURL else {
                    if let authorizeNetwork {
                        try await authorizeNetwork(url)
                        return
                    }
                    try authorizeUnderRoots(
                        url: url,
                        canonicalRoots: [],
                        allowedHosts: allowedHostSet)
                    return
                }
                try authorizeUnderRoots(
                    url: url,
                    canonicalRoots: canonicalRoots,
                    allowedHosts: allowedHostSet)
            })
    }

    // MARK: - Authorization helpers (internal but file-scoped sendable)

    fileprivate static func authorizeUnderRoot(
        url: URL,
        canonicalRoot: String,
        allowedHosts: Set<String>
    ) throws {
        try authorizeUnderRoots(
            url: url,
            canonicalRoots: [canonicalRoot],
            allowedHosts: allowedHosts)
    }

    fileprivate static func authorizeUnderRoots(
        url: URL,
        canonicalRoots: [String],
        allowedHosts: Set<String>
    ) throws {
        if url.isFileURL {
            let candidate = canonicalizeForCheck(url.path)
            for root in canonicalRoots where pathHasPrefix(candidate, prefix: root) {
                return
            }
            // Build a hint pointing at where, conceptually, this URL
            // would land under the first root. Built from the
            // *standardized* (not symlink-resolved) input path so the
            // hint reflects user intent rather than disk layout.
            // Implementer-defined; not a guarantee. Callers must not
            // blind-retry — see `Sandbox.Denial` doc.
            let hintRoot = canonicalRoots.first ?? ""
            let standardized = url.standardizedFileURL.path
            let suggestion: URL?
            if !hintRoot.isEmpty, standardized.hasPrefix("/") {
                suggestion = URL(fileURLWithPath: hintRoot)
                    .appendingPathComponent(String(standardized.dropFirst()))
            } else {
                suggestion = nil
            }
            throw Sandbox.Denial(
                url: url,
                reason: "file URL is outside sandbox root",
                suggestion: suggestion)
        }

        // Non-file URL: check host allowlist.
        guard let host = url.host, !host.isEmpty else {
            throw Sandbox.Denial(
                url: url,
                reason: "non-file URL has no host to authorize",
                suggestion: nil)
        }
        if allowedHosts.contains(host) {
            return
        }
        throw Sandbox.Denial(
            url: url,
            reason: "host '\(host)' is not in the sandbox allowlist",
            suggestion: nil)
    }

    /// Canonicalize a path for the prefix check. Tries `realpath(3)`
    /// for the full path; if that fails (path doesn't exist yet),
    /// canonicalizes the deepest existing ancestor and re-appends
    /// the missing tail. This handles the common "authorize a write
    /// path before creating the file" case without losing symlink
    /// resolution for the existing prefix.
    private static func canonicalizeForCheck(_ path: String) -> String {
        if let canonical = canonicalizePath(path) {
            return canonical
        }
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var trailing: [String] = []
        while !url.path.isEmpty, url.path != "/" {
            if FileManager.default.fileExists(atPath: url.path) {
                if let canonical = canonicalizePath(url.path) {
                    var result = canonical
                    for component in trailing.reversed() {
                        if !result.hasSuffix("/") {
                            result += "/"
                        }
                        result += component
                    }
                    return result
                }
                return url.path
            }
            trailing.append(url.lastPathComponent)
            url = url.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// True if `path` equals or is a strict descendant of `prefix`.
    /// Both arguments are expected to be canonicalized (no `..`,
    /// symlinks resolved). Avoids the classic `/foo` matching
    /// `/foobar` bug by requiring an exact match or a `/` boundary.
    private static func pathHasPrefix(_ path: String, prefix: String) -> Bool {
        if path == prefix { return true }
        if prefix.isEmpty { return false }
        let normalizedPrefix = prefix.hasSuffix("/") ? prefix : prefix + "/"
        return path.hasPrefix(normalizedPrefix)
    }
}

// MARK: - Platform helpers

/// `realpath(3)` wrapper. Returns `nil` if the path can't be
/// canonicalized (typically because it doesn't exist).
///
/// **Windows note.** On Windows we currently fall back to
/// `URL.standardizedFileURL.path`, which strips `..` and resolves
/// `.` but does NOT follow symlinks. The symlink-escape protection
/// in `rooted(at:)` is therefore partial on Windows — a symlink
/// inside the sandbox root pointing outside it will not be rejected
/// by `authorize`. POSIX platforms (macOS / iOS / Linux / Android)
/// use `realpath(3)` and have full protection. Tracked as a follow-
/// up; full Windows resolution would use `GetFinalPathNameByHandleW`.
internal func canonicalizePath(_ path: String) -> String? {
    #if os(Windows)
    return URL(fileURLWithPath: path).standardizedFileURL.path
    #else
    return path.withCString { cPath -> String? in
        guard let resolved = realpath(cPath, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    #endif
}

/// Apple platforms' Documents directory, with a sane fallback for
/// non-Apple builds (only used by `appContainer`, which is itself
/// most useful on Apple platforms).
private func appleDocumentsDirectory() -> URL {
    if let url = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask).first {
        return url
    }
    return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Documents", isDirectory: true)
}

private func appleCachesDirectory() -> URL {
    if let url = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first {
        return url
    }
    return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Library/Caches", isDirectory: true)
}

private func appleLibraryDirectory() -> URL {
    if let url = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask).first {
        return url
    }
    return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Library", isDirectory: true)
}

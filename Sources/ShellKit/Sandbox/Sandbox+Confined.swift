import Foundation

extension Sandbox {

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
}

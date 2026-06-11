import Foundation

/// The virtual↔host path mapping a cooperative sandbox is built on:
/// a mount table translating script-visible *virtual* paths (`/`,
/// `/tmp`, `/batch`, …) to the *host* directories that back them.
///
/// This is the single authority both enforcement facades share:
///
/// - **Facade A — a `FileSystem` protocol** (SwiftBash's builtins and
///   any pure-Swift command written against it) routes every
///   operation through the table and confines symlink traversal to
///   each mount's host root.
/// - **Facade B — ``Shell/resolve(_:)``** (SwiftPorts CLIs, the JS
///   runtime, SwiftScript, and other Foundation/C-backed code)
///   translates a virtual path to its host spelling once, up front,
///   and then does real I/O; ``Sandbox/authorize(_:)`` re-checks the
///   same host path against the same mount roots.
///
/// One core, two doors: a path is translated and confined
/// identically no matter which facade it arrives through. Keeping
/// the table here (rather than inside one consumer's filesystem
/// layer) is what stops the two sides from disagreeing about where
/// `/tmp/foo` lives.
///
/// Translation is **purely lexical**: `.` / `..` are collapsed as
/// text before routing (so `..` cannot escape a mount), and no
/// symlinks are consulted. Symlink-escape *confinement* — verifying
/// that the canonical host path still lands inside the mount's host
/// root — is layered on top by the consumers that touch the disk:
/// ``Sandbox/confined(to:home:temporaryDirectory:allowedHosts:authorizeNetwork:)``
/// for Facade B, and the embedder's mounted filesystem for Facade A.
///
/// Mount precedence is "longest virtual prefix wins" — `/tmp/foo`
/// matches a `/tmp` mount before a `/` mount.
public struct PathMapping: Sendable {

    /// One mount-table entry: an absolute virtual prefix backed by an
    /// absolute host directory.
    public struct Mount: Sendable {
        /// Virtual prefix this mount answers to. `/` matches every
        /// virtual path; `/tmp` matches `/tmp` and `/tmp/...`.
        public var virtual: String
        /// Absolute host path the mount maps onto.
        public var host: String
        /// If true, the mount is advertised as read-only. The mapping
        /// itself doesn't enforce this (translation has no read/write
        /// intent); filesystem layers consult it to reject writes.
        public var readOnly: Bool

        public init(virtual: String, host: String, readOnly: Bool = false) {
            // Normalise lexically: strip `.` / `..` / trailing `/` so
            // `/tmp` and `/tmp/` compare equal. Deliberately NOT
            // `NSString.standardizingPath`, which consults the host
            // disk and resolves symlinks on corelibs-foundation —
            // the virtual side must never depend on host disk layout.
            self.virtual = Shell.normalizePath(virtual)
            self.host = (host as NSString).standardizingPath
            self.readOnly = readOnly
        }
    }

    /// Mount table, longest virtual prefix first so the most specific
    /// mount wins during translation.
    public let mounts: [Mount]

    public init(mounts: [Mount]) {
        self.mounts = mounts.sorted { $0.virtual.count > $1.virtual.count }
    }

    /// Mount table ordered by virtual path, for display by a `mount`
    /// command (``mounts`` is sorted longest-prefix first internally).
    public var mountList: [Mount] {
        mounts.sorted { $0.virtual < $1.virtual }
    }

    // MARK: - Virtual → host

    /// Translate an absolute virtual path to the host path that backs
    /// it, or `nil` when no mount matches (the path doesn't exist as
    /// far as the sandbox is concerned) or `path` isn't absolute.
    ///
    /// The path is normalised lexically (`/tmp/../home/foo` →
    /// `/home/foo`) BEFORE routing, so `..` cannot cross out of a
    /// mount unseen. Purely textual — no symlink resolution, no disk
    /// access; confinement of what the host path *resolves to* is the
    /// caller's second step.
    public func hostPath(forVirtual path: String) -> (mount: Mount, host: String)? {
        let std = Shell.normalizePath(path)
        guard std.hasPrefix("/") else { return nil }
        for mount in mounts {
            if mount.virtual == "/" {
                // Root mount — every path lands here unless an earlier
                // (more specific) mount matched. Strip the leading `/`
                // and append.
                let rel = std == "/" ? "" : String(std.dropFirst())
                let host = (mount.host as NSString)
                    .appendingPathComponent(rel)
                return (mount, host)
            }
            if std == mount.virtual {
                return (mount, mount.host)
            }
            if std.hasPrefix(mount.virtual + "/") {
                let rel = String(std.dropFirst(mount.virtual.count + 1))
                let host = (mount.host as NSString)
                    .appendingPathComponent(rel)
                return (mount, host)
            }
        }
        return nil
    }

    // MARK: - Host → virtual

    /// Fold a host path back to its virtual spelling, or `nil` when
    /// it doesn't fall under any mount's host root.
    ///
    /// This is the "no `realpath` leak" direction: anything a script
    /// gets to *see* — `$TMPDIR`-derived answers, display output,
    /// diagnostics carrying resolved paths — should travel through
    /// here (via ``Shell/displayPath(for:)-swift.method``) so the
    /// embedder's host directory layout stays out of the sandbox.
    ///
    /// Matching tolerates spelling variance on both sides: the
    /// verbatim, lexically-normalised, and symlink-resolved forms of
    /// the mount's host root and of `path` are all compared (macOS
    /// reports temp paths behind the `/var` → `/private/var` link in
    /// either spelling depending on which API produced them). The
    /// longest matching host root wins, mirroring the
    /// longest-virtual-prefix rule of ``hostPath(forVirtual:)``.
    public func virtualPath(forHost path: String) -> String? {
        let candidates = Self.spellings(of: path)
        var best: (virtual: String, rel: String, matched: Int)?
        for mount in mounts {
            for root in Self.spellings(of: mount.host) {
                for candidate in candidates {
                    let rel: String
                    if candidate == root {
                        rel = ""
                    } else if candidate.hasPrefix(root + "/") {
                        rel = String(candidate.dropFirst(root.count + 1))
                    } else {
                        continue
                    }
                    if best == nil || root.count > best!.matched {
                        best = (mount.virtual, rel, root.count)
                    }
                }
            }
        }
        guard let best else { return nil }
        if best.rel.isEmpty { return best.virtual }
        return best.virtual == "/"
            ? "/" + best.rel
            : best.virtual + "/" + best.rel
    }

    /// The spellings under which a host path might be reported:
    /// verbatim (minus a trailing `/`), lexically normalised, and
    /// symlink-resolved. `$TMPDIR`-style values keep the embedder's
    /// verbatim spelling while `FileManager` answers carry the
    /// canonical one; both must fold.
    private static func spellings(of path: String) -> [String] {
        var stripped = path
        if stripped.count > 1, stripped.hasSuffix("/") {
            stripped.removeLast()
        }
        var result: [String] = []
        for candidate in [
            stripped,
            Shell.normalizePath(stripped),
            URL(fileURLWithPath: stripped).resolvingSymlinksInPath().path
        ] where !result.contains(candidate) {
            result.append(candidate)
        }
        return result
    }
}

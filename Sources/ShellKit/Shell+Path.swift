import Foundation

extension Shell {

    /// Lexical path normalisation — collapses `.` / `..` / repeated
    /// `/` purely as text, never touching the filesystem. **Does not
    /// resolve symlinks.**
    ///
    /// Replaces `NSString.standardizingPath`, which is technically
    /// supposed to be lexical but on swift-corelibs-foundation
    /// (Linux) follows symlinks too — making a purely textual
    /// operation (`cd -L`, mount-table routing, virtual→host
    /// translation) suddenly depend on what happens to exist on the
    /// host disk. ``PathMapping`` routes every virtual path through
    /// this before consulting its mount table, so `..` cannot escape
    /// a mount and macOS autofs symlinks (`/home` →
    /// `/System/Volumes/Data/home`) cannot hijack the routing.
    ///
    /// On Windows, backslashes are normalised to forward slashes
    /// up front (Win32 path APIs accept both). Drive-letter paths
    /// keep their `C:` prefix as the root segment so the result is
    /// still a valid Windows path: `C:\Users\foo\..\bar` → `C:/Users/bar`.
    public static func normalizePath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        #if os(Windows)
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        #else
        let normalized = path
        #endif
        // Split on `/`, tracking whether the path is anchored at the
        // root (Unix `/foo`) or at a drive (Windows `C:/foo`). For a
        // drive-letter path we keep the `C:` segment in the stack so
        // the rebuilt string still stems from that drive.
        let isUnixAbsolute = normalized.hasPrefix("/")
        var stack: [String] = []
        var driveRoot: String?
        var saw: [Substring] = normalized.split(
            separator: "/", omittingEmptySubsequences: true)
        #if os(Windows)
        // Detect a leading `C:` segment (drive root). After we
        // record it, the rest of the segments are walked as if the
        // path were absolute beneath that drive.
        if let first = saw.first,
           first.count == 2,
           let firstChar = first.first, firstChar.isLetter,
           first.last == ":" {
            driveRoot = String(first)
            saw = Array(saw.dropFirst())
        }
        #endif
        let anchored = isUnixAbsolute || driveRoot != nil
        for seg in saw {
            switch seg {
            case ".":
                continue
            case "..":
                // For anchored paths, `..` at the root stays at the
                // root. For relative paths we let `..` underflow as
                // a literal segment so callers can preserve the
                // user's intent (rare in practice).
                if !stack.isEmpty, stack.last != ".." {
                    stack.removeLast()
                } else if !anchored {
                    stack.append("..")
                }
            default:
                stack.append(String(seg))
            }
        }
        if let driveRoot {
            return driveRoot + "/" + stack.joined(separator: "/")
        }
        if isUnixAbsolute {
            return "/" + stack.joined(separator: "/")
        }
        return stack.isEmpty ? "." : stack.joined(separator: "/")
    }
}

extension Shell {

    // MARK: - Path resolution

    /// Resolve a (possibly relative) path string into the absolute
    /// `URL` to do real I/O on, honouring the shell's current working
    /// directory and — under a path-mapped sandbox — translating the
    /// virtual spelling to the host directory that backs it.
    ///
    /// Relative paths resolve against ``environment``'s
    /// ``Environment/workingDirectory``. When the bound sandbox
    /// carries a ``Sandbox/pathMapping`` (the cooperative-sandbox
    /// case: the script-visible path space is virtual), the resolved
    /// path is then routed through the mount table, so `/tmp/x`
    /// comes back as the per-instance host temp dir's `x` — ready
    /// for `FileManager` / C APIs and for ``Sandbox/authorize(_:)``,
    /// which gates the same host space. Without a mapping the result
    /// is the path as given (absolute) or CWD-joined (relative),
    /// unchanged from how it always worked.
    ///
    /// The returned URL is for *doing I/O*, not for *showing to the
    /// script* — display output should keep the user's own spelling
    /// or fold a host path back through
    /// ``displayPath(for:)-swift.method`` so the embedder's host
    /// layout never leaks into the sandbox.
    ///
    /// Under a mapping, a path that matches **no** mount — `/etc/x`,
    /// or the *host* spelling of a mounted directory (guessed, or
    /// leaked through some diagnostic) — never comes back as given:
    /// it resolves to a voided location under
    /// ``unmappedPathSentinel`` that cannot exist on disk and that
    /// ``Sandbox/authorize(_:)`` rejects. Script-visible text is the
    /// only addressing scheme inside the virtual namespace; if host
    /// spellings passed through here, anyone holding the host path
    /// of a mount could sidestep the no-host-paths boundary (the
    /// containment boundary would hold, the namespace one wouldn't —
    /// and bash's mounted filesystem, which ENOENTs those spellings,
    /// would disagree with this facade).
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
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            #if os(Windows)
            if path.count >= 2,
               let second = path.dropFirst().first, second == ":" {
                // Drive-letter absolutes live outside the unix-style
                // virtual namespace; under a mapping they fall through
                // to the unmapped sentinel below.
                let driveURL = URL(fileURLWithPath: path)
                guard sandbox?.pathMapping != nil else { return driveURL }
                return Self.voidedUnmappedPath(path)
            }
            #endif
            let cwd = environment.workingDirectory
            if cwd.isEmpty {
                // Host-process CWD fallback. Without a mapping this
                // is the standalone-CLI behaviour. With one, an empty
                // embedder CWD is a misconfiguration — the host-CWD
                // join would produce exactly the kind of host-space
                // path the namespace must not honour, so it voids.
                let hostJoined = URL(
                    fileURLWithPath: FileManager.default.currentDirectoryPath,
                    isDirectory: true)
                    .appendingPathComponent(path)
                guard let mapping = sandbox?.pathMapping else {
                    return hostJoined
                }
                if let translated = mapping.hostPath(forVirtual: hostJoined.path) {
                    return URL(fileURLWithPath: translated.host)
                }
                return Self.voidedUnmappedPath(hostJoined.path)
            }
            url = URL(fileURLWithPath: cwd, isDirectory: true)
                .appendingPathComponent(path)
        }
        guard let mapping = sandbox?.pathMapping else {
            // No mapping: the resolution is the path itself, exactly
            // as it always worked.
            return url
        }
        guard let translated = mapping.hostPath(forVirtual: url.path) else {
            // Mapping present but no mount matches: the path does not
            // exist in the virtual namespace. Void it — never hand
            // back text that the host (or the gate) could interpret
            // as a real location.
            return Self.voidedUnmappedPath(url.path)
        }
        return URL(fileURLWithPath: translated.host)
    }

    /// Resolve `path` against ``current``'s working directory.
    /// Equivalent to `Shell.current.resolve(path)`; provided for
    /// call-site convenience.
    public static func resolve(_ path: String) -> URL {
        current.resolve(path)
    }

    /// Prefix under which ``resolve(_:)`` voids paths that exist in
    /// no mount of the bound mapping. Rooted under `/dev/null` — a
    /// *file* on every POSIX host — so nothing below it can exist or
    /// be created (`mkdir -p` included), and no sane mount table
    /// roots a host directory there; ``Sandbox/authorize(_:)``'s
    /// containment check rejects it like any other out-of-roots path.
    /// The original (virtual) spelling rides along as the suffix so a
    /// stray diagnostic stays debuggable, and
    /// ``displayPath(for:)-swift.method`` folds it back out.
    public static let unmappedPathSentinel = "/dev/null/unmapped"

    /// Build the voided URL for an absolute path that matched no
    /// mount. Lexically normalised first so the sentinel can't be
    /// `..`-escaped back out of `/dev/null`.
    private static func voidedUnmappedPath(_ path: String) -> URL {
        var normalized = normalizePath(path)
        if !normalized.hasPrefix("/") { normalized = "/" + normalized }
        return URL(fileURLWithPath: unmappedPathSentinel + normalized)
    }

    // MARK: - Display paths

    /// Fold a host filesystem path back to its virtual spelling for
    /// display, when the bound sandbox carries a
    /// ``Sandbox/pathMapping``. The inverse of ``resolve(_:)``:
    /// `resolve` is for doing I/O, `displayPath` is for anything the
    /// script gets to *see* — `realpath`-style answers, `--absolute-path`
    /// output, `os.tmpdir()`, diagnostics that embed a resolved path.
    /// Returns `path` unchanged when no mapping is bound or the path
    /// doesn't fall under any mount (nothing to hide).
    ///
    /// Voided paths (``unmappedPathSentinel``) fold back to the
    /// virtual spelling they were built from, so a diagnostic that
    /// routes through here shows the script its own path, not the
    /// sentinel.
    public func displayPath(for path: String) -> String {
        guard let mapping = sandbox?.pathMapping else { return path }
        if path == Self.unmappedPathSentinel {
            return "/"
        }
        if path.hasPrefix(Self.unmappedPathSentinel + "/") {
            return String(path.dropFirst(Self.unmappedPathSentinel.count))
        }
        guard let virtual = mapping.virtualPath(forHost: path) else {
            return path
        }
        return virtual
    }

    /// URL-form convenience for ``displayPath(for:)-swift.method``.
    public func displayPath(for url: URL) -> String {
        displayPath(for: url.path)
    }

    /// Fold `path` through ``current``'s mapping for display.
    public static func displayPath(for path: String) -> String {
        current.displayPath(for: path)
    }

    /// Fold `url` through ``current``'s mapping for display.
    public static func displayPath(for url: URL) -> String {
        current.displayPath(for: url)
    }
}

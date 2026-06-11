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

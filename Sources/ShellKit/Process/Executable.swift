import Foundation

/// How to locate the program to run when launching a subprocess.
///
/// Mirrors swift-subprocess's ``Subprocess.Executable`` so callers can
/// move between layers without translating types — SwiftScript's
/// `run(...)` bridge re-exports this directly. Lives in ShellKit so
/// consumers don't need a direct swift-subprocess dependency.
///
/// Two forms:
/// - ``name(_:)`` — plain command name (`"git"`, `"echo"`). The
///   launcher resolves it through `PATH` taken from the supplied
///   ``Environment``.
/// - ``path(_:)`` — fully-qualified path (`"/usr/bin/env"`). Used as-is.
public struct Executable: Sendable, Hashable {

    public enum Storage: Sendable, Hashable {
        case name(String)
        case path(String)
    }

    public let storage: Storage

    private init(_ storage: Storage) {
        self.storage = storage
    }

    /// Locate the executable by name; the launcher resolves it via
    /// `PATH`.
    public static func name(_ executableName: String) -> Executable {
        Executable(.name(executableName))
    }

    /// Locate the executable by absolute path.
    public static func path(_ filePath: String) -> Executable {
        Executable(.path(filePath))
    }

    /// The string form a user would type — name or path.
    public var description: String {
        switch storage {
        case .name(let n): return n
        case .path(let p): return p
        }
    }
}

/// Argument vector handed to a subprocess. Mirrors
/// swift-subprocess's ``Subprocess.Arguments`` — argv[0] (the program
/// name) is supplied automatically by the launcher; this collection
/// holds argv[1...] only.
public struct Arguments: Sendable, Hashable, ExpressibleByArrayLiteral {

    public typealias ArrayLiteralElement = String

    public let values: [String]

    public init(_ values: [String] = []) {
        self.values = values
    }

    public init(arrayLiteral elements: String...) {
        self.values = elements
    }
}

import Foundation

/// An error that says exactly what its command prints and how it exits.
///
/// A command that fails the way a real tool does (`fatal: …` on stderr,
/// exit 128) throws one of these from `run()`. A host shell prints
/// ``diagnostic`` to the command's stderr as it is and returns
/// ``exitStatus``, with no formatting of its own. ArgumentParser's
/// formatter, by contrast, would prefix the text with `Error: ` and exit
/// with 1.
public protocol CommandFailure: Error {
    /// What the command writes to stderr, line endings included.
    var diagnostic: String { get }
    /// The status the command exits with.
    var exitStatus: ExitStatus { get }
}

import Foundation
import Testing
@testable import ShellKit

/// ``InputSource/isCanonicalEmpty`` — the "did the shell attach real
/// input?" probe used by commands with read-stdin-or-walk-cwd
/// behaviour (rg's no-path default).
@Suite struct InputSourceCanonicalEmptyTests {

    @Test func canonicalEmptyAnswersTrue() {
        #expect(InputSource.empty.isCanonicalEmpty)
        // Copies share the cursor, so the marker survives passing
        // the source around by value.
        let copy = InputSource.empty
        #expect(copy.isCanonicalEmpty)
    }

    @Test func attachedSourcesAnswerFalse() {
        #expect(!InputSource.string("x").isCanonicalEmpty)
        // Deliberately attached zero-byte input is NOT canonical —
        // bash's `true | cmd` hands cmd a real (empty) pipe, and a
        // command must read it (and see EOF), not walk the cwd.
        #expect(!InputSource.string("").isCanonicalEmpty)
        #expect(!InputSource.data(Data()).isCanonicalEmpty)
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        continuation.finish()
        #expect(!InputSource(bytes: stream).isCanonicalEmpty)
    }
}

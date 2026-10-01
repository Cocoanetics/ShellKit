import Testing
@testable import ShellKit

@Suite struct PathNormalizationTests {

    @Test func preservesEmptyPath() {
        #expect(Shell.normalizePath("") == "")
    }

    @Test func normalizesRelativePathSegments() {
        #expect(Shell.normalizePath("foo/./bar/../baz") == "foo/baz")
        #expect(Shell.normalizePath("foo//bar/") == "foo/bar")
        #expect(Shell.normalizePath("../../foo/../bar") == "../../bar")
    }

    @Test func normalizesAbsolutePathSegments() {
        #expect(Shell.normalizePath("/foo/./bar/../baz") == "/foo/baz")
        #expect(Shell.normalizePath("/../../foo") == "/foo")
        #expect(Shell.normalizePath("/") == "/")
    }

    #if !os(Windows)
    @Test func collapsesMultipleLeadingSlashesOnPOSIX() {
        #expect(Shell.normalizePath("//foo///bar") == "/foo/bar")
    }
    #endif

    #if os(Windows)
    @Test func preservesDriveRoot() {
        #expect(Shell.normalizePath(#"C:\Users\foo\..\bar"#) == "C:/Users/bar")
        #expect(Shell.normalizePath(#"C:\.."#) == "C:/")
    }

    @Test func preservesUNCRoot() {
        #expect(Shell.normalizePath(#"\\server\share\x\.."#) == "//server/share")
        #expect(Shell.normalizePath("//server/share/file") == "//server/share/file")
        #expect(Shell.normalizePath("//server/share/../../file") == "//server/share/file")
    }

    @Test func preservesExtendedUNCRoot() {
        #expect(
            Shell.normalizePath(#"\\?\UNC\server\share\dir\.."#)
                == "//?/UNC/server/share")
        #expect(
            Shell.normalizePath(#"\\?\UNC\server\share\..\file"#)
                == "//?/UNC/server/share/file")
    }
    #endif
}

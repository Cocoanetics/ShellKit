import Foundation
import Testing
@testable import ShellKit

/// The virtual↔host mapping core (#SwiftBash 83): lexical
/// translation through the mount table in both directions, plus the
/// two doors over it — `Shell.resolve` (virtual → host, for I/O) and
/// `Shell.displayPath` (host → virtual, for output) — and the
/// `Sandbox.confined(to:)` gate that authorizes the same host space
/// `resolve` produces.
@Suite(.timeLimit(.minutes(1))) struct PathMappingTests {

    // MARK: - Fixtures

    /// On-disk workspace + per-instance temp dir, shaped like the
    /// SwiftBash CLI's `--sandbox <dir>` setup. Caller removes both.
    private static func makeRoots() throws -> (workspace: URL, temp: URL) {
        let base = FileManager.default.temporaryDirectory
        let workspace = base.appendingPathComponent(
            "shellkit-ws-\(UUID().uuidString)", isDirectory: true)
        let temp = base.appendingPathComponent(
            "shellkit-tmp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: temp, withIntermediateDirectories: true)
        return (workspace, temp)
    }

    private static func mapping(workspace: URL, temp: URL) -> PathMapping {
        PathMapping(mounts: [
            .init(virtual: "/batch", host: workspace.path),
            .init(virtual: "/tmp", host: temp.path)
        ])
    }

    // MARK: - Virtual → host translation

    @Test func translatesUnderEachMount() throws {
        let (workspace, temp) = try Self.makeRoots()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: temp)
        }
        let mapping = Self.mapping(workspace: workspace, temp: temp)

        #expect(mapping.hostPath(forVirtual: "/batch/a/b.txt")?.host
                == workspace.path + "/a/b.txt")
        #expect(mapping.hostPath(forVirtual: "/tmp/x")?.host
                == temp.path + "/x")
        // The mount point itself maps to the host root.
        #expect(mapping.hostPath(forVirtual: "/batch")?.host
                == workspace.path)
        #expect(mapping.hostPath(forVirtual: "/tmp/")?.host
                == temp.path)
    }

    @Test func longestVirtualPrefixWins() {
        let mapping = PathMapping(mounts: [
            .init(virtual: "/", host: "/host/root"),
            .init(virtual: "/tmp", host: "/host/tmp")
        ])
        #expect(mapping.hostPath(forVirtual: "/tmp/f")?.host == "/host/tmp/f")
        #expect(mapping.hostPath(forVirtual: "/tmpfoo")?.host
                == "/host/root/tmpfoo")
        #expect(mapping.hostPath(forVirtual: "/other")?.host
                == "/host/root/other")
        #expect(mapping.hostPath(forVirtual: "/")?.host == "/host/root")
    }

    @Test func dotDotCollapsesBeforeRouting() {
        let mapping = PathMapping(mounts: [
            .init(virtual: "/batch", host: "/host/ws"),
            .init(virtual: "/tmp", host: "/host/tmp")
        ])
        // `..` crossing from one mount into another routes to the
        // OTHER mount — never to a host path outside both.
        #expect(mapping.hostPath(forVirtual: "/tmp/../batch/f")?.host
                == "/host/ws/f")
        // `..` above the root stays at the root (no mount → nil).
        #expect(mapping.hostPath(forVirtual: "/batch/../../etc") == nil)
    }

    @Test func unmappedAndRelativePathsReturnNil() {
        let mapping = PathMapping(mounts: [
            .init(virtual: "/batch", host: "/host/ws")
        ])
        #expect(mapping.hostPath(forVirtual: "/etc/passwd") == nil)
        #expect(mapping.hostPath(forVirtual: "/") == nil)
        #expect(mapping.hostPath(forVirtual: "relative/path") == nil)
        // Prefix sibling: `/batchwork` must not match `/batch`.
        #expect(mapping.hostPath(forVirtual: "/batchwork/f") == nil)
    }

    @Test func readOnlyFlagRidesAlong() {
        let mapping = PathMapping(mounts: [
            .init(virtual: "/ro", host: "/host/ro", readOnly: true),
            .init(virtual: "/rw", host: "/host/rw")
        ])
        #expect(mapping.hostPath(forVirtual: "/ro/f")?.mount.readOnly == true)
        #expect(mapping.hostPath(forVirtual: "/rw/f")?.mount.readOnly == false)
        // Display order is by virtual path, not specificity.
        #expect(mapping.mountList.map(\.virtual) == ["/ro", "/rw"])
    }

    // MARK: - Host → virtual folding

    @Test func foldsHostPathsBackToVirtual() throws {
        let (workspace, temp) = try Self.makeRoots()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: temp)
        }
        let mapping = Self.mapping(workspace: workspace, temp: temp)

        #expect(mapping.virtualPath(forHost: temp.path + "/probe/f.txt")
                == "/tmp/probe/f.txt")
        #expect(mapping.virtualPath(forHost: workspace.path) == "/batch")
        // Symlink-resolved spelling folds too (macOS reports temp
        // paths behind `/var` → `/private/var` in either form).
        let resolved = temp.resolvingSymlinksInPath().path
        #expect(mapping.virtualPath(forHost: resolved + "/f") == "/tmp/f")
        // Outside every mount: nothing to fold.
        #expect(mapping.virtualPath(forHost: "/etc/passwd") == nil)
    }

    @Test func foldPrefersLongestHostRoot() throws {
        // Nested host roots (the Linux case: per-instance temp dir
        // under `/tmp` with `/tmp` itself also mounted) fold to the
        // more specific mount.
        let (workspace, temp) = try Self.makeRoots()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: temp)
        }
        let nested = temp.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nested, withIntermediateDirectories: true)
        let mapping = PathMapping(mounts: [
            .init(virtual: "/outer", host: temp.path),
            .init(virtual: "/inner", host: nested.path)
        ])
        #expect(mapping.virtualPath(forHost: nested.path + "/f")
                == "/inner/f")
        #expect(mapping.virtualPath(forHost: temp.path + "/other")
                == "/outer/other")
    }

    // MARK: - Shell.resolve translation (Facade B, inbound)

    @Test func resolveTranslatesVirtualPathsUnderMapping() async throws {
        let (workspace, temp) = try Self.makeRoots()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: temp)
        }
        let mapping = Self.mapping(workspace: workspace, temp: temp)
        var env = Environment()
        env.workingDirectory = "/batch"
        let shell = Shell(environment: env)
        shell.sandbox = .confined(to: mapping, home: "/batch")

        // Absolute virtual paths translate through the table.
        #expect(shell.resolve("/tmp/scratch.txt").path
                == temp.path + "/scratch.txt")
        #expect(shell.resolve("/batch/data.json").path
                == workspace.path + "/data.json")
        // Relative paths resolve against the VIRTUAL cwd, then
        // translate.
        #expect(shell.resolve("data.json").path
                == workspace.path + "/data.json")
        #expect(shell.resolve("../tmp/x").path == temp.path + "/x")
        // Virtual paths outside every mount come back untranslated —
        // the gate denies them and the host reports them missing.
        #expect(shell.resolve("/etc/passwd").path == "/etc/passwd")

        // The static accessors agree under the binding.
        try await shell.withCurrent {
            #expect(Shell.resolve("/tmp/y").path == temp.path + "/y")
            #expect(Shell.currentDirectory.path == workspace.path)
        }
    }

    @Test func resolveWithoutMappingIsUnchanged() {
        var env = Environment()
        env.workingDirectory = "/virtual/cwd"
        let shell = Shell(environment: env)
        // No sandbox at all.
        #expect(shell.resolve("/tmp/x").path == "/tmp/x")
        #expect(shell.resolve("f").path == "/virtual/cwd/f")
        // A sandbox without a mapping (rooted) doesn't translate
        // either.
        shell.sandbox = .rooted(
            at: FileManager.default.temporaryDirectory)
        #expect(shell.resolve("/tmp/x").path == "/tmp/x")
    }

    // MARK: - Shell.displayPath folding (Facade B, outbound)

    @Test func displayPathFoldsHostToVirtual() async throws {
        let (workspace, temp) = try Self.makeRoots()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: temp)
        }
        let mapping = Self.mapping(workspace: workspace, temp: temp)
        let shell = Shell()
        shell.sandbox = .confined(to: mapping, home: "/batch")

        #expect(shell.displayPath(for: temp.path + "/f") == "/tmp/f")
        #expect(shell.displayPath(
            for: URL(fileURLWithPath: workspace.path + "/a/b"))
            == "/batch/a/b")
        // Round trip: resolve → displayPath is the identity on the
        // virtual spelling.
        #expect(shell.displayPath(for: shell.resolve("/tmp/round"))
                == "/tmp/round")
        // Unmapped host paths display as-is.
        #expect(shell.displayPath(for: "/usr/lib/x") == "/usr/lib/x")
        // Without a mapping, identity.
        let plain = Shell()
        #expect(plain.displayPath(for: temp.path) == temp.path)
    }
}

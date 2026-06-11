import Foundation
import Testing
@testable import ShellKit

/// The `Sandbox.confined(to:)` gate over a ``PathMapping`` —
/// Facade B's boundary (#SwiftBash 83): canonical containment under
/// the mapping's host roots, symlink-escape rejection, region/temp
/// derivation, and the network policy knobs. Translation mechanics
/// live in `PathMappingTests`.
@Suite(.timeLimit(.minutes(1))) struct SandboxConfinedTests {

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

    @Test func confinedAuthorizesHostSpaceOnly() async throws {
        let (workspace, temp) = try Self.makeRoots()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: temp)
        }
        let mapping = Self.mapping(workspace: workspace, temp: temp)
        let sandbox = Sandbox.confined(to: mapping, home: "/batch")

        // Host paths under either mount root pass — existing or not.
        try await sandbox.authorize(workspace.appendingPathComponent("new/file"))
        try await sandbox.authorize(temp)
        try await sandbox.authorize(temp.appendingPathComponent("probe.txt"))

        // The VIRTUAL spelling is not host space: a literal `/tmp/...`
        // (the host's shared temp dir!) or `/batch/...` is denied —
        // callers reach the gate with `Shell.resolve` output.
        await #expect(throws: Sandbox.Denial.self) {
            try await sandbox.authorize(URL(fileURLWithPath: "/tmp/leak"))
        }
        await #expect(throws: Sandbox.Denial.self) {
            try await sandbox.authorize(URL(fileURLWithPath: "/batch/f"))
        }
        // Outside both roots.
        await #expect(throws: Sandbox.Denial.self) {
            try await sandbox.authorize(URL(fileURLWithPath: "/etc/passwd"))
        }
        // Sibling/prefix collision: `<temp>extra` must not pass.
        await #expect(throws: Sandbox.Denial.self) {
            try await sandbox.authorize(
                URL(fileURLWithPath: temp.path + "extra"))
        }
        // The shared platform temp root is NOT authorized — only the
        // per-instance dir under it.
        await #expect(throws: Sandbox.Denial.self) {
            try await sandbox.authorize(
                FileManager.default.temporaryDirectory)
        }
    }

#if !os(Windows)
    @Test func confinedRejectsSymlinkEscape() async throws {
        // A link planted inside a mount pointing outside it resolves
        // out of every canonical host root → denied (the FileManager-
        // backed caller would otherwise follow it out of the sandbox).
        let (workspace, temp) = try Self.makeRoots()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: temp)
        }
        let link = temp.appendingPathComponent("escape-link").path
        try FileManager.default.createSymbolicLink(
            atPath: link, withDestinationPath: "/")
        let sandbox = Sandbox.confined(
            to: Self.mapping(workspace: workspace, temp: temp),
            home: "/batch")
        await #expect(throws: Sandbox.Denial.self) {
            try await sandbox.authorize(URL(fileURLWithPath: link))
        }
    }

    @Test func confinedAcceptsSymlinkSpelledMountRoot() async throws {
        // A mount whose host root is itself reached through a symlink
        // still authorizes: both sides canonicalise to the same
        // prefix.
        let (workspace, temp) = try Self.makeRoots()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: temp)
        }
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("shellkit-link-\(UUID().uuidString)")
            .path
        try FileManager.default.createSymbolicLink(
            atPath: link, withDestinationPath: temp.path)
        defer { try? FileManager.default.removeItem(atPath: link) }

        let mapping = PathMapping(mounts: [
            .init(virtual: "/batch", host: workspace.path),
            .init(virtual: "/tmp", host: link)
        ])
        let sandbox = Sandbox.confined(to: mapping, home: "/batch")
        try await sandbox.authorize(
            URL(fileURLWithPath: link).appendingPathComponent("f"))
        try await sandbox.authorize(temp.appendingPathComponent("f"))
    }
#endif

    @Test func confinedRegionsAndTempDerivation() throws {
        let (workspace, temp) = try Self.makeRoots()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: temp)
        }
        let mapping = Self.mapping(workspace: workspace, temp: temp)

        // temporaryDirectory defaults to the `/tmp` mount's host root.
        let sandbox = Sandbox.confined(to: mapping, home: "/batch")
        #expect(sandbox.temporaryDirectory.standardizedFileURL.path
                == temp.standardizedFileURL.path)
        // The home mount's host root anchors home/user regions —
        // the workspace IS the user's home.
        #expect(sandbox.homeDirectory.standardizedFileURL.path
                == workspace.standardizedFileURL.path)
        #expect(sandbox.userDirectory.standardizedFileURL.path
                == workspace.standardizedFileURL.path)
        // The mapping rides on the sandbox for the resolve facade.
        #expect(sandbox.pathMapping?.mounts.count == 2)

        // Explicit override wins.
        let custom = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-\(UUID().uuidString)")
        let overridden = Sandbox.confined(
            to: mapping, home: "/batch", temporaryDirectory: custom)
        #expect(overridden.temporaryDirectory == custom)
    }

    @Test func confinedNetworkPolicy() async throws {
        let (workspace, temp) = try Self.makeRoots()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: temp)
        }
        let mapping = Self.mapping(workspace: workspace, temp: temp)

        // Default: non-file URLs denied.
        let offline = Sandbox.confined(to: mapping, home: "/batch")
        await #expect(throws: Sandbox.Denial.self) {
            try await offline.authorize(URL(string: "https://example.com/")!)
        }

        // allowedHosts admits matching hosts.
        let allowing = Sandbox.confined(
            to: mapping, home: "/batch",
            allowedHosts: ["api.example.com"])
        try await allowing.authorize(
            URL(string: "https://api.example.com/v1")!)

        // authorizeNetwork override routes non-file URLs; file URLs
        // keep using the mapping gate.
        struct Blocked: Error {}
        let custom = Sandbox.confined(
            to: mapping, home: "/batch",
            authorizeNetwork: { _ in throw Blocked() })
        await #expect(throws: Blocked.self) {
            try await custom.authorize(URL(string: "https://x.example/")!)
        }
        try await custom.authorize(temp.appendingPathComponent("ok"))
    }
}

// swift-tools-version:6.0
import PackageDescription

// ShellKit — the virtualized shell-environment abstraction.
//
// Owns every surface that an in-process bash interpreter (or any other
// shell host) needs to virtualise so that command implementations can
// be written against ONE contract and run unchanged in two modes:
//
//   1. Virtualised — running under an embedder (SwiftBash, swift-js,
//      SwiftScript, …) that has bound a custom `Shell` for the
//      current Task. IO routes through the embedder's sinks/sources;
//      env, FS, network, and process state come from the embedder.
//
//   2. Passthrough — running as a standalone CLI (`swift run gh …`).
//      `Shell.current` defaults to a process-bound implementation
//      that wraps `FileHandle.standard*`, `FileManager.default`,
//      `ProcessInfo.processInfo`, etc. Same code path as virtualised
//      mode; only the bindings differ.
//
// What lives here:
//   • IO primitives (OutputSink, InputSource).
//   • Environment (variables, working directory, positional args).
//   • Sandbox (URL/path gate, region directories).
//   • NetworkConfig + helpers (URL allow-list, secure fetcher,
//     private-IP detection).
//   • ProcessTable + HostInfo (virtual PIDs, identity reporting).
//   • Command protocol + BinCatalog (registry + virtual /bin paths).
//   • ExitStatus.
//   • ParsableShellCommand (ArgumentParser bridge that routes through
//     `Shell.current` instead of `FileHandle.standard*`).
//
// What does NOT live here:
//   • Bash language: parser, interpreter, control flow, expansion,
//     bash-specific builtins. That stays in SwiftBash.
//   • Other shell-language interpreters. They live in their own
//     packages and consume ShellKit.
//
// Direct consumers:
//   • SwiftBash      — implements the bash interpreter on top.
//   • SwiftPorts     — implements `gh` / `glab` / `git` / `jq` /
//                      `tar` / `zip` / compression CLIs against
//                      `Shell.current`.
//   • SwiftScript    — same pattern, different language at the top.
//
// Platform floor matches SwiftBash and swift-archive (macOS 13 /
// iOS 16 / tvOS 16 / watchOS 9). No source uses `@available` gates
// or APIs newer than that floor; raise the bound only when adding
// something that genuinely requires it.

let package = Package(
    name: "ShellKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "ShellKit", targets: ["ShellKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser",
                 from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "ShellKit",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/ShellKit"
        ),
        .testTarget(
            name: "ShellKitTests",
            dependencies: ["ShellKit"],
            path: "Tests/ShellKitTests"
        ),
    ]
)

// swift-tools-version:6.1
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
//
// Split into the sibling `ShellCommandKit` product (NOT core ShellKit):
//   • ParsableCommandBridge + `Shell.register(_:)` — the ArgumentParser
//     bridge that routes through `Shell.current`. Lives apart so core
//     ShellKit carries no ArgumentParser dependency, keeping it (and
//     every SDK library that imports it) off ArgumentParser's module
//     graph entirely.
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
        // ArgumentParser bridge, split out so core ShellKit (and every
        // SDK library that imports it) carries ZERO ArgumentParser
        // dependency. Only command-layer embedders that register
        // `ParsableCommand` types need this.
        .library(name: "ShellCommandKit", targets: ["ShellCommandKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser",
                 from: "1.3.0"),
        // Pinned to 0.4.x until 1.0 ships. See issue #1 for context.
        // Explicit traits — opt OUT of `SubprocessSpan` because
        // ShellKit doesn't use the Span-based overloads, and enabling
        // them links a back-deployment shim
        // (`libswiftCompatibilitySpan.dylib`) whose @rpath isn't on
        // SwiftPM's test runtime search path on macOS 13–15. We do
        // keep `SubprocessFoundation` (default-on) because
        // ``DefaultProcessLauncher`` reads its captured byte buffers
        // through Foundation's `Data`.
        .package(url: "https://github.com/swiftlang/swift-subprocess",
                 .upToNextMinor(from: "0.4.0"),
                 traits: ["SubprocessFoundation"]),
    ],
    targets: [
        .target(
            name: "ShellKit",
            dependencies: [
                // swift-subprocess pins iOS / tvOS / watchOS to "99.0" — kernel
                // bans posix_spawn / fork there, so the dep is conditionally
                // linked only on platforms where real exec is possible.
                // ``DefaultProcessLauncher`` falls back to throwing
                // ``ProcessLaunchUnsupportedOnThisPlatform`` on the rest.
                .product(name: "Subprocess", package: "swift-subprocess",
                         condition: .when(platforms: [
                            .macOS, .linux, .windows, .android,
                         ])),
            ],
            path: "Sources/ShellKit"
        ),
        // ParsableCommandBridge + `Shell.register(_:)` — the only
        // ArgumentParser-touching surface. Kept out of core ShellKit so
        // importing ShellKit never drags ArgumentParser (and its libc
        // overlay edges) into a consumer's module graph.
        .target(
            name: "ShellCommandKit",
            dependencies: [
                "ShellKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/ShellCommandKit"
        ),
        .testTarget(
            name: "ShellKitTests",
            // ShellCommandKit for `Shell.register(_:)` (the ArgumentParser
            // bridge moved out of core ShellKit).
            dependencies: ["ShellKit", "ShellCommandKit"],
            path: "Tests/ShellKitTests"
        ),
    ]
)

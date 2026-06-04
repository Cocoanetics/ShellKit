# ShellKit

A virtualised shell-environment abstraction for Swift.

ShellKit owns the entire surface that an in-process shell host
(SwiftBash, SwiftScript, swift-js, …) needs to virtualise so command
implementations can be written *once* and run unchanged in two modes:

1. **Virtualised** — under an embedder. The embedder constructs a
   `Shell` with custom IO sinks, a confined `Sandbox`, an enforced
   `NetworkConfig`, etc., and binds it onto the current Task. Every
   read of `Shell.current` inside the binding sees the embedder's
   plumbing.

2. **Passthrough** — running standalone (`swift run somecommand …`).
   Nothing is bound. `Shell.current` lazily returns
   `Shell.processDefault` — stdio wraps `FileHandle.standard*`,
   environment mirrors `ProcessInfo.processInfo.environment`, host
   identity is `HostInfo.real()`, sandbox/network policy are `nil`
   (no enforcement).

Same command body, both modes. That's the contract.

## What lives here

| Surface | Purpose |
|---|---|
| `OutputSink` / `InputSource` | Streaming byte-oriented stdio. AsyncStream-backed, with `.bytes` / `.lines` / `readAllString()` consumers. |
| `Environment` | Variables (scalar / indexed / associative arrays), working directory, positional args. Mutable; commands `export` / `cd` and the changes stick. |
| `Sandbox` | URL/path/host gate plus 12 typed region directories (Documents, Downloads, Caches, …). `rooted(at:)` / `appContainer(id:)` factories, or hand-rolled `init` for custom layouts. |
| `NetworkConfig` + `URLAllowList` + `SecureFetcher` + `PrivateIP` + `URLSessionFetcher` | HTTP policy (origin / path-prefix allow-list, method gating, header transforms, redirect-chain re-validation, private-IP guard, body-size cap). |
| `HostInfo` | Identity reported by `whoami` / `hostname` / `id` / `uname`. `.synthetic` (anonymous) and `.real()` factories. |
| `ProcessTable` | Virtual PID table — backgrounded `&` jobs, `ps` / `kill` / `pgrep` / `pkill` operate against this; **not** the host's real process table. |
| `Command` + `ClosureCommand` | Command protocol; Shell's registry dispatches by name. |
| `BinCatalog` | Canonical macOS-shaped paths (`/bin/cat`, `/usr/bin/grep`, `/usr/local/bin/rg`) used by `which` / `type` / `command -v`. |
| `Shell.register(_:)` | ArgumentParser bridge — register any `AsyncParsableCommand` (or `ParsableCommand`) on a `Shell` and dispatch by name. The command's `run()` reads from / writes to `Shell.current`. |
| `Shell` | The central `@TaskLocal` context. Mutable class. Holds all of the above. `withCurrent { … }` binds for a Task scope. |
| `ExitStatus` | POSIX-compatible exit code wrapper. |

## What does NOT live here

- **Bash language**: parser, interpreter, control flow, expansion,
  bash-specific builtins. That's [SwiftBash](https://github.com/Cocoanetics/SwiftBash).
- **Other shell-language interpreters**. They live in their own
  packages and consume ShellKit.
- **Tool implementations** (`gh`, `git`, `tar`, `jq`, …). Those live
  in [SwiftPorts](https://github.com/Cocoanetics/SwiftPorts) and
  build their command structs against ShellKit.

## Identity (`HostInfo`)

`HostInfo` is what `whoami` / `id` / `hostname` / `uname` report. There
are two factories, and which one is the default depends on the
construction path **by design**:

- **`.synthetic`** — anonymous, stable values that leak nothing about
  the host. The default for any `Shell` you construct yourself
  (`Shell(…)`), and what anything sandboxed keeps.
- **`.real()`** — the host's actual login name / uid / gid / `uname`.
  The default for the passthrough `Shell.processDefault` *only* — i.e. a
  standalone `swift run sometool`, where the user is running their own
  tool on their own machine and expects `whoami` to print their login
  name.

So an explicitly-constructed `Shell` is synthetic while the implicit
passthrough shell is real. These are intentional opposites, not a
contradiction.

### The synthetic OS identity is a deliberate hybrid

`.synthetic` reports a **Darwin kernel identity over a generic Unix
layout**:

| Field | Value |
|---|---|
| `uname` sysname / release / version / machine | `Darwin` / `0.0.0` / `swift-bash` / `arm64` |
| node (hostname) | `sandbox` |
| user / uid / group / gid | `user` / `1000` / `users` / `1000` |

So `uname -a` prints `Darwin sandbox 0.0.0 swift-bash arm64`, and a
consumer such as SwiftBash derives `$OSTYPE=darwin` /
`$MACHTYPE=arm64-apple-darwin` from these fields. But the filesystem an
embedder presents around it is a neutral POSIX tree (`/bin`, `/usr/bin`,
`/home/user`) — it is **not** a faithful macOS (no `/System`, no real
Darwin version) and **not** a Linux (`uname` would say `Linux`).

Treat it as a **custom virtual Unix**: a Darwin-flavoured kernel
identity on a generic POSIX layout. Embedders that want a different
shape build their own `HostInfo` and assign it to `Shell.hostInfo`.

## Quick example

The same `AsyncParsableCommand` runs in both modes — no parallel
protocol, no rewriting:

```swift
import ArgumentParser
import ShellKit

public struct Greet: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "greet",
        abstract: "Print a friendly hello.",
        version: "0.1.0")

    @Argument public var name: String = "world"
    @Flag(name: .shortAndLong) public var loud: Bool = false

    public init() {}

    public func run() async throws {
        let msg = loud ? "HELLO \(name.uppercased())" : "hello \(name)"
        // Reads from `Shell.current` — under an embedder this is the
        // bound shell; standalone it's `Shell.processDefault` which
        // wraps `FileHandle.standardOutput`. Same code, both modes.
        Shell.current.stdout(msg + "\n")
    }
}
```

**Standalone** — exactly the ArgumentParser idiom; ShellKit isn't
even imported in the executable wrapper:

```swift
import GreetCommand   // wherever Greet is defined

@main struct Entry {
    static func main() async {
        await Greet.main()
    }
}
```

**Embedded** — an in-process shell registers the same type and
dispatches it with custom IO / env / sandbox:

```swift
import GreetCommand
import ShellKit

let captured = OutputSink()
let sandbox = Sandbox.rooted(at: tempDir, allowedHosts: ["api.github.com"])
let shell = Shell(
    stdout: captured,
    environment: Environment(variables: ["HOME": "/sandbox"]),
    sandbox: sandbox,
    hostInfo: .synthetic)
shell.register(Greet.self)

try await shell.withCurrent {
    // The shell hands the bridge the FULL argv — argv[0] is the
    // command name, set by the shell. The bridge strips it
    // internally before handing off to ArgumentParser.
    let cmd = shell.commands["greet"]!
    _ = try await cmd.run(["greet", "--loud", "Alice"])
}
captured.finish()
print(await captured.readAllString())   // → "HELLO ALICE\n"
```

`--help` / `--version` / parse errors / `throw ExitCode(_:)` all
work exactly as ArgumentParser specifies — the bridge translates
the conventions to ``ExitStatus`` instead of calling `exit()`.

## Status

Pre-1.0. The surface listed above is what shipped at v0.0.1. The
current consumers are SwiftBash and SwiftPorts; the abstraction is
designed to compose with any other shell-host package that wants to
embed CLI tools without forking processes.

## Platform support

macOS 13+ / iOS 16+ / tvOS 16+ / watchOS 9+ / Linux / Windows /
Android. The platform floor matches `swift-archive` (the heaviest
direct Apple dependency in the SwiftPorts ecosystem) and SwiftBash.

No `@available` gates in `Sources/`; raise the bound only when adding
something that genuinely requires it.

## License

MIT. See [LICENSE](LICENSE).

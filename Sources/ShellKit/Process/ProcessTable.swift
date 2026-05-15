import Foundation

/// In-memory virtual process table. Each `Shell` has one; backgrounded
/// commands (`cmd &`) and any other "spawn-like" operation register a
/// virtual PID here, with the underlying Swift `Task` retained so the
/// shell can `wait` on it or signal it.
///
/// **Crucially virtual.** PIDs are monotonic counters allocated by this
/// table — they do *not* correspond to host process IDs and the table
/// only knows about Tasks SwiftBash itself spawned. `ps` / `kill` /
/// `pgrep` / `pkill` operate on these entries; there is no path from
/// here to the real OS process table.
///
/// **Cancellation is cooperative.** `signal(_:)` calls `Task.cancel()`
/// on the entry's Task. The Task body must observe `Task.isCancelled`
/// (or be `await`-ing a cancellable primitive) to actually stop —
/// Swift Concurrency does not preempt CPU-bound code. That's the same
/// limitation as `kill -TERM` against a process ignoring SIGTERM.
public actor ProcessTable {

    /// One entry. Created when something spawns; promoted to `.exited`
    /// or `.failed` when the Task completes; never removed (so `$!`
    /// references survive after the Task is done, matching bash).
    public struct Entry: Sendable {
        // `Entry.State` is the meaningful name for callers; lifting it
        // out would lose that grouping without buying anything.
        // swiftlint:disable:next nesting
        public enum State: Sendable, Equatable {
            case running
            case exited(ExitStatus)
            case failed(message: String)
            case cancelled
        }
        public let pid: Int32
        public let command: String
        public let startedAt: Date
        public var state: State
    }

    private var nextPID: Int32
    private var entries: [Int32: Entry] = [:]
    /// Internal Tasks store the outcome (status + state) directly so
    /// errors never need to escape the Task boundary.
    private var tasks: [Int32: Task<TaskOutcome, Never>] = [:]
    /// Most-recently-spawned PID — what `$!` resolves to.
    public private(set) var lastBackgroundPID: Int32?

    public init(startingAt: Int32 = 1000) {
        self.nextPID = startingAt
    }

    /// Allocate a fresh virtual PID, register an `Entry`, and run
    /// `body` in a detached `Task`. The returned Task is retained by
    /// the table; `wait(pid:)` awaits it, `signal(pid:_:)` cancels it.
    ///
    /// `body` should run the command in its own subshell — use
    /// `Shell.current.copy()` then `withCurrent { … }` so the spawned
    /// Task has the right shell. The factory closure assembles that
    /// before this call.
    public func spawn(
        command: String,
        body: @Sendable @escaping () async throws -> ExitStatus
    ) -> Int32 {
        let pid = nextPID
        nextPID += 1
        entries[pid] = Entry(pid: pid, command: command,
                             startedAt: Date(), state: .running)
        // Wrap the body in an internal `Task<…, Never>` so errors
        // never escape. If a thrown error reached the unstructured
        // Task's value, Swift's runtime would log it to stderr as a
        // stray "Error: CancellationError()". Bottling the result as
        // a (status, state) pair keeps that quiet.
        let task = Task<TaskOutcome, Never> {
            do {
                let status = try await body()
                return TaskOutcome(status: status, state: .exited(status))
            } catch is CancellationError {
                return TaskOutcome(status: ExitStatus(143), state: .cancelled)
            } catch {
                return TaskOutcome(
                    status: ExitStatus(1),
                    state: .failed(message: String(describing: error)))
            }
        }
        tasks[pid] = task
        lastBackgroundPID = pid
        // Completion observer — flips entry state when the Task ends
        // so `ps` reports "exited" / "cancelled" without needing
        // `wait`.
        Task { [weak self] in
            let outcome = await task.value
            await self?.markFinished(pid: pid, state: outcome.state)
        }
        return pid
    }

    private struct TaskOutcome: Sendable {
        let status: ExitStatus
        let state: Entry.State
    }

    /// Await the Task at `pid`; returns its exit status, or the status
    /// of an entry that has already finished. Returns `nil` if `pid`
    /// is unknown.
    ///
    /// Reaps the entry on the way out — `bash`'s `wait $PID` makes that
    /// PID disappear from `jobs` / `ps` the moment it returns. Without
    /// the reap, completed jobs lingered forever as "Z"-state entries
    /// in `ps` output, and a subsequent `wait` on the same PID kept
    /// returning the stale status instead of "not a child of this
    /// shell".
    public func wait(pid: Int32) async -> ExitStatus? {
        if let entry = entries[pid] {
            switch entry.state {
            case .exited(let status):
                reap(pid: pid)
                return status
            case .failed:
                reap(pid: pid)
                return ExitStatus(1)
            case .cancelled:
                reap(pid: pid)
                return ExitStatus(143) // 128 + SIGTERM
            case .running: break // fall through and await
            }
        }
        guard let task = tasks[pid] else { return nil }
        let status = await task.value.status
        // The completion observer (`markFinished`) has already run by
        // the time the Task value is available, so the entry is in a
        // terminal state here — safe to reap.
        reap(pid: pid)
        return status
    }

    /// Wait for every recorded child entry. Returns the LAST awaited
    /// status — bash's `wait` (no args) returns 0 if there were no
    /// jobs, else the last child's status. Reaps each entry as it's
    /// awaited, matching real bash's "after `wait`, `jobs` is empty".
    ///
    /// Crucially, this includes children that already finished
    /// BEFORE `wait` was called. A common pattern is `(cmd) &; wait`
    /// where the spawned subshell can complete between the spawn and
    /// the wait — real bash still reports the finished child's exit
    /// status from `$?` because the parent hasn't reaped it yet.
    /// Filtering to `.running` here would lose that status and
    /// silently return 0 when the timing went the "spawn finished
    /// fast" way.
    public func waitAll() async -> ExitStatus {
        let pending = entries.keys.sorted()
        var last = ExitStatus.success
        for pid in pending {
            if let status = await wait(pid: pid) { last = status }
        }
        return last
    }

    /// Drop `pid`'s entry from the table. Used by `wait` after it
    /// hands back the exit status — once the caller has observed the
    /// final state, the entry is no longer interesting. Public so an
    /// embedder's REPL can auto-reap at the prompt boundary the way
    /// real bash does between commands.
    public func reap(pid: Int32) {
        guard let entry = entries[pid], entry.state != .running else { return }
        entries.removeValue(forKey: pid)
        tasks.removeValue(forKey: pid)
    }

    /// Sweep every finished entry. Real bash's interactive loop runs
    /// the equivalent at each prompt so old `&` jobs don't accumulate
    /// in `jobs` / `ps`. Embedders that drive a REPL can call this
    /// between commands; the non-interactive path doesn't need it
    /// because `wait` reaps as it goes.
    public func reapAllFinished() {
        for (pid, entry) in entries where entry.state != .running {
            entries.removeValue(forKey: pid)
            tasks.removeValue(forKey: pid)
        }
    }

    /// Cancel the Task at `pid`. Cooperative — the Task must observe
    /// cancellation. Returns `true` if the entry exists, regardless of
    /// whether the Task actually noticed.
    public func signal(pid: Int32, signo: Int32 = 15 /*SIGTERM*/) -> Bool {
        guard let task = tasks[pid] else { return false }
        task.cancel()
        return true
    }

    /// All entries, sorted by PID. Used by `ps`, `pgrep`, `jobs`.
    public func list() -> [Entry] {
        return entries.values.sorted { $0.pid < $1.pid }
    }

    /// Look up by PID. Used by `kill PID` to validate before signal.
    public func entry(for pid: Int32) -> Entry? {
        return entries[pid]
    }

    private func markFinished(pid: Int32, state: Entry.State) {
        if var entry = entries[pid] {
            // Don't overwrite a state we set deliberately (e.g. a
            // signal landing right at the same moment as natural exit).
            if case .running = entry.state {
                entry.state = state
                entries[pid] = entry
            }
        }
        // Drop the strong Task reference now that it's done.
        tasks.removeValue(forKey: pid)
    }
}

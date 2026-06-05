import Foundation
import Testing
@testable import ShellKit

/// Covers ``ProcessTable/register(command:pid:state:startedAt:)`` — the
/// affordance that lets a host seed an entry it didn't `spawn` (e.g. the
/// shell itself) so `ps` / `pgrep` can see it.
@Suite struct ProcessTableRegisterTests {

    @Test("register without a pid allocates a monotonic id and lists it")
    func registerAutoPID() async {
        let table = ProcessTable(startingAt: 1000)
        let pid = await table.register(command: "bash")
        #expect(pid == 1000)
        let list = await table.list()
        #expect(list.count == 1)
        #expect(list[0].pid == 1000)
        #expect(list[0].command == "bash")
        #expect(list[0].state == .running)
    }

    @Test("register with an explicit pid uses it without colliding later")
    func registerExplicitPID() async {
        let table = ProcessTable(startingAt: 1000)
        let pid = await table.register(command: "bash", pid: 1)
        #expect(pid == 1)
        // A subsequent auto-allocation stays in its own range and never
        // reuses the explicit id.
        let spawned = await table.spawn(command: "sleep") { ExitStatus.success }
        #expect(spawned >= 1000)
        #expect(spawned != 1)
        let entry = await table.entry(for: 1)
        #expect(entry?.command == "bash")
    }

    @Test("an explicit pid above the counter bumps it past itself")
    func registerHighPIDBumpsCounter() async {
        let table = ProcessTable(startingAt: 1000)
        _ = await table.register(command: "bash", pid: 5000)
        let spawned = await table.spawn(command: "x") { ExitStatus.success }
        #expect(spawned > 5000)
    }

    @Test("a running registered entry survives reapAllFinished")
    func registeredSelfPersists() async {
        let table = ProcessTable()
        _ = await table.register(command: "bash", pid: 1)
        await table.reapAllFinished()
        #expect(await table.entry(for: 1) != nil)
    }

    @Test("signal on a non-spawned entry returns false (nothing to cancel)")
    func signalRegisteredIsNoop() async {
        let table = ProcessTable()
        _ = await table.register(command: "bash", pid: 1)
        let signaled = await table.signal(pid: 1)
        #expect(signaled == false)
    }

    @Test("register over a spawned PID clears the task and stays non-spawned")
    func registerOverSpawnedPid() async {
        let table = ProcessTable(startingAt: 1000)
        // A backgrounded job that finishes on its own shortly.
        let pid = await table.spawn(command: "worker") {
            try? await Task.sleep(nanoseconds: 20_000_000)
            return ExitStatus.success
        }
        // Re-register the same pid as a non-spawned entry.
        _ = await table.register(command: "bash", pid: pid)
        // No backing task: signal is a no-op; the entry is the registered one.
        #expect(await table.signal(pid: pid) == false)
        #expect(await table.entry(for: pid)?.command == "bash")
        // Once the superseded task finishes, its stale completion observer
        // must NOT flip the registered entry to exited.
        try? await Task.sleep(nanoseconds: 80_000_000)   // > the 20ms job
        let entry = await table.entry(for: pid)
        #expect(entry?.command == "bash")
        #expect(entry?.state == .running)
    }

    @Test("a finished registered entry is reapable")
    func registeredFinishedReaps() async {
        let table = ProcessTable()
        _ = await table.register(command: "worker", pid: 7,
                                 state: .exited(.success))
        await table.reapAllFinished()
        #expect(await table.entry(for: 7) == nil)
    }
}

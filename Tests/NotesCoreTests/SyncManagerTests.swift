import Foundation
import NotesCore
import Testing

@MainActor
struct SyncManagerTests {
    @Test func manualByDefaultAndNoAutomaticFolderOrAccountConnection() async throws {
        try await fixture { defaults, clock, probe in
            let manager = SyncManager(defaults: defaults, now: { clock.date }, exchange: probe.run)
            #expect(!manager.schedule.enabled)
            #expect(!manager.connected)
            #expect(manager.nextAttempt == nil)
            manager.tick()
            manager.request()
            #expect(probe.calls == 0)
            manager.setConnected(true)
            clock.advance(86_400)
            manager.tick()
            #expect(probe.calls == 0)
            manager.request()
            await manager.waitForCurrentExchange()
            #expect(probe.calls == 1)
            #expect(manager.schedule.lastSuccess == clock.date)
            #expect(manager.nextAttempt == nil)
        }
    }

    @Test func intervalAndDueTimeSurviveRestartAndCatchUpOnlyOnce() async throws {
        try await fixture { defaults, clock, probe in
            let original = SyncManager(defaults: defaults, now: { clock.date }, exchange: probe.run)
            original.setConnected(true)
            original.configure(enabled: true, minutes: 30)
            let due = clock.date.addingTimeInterval(1800)
            #expect(original.nextAttempt == due)
            let restarted = SyncManager(defaults: defaults, now: { clock.date }, exchange: probe.run)
            #expect(restarted.schedule.enabled)
            #expect(restarted.schedule.minutes == 30)
            #expect(!restarted.connected)
            restarted.setConnected(true)
            #expect(restarted.nextAttempt == due)
            restarted.tick()
            #expect(probe.calls == 0)
            clock.advance(86_400)
            restarted.tick()
            await restarted.waitForCurrentExchange()
            restarted.tick()
            #expect(probe.calls == 1)
            #expect(restarted.nextAttempt == clock.date.addingTimeInterval(1800))
            let final = SyncManager(defaults: defaults, now: { clock.date }, exchange: probe.run)
            #expect(final.schedule.lastSuccess == clock.date)
            #expect(final.schedule.nextAttempt == restarted.nextAttempt)
        }
    }

    @Test func offlineAndErrorRetryDoNotClaimSuccessOrSpin() async throws {
        try await fixture { defaults, clock, probe in
            let manager = SyncManager(defaults: defaults, now: { clock.date }, exchange: probe.run)
            manager.setConnected(true)
            manager.configure(enabled: true, minutes: 15)
            manager.request()
            await manager.waitForCurrentExchange()
            let success = manager.schedule.lastSuccess
            probe.failure = .unavailable("Folder is not downloaded")
            clock.advance(900)
            manager.tick()
            await manager.waitForCurrentExchange()
            #expect(manager.status == .offline)
            #expect(manager.message.contains("not downloaded"))
            #expect(manager.schedule.lastSuccess == success)
            #expect(manager.nextAttempt == clock.date.addingTimeInterval(300))
            for _ in 0..<10 { manager.tick() }
            #expect(probe.calls == 2)
            clock.advance(299)
            manager.tick()
            #expect(probe.calls == 2)
            probe.failure = .failed("Checksum mismatch")
            clock.advance(1)
            manager.tick()
            await manager.waitForCurrentExchange()
            #expect(probe.calls == 3)
            #expect(manager.status == .failed)
            #expect(manager.schedule.lastSuccess == success)
            probe.failure = nil
            clock.advance(300)
            manager.tick()
            await manager.waitForCurrentExchange()
            #expect(manager.status == .idle)
            #expect(manager.schedule.lastSuccess == clock.date)
            #expect(manager.nextAttempt == clock.date.addingTimeInterval(900))
        }
    }

    @Test func manualAndScheduledRunsShareOneSlotEvenWhenCancelled() async throws {
        try await fixture { defaults, clock, probe in
            probe.hold = true
            let manager = SyncManager(defaults: defaults, now: { clock.date }, exchange: probe.run)
            manager.setConnected(true)
            manager.configure(enabled: true, minutes: 5)
            clock.advance(300)
            manager.tick()
            await probe.waitUntilStarted()
            manager.request()
            manager.tick()
            #expect(probe.calls == 1)
            manager.cancel()
            manager.request()
            #expect(manager.isRunning)
            #expect(manager.status == .cancelled)
            #expect(probe.calls == 1)
            probe.finish()
            await manager.waitForCurrentExchange()
            #expect(!manager.isRunning)
            #expect(manager.schedule.lastSuccess == nil)
            #expect(manager.nextAttempt == clock.date.addingTimeInterval(300))
            probe.hold = false
            manager.request()
            await manager.waitForCurrentExchange()
            #expect(probe.calls == 2)
            #expect(manager.schedule.lastSuccess == clock.date)
            clock.advance(299)
            manager.tick()
            #expect(probe.calls == 2)
        }
    }

    @Test func disconnectAndStopInvalidateInflightResultsWithoutReleasingSlotEarly() async throws {
        try await fixture { defaults, clock, probe in
            probe.hold = true
            let manager = SyncManager(defaults: defaults, now: { clock.date }, exchange: probe.run)
            manager.setConnected(true)
            manager.configure(enabled: true)
            manager.request()
            await probe.waitUntilStarted()
            manager.setConnected(false)
            #expect(manager.nextAttempt == nil)
            #expect(manager.isRunning)
            manager.tick()
            manager.request()
            probe.finish()
            await manager.waitForCurrentExchange()
            #expect(probe.calls == 1)
            #expect(manager.status == .disconnected)
            #expect(manager.schedule.lastSuccess == nil)
            manager.setConnected(true)
            manager.request()
            await probe.waitUntilStarted()
            manager.stop()
            probe.finish()
            await manager.waitForCurrentExchange()
            #expect(probe.calls == 2)
            #expect(manager.status == .cancelled)
            #expect(manager.schedule.lastSuccess == nil)
        }
    }

    @Test func disablingScheduleKeepsManualExchangeAndInvalidSettingsArePreservedUntilReset() async throws {
        try await fixture { defaults, clock, probe in
            let manager = SyncManager(defaults: defaults, now: { clock.date }, exchange: probe.run)
            manager.setConnected(true)
            manager.configure(enabled: true, minutes: 5)
            manager.configure(enabled: false)
            clock.advance(1000)
            manager.tick()
            #expect(probe.calls == 0)
            manager.request()
            await manager.waitForCurrentExchange()
            #expect(probe.calls == 1)
            #expect(manager.nextAttempt == nil)
            let damaged = Data("invalid settings".utf8)
            defaults.set(damaged, forKey: "folderSyncSchedule")
            let recovering = SyncManager(defaults: defaults, now: { clock.date }, exchange: probe.run)
            recovering.setConnected(true)
            recovering.configure(enabled: true)
            recovering.tick()
            #expect(!recovering.settingsAvailable)
            #expect(defaults.data(forKey: "folderSyncSchedule") == damaged)
            recovering.resetSchedule()
            #expect(recovering.settingsAvailable)
            #expect(!recovering.schedule.enabled)
            #expect(recovering.connected)
            #expect(defaults.object(forKey: "folderSyncSchedule") == nil)
            var unsupported = SyncSchedule()
            unsupported.enabled = true
            unsupported.version = 2
            let unknown = try JSONEncoder().encode(unsupported)
            defaults.set(unknown, forKey: "folderSyncSchedule")
            let unknownVersion = SyncManager(defaults: defaults, now: { clock.date }, exchange: probe.run)
            unknownVersion.setConnected(true)
            unknownVersion.tick()
            #expect(!unknownVersion.settingsAvailable)
            #expect(!unknownVersion.schedule.enabled)
            #expect(unknownVersion.nextAttempt == nil)
            #expect(unknownVersion.message.contains("automatic exchange is off"))
            #expect(probe.calls == 1)
            #expect(defaults.data(forKey: "folderSyncSchedule") == unknown)
        }
    }

    private func fixture(_ action: @MainActor (UserDefaults, TestSyncClock, ExchangeProbe) async throws -> Void) async throws {
        let suite = "DeltosSyncManagerTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try await action(defaults, TestSyncClock(), ExchangeProbe())
    }
}

@MainActor
private final class TestSyncClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { date.addTimeInterval(seconds) }
}

@MainActor
private final class ExchangeProbe {
    var calls = 0
    var failure: SyncFailure?
    var hold = false
    private var completion: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func run() async throws {
        calls += 1
        if hold {
            await withCheckedContinuation { continuation in
                completion = continuation
                started?.resume()
                started = nil
            }
        }
        if let failure { throw failure }
    }

    func waitUntilStarted() async {
        if completion != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        completion?.resume()
        completion = nil
    }
}

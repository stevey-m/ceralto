import Combine
import Foundation

public struct SyncSchedule: Codable, Equatable, Sendable {
    public var version = 1
    public var enabled = false
    public var minutes = 15
    public var lastSuccess: Date?
    public var nextAttempt: Date?
    public init() {}

    public static let intervals = [5, 15, 30, 60]

    func validate() throws {
        guard version == 1, Self.intervals.contains(minutes),
              lastSuccess?.timeIntervalSince1970.isFinite != false,
              nextAttempt?.timeIntervalSince1970.isFinite != false else {
            throw SyncFailure.failed("Saved sync settings are invalid. Reset the schedule to recover; your folder and notes are unchanged.")
        }
    }
}

public enum SyncFailure: LocalizedError, Sendable {
    case unavailable(String), deferred(String), failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message), .deferred(let message), .failed(let message): message
        }
    }
}

/// Serializes manual and scheduled local folder exchanges. A cancelled exchange holds
/// its slot until transport returns: synchronous file coordination cannot be interrupted.
@MainActor
public final class SyncManager: ObservableObject {
    public enum Status: String, Sendable {
        case disconnected = "Disconnected"
        case idle = "Ready"
        case running = "Exchanging locally"
        case offline = "Offline / unavailable locally"
        case failed = "Exchange failed"
        case deferred = "Retry needed"
        case cancelled = "Cancelled"
    }

    @Published public private(set) var schedule = SyncSchedule()
    @Published public private(set) var status: Status = .disconnected
    @Published public private(set) var message = "No shared folder connected. Local notes remain available offline."
    @Published public private(set) var isRunning = false
    @Published public private(set) var settingsAvailable = true
    @Published public private(set) var connected = false
    public var nextAttempt: Date? { settingsAvailable && connected && schedule.enabled ? schedule.nextAttempt : nil }

    private let defaults: UserDefaults
    private let key: String
    private let now: @MainActor () -> Date
    private let exchange: @MainActor () async throws -> Void
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var generation = 0

    public init(defaults: UserDefaults, key: String = "folderSyncSchedule",
                now: @escaping @MainActor () -> Date = Date.init,
                exchange: @escaping @MainActor () async throws -> Void) {
        self.defaults = defaults
        self.key = key
        self.now = now
        self.exchange = exchange
        do {
            if let stored = defaults.object(forKey: key) {
                guard let data = stored as? Data else { throw SyncFailure.failed("Saved sync settings are not valid data.") }
                schedule = try JSONDecoder().decode(SyncSchedule.self, from: data)
            }
            try schedule.validate()
        } catch {
            schedule = SyncSchedule()
            settingsAvailable = false
            message = "Sync schedule unavailable; automatic exchange is off. Saved settings are preserved. \(error.localizedDescription)"
        }
    }

    public func setConnected(_ value: Bool, newFolder: Bool = false) {
        if !value { cancel() }
        connected = value
        if newFolder {
            schedule.lastSuccess = nil
            schedule.nextAttempt = nil
        }
        if value, schedule.enabled, schedule.nextAttempt == nil {
            schedule.nextAttempt = now().addingTimeInterval(interval)
        }
        if !value { schedule.nextAttempt = nil }
        persist()
        if !isRunning {
            status = value ? .idle : .disconnected
            if settingsAvailable {
                message = value ? "Folder connected. Cloud upload and delivery are not verified by Ceralto." :
                    "Disconnected. All local notes and attachments are still here."
            }
        }
    }

    public func configure(enabled: Bool? = nil, minutes: Int? = nil) {
        guard settingsAvailable else { return }
        var candidate = schedule
        if let enabled { candidate.enabled = enabled }
        if let minutes { candidate.minutes = minutes }
        do { try candidate.validate() }
        catch { message = error.localizedDescription; return }
        candidate.nextAttempt = candidate.enabled && connected ?
            now().addingTimeInterval(Double(candidate.minutes) * 60) : nil
        schedule = candidate
        persist()
    }

    public func resetSchedule() {
        guard !isRunning else { return }
        defaults.removeObject(forKey: key)
        schedule = SyncSchedule()
        settingsAvailable = true
        message = "Manual sync only. Folder connection and notes are unchanged."
    }

    public func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        cancel()
    }

    public func tick() {
        guard settingsAvailable, connected, schedule.enabled, !isRunning,
              let due = nextAttempt, now() >= due else { return }
        request()
    }

    /// Also used by manual sync, which remains available when scheduling is off.
    public func request() {
        guard connected, !isRunning else { return }
        isRunning = true
        status = .running
        message = "Exchanging a verified local snapshot…"
        let token = generation
        task = Task { [weak self] in await self?.perform(token: token) }
    }

    public func cancel() {
        generation += 1
        task?.cancel()
        if isRunning {
            status = .cancelled
            message = "Cancelled. Waiting for in-flight file access to finish; its result will not replace local notes. Already-written snapshots may remain in the folder."
        }
    }

    public func waitForCurrentExchange() async {
        await task?.value
    }

    private var interval: TimeInterval { Double(schedule.minutes) * 60 }

    private func perform(token: Int) async {
        defer { isRunning = false; task = nil }
        do {
            try Task.checkCancellation()
            try await exchange()
            try Task.checkCancellation()
            guard token == generation, connected else { return }
            schedule.lastSuccess = now()
            status = .idle
            message = "Snapshot exchange completed locally. Cloud upload and delivery are not verified by Ceralto."
            schedule.nextAttempt = schedule.enabled ? now().addingTimeInterval(interval) : nil
        } catch {
            if token != generation || Task.isCancelled {
                status = connected ? .cancelled : .disconnected
            } else {
                switch error {
                case SyncFailure.unavailable: status = .offline
                case SyncFailure.deferred: status = .deferred
                default: status = .failed
                }
                message = "Local notes are safe. \(error.localizedDescription)"
            }
            // Retry unavailable folders, failed verification, and edits made during exchange
            // without a tight loop or pretending that an unsuccessful attempt was a success.
            schedule.nextAttempt = connected && schedule.enabled ?
                now().addingTimeInterval(min(interval, 300)) : nil
        }
        persist()
    }

    private func persist() {
        guard settingsAvailable else { return }
        do { defaults.set(try JSONEncoder().encode(schedule), forKey: key) }
        catch {
            settingsAvailable = false
            message = "Sync schedule could not be saved; scheduling is inactive. \(error.localizedDescription)"
        }
    }
}

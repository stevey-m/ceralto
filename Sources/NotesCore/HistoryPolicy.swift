import Foundation

public struct HistoryPolicy: Codable, Equatable, Sendable {
    public static let preferenceKey = "noteHistoryPolicy"
    public static let counts = [5, 20, 50, 100]
    public static let intervals = [60, 300, 900, 1_800]
    public static let standard = HistoryPolicy()
    public var version = 1
    public var enabled: Bool
    public var maximumCheckpoints: Int
    public var intervalSeconds: Int

    public init(enabled: Bool = true, maximumCheckpoints: Int = 20, intervalSeconds: Int = 300) {
        self.enabled = enabled
        self.maximumCheckpoints = maximumCheckpoints
        self.intervalSeconds = intervalSeconds
    }

    public func validate() throws {
        guard version == 1, Self.counts.contains(maximumCheckpoints), Self.intervals.contains(intervalSeconds) else {
            throw NoteWorkflowError("Unsupported note-history settings. Existing settings and checkpoints have been preserved.")
        }
    }

    public var summary: String {
        enabled
            ? "Up to \(maximumCheckpoints) checkpoints, captured at most once every \(intervalSeconds / 60) minute(s)."
            : "Automatic history is paused. Existing checkpoints are kept; restoring still saves your current text."
    }
}

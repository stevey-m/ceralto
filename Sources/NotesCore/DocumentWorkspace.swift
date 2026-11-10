import Foundation

/// Navigation is device-local and never part of a library export or sync snapshot.
public struct DocumentWorkspace: Codable, Equatable, Sendable {
    public private(set) var tabs: [UUID] = []
    public private(set) var activeID: UUID?
    public private(set) var referenceID: UUID?
    private var history: [UUID] = []
    private var position: Int = -1

    public init() {}

    public var canGoBack: Bool { position > 0 }
    public var canGoForward: Bool { position >= 0 && position + 1 < history.count }

    public mutating func setReference(_ id: UUID?) { referenceID = id }

    public mutating func select(_ id: UUID?, replacingCurrent: Bool = false) {
        if let id, !tabs.contains(id) {
            if replacingCurrent, let activeID, let index = tabs.firstIndex(of: activeID) {
                tabs[index] = id
            } else {
                tabs.append(id)
            }
        }
        activeID = id
        guard let id else { return }
        guard position < 0 || history[position] != id else { return }
        history = Array(history.prefix(position + 1))
        history.append(id)
        history = Array(history.suffix(100))
        position = history.count - 1
    }

    @discardableResult
    public mutating func goBack() -> UUID? {
        guard canGoBack else { return nil }
        position -= 1
        activateHistory()
        return activeID
    }

    @discardableResult
    public mutating func goForward() -> UUID? {
        guard canGoForward else { return nil }
        position += 1
        activateHistory()
        return activeID
    }

    public mutating func close(_ id: UUID) {
        guard let index = tabs.firstIndex(of: id) else { return }
        tabs.remove(at: index)
        if activeID == id {
            select(tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)])
        }
    }

    public mutating func retainNotes(_ validIDs: Set<UUID>) {
        tabs = tabs.filter { validIDs.contains($0) }
        let current = position >= 0 && position < history.count ? history[position] : nil
        let earlier = history.prefix(max(0, min(position, history.count))).filter { validIDs.contains($0) }.count
        history = history.filter { validIDs.contains($0) }
        position = history.isEmpty ? -1 : min(max(0, earlier - (current.map(validIDs.contains) == true ? 0 : 1)), history.count - 1)
        if let activeID, !tabs.contains(activeID) { self.activeID = tabs.first }
        if let referenceID, !validIDs.contains(referenceID) { self.referenceID = nil }
    }

    public func validate() throws {
        guard Set(tabs).count == tabs.count,
              history.count <= 100, position >= -1, position < history.count,
              history.isEmpty == (position == -1),
              activeID.map({ tabs.contains($0) }) ?? true else {
            throw LibraryError.invalidLibrary
        }
    }

    private mutating func activateHistory() {
        let id = history[position]
        if !tabs.contains(id) { tabs.append(id) }
        activeID = id
    }
}

import Foundation

public struct PaneWidths: Equatable, Sendable {
    public let notebooks: Double
    public let notes: Double
    public let document: Double
    public static let divider: Double = 8

    public init(available: Double, notebooks requestedNotebooks: Double = 220,
                notes requestedNotes: Double = 250, showNotebooks: Bool = true, showNotes: Bool = true) {
        let total = max(0, available)
        let dividers = Double((showNotebooks ? 1 : 0) + (showNotes ? 1 : 0)) * Self.divider
        let readableDocument = min(520, max(400, total - 296))
        var budget = max(0, total - readableDocument - dividers)
        let notebookMinimum = showNotebooks ? min(120, budget) : 0
        let noteMinimum = showNotes ? min(160, max(0, budget - notebookMinimum)) : 0
        let notebookWidth = showNotebooks
            ? min(max(notebookMinimum, requestedNotebooks), max(notebookMinimum, budget - noteMinimum)) : 0
        budget -= notebookWidth
        let noteWidth = showNotes ? min(max(noteMinimum, requestedNotes), max(0, budget)) : 0
        notebooks = notebookWidth
        notes = noteWidth
        document = max(0, total - dividers - notebookWidth - noteWidth)
    }
}

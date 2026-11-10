import NotesCore
import Testing

struct PaneWidthsTests {
    @Test func defaultNavigationStaysCompactAndNoteGetsRemainingSpace() {
        let widths = PaneWidths(available: 1240)
        #expect(widths.notebooks == 220)
        #expect(widths.notes == 250)
        #expect(widths.document == 754)
        let larger = PaneWidths(available: 1600)
        #expect(larger.notebooks == widths.notebooks)
        #expect(larger.notes == widths.notes)
        #expect(larger.document == 1114)
    }

    @Test(arguments: [720.0, 960.0, 1240.0, 1600.0])
    func oversizedNavigationCannotSqueezeDocument(available: Double) {
        let widths = PaneWidths(available: available, notebooks: 2000, notes: 2000)
        #expect(widths.document >= 400)
        if available >= 960 { #expect(widths.document >= 520) }
        #expect(widths.notebooks + widths.notes + widths.document + 16 == available)
    }

    @Test func hidingPanesReturnsSpaceToDocumentWithoutGrowingOtherNavigation() {
        let noNotebooks = PaneWidths(available: 1240, showNotebooks: false)
        #expect(noNotebooks.notes == 250)
        #expect(noNotebooks.document == 982)
        let noNotes = PaneWidths(available: 1240, showNotes: false)
        #expect(noNotes.notebooks == 220)
        #expect(noNotes.document == 1012)
        let focus = PaneWidths(available: 1240, showNotebooks: false, showNotes: false)
        #expect(focus.document == 1240)
    }
}

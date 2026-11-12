import AppKit
import NotesCore

enum TableAction: Int, CaseIterable {
    case rowAbove, rowBelow, deleteRow, columnBefore, columnAfter, deleteColumn
    case writeAbove, writeBelow, deleteTable

    var title: String {
        switch self {
        case .rowAbove: "Add Row Above"
        case .rowBelow: "Add Row Below"
        case .deleteRow: "Delete Row"
        case .columnBefore: "Add Column Before"
        case .columnAfter: "Add Column After"
        case .deleteColumn: "Delete Column"
        case .writeAbove: "Write Above Table"
        case .writeBelow: "Write Below Table"
        case .deleteTable: "Delete Table"
        }
    }
}

@MainActor
enum NativeTableLayout {
    struct Cell {
        let block: NSTextTableBlock
        let paragraph: NSRange
        let body: NSRange
    }

    struct Grid {
        let range: NSRange
        let cells: [Cell]
        let current: Cell
        var rows: [[FormattedTableCell]]
    }

    static func cell(in text: NSAttributedString, at index: Int) -> NSTextTableBlock? {
        guard index >= 0, index < text.length else { return nil }
        return (text.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)?
            .textBlocks.last as? NSTextTableBlock
    }

    static func grid(in text: NSAttributedString, at index: Int) -> Grid? {
        guard let selected = cell(in: text, at: index) else { return nil }
        let string = text.string as NSString
        var start = string.paragraphRange(for: NSRange(location: index, length: 0)).location
        while start > 0, cell(in: text, at: start - 1)?.table === selected.table {
            start = string.paragraphRange(for: NSRange(location: start - 1, length: 0)).location
        }
        var position = start
        var cells: [Cell] = []
        while position < text.length, let block = cell(in: text, at: position), block.table === selected.table {
            let paragraph = string.paragraphRange(for: NSRange(location: position, length: 0))
            var body = paragraph
            while body.length > 0 && ["\n", "\r"].contains(string.substring(with:
                NSRange(location: body.upperBound - 1, length: 1))) { body.length -= 1 }
            if let previous = cells.last, previous.block.startingRow == block.startingRow,
               previous.block.startingColumn == block.startingColumn {
                cells[cells.count - 1] = Cell(block: block, paragraph: NSUnionRange(previous.paragraph, paragraph),
                    body: NSUnionRange(previous.body, body))
            } else {
                cells.append(Cell(block: block, paragraph: paragraph, body: body))
            }
            position = paragraph.upperBound
        }
        guard let current = cells.first(where: { NSLocationInRange(index, $0.paragraph) }),
              let lastRow = cells.map({ $0.block.startingRow }).max(),
              cells.allSatisfy({ $0.block.rowSpan == 1 && $0.block.columnSpan == 1 }),
              selected.table.numberOfColumns > 0 else { return nil }
        var rows = Array(repeating: Array(repeating: FormattedTableCell(runs: []),
            count: selected.table.numberOfColumns), count: lastRow + 1)
        for cell in cells {
            guard rows.indices.contains(cell.block.startingRow),
                  rows[cell.block.startingRow].indices.contains(cell.block.startingColumn) else { return nil }
            rows[cell.block.startingRow][cell.block.startingColumn] =
                FormattedTableCell(runs: NativePageCodec.runs(in: text, range: cell.body, tableCell: true))
        }
        return Grid(range: NSRange(location: start, length: position - start),
                    cells: cells, current: current, rows: rows)
    }

    static func decode(_ rows: [[FormattedTableCell]], size: Double, family: ReadingFont,
                       color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        guard let columns = rows.first?.count, columns > 0 else { return result }
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        for (rowIndex, row) in rows.enumerated() {
            for (column, value) in row.enumerated() {
                let cell = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1,
                                             startingColumn: column, columnSpan: 1)
                cell.setContentWidth(100 / CGFloat(columns), type: .percentageValueType)
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setWidth(7, type: .absoluteValueType, for: .padding)
                cell.setBorderColor(color.withAlphaComponent(0.3))
                if rowIndex == 0 { cell.backgroundColor = color.withAlphaComponent(0.06) }
                var attributes = NativePageCodec.attributes(style: .table, size: size, family: family, color: color)
                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [cell]
                paragraph.lineSpacing = 3
                attributes[.paragraphStyle] = paragraph
                attributes[.folioTableRow] = true
                if rowIndex == 0, let font = attributes[.font] as? NSFont {
                    attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                }
                result.append(NativePageCodec.attributedRuns(value.runs, base: attributes,
                    resources: nil, size: size, family: family, tableCell: true))
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
        return result
    }

    static func recolor(_ text: NSAttributedString, color: NSColor) {
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            guard let cell = (value as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock else { return }
            cell.setBorderColor(color.withAlphaComponent(0.3))
            if cell.startingRow == 0 { cell.backgroundColor = color.withAlphaComponent(0.06) }
        }
    }
}

extension FormattingActions {
    var tableGrid: NativeTableLayout.Grid? {
        guard let editor, let storage = editor.textStorage,
              let grid = NativeTableLayout.grid(in: storage, at: editor.selectedRange().location),
              editor.selectedRange().upperBound <= grid.range.upperBound else { return nil }
        return grid
    }

    func tableActionEnabled(_ action: TableAction) -> Bool {
        guard let grid = tableGrid else { return false }
        switch action {
        case .deleteRow: return grid.rows.count > 1
        case .deleteColumn: return (grid.rows.first?.count ?? 0) > 1
        default: return true
        }
    }

    func performTableAction(_ action: TableAction) {
        guard let editor, editor.isEditable, var grid = tableGrid else { return }
        var row = grid.current.block.startingRow
        var column = grid.current.block.startingColumn
        let normal = NativePageCodec.attributes(style: .paragraph, size: editor.pageFontSize,
            family: editor.pageFont, color: editor.textColor ?? .textColor)
        if action == .writeAbove || action == .writeBelow {
            let position = action == .writeAbove ? grid.range.location : grid.range.upperBound
            if action == .writeAbove {
                editor.editAttributes(name: "Write Above Table") {
                    $0.insert(NSAttributedString(string: "\n", attributes: normal), at: position)
                }
            }
            editor.window?.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: position, length: 0))
            editor.typingAttributes = normal
            editor.scrollRangeToVisible(editor.selectedRange())
            refresh()
            return
        }
        guard tableActionEnabled(action) else { return }
        switch action {
        case .rowAbove, .rowBelow:
            row += action == .rowBelow ? 1 : 0
            grid.rows.insert(Array(repeating: FormattedTableCell(runs: []), count: grid.rows[0].count), at: row)
        case .deleteRow:
            grid.rows.remove(at: row)
            row = min(row, grid.rows.count - 1)
        case .columnBefore, .columnAfter:
            column += action == .columnAfter ? 1 : 0
            for index in grid.rows.indices { grid.rows[index].insert(FormattedTableCell(runs: []), at: column) }
        case .deleteColumn:
            for index in grid.rows.indices { grid.rows[index].remove(at: column) }
            column = min(column, grid.rows[0].count - 1)
        case .deleteTable:
            var range = grid.range
            if let storage = editor.textStorage, range.upperBound < storage.length,
               storage.attribute(.folioTableExit, at: range.upperBound, effectiveRange: nil) as? Bool == true {
                range.length += 1
            }
            editor.editAttributes(name: action.title) { $0.deleteCharacters(in: range) }
            editor.window?.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: min(range.location, editor.string.utf16.count), length: 0))
            editor.typingAttributes = normal
            refresh()
            return
        case .writeAbove, .writeBelow: return
        }
        let value = NativeTableLayout.decode(grid.rows, size: editor.pageFontSize,
            family: editor.pageFont, color: editor.textColor ?? .textColor)
        editor.breakUndoCoalescing()
        editor.editAttributes(name: action.title) { $0.replaceCharacters(in: grid.range, with: value) }
        if let updated = editor.textStorage.flatMap({ NativeTableLayout.grid(in: $0, at: grid.range.location) }),
           let target = updated.cells.first(where: { $0.block.startingRow == row && $0.block.startingColumn == column }) {
            selectTableCell(target)
        }
        editor.breakUndoCoalescing()
    }

    func selectTableCell(_ cell: NativeTableLayout.Cell) {
        guard let editor, let storage = editor.textStorage else { return }
        editor.window?.makeFirstResponder(editor)
        editor.setSelectedRange(cell.body)
        editor.typingAttributes = storage.attributes(at: cell.paragraph.location, effectiveRange: nil)
        editor.scrollRangeToVisible(cell.body)
        refresh()
    }

    @discardableResult
    func moveTableCell(backwards: Bool) -> Bool {
        guard let grid = tableGrid,
              let index = grid.cells.firstIndex(where: { $0.paragraph == grid.current.paragraph }) else { return false }
        if backwards {
            if index > 0 { selectTableCell(grid.cells[index - 1]) }
        } else if index + 1 < grid.cells.count {
            selectTableCell(grid.cells[index + 1])
        } else {
            performTableAction(.rowBelow)
            if let updated = tableGrid,
               let first = updated.cells.first(where: { $0.block.startingRow == grid.rows.count && $0.block.startingColumn == 0 }) {
                selectTableCell(first)
            }
        }
        return true
    }
}

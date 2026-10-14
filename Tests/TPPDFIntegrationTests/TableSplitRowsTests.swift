import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import TPPDF

/// Tables with `shouldSplitCellsOnPageBreak`, generated and read back with PDFKit. PDFKit finds a sliced cell's text on
/// every page the cell runs over, drawn or clipped, so the tests that need to know what a page shows read its pixels.
struct TableSplitRowsTests {
    /// The page margins; the table's left edge sits on the left one.
    private static let margin: CGFloat = 54

    /// A row that fits a page moves whole to the next page instead of being sliced across the page break.
    @Test func rowThatFitsAPageMovesWhole() throws {
        let rows = (1...40).map { row in
            (1...9).map { String(format: "555-%02d%02d", row, $0) }
        }

        let pdf = try generate(rows: rows)

        #expect(pdf.pageCount > 2)
        for numbers in rows {
            let pages = Set(numbers.flatMap { pdf.findString($0, withOptions: []) }.flatMap(\.pages).map { pdf.index(for: $0) })
            #expect(pages.count == 1, "\(numbers[0]) is on pages \(pages.sorted())")
        }
    }

    /// A row taller than a page starts under the rows before it and breaks between two lines, so each of its numbers is
    /// drawn whole on exactly one page. Each row before it moves the page break along the line pitch, so four counts
    /// put a break at a fixed height on the page through the digits at least once.
    @Test(arguments: 4...7)
    func rowTallerThanAPageBreaksBetweenLines(rowsBefore: Int) throws {
        let pdf = try generate(rows: Self.tallRowTable(rowsBefore: rowsBefore))
        let bitmaps = try (0..<pdf.pageCount).map { try PageBitmap(page: #require(pdf.page(at: $0))) }
        let headers = pdf.findString("Numbers", withOptions: [])

        var drawn: [(number: String, page: Int, inkHeight: CGFloat)] = []
        for number in Self.tallNumbers {
            for selection in pdf.findString(number, withOptions: []) {
                for page in selection.pages {
                    let index = pdf.index(for: page)
                    let bounds = selection.bounds(for: page)
                    let headerBounds = headers.first { $0.pages.contains(page) }?.bounds(for: page) ?? .null
                    // The header's own text would read as ink. A number overlapping it is hidden or, when cut, the rest
                    // of a number already measured as cut at the previous page's bottom.
                    if bounds.maxY > headerBounds.minY && bounds.minY < headerBounds.maxY {
                        continue
                    }
                    let inkHeight = bitmaps[index].inkHeight(in: bounds)
                    if inkHeight > 0 {
                        drawn.append((number, index + 1, inkHeight))
                    }
                }
            }
        }
        // Every number is set in the same digits, so a whole one shows the full digit height and a cut one less.
        let digitHeight = drawn.map(\.inkHeight).max() ?? 0
        var wholePages: [String: [Int]] = [:]
        for line in drawn {
            #expect(line.inkHeight >= digitHeight - 0.5, "\(line.number) is cut on page \(line.page)")
            if line.inkHeight >= digitHeight - 0.5 {
                wholePages[line.number, default: []].append(line.page)
            }
        }

        #expect(pdf.pageCount >= 3)
        #expect(wholePages[Self.tallNumbers[0]] == [1], "the tall row starts on page 1, under the rows before it")
        for number in Self.tallNumbers {
            #expect(wholePages[number]?.count == 1, "\(number) is drawn whole on pages \(wholePages[number] ?? [])")
        }
    }

    /// The table outline stays on the page: none in the top margin above a repeated header, and none in the bottom
    /// margin, where a split row's outline used to run on to the row's end.
    @Test func tableOutlineStaysOutOfTheMargins() throws {
        let pdf = try generate(rows: Self.tallRowTable(rowsBefore: 6))

        #expect(pdf.pageCount >= 3)
        for index in 0..<pdf.pageCount {
            let page = try #require(pdf.page(at: index))
            let bitmap = try PageBitmap(page: page)
            let height = page.bounds(for: .mediaBox).height
            let topMargin = CGRect(x: Self.margin - 1, y: height - Self.margin + 4, width: 2, height: Self.margin - 5)
            let bottomMargin = CGRect(x: Self.margin - 1, y: 1, width: 2, height: Self.margin - 5)
            #expect(!bitmap.hasInk(in: topMargin, darkerThan: 0.75), "an outline in page \(index + 1)'s top margin")
            #expect(!bitmap.hasInk(in: bottomMargin, darkerThan: 0.75), "an outline in page \(index + 1)'s bottom margin")
        }
    }

    // MARK: - Helpers

    /// The tall row's 120 numbers, which run over three A4 pages.
    private static let tallNumbers = (1...120).map { String(format: "555-9%03d", $0) }

    /// `rowsBefore` one-number rows, the row of `tallNumbers`, and three more one-number rows.
    private static func tallRowTable(rowsBefore: Int) -> [[String]] {
        let before = (1...rowsBefore).map { [String(format: "555-80%02d", $0)] }
        let after = (1...3).map { [String(format: "555-81%02d", $0)] }
        return before + [tallNumbers] + after
    }

    /// An A4 table in split mode with a "Numbers" header repeated on every page and one row per entry of `rows`, its
    /// numbers one per line, then generated and read back.
    private func generate(rows: [[String]]) throws -> PDFKit.PDFDocument {
        let margins = EdgeInsets(top: Self.margin, left: Self.margin, bottom: Self.margin, right: Self.margin)
        let document = PDFDocument(layout: PDFPageLayout(size: PDFPageFormat.a4.size, margin: margins))
        let table = PDFTable(rows: rows.count + 1, columns: 2)
        table.widths = [0.3, 0.7]
        table.padding = 5
        table.showHeadersOnEveryPage = true
        table.shouldSplitCellsOnPageBreak = true
        // Grey, so the borders never read as text ink in `PageBitmap`
        let line = PDFLineStyle(type: .full, color: .gray, width: 1)
        let cellStyle = PDFTableCellStyle(borders: PDFTableCellBorders(left: line, top: line, right: line, bottom: line))
        table.style = PDFTableStyle(
            rowHeaderCount: 0,
            columnHeaderCount: 1,
            footerCount: 0,
            outline: line,
            columnHeaderStyle: cellStyle,
            contentStyle: cellStyle
        )
        table[0, 0].content = "Row".asTableContent
        table[0, 1].content = "Numbers".asTableContent
        for (index, numbers) in rows.enumerated() {
            table[index + 1, 0].content = "Row \(index + 1)".asTableContent
            table[index + 1, 1].content = numbers.joined(separator: "\n").asTableContent
            table[index + 1, 0].alignment = .topLeft
            table[index + 1, 1].alignment = .topLeft
        }
        document.add(table: table)
        let data = try PDFGenerator(document: document).generateData()
        // `#require` reads a module-qualified initializer as a call on the module, so the PDF is made first.
        let pdf = PDFKit.PDFDocument(data: data)
        return try #require(pdf)
    }
}

/// A PDF page drawn on white at 3 pixels per point, read back as grey levels. Rects are in page space, bottom up, like
/// PDFKit's selection bounds.
private struct PageBitmap {
    private static let scale: CGFloat = 3
    /// Darker than this is text: the cell text is black and the table's lines 50% grey.
    private static let textLevel: CGFloat = 0.25

    private let pixels: [UInt8]
    private let width: Int
    private let height: Int

    init(page: PDFPage) throws {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * Self.scale)
        let height = Int(bounds.height * Self.scale)
        var pixels = [UInt8](repeating: 255, count: width * height)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ))
            context.scaleBy(x: Self.scale, y: Self.scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .mediaBox, to: context)
        }
        self.pixels = pixels
        self.width = width
        self.height = height
    }

    /// The height in points from the topmost to the bottommost row of text ink inside `bounds`; 0 when none shows.
    func inkHeight(in bounds: CGRect) -> CGFloat {
        let rows = inkRows(in: bounds, darkerThan: Self.textLevel)
        guard let first = rows.first, let last = rows.last else {
            return 0
        }
        return CGFloat(last - first + 1) / Self.scale
    }

    /// Whether any pixel inside `rect` is darker than `level`, from 0 black to 1 white. Parts off the page count as white.
    func hasInk(in rect: CGRect, darkerThan level: CGFloat) -> Bool {
        !inkRows(in: rect, darkerThan: level).isEmpty
    }

    /// The bitmap rows, top down, holding a pixel inside `rect` darker than `level`.
    private func inkRows(in rect: CGRect, darkerThan level: CGFloat) -> [Int] {
        let threshold = UInt8(level * 255)
        let left = max(0, Int(rect.minX * Self.scale))
        let right = min(width, Int((rect.maxX * Self.scale).rounded(.up)))
        // The bitmap's rows run top down.
        let top = max(0, height - Int((rect.maxY * Self.scale).rounded(.up)))
        let bottom = min(height, height - Int(rect.minY * Self.scale))
        guard left < right, top < bottom else {
            return []
        }
        return (top..<bottom).filter { row in
            (left..<right).contains { pixels[row * width + $0] < threshold }
        }
    }
}

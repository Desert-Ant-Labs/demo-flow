import AppKit
import Charts
import SwiftUI

/// Exports everything on the Results page at once: as a PDF drawn from the
/// same views, as Markdown, or as a folder with each result in its own file
/// and a report that links them.
struct ExportMenu: View {
    let title: String
    let description: String
    let outcomes: [Outcome]

    var body: some View {
        Menu {
            Button("PDF\u{2026}", systemImage: "doc.richtext") { export(.pdf) }
            Button("Markdown\u{2026}", systemImage: "text.document") { export(.markdown) }
            Divider()
            Button("Folder with Every Result\u{2026}", systemImage: "folder") { export(.folder) }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up.on.square")
        }
        .fixedSize()
        .help("Export every result on this page")
    }

    private enum Format { case pdf, markdown, folder }

    private func export(_ format: Format) {
        let report = ResultsReport(title: title, description: description, outcomes: outcomes)
        let window = NSApp.keyWindow
        Task {
            do {
                switch format {
                case .pdf: Exports.save([try report.pdf()], window: window)
                case .markdown: Exports.save([Exports.file(text: report.markdown(), name: "\(Exports.slug(title)).md")], window: window)
                case .folder: try await report.folder(window: window)
                }
            } catch {
                if let window { _ = await NSAlert(error: error).beginSheetModal(for: window) } else { NSAlert(error: error).runModal() }
            }
        }
    }
}

/// A flow's results, written out.
@MainActor
struct ResultsReport {
    let title: String
    let description: String
    let outcomes: [Outcome]

    /// The page's width in points, and its margins: A4.
    private static let page = CGSize(width: 595, height: 842)
    private static let margin: CGFloat = 48
    private static var column: CGFloat { page.width - margin * 2 }

    // MARK: PDF

    /// A PDF of the results: each result laid out as on screen, starting a
    /// new page rather than breaking across one when it fits on the next.
    func pdf() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "\(Exports.slug(title)).pdf")
        var box = CGRect(origin: .zero, size: Self.page)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: title] as CFDictionary) else {
            throw StepError("Couldn't make the PDF")
        }
        let blocks: [AnyView] = [AnyView(ReportHeader(title: title, description: description))]
            + outcomes.filter { !$0.isEmpty }.map { AnyView(ReportSection(outcome: $0)) }
        let height = Self.page.height - Self.margin * 2
        var used = CGFloat.infinity
        for block in blocks {
            let renderer = ImageRenderer(content: block
                .frame(width: Self.column, alignment: .leading)
                .environment(\.colorScheme, .light))
            renderer.proposedSize = ProposedViewSize(width: Self.column, height: nil)
            renderer.render { size, draw in
                // A block that doesn't fit the rest of the page starts the next
                // one; a block taller than a page runs on across pages.
                if used + size.height > height && used > 0 {
                    if used != .infinity { pdf.endPDFPage() }
                    pdf.beginPDFPage(nil)
                    used = 0
                }
                var shown: CGFloat = 0
                while shown < size.height {
                    if shown > 0 {
                        pdf.endPDFPage()
                        pdf.beginPDFPage(nil)
                        used = 0
                    }
                    let slice = min(size.height - shown, height - used)
                    pdf.saveGState()
                    let top = Self.page.height - Self.margin - used
                    pdf.clip(to: CGRect(x: Self.margin, y: top - slice, width: Self.column, height: slice))
                    // The block's own origin is its bottom left; this puts the part not yet shown at the top of the space left.
                    pdf.translateBy(x: Self.margin, y: top - size.height + shown)
                    draw(pdf)
                    pdf.restoreGState()
                    shown += slice
                    used += slice
                }
                used += 24
            }
        }
        if used != .infinity { pdf.endPDFPage() }
        pdf.closePDF()
        return url
    }

    // MARK: Markdown

    /// The results as Markdown. `files` names the file each result was saved
    /// as, by step, for a report that sits next to them.
    func markdown(files: [String: [String]] = [:]) -> String {
        var out = "# \(title)\n"
        if !description.isEmpty { out += "\n\(description)\n" }
        for outcome in outcomes {
            out += "\n## \(outcome.name)\n\n"
            let saved = files[outcome.id] ?? []
            switch outcome.content {
            case nil:
                out += "_Nothing on this run._\n"
            case .photos(let items):
                for (i, item) in items.enumerated() {
                    let caption = item.caption ?? item.photo.name
                    out += i < saved.count ? "![\(caption)](\(link(saved[i])))\n" : "- \(item.photo.name)\(item.caption.map { ": \($0)" } ?? "")\n"
                }
            case .table(let columns, let rows):
                out += Self.table(columns, rows)
            case .value(let value, let mode):
                out += Self.markdown(value, kind: mode == .auto ? kind(of: value) : mode, saved: saved.map(link))
            }
        }
        return out
    }

    private func link(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
    }

    private static func markdown(_ value: Value, kind: ValueKind, saved: [String]) -> String {
        switch kind {
        case .markdown, .document, .text:
            return Exports.plainText(value) + "\n"
        case .scored:
            return (scored(value.present) ?? []).map { "- \($0.label): \(Int(($0.score * 100).rounded()))%\n" }.joined()
        case .audio:
            let length = value.audio.map { String(format: "%.1f seconds", $0.duration) } ?? ""
            return saved.first.map { "[Recording, \(length)](\($0))\n" } ?? "Recording, \(length)\n"
        case .image:
            return saved.first.map { "![\(value.asText)](\($0))\n" } ?? "\(value.asText)\n"
        case .list:
            return value.present.map { "- \($0.asText)\n" }.joined()
        case .number:
            return "**\(value.asText)**\n"
        default:
            return "```json\n\(value.jsonText())\n```\n"
        }
    }

    private static func table(_ columns: [String], _ rows: [[Value?]]) -> String {
        let cell = { (s: String) in s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
        var out = "| " + columns.map(cell).joined(separator: " | ") + " |\n"
        out += "|" + String(repeating: " --- |", count: columns.count) + "\n"
        for row in rows { out += "| " + row.map { cell($0.asText) }.joined(separator: " | ") + " |\n" }
        return out
    }

    // MARK: Folder

    /// Asks where, then writes a folder named after the flow: each result in
    /// its own file, a Markdown report that links them, and the PDF.
    func folder(window: NSWindow?) async throws {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where to put a folder with every result of \(title)."
        let response = if let window { await panel.beginSheetModal(for: window) } else { panel.runModal() }
        guard response == .OK, let parent = panel.url else { return }

        let folder = Exports.free(title.isEmpty ? "Results" : title, in: parent)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [String: [String]] = [:]
        for outcome in outcomes where !outcome.isEmpty {
            guard let value = outcome.value else { continue }
            files[outcome.id] = try FolderWriter.write(value, to: folder, name: Exports.slug(outcome.name)).map(\.lastPathComponent)
        }
        try markdown(files: files).write(to: folder.appending(path: "Results.md"), atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: try pdf(), to: folder.appending(path: "Results.pdf"))
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

// MARK: The PDF's views

/// The flow's name and description at the top of the PDF.
private struct ReportHeader: View {
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 24, weight: .bold))
            if !description.isEmpty { Text(description).font(.system(size: 12)).foregroundStyle(.secondary) }
            Text("Made on this Mac with Desert Ant Flow, \(Date.now.formatted(date: .long, time: .shortened))")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(.bottom, 8)
    }
}

/// One result in the PDF: the page's views, without the ones only a screen
/// can draw, as a scrolling table or a player.
private struct ReportSection: View {
    let outcome: Outcome

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(outcome.name).font(.system(size: 15, weight: .semibold))
            switch outcome.content {
            case .photos(let items):
                Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 10) {
                    ForEach(Array(stride(from: 0, to: items.count, by: 4)), id: \.self) { start in
                        GridRow {
                            ForEach(items[start..<min(start + 4, items.count)]) { item in
                                VStack(alignment: .leading, spacing: 3) {
                                    Color.clear
                                        .aspectRatio(1, contentMode: .fit)
                                        .overlay { Image(decorative: item.photo.thumb, scale: 1).resizable().scaledToFill() }
                                        .clipShape(.rect(cornerRadius: 4))
                                    if let caption = item.caption { Text(caption).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(2) }
                                }
                            }
                        }
                    }
                }
            case .table(let columns, let rows):
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    GridRow { ForEach(columns, id: \.self) { Text(ResultTable.heading($0)).font(.system(size: 9, weight: .semibold)) } }
                    Divider()
                    ForEach(rows.indices, id: \.self) { r in
                        GridRow { ForEach(rows[r].indices, id: \.self) { Text(rows[r][$0].asText).font(.system(size: 9)).lineLimit(3) } }
                    }
                }
            case .value(let value, let mode):
                switch mode == .auto ? kind(of: value) : mode {
                case .scored: ScoreChart(items: scored(value.present) ?? [])
                case .number: BigValue(value: value)
                case .audio: Text("Recording, \(String(format: "%.1f", value.audio?.duration ?? 0)) seconds").foregroundStyle(.secondary)
                case .image:
                    if let photo = value.photo { Image(decorative: photo.thumb, scale: 1).resizable().scaledToFit().frame(maxHeight: 360) }
                case .markdown: MarkdownView(text: Exports.plainText(value)).font(.system(size: 11))
                case .list: NumberedList(items: value.present).font(.system(size: 11))
                case .document, .text: Text(marked(Exports.plainText(value))).font(.system(size: 11)).lineSpacing(2)
                default: Text(value.jsonText()).font(.system(size: 9).monospaced())
                }
            case nil:
                EmptyView()
            }
        }
    }
}

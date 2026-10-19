import Charts
import DesertAntUI
import SwiftUI

/// A result at full size, in the form that fits what it holds.
struct OutcomeContent: View {
    let content: Outcome.Content

    var body: some View {
        switch content {
        case .photos(let items):
            PhotoWall(items: items)
        case .table(let columns, let rows):
            ResultTable(columns: columns, rows: rows)
        case .value(let value, let mode):
            ValueContent(value: value, kind: mode == .auto ? kind(of: value) : mode)
        }
    }
}

/// A single value at full size.
private struct ValueContent: View {
    let value: Value
    let kind: ValueKind

    var body: some View {
        switch kind {
        case .scored:
            ScoreChart(items: scored(value.present) ?? [])
        case .number:
            BigValue(value: value)
        case .audio:
            if let clip = value.audio { AudioPlayerView(clip: clip, height: 64) }
        case .image:
            if let photo = value.photo {
                PhotoView(photo: photo, all: [photo])
                    .frame(maxWidth: 720, maxHeight: 560, alignment: .leading)
            }
        case .gallery:
            PhotoWall(items: value.present.enumerated().compactMap { i, v in v.photo.map { Outcome.Captioned(id: i, photo: $0, caption: nil) } })
        case .markdown, .document, .text:
            ReadableText(text: Exports.plainText(value), markdown: kind == .markdown)
        case .list:
            NumberedList(items: value.present)
        case .table, .json:
            Text(value.jsonText())
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .auto, .empty:
            EmptyView()
        }
    }
}

// MARK: Photos

/// Photos as a wall of tiles. When the photos carry a few labels that repeat,
/// as Eye's expressions do, chips above the wall show one label at a time.
struct PhotoWall: View {
    let items: [Outcome.Captioned]
    @State private var filter: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let facets = Self.facets(items)
        let shown = filter.map { f in items.filter { $0.caption == f } } ?? items
        VStack(alignment: .leading, spacing: 16) {
            if facets.count > 1 {
                ScrollView(.horizontal) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            FacetChip(label: "All", count: items.count, on: filter == nil) { filter = nil }
                            ForEach(facets, id: \.label) { facet in
                                FacetChip(label: facet.label, count: facet.count, on: filter == facet.label) {
                                    filter = filter == facet.label ? nil : facet.label
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .scrollIndicators(.never)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 280), spacing: 14)], alignment: .leading, spacing: 18) {
                ForEach(shown) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        PhotoView(photo: item.photo, all: shown.map(\.photo), caption: item.caption, square: true)
                        if let caption = item.caption, !caption.isEmpty {
                            Text(caption).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: filter)
        }
    }

    /// The labels worth filtering by: two to eight of them, at least one on
    /// more than one photo, the most common first.
    static func facets(_ items: [Outcome.Captioned]) -> [(label: String, count: Int)] {
        var counts: [String: Int] = [:]
        for case let caption? in items.map(\.caption) where !caption.isEmpty { counts[caption, default: 0] += 1 }
        guard (2...8).contains(counts.count), counts.values.contains(where: { $0 > 1 }) else { return [] }
        return counts.map { ($0.key, $0.value) }.sorted { ($0.count, $1.label) > ($1.count, $0.label) }
    }
}

private struct FacetChip: View {
    let label: String
    let count: Int
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label)
                Text("\(count)").monospacedDigit().foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(on ? .regular.tint(DA.Color.accent.opacity(0.35)).interactive() : .regular.interactive(), in: .capsule)
        .accessibilityLabel("\(label), \(count)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: Tables

/// Rows under named columns, in a native table: click a column to sort by
/// it, select rows and press Command-C to copy them.
struct ResultTable: View {
    let columns: [String]
    let rows: [[Value?]]
    @State private var order: [CellOrder] = []
    @State private var selection: Set<Int> = []

    struct Row: Identifiable {
        let id: Int
        let cells: [Value?]
    }

    var body: some View {
        let sorted = rows.enumerated().map { Row(id: $0, cells: $1) }.sorted(using: order)
        Table(sorted, selection: $selection, sortOrder: $order) {
            TableColumnForEach(columns.indices, id: \.self) { i in
                TableColumn(Self.heading(columns[i]), sortUsing: CellOrder(column: i)) { row in
                    Cell(value: i < row.cells.count ? row.cells[i] : nil)
                }
            }
        }
        // A table inside the page's scroll view needs a height of its own.
        .frame(height: min(560, 32 + CGFloat(rows.count) * 24))
        .clipShape(.rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        .onCopyCommand {
            let picked = sorted.filter { selection.contains($0.id) }
            let text = (picked.isEmpty ? sorted : picked).map { row in row.cells.map { $0.asText }.joined(separator: "\t") }
                .joined(separator: "\n")
            return [NSItemProvider(object: text as NSString)]
        }
    }

    /// A field name as a column heading: "given_name" reads "Given name".
    static func heading(_ key: String) -> String {
        let words = key.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private struct Cell: View {
        let value: Value?

        var body: some View {
            switch value {
            case .image(let photo)?:
                Image(decorative: photo.thumb, scale: 1).resizable().scaledToFill()
                    .frame(width: 22, height: 22).clipShape(.rect(cornerRadius: 4))
            case .number(let n)?:
                Text(Value.format(n)).monospacedDigit()
            case .bool(let b)?:
                Text(b ? "Yes" : "No")
            default:
                Text(value.asText).lineLimit(2)
            }
        }
    }
}

/// Sorts table rows by one column: numbers by value, everything else by its words.
struct CellOrder: SortComparator {
    var column: Int
    var order: SortOrder = .forward

    func compare(_ a: ResultTable.Row, _ b: ResultTable.Row) -> ComparisonResult {
        let x = column < a.cells.count ? a.cells[column] : nil, y = column < b.cells.count ? b.cells[column] : nil
        let result = Flow.compare(x, y)
        let ascending: ComparisonResult = result < 0 ? .orderedAscending : result > 0 ? .orderedDescending : .orderedSame
        guard order == .reverse else { return ascending }
        return switch ascending {
        case .orderedAscending: .orderedDescending
        case .orderedDescending: .orderedAscending
        case .orderedSame: .orderedSame
        }
    }

    static func == (a: Self, b: Self) -> Bool { a.column == b.column && a.order == b.order }
    func hash(into hasher: inout Hasher) {
        hasher.combine(column)
        hasher.combine(order == .forward)
    }
}

// MARK: Scores, numbers, text

/// Labels with scores, as a bar chart with each share written beside its bar.
struct ScoreChart: View {
    let items: [(label: String, score: Double)]

    var body: some View {
        let shown = Array(items.prefix(12).enumerated())
        Chart(shown, id: \.offset) { _, item in
            BarMark(x: .value("Score", item.score), y: .value("Label", item.label))
                .foregroundStyle(DA.Color.accent.gradient)
                .clipShape(.capsule)
                .annotation(position: .trailing, spacing: 6) {
                    Text(item.score, format: .percent.precision(.fractionLength(0)))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
        }
        .chartXScale(domain: 0...1)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks { _ in AxisValueLabel().font(.body) }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .frame(height: CGFloat(shown.count) * 34 + 8)
        .accessibilityLabel(items.prefix(12).map { "\($0.label) \(Int(($0.score * 100).rounded())) percent" }.joined(separator: ", "))
    }
}

/// A number or a yes or no, large.
struct BigValue: View {
    let value: Value

    var body: some View {
        switch value {
        case .bool(let b):
            Label(b ? "Yes" : "No", systemImage: b ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(b ? Theme.success : Theme.danger)
        default:
            Text(value.asText)
                .font(.system(size: 52, weight: .semibold, design: .rounded).monospacedDigit())
                .textSelection(.enabled)
        }
    }
}

/// Text set for reading: a comfortable size and measure, with Redact's
/// placeholders marked and Markdown drawn.
struct ReadableText: View {
    let text: String
    let markdown: Bool

    var body: some View {
        Group {
            if markdown {
                MarkdownView(text: text)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                        Text(marked(paragraph)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
            }
        }
        .font(.system(size: 15))
        .lineSpacing(4)
        .frame(maxWidth: 680, alignment: .leading)
    }
}

/// Items one per line, numbered.
struct NumberedList: View {
    let items: [Value]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(i + 1)").font(.callout.monospacedDigit()).foregroundStyle(.tertiary).frame(minWidth: 22, alignment: .trailing)
                    ValueView(value: item, compact: false)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                if i < items.count - 1 { Divider().padding(.leading, 34) }
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }
}

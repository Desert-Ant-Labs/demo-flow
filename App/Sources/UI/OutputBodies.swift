import SwiftUI

struct TableBody: View {
    let node: Node
    let state: StepState
    @Environment(\.flowActions) private var actions
    @State private var sort: (key: String, ascending: Bool)?
    @State private var height: CGFloat?

    var body: some View {
        let p = ParamBinding(node: node, actions: actions)
        let cols = ["a", "b", "c"].filter { state.inputs[$0] != nil }
        let names = (node.params["columns"]?.string ?? "").split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let cell = { (k: String, i: Int) -> Value? in
            guard let v = state.inputs[k] else { return nil }
            return v.isStream ? (i < v.items.count ? v.items[i] : nil) : v
        }
        let rows = cols.compactMap { state.inputs[$0] }.map { $0.isStream ? $0.items.count : 1 }.max() ?? 0
        var order = (0..<rows).filter { !cols.isEmpty && cell(cols[0], $0) != nil }
        if let sort {
            order.sort { compare(cell(sort.key, $0), cell(sort.key, $1)) * (sort.ascending ? 1 : -1) < 0 }
        }
        return VStack(alignment: .leading, spacing: 8) {
            TextField("Column names, separated by commas", text: p.text("columns"))
                .textFieldStyle(.roundedBorder)
            if !cols.isEmpty {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                        GridRow {
                            ForEach(cols, id: \.self) { k in
                                let i = ["a", "b", "c"].firstIndex(of: k)!
                                Button {
                                    sort = sort?.key != k ? (k, true) : sort!.ascending ? (k, false) : nil
                                } label: {
                                    HStack(spacing: 3) {
                                        Text(i < names.count && !names[i].isEmpty ? names[i] : k)
                                        Image(systemName: sort?.key == k ? (sort!.ascending ? "chevron.up" : "chevron.down") : "chevron.up.chevron.down")
                                            .font(.system(size: 8))
                                    }
                                    .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        ForEach(order, id: \.self) { i in
                            GridRow(alignment: .top) {
                                ForEach(cols, id: \.self) { k in
                                    TableCell(value: cell(k, i))
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: height ?? node.params["h"]?.number.map { CGFloat($0) } ?? 420)
                HeightGrip(node: node, fallback: 420, live: $height)
            }
        }
    }
}

struct TableCell: View {
    let value: Value?
    var body: some View {
        if let photo = value?.photo {
            PhotoView(photo: photo, all: [photo]).frame(width: 90)
        } else {
            ValueView(value: value)
        }
    }
}

/// The Result step's controls: the answer, large, with the ways to take it
/// elsewhere. `ResultView` draws the answer itself.
struct ResultBody: View {
    let node: Node
    let state: StepState
    @Environment(\.flowActions) private var actions
    @State private var done: String?
    @State private var flashing: Task<Void, Never>?
    @State private var height: CGFloat?

    var body: some View {
        let p = ParamBinding(node: node, actions: actions)
        let value = state.inputs["value"]
        let has = value.map { !($0.isList && $0.present.isEmpty) } ?? false
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Group {
                    if has { ResultView(value: value, mode: ValueKind(rawValue: node.params["as"]?.string ?? "auto") ?? .auto) } else {
                        Text("The result shows here once the steps before it have run.").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: height ?? node.params["h"]?.number.map { CGFloat($0) } ?? 520)
            .fixedSize(horizontal: false, vertical: true)
            if has { HeightGrip(node: node, fallback: 520, live: $height) }
            HStack(spacing: 8) {
                Picker("Show as", selection: p.text("as", "auto")) {
                    ForEach(ValueKind.modes, id: \.0) { Text($0.1).tag($0.0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                if let done { Text(done).font(.caption).foregroundStyle(.secondary).transition(.opacity) }
                if has, let value {
                    if value.audio == nil && kind(of: value) != .gallery {
                        Button("Copy") { Exports.copy(value); flash("Copied") }
                    }
                    let options = Exports.saveOptions(value, title: actions.title())
                    if options.count == 1 {
                        Button("Save…") { save(options[0]) }
                    } else if options.count > 1 {
                        Menu("Save") {
                            ForEach(options) { o in Button(o.label + "…") { save(o) } }
                        }
                        .fixedSize()
                    }
                    ShareButton(items: { await shareItems(value) })
                        .fixedSize()
                }
            }
            .controlSize(.small)
        }
    }

    private func shareItems(_ value: Value) async -> [Any] {
        switch kind(of: value) {
        case .image, .audio, .gallery: await Exports.saveOptions(value, title: actions.title()).first?.files() ?? []
        default: [Exports.plainText(value)]
        }
    }

    private func save(_ option: SaveOption) {
        let window = NSApp.keyWindow
        Task { Exports.save(await option.files(), window: window) }
    }

    /// Shows a word for a moment. A second one starts the moment over.
    private func flash(_ text: String) {
        withAnimation { done = text }
        flashing?.cancel()
        flashing = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation { done = nil }
        }
    }
}

/// A handle under a step's content: drag it down to show more of it, up to
/// show less. The flow keeps the height, written once the drag ends so one
/// resize is one step to undo.
struct HeightGrip: View {
    let node: Node
    let fallback: CGFloat
    /// The height while dragging.
    @Binding var live: CGFloat?
    @Environment(\.flowActions) private var actions
    @State private var start: CGFloat?
    @State private var hover = false

    var body: some View {
        Capsule()
            .fill(.primary.opacity(hover || start != nil ? 0.35 : 0.15))
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity, minHeight: 12)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: .bottom))
            .onHover { hover = $0 }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { g in
                    let from = start ?? node.params["h"]?.number.map { CGFloat($0) } ?? fallback
                    start = from
                    live = min(1600, max(120, from + g.translation.height)).rounded()
                }
                .onEnded { _ in
                    if let live { actions.set(node.id, ["h": .number(live)]) }
                    start = nil
                    live = nil
                })
            .help("Drag to make this taller or shorter")
    }
}

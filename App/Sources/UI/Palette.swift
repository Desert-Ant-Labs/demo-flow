import SwiftUI

/// The steps you can add. With a step selected, the ones that fit after it
/// come first, and choosing one wires it up.
struct PaletteView: View {
    let anchor: Node?
    var onlyInputs = false
    let pick: (String) -> Void
    @State private var query = ""
    @FocusState private var searching: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.flowSession) private var session
    @Environment(\.flowActions) private var actions

    var body: some View {
        let sources = anchor.map { upstreamOutputs(from: $0, in: actions.graph, session: session) } ?? []
        let fits = { (d: StepDef) in d.inputs.contains { nearest(for: $0, of: d, in: sources) != nil } }
        let matches = { (d: StepDef) in
            query.isEmpty || "\(d.title) \(d.description) \(d.model?.info.task ?? "")".localizedCaseInsensitiveContains(query)
        }
        let rank = { (d: StepDef) in (d.model != nil ? 0 : 1, d.category == .output ? 1 : 0) }
        let suggested = anchor == nil || onlyInputs ? [] : Steps.palette
            .filter { $0.category != .input && $0.category != .note && fits($0) && matches($0) }
            .sorted { rank($0) < rank($1) }
        let starts = anchor == nil || onlyInputs ? Steps.palette.filter { TriggerSteps.isTrigger($0.type) && matches($0) } : []
        let groups = Category.allCases.filter { !onlyInputs || $0 == .input }.map { c in
            (c, Steps.palette.filter { d in
                d.category == c && !TriggerSteps.isTrigger(d.type) && !suggested.contains { $0.type == d.type } && matches(d)
            })
        }
        // What Return adds: the first step shown.
        let first = (suggested + starts + groups.flatMap(\.1)).first
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(onlyInputs ? "How does this flow start?" : anchor == nil ? "Add a step" : "Add the next step")
                    .font(.title3.weight(.semibold))
                Spacer()
                TextField("Find a step", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .focused($searching)
                    .onSubmit { if let first { pick(first.type) } }
                    .onAppear { searching = true }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !suggested.isEmpty {
                        section("Fits after \(anchor.map { actions.graph.name(of: $0.id) } ?? "")", suggested)
                    }
                    if !starts.isEmpty { section("Run on its own", starts) }
                    ForEach(groups, id: \.0) { c, items in
                        if !items.isEmpty { section(c.label, items) }
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 600, height: 560)
    }

    private func section(_ title: String, _ items: [StepDef]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(items, id: \.type) { d in PaletteItem(def: d) { pick(d.type) } }
            }
        }
    }
}

/// A step to add. A model shows as a small card in its brand color.
struct PaletteItem: View {
    let def: StepDef
    let action: () -> Void
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let colors = Theme.card(def)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    if def.model == nil {
                        Image(systemName: symbol(for: def.type))
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                    }
                    Text(def.model?.info.name ?? def.title)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(def.model?.info.task ?? def.description)
                    .font(.caption)
                    .opacity(0.75)
                    .lineLimit(2, reservesSpace: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(colors.ink)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(colors.fill))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(hover ? AnyShapeStyle(.primary.opacity(0.4)) : AnyShapeStyle(Theme.hairline), lineWidth: hover ? 1.5 : 1)
            }
            .scaleEffect(hover && !reduceMotion ? 1.015 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.snappy(duration: 0.15)) { hover = h } }
        .help(def.description)
    }
}

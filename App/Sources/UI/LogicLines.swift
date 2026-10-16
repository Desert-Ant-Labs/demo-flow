import DesertAntUI
import SwiftUI

/// Split and Merge in the step list: one line that reads as a sentence, in
/// place of a card with ports. The Split's condition sits on its If side.
struct LogicLine: View {
    let node: Node
    var selected = false
    @Environment(\.flowActions) private var actions
    @Environment(\.flowSession) private var session

    nonisolated static func has(_ type: String) -> Bool { ["if", "merge"].contains(type) }

    var body: some View {
        let state = session?.engine.state(node.id) ?? StepState()
        VStack(alignment: .leading, spacing: 6) {
            sentence
            if let note = note(state) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(state.status == .error ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(0.035)))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(DA.Color.accent) : AnyShapeStyle(Theme.hairline), lineWidth: selected ? 1.5 : 1)
        }
        .contentShape(Rectangle())
        .contextMenu { Button("Remove") { actions.remove(node.id) } }
    }

    @ViewBuilder
    private var sentence: some View {
        switch node.type {
        case "if":
            // What it sorts is set for it: whatever its check was about.
            HStack(spacing: 8) {
                Text("Split").fontWeight(.semibold)
                Text("sorts each \(sortedNoun) into If or Else").foregroundStyle(.secondary)
            }
        case "merge":
            Text("If and Else come together again").fontWeight(.semibold)
        default:
            EmptyView()
        }
    }

    /// What an If sorts, in a word: the kind of what it sends on.
    private var sortedNoun: String {
        guard let edge = actions.graph.incoming(node.id).first(where: { $0.targetHandle == "value" }),
              let source = actions.graph.node(edge.source),
              let port = source.def?.outputs.first(where: { $0.id == edge.sourceHandle })
        else { return "item" }
        switch outputKind(source, port, session: session) {
        case .photo: return "photo"
        case .text, .label: return "text"
        case .file: return "file"
        case .audio: return "recording"
        case .drawing: return "drawing"
        default: return "item"
        }
    }

    /// What happened, in a few words, once it has run.
    private func note(_ state: StepState) -> String? {
        if let error = state.error { return error }
        if state.status == .skipped { return "Nothing came in, so this was skipped" }
        guard let out = state.outputs else { return nil }
        switch node.type {
        case "if":
            let yes = out["yes"], no = out["no"]
            if yes?.isStream == true || no?.isStream == true {
                let count = { (v: Value?) in v?.present.count ?? 0 }
                return "\(count(yes)) went to If, \(count(no)) to Else"
            }
            return yes != nil ? "The check was true, so it went to If" : "The check was false, so it went to Else"
        default:
            return nil
        }
    }
}

/// The heading over a Split's Else side, with a way to add the first step
/// there or check something else.
struct ElseLabel: View {
    let empty: Bool
    let add: () -> Void
    var elseIf: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text("Else").fontWeight(.semibold)
            Text("otherwise").foregroundStyle(.secondary)
            if empty { Chip(text: "Add a step", symbol: "plus", action: add) }
            if empty, let elseIf { Chip(text: "Else if", symbol: "plus", action: elseIf).help("Check something else for what reached Else") }
        }
        .font(.callout)
        .padding(.top, 5)
    }
}

/// "is one of": each value a chip you can take out, and a menu to add more,
/// from what the last run saw or typed in.
struct ValueChips: View {
    let node: Node
    let seen: [String]
    @Environment(\.flowActions) private var actions
    @State private var typing = ""
    @State private var adding = false

    var body: some View {
        let values = (node.params["operand"]?.string ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let set = { (list: [String]) in actions.set(node.id, ["operand": .string(list.joined(separator: ", "))]) }
        ForEach(values, id: \.self) { v in
            HStack(spacing: 4) {
                Text(v)
                Button { set(values.filter { $0 != v }) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .opacity(0.6)
                .help("Take out \(v)")
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(.primary.opacity(0.07)))
        }
        if adding {
            TextField("Value", text: $typing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .onSubmit {
                    let v = typing.trimmingCharacters(in: .whitespaces)
                    if !v.isEmpty, !values.contains(v) { set(values + [v]) }
                    typing = ""
                    adding = false
                }
        } else {
            Menu {
                ForEach(seen.filter { !values.contains($0) }, id: \.self) { v in Button(v) { set(values + [v]) } }
                if !seen.isEmpty { Divider() }
                Button("Type a Value…") { adding = true }
            } label: {
                Label(values.isEmpty ? "Add a value" : "Add", systemImage: "plus")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .overlay(Capsule().strokeBorder(.primary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        }
    }
}

/// The If branch's heading: the condition itself, right above the steps it
/// decides.
struct IfCondition: View {
    let node: Node
    let before: [Node]
    var empty = false
    var add: () -> Void = {}
    @Environment(\.flowActions) private var actions
    @Environment(\.flowSession) private var session

    var body: some View {
        let state = session?.engine.state(node.id) ?? StepState()
        let def = node.def!
        let p = ParamBinding(node: node, actions: actions)
        let port = { (id: String) in def.inputs.first { $0.id == id }! }
        let op = Condition(rawValue: node.params["op"]?.string ?? "") ?? .equals
        FlowRow(spacing: 8) {
            Text("If").fontWeight(.semibold).padding(.top, 3)
            SourcePicker(node: node, input: port("test"), before: before, shows: "value")
            ChoiceMenu {
                Text(op.label)
            } content: {
                Picker("", selection: p.text("op", "equals")) {
                    ForEach(Condition.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            if op == .oneOf {
                ValueChips(node: node, seen: seen(state))
            } else if !op.unary {
                // A score reads as a percentage on its card, so it is typed
                // as one here too. The flow keeps the 0 to 1 the engine
                // compares.
                let percent = checksScore && [.above, .below].contains(op)
                HStack(spacing: 4) {
                    TextField("Value", text: percent ? percentBinding : p.text("operand"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: percent ? 56 : 160)
                    if percent { Text("%") }
                    if !percent, !seen(state).isEmpty {
                        Menu {
                            ForEach(seen(state), id: \.self) { v in Button(v) { actions.set(node.id, ["operand": .string(v)]) } }
                        } label: { Image(systemName: "chevron.down") }
                        .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
                        .help("Pick a value from the last run")
                    }
                }
            }
        }
        .font(.callout)
        if empty { Chip(text: "Add a step", symbol: "plus", action: add).padding(.top, 6) }
    }

    /// The values what If checks had in the last run, each once, to pick
    /// from instead of typing them.
    private func seen(_ state: StepState) -> [String] {
        let values = (state.inputs["test"] ?? state.inputs["value"])?.present ?? []
        var out: [String] = []
        for v in values {
            let t = v.asText
            guard !t.isEmpty, t.count <= 40, !out.contains(t) else { continue }
            out.append(t)
            if out.count == 30 { break }
        }
        return out
    }

    /// Whether If checks a score: what is wired to Check, or else to Value.
    private var checksScore: Bool {
        let incoming = actions.graph.incoming(node.id)
        guard let edge = incoming.first(where: { $0.targetHandle == "test" }) ?? incoming.first(where: { $0.targetHandle == "value" })
        else { return false }
        return isScore(actions.graph.node(edge.source)?.type, edge.sourceHandle)
    }

    private var percentBinding: Binding<String> {
        Binding(
            get: {
                let raw = node.params["operand"]?.string ?? ""
                return Double(raw).map { Value.format(($0 * 1000).rounded() / 10) } ?? raw
            },
            set: { text in
                let stored = Double(text.replacingOccurrences(of: "%", with: "")).map { Value.format($0 / 100) } ?? text
                actions.set(node.id, ["operand": .string(stored)])
            }
        )
    }

}

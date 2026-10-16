import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Bindings into a step's settings that write through the document.
@MainActor
struct ParamBinding {
    let node: Node
    let actions: FlowActions

    func text(_ key: String, _ fallback: String = "") -> Binding<String> {
        Binding(get: { node.params[key]?.string ?? fallback }, set: { actions.set(node.id, [key: .string($0)]) })
    }

    func number(_ key: String, _ fallback: Double) -> Binding<Double> {
        Binding(get: { node.params[key]?.number ?? fallback }, set: { actions.set(node.id, [key: .number($0)]) })
    }

    func bool(_ key: String) -> Binding<Bool> {
        Binding(get: { node.params[key]?.bool ?? false }, set: { actions.set(node.id, [key: .bool($0)]) })
    }
}

/// A step's controls.
struct StepBody: View {
    let node: Node
    @Environment(\.flowActions) private var actions
    @Environment(\.flowSession) private var session

    nonisolated static func has(_ type: String) -> Bool {
        ["call", "watch", "schedule", "shortcut", "text", "textlist", "audio", "record", "image", "photos", "sketch", "whiteboard", "cleanboard", "if", "list",
         "template", "join", "convert", "readtext", "table", "gallery", "view", "folder", "files", "rename", "copy", "speak", "clear", "gist", "emo",
         "moderator"].contains(type)
    }

    var body: some View {
        let p = ParamBinding(node: node, actions: actions)
        let state = session?.engine.state(node.id) ?? StepState()
        switch node.type {
        case "text":
            TextEditor(text: p.text("text"))
                .font(.system(size: 13))
                .frame(minHeight: CGFloat(node.params["rows"]?.number ?? 5) * 18, maxHeight: 260)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if node.params["text"]?.string?.isEmpty ?? true {
                        Text("Type or paste anything").foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                    }
                }
        case "call", "watch", "schedule", "shortcut": TriggerBody(node: node, state: state)
        case "textlist": TextListBody(node: node)
        case "audio": AudioBody(node: node, state: state)
        case "record": RecordBody(node: node, state: state)
        case "image": PhotoBody(node: node, state: state)
        case "photos": PhotosBody(node: node)
        case "sketch": SketchBody(node: node, wrapped: false)
        case "whiteboard": SketchBody(node: node, wrapped: true)
        case "cleanboard":
            ShapeBoard(shapes: (state.inputs["shapes"]?.present ?? []).compactMap { if case .shape(let s) = $0 { s } else { nil } }, strokes: [])
                .frame(height: 220)
        case "readtext":
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Fast, for clean screenshots", isOn: p.bool("fast"))
                if let text = state.outputs?["text"] {
                    if case .stream(let items) = text {
                        ItemRows(items: items) { Text($0.asText.isEmpty ? "No text" : $0.asText).lineLimit(3) }
                    } else {
                        Text(text.asText.isEmpty ? "No text in this photo" : text.asText)
                            .textSelection(.enabled)
                            .lineLimit(12)
                    }
                }
                Text("Uses Apple's Vision on this Mac, not a Desert Ant model.").font(.caption).foregroundStyle(.secondary)
            }
        case "convert":
            // The formats for what comes in, or every format before it has run.
            let group = FileFormat.group(of: state.inputs["value"])
            Picker("To", selection: p.text("to", "")) {
                Text(group.map { "Automatic (\(FileFormat.of($0)[0].label))" } ?? "Automatic").tag("")
                ForEach(group.map { [$0] } ?? FileFormat.Group.allCases, id: \.self) { g in
                    Section(g.label) {
                        ForEach(FileFormat.of(g), id: \.self) { Text($0.label).tag($0.rawValue) }
                    }
                }
            }
            .fixedSize()
        case "if":
            HStack {
                Picker("", selection: p.text("op", "equals")) {
                    ForEach(Condition.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
                if !(Condition(rawValue: node.params["op"]?.string ?? "")?.unary ?? false) {
                    TextField("Value", text: p.text("operand"))
                        .textFieldStyle(.roundedBorder)
                }
            }
        case "list": ListBody(node: node)
        case "template": TemplateBody(node: node)
        case "join":
            Picker("", selection: p.text("separator", "newline")) {
                Text("New lines").tag("newline"); Text("Spaces").tag("space"); Text("Commas").tag("comma")
            }
            .labelsHidden()
        case "table": TableBody(node: node, state: state)
        case "gallery":
            if let photos = state.inputs["photos"] {
                let items = photos.items
                let captions = state.inputs["captions"]?.items.map { c -> String? in
                    guard let c else { return nil }
                    if case .list(let l) = c { return l.compactMap { $0?.asText }.joined(separator: ", ") }
                    return c.asText
                }
                let pairs = items.enumerated().compactMap { i, v in v?.photo.map { ($0, captions.flatMap { i < $0.count ? $0[i] : nil }) } }
                GalleryGrid(photos: pairs.map(\.0), captions: pairs.map(\.1))
            }
        case "view": ResultBody(node: node, state: state)
        case "folder": FolderBody(node: node, state: state)
        case "files": FilesBody(node: node, state: state)
        case "rename": RenameBody(node: node, state: state)
        case "copy": CopyBody(node: node, state: state)
        case "speak":
            HStack {
                Button("Speak") { Voice.speak(state.inputs["text"].asText, language: state.inputs["lang"]?.asText) }
                    .disabled(state.inputs["text"] == nil)
                Toggle("On every run", isOn: p.bool("auto"))
            }
        case "clear":
            Picker("Loudness", selection: p.text("loudness", "podcast")) {
                Text("Podcast").tag("podcast"); Text("Music apps").tag("spotify"); Text("Video").tag("youtube")
                Text("Broadcast").tag("broadcast"); Text("Keep as is").tag("off")
            }
        case "gist", "emo":
            Stepper(value: p.number("limit", 3), in: 1...(node.type == "gist" ? 8 : 5)) {
                Text("Limit \(node.params["limit"]?.int ?? 3)")
            }
        case "moderator":
            HStack {
                Text("Flag at")
                Slider(value: p.number("threshold", 0.5), in: 0.3...0.95, step: 0.05)
                Text(String(format: "%.2f", node.params["threshold"]?.number ?? 0.5)).font(.caption.monospacedDigit())
            }
        default:
            EmptyView()
        }
    }
}

/// A Template's text as it reads, with each {{a}} shown as the step that
/// fills it, and the raw template one click away. Once it has run, the filled
/// text below it says the rest.
struct TemplateBody: View {
    let node: Node
    @Environment(\.flowActions) private var actions
    @State private var editing = false

    var body: some View {
        let raw = node.params["template"]?.string ?? ""
        if editing || raw.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: ParamBinding(node: node, actions: actions).text("template"))
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 160)
                    .scrollContentBackground(.hidden)
                HStack(alignment: .firstTextBaseline) {
                    Text(legend)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if !raw.isEmpty { Button("Done") { editing = false }.controlSize(.small) }
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(readable(raw))
                    .font(.system(size: 13))
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { editing = true }
                Button("Edit") { editing = true }
                    .controlSize(.small)
                    .help("Edit the template")
            }
        }
    }

    /// What fills a placeholder: the step wired into that input, and the
    /// output it gives when the step has more than one.
    private func source(_ input: String) -> String? {
        guard let edge = actions.graph.incoming(node.id).first(where: { $0.targetHandle == input }) else { return nil }
        let name = actions.graph.name(of: edge.source)
        let outputs = actions.graph.node(edge.source)?.def?.outputs ?? []
        guard outputs.count > 1, let port = outputs.first(where: { $0.id == edge.sourceHandle }) else { return name }
        return "\(name) \(port.label.lowercased())"
    }

    /// The template with its placeholders named.
    private func readable(_ raw: String) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(raw)
        while let m = rest.firstMatch(of: #/\{\{\s*(a|b|c|date|time)(\|lang)?\s*\}\}/#) {
            out += AttributedString(String(rest[..<m.range.lowerBound]))
            let key = String(m.output.1)
            let name: String
            switch key {
            case "date": name = "today\u{2019}s date"
            case "time": name = "the time"
            default: name = source(key) ?? "nothing yet (\(key))"
            }
            var part = AttributedString(name)
            part.foregroundColor = .accentColor
            part.font = .system(size: 13, weight: .semibold)
            out += part
            rest = rest[m.range.upperBound...]
        }
        out += AttributedString(String(rest))
        return out
    }

    /// Which placeholder is which, under the raw template.
    private var legend: String {
        let wired = ["a", "b", "c"].compactMap { key in source(key).map { "{{\(key)}} is \($0)" } }
        let given = wired.isEmpty ? "Wire a step into a, b, or c to use it here." : wired.joined(separator: ", ") + "."
        return given + " {{date}} is today\u{2019}s date."
    }
}

struct TextListBody: View {
    let node: Node
    @Environment(\.flowActions) private var actions

    var body: some View {
        let items = node.params["items"]?.strings ?? []
        let set = { (list: [String]) in actions.set(node.id, ["items": .array(list.map { .string($0) })]) }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, v in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(i + 1)").font(.caption.monospaced()).foregroundStyle(.tertiary).frame(width: 16).padding(.top, 5)
                    TextField("Type a message", text: Binding(get: { v }, set: { new in
                        var list = items
                        if i < list.count { list[i] = new }
                        set(list)
                    }), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    Button { set(items.enumerated().filter { $0.offset != i }.map(\.element)) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .help("Remove")
                }
            }
            Button("Add", systemImage: "plus") { set(items + [""]) }
                .controlSize(.small)
        }
    }
}

struct ListBody: View {
    let node: Node
    @Environment(\.flowActions) private var actions

    var body: some View {
        let p = ParamBinding(node: node, actions: actions)
        let op = ListOp(rawValue: node.params["op"]?.string ?? "") ?? .count
        HStack {
            Picker("", selection: p.text("op", "count")) {
                ForEach(ListOp.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
            }
            .labelsHidden()
            .fixedSize()
            if op.takesNumber {
                TextField("", value: p.number("n", 1), format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 50)
            }
            if op.keeps {
                Text("Keep")
                TextField("All", value: Binding(
                    get: { (node.params["n"]?.number ?? 0) > 0 ? node.params["n"]?.number : nil },
                    set: { actions.set(node.id, ["n": .number(max(0, $0 ?? 0))]) }
                ), format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 50)
            }
        }
    }
}

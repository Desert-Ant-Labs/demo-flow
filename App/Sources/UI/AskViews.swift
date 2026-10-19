import DesertAntUI
import SwiftUI

/// Ask's card: what it asks and how, then the question itself while the flow
/// waits on it, or the answer once it is given.
struct AskBody: View {
    let node: Node
    let state: StepState
    @Environment(\.flowActions) private var actions
    @Environment(\.flowSession) private var session

    private var kind: AskKind { AskKind(node.params) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let question = session?.engine.questions[node.id] {
                QuestionView(question: question) { session?.engine.answer(node.id, $0) }
                    .padding(12)
                    .background(DA.Color.accent.opacity(0.08), in: .rect(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DA.Color.accent.opacity(0.5)))
            } else {
                status
            }
            AskSettings(node: node, kind: kind)
        }
    }

    /// Where the step is when it is not asking.
    @ViewBuilder private var status: some View {
        switch state.status {
        case .done:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.bubble").foregroundStyle(Theme.success)
                Text(said).fontWeight(.medium).lineLimit(2)
                Spacer(minLength: 4)
                Button("Ask Again", action: askAgain)
                    .buttonStyle(.link)
                    .font(.callout)
                    .help("Clear the answer and ask the question again")
            }
            .accessibilityElement(children: .contain)
        case .idle, .skipped:
            Label(state.status == .skipped ? "Nothing came in to ask about" : "Asks once the steps before it are done",
                  systemImage: "bubble.left")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .running, .error:
            EmptyView()
        }
    }

    /// The answer as the step's results tell it.
    private var said: String {
        let out = state.outputs ?? [:]
        if let answer = out["answer"]?.string { return answer.isEmpty ? "Answered with nothing" : "\u{201C}\(answer)\u{201D}" }
        if kind == .pick {
            let picked = out["yes"]?.present.count ?? 0, total = picked + (out["no"]?.present.count ?? 0)
            return "\(picked) of \(total) picked"
        }
        if kind != .confirm, out["no"] != nil { return "Skipped" }
        return out["yes"] != nil ? "Answered Yes" : "Answered No"
    }

    private func askAgain() {
        session?.engine.forget(node.id)
        actions.rerun()
    }
}

/// How Ask asks: the kind of answer, the question, and what a run nobody
/// watches does when no answer comes.
private struct AskSettings: View {
    let node: Node
    let kind: AskKind
    @Environment(\.flowActions) private var actions

    var body: some View {
        let p = ParamBinding(node: node, actions: actions)
        VStack(alignment: .leading, spacing: 8) {
            Picker("Ask for", selection: Binding(get: { kind }, set: change)) {
                ForEach(AskKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .fixedSize()
            TextField("Question", text: p.text("question", kind.question), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            switch kind {
            case .choose:
                TextField("Answers, separated by commas", text: p.text("options"))
                    .textFieldStyle(.roundedBorder)
            case .type:
                TextField("Answer it starts with", text: p.text("answer"))
                    .textFieldStyle(.roundedBorder)
            case .confirm, .pick:
                EmptyView()
            }
            Text("{{items}} counts what it asks about, as \u{201C}8 photos\u{201D}, {{count}} gives just the number, and {{a}} reads it out.")
                .font(.caption)
                .foregroundStyle(.secondary)
            WhenNobodyAnswers(node: node, kind: kind)
        }
    }

    /// A new kind gets its own question, unless someone wrote one.
    private func change(_ new: AskKind) {
        var patch: Params = ["kind": .string(new.rawValue)]
        let question = node.params["question"]?.string ?? ""
        if question.isEmpty || AskKind.allCases.contains(where: { $0.question == question }) {
            patch["question"] = .string(new.question)
        }
        actions.set(node.id, patch)
    }
}

/// For a flow that runs on its own: how long its question waits, and what
/// the run does after that.
private struct WhenNobodyAnswers: View {
    let node: Node
    let kind: AskKind
    @Environment(\.flowActions) private var actions

    var body: some View {
        let p = ParamBinding(node: node, actions: actions)
        let wait = node.params["wait"]?.number ?? 0
        DisclosureGroup("When nobody answers") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Wait", selection: p.number("wait", 0)) {
                    ForEach(AskStep.waits, id: \.self) { Text(AskStep.label(forWait: $0)).tag($0) }
                }
                .fixedSize()
                Picker("Then", selection: p.text("fallback", Fallback.no.rawValue)) {
                    ForEach(Fallback.allCases, id: \.self) { Text(label($0)).tag($0.rawValue) }
                }
                .fixedSize()
                .disabled(wait == 0)
                Text("Only for a flow that runs on its own. With the flow open, the question waits for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
        .font(.callout)
    }

    private func label(_ fallback: Fallback) -> String {
        switch (fallback, kind) {
        case (.stop, _): "Stop the flow"
        case (.yes, .confirm): "Go on with Yes"
        case (.yes, .pick): "Go on with all of them"
        case (.yes, .choose): "Go on with the first answer"
        case (.yes, .type): "Go on with the answer it starts with"
        case (.no, .pick): "Go on with none"
        case (.no, _): "Go on with No"
        }
    }
}

/// A question and the ways to answer it, in a card or the review window.
struct QuestionView: View {
    let question: Question
    /// In the review window: bigger photos, and Return answers.
    var large = false
    let answer: (Answer) -> Void

    @State private var picked: Set<Int> = []
    @State private var typed = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(question.text)
                    .font(large ? .title3.weight(.semibold) : .body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(DA.Color.accent)
            }
            if question.kind == .pick {
                PickList(items: question.items, picked: $picked, large: large)
            } else if !question.items.isEmpty {
                ItemsGlance(items: question.items, large: large)
            }
            controls
            if let deadline = question.deadline, let fallback = question.fallback {
                Text("Goes on with \(fallback.said(question)) \(Text(deadline, style: .relative))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: question.id, initial: true) { start() }
    }

    @ViewBuilder private var controls: some View {
        switch question.kind {
        case .confirm:
            HStack {
                Spacer()
                Button("No") { answer(.no) }
                Button("Yes") { answer(.yes) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(large ? .defaultAction : nil)
            }
        case .pick:
            HStack {
                Button("All") { picked = Set(question.items.indices) }.buttonStyle(.link)
                Button("None") { picked = [] }.buttonStyle(.link)
                Spacer()
                Button(picked.isEmpty ? "Go On with None" : "Go On with \(picked.count)") { answer(.picked(picked.sorted())) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(large ? .defaultAction : nil)
            }
        case .choose:
            VStack(alignment: .leading, spacing: 8) {
                FlowRow(spacing: 6) {
                    ForEach(question.options, id: \.self) { option in
                        Button(option) { answer(.chose(option)) }
                    }
                }
                Button("Skip") { answer(.no) }.buttonStyle(.link).font(.callout)
            }
        case .type:
            VStack(alignment: .trailing, spacing: 8) {
                TextField("Answer", text: $typed, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .focused($typing)
                    .onSubmit { answer(.typed(typed)) }
                HStack {
                    Button("Skip") { answer(.no) }
                    Button("Send") { answer(.typed(typed)) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(large ? .defaultAction : nil)
                }
            }
        }
    }

    /// A new question starts with every item ticked and its suggested words
    /// typed. In the review window, typing starts at once.
    private func start() {
        picked = Set(question.items.indices)
        typed = question.suggestion
        typing = large && question.kind == .type
    }
}

/// The items to pick from: photos as a grid of tiles, anything else as a
/// list of checkboxes.
private struct PickList: View {
    let items: [Value]
    @Binding var picked: Set<Int>
    let large: Bool

    var body: some View {
        if items.allSatisfy({ $0.photo != nil }) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: large ? 120 : 64), spacing: 6)], spacing: 6) {
                ForEach(items.indices, id: \.self) { i in
                    PhotoTile(photo: items[i].photo!, on: picked.contains(i)) { toggle(i) }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { i in
                    Toggle(isOn: Binding(get: { picked.contains(i) }, set: { _ in toggle(i) })) {
                        Text(items[i].asText).lineLimit(2)
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    private func toggle(_ i: Int) {
        if picked.contains(i) { picked.remove(i) } else { picked.insert(i) }
    }
}

/// A photo to tick or untick. An unticked photo fades, so what goes on stands out.
private struct PhotoTile: View {
    let photo: Photo
    let on: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { Image(decorative: photo.thumb, scale: 1).resizable().scaledToFill() }
                .clipShape(.rect(cornerRadius: 8))
                .opacity(on ? 1 : 0.35)
                .overlay(alignment: .topTrailing) {
                    // White on a dark disc reads on any photo, light or dark.
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .padding(4)
                }
                .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(photo.name)
        .accessibilityValue(on ? "Picked" : "Not picked")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// What a question is about, at a glance: the first few photos, or the first
/// few lines, and how many more.
private struct ItemsGlance: View {
    let items: [Value]
    let large: Bool

    var body: some View {
        let photos = items.allSatisfy { $0.photo != nil }
        let shown = photos ? (large ? 8 : 5) : 3
        HStack(spacing: 6) {
            if photos {
                ForEach(items.prefix(shown).indices, id: \.self) { i in
                    Image(decorative: items[i].photo!.thumb, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: large ? 64 : 40, height: large ? 64 : 40)
                        .clipShape(.rect(cornerRadius: 6))
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items.prefix(shown).indices, id: \.self) { i in
                        Text(items[i].asText).lineLimit(large ? 3 : 1)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            if items.count > shown {
                Text("and \(items.count - shown) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AskStep.counted(items))
    }
}

/// The heading over one side of an Ask in the step list.
struct AskSide: View {
    let node: Node
    let yes: Bool
    let empty: Bool
    let add: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(yes ? "Yes" : "No").fontWeight(.semibold)
            Text(detail).foregroundStyle(.secondary)
            if empty { Chip(text: "Add a step", symbol: "plus", action: add) }
        }
        .font(.callout)
        .padding(.top, 5)
    }

    private var detail: String {
        switch AskKind(node.params) {
        case .confirm: yes ? "when you answer yes" : "when you answer no"
        case .pick: yes ? "the ones you pick" : "the rest"
        case .choose, .type: yes ? "once you answer" : "when you skip"
        }
    }
}

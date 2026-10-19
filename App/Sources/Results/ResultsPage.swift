import DesertAntUI
import SwiftUI

/// The flow's results, in the pane beside the flow: any question the flow
/// waits on, then each result as large as the pane allows, with ways to copy,
/// save, share, and export them.
struct ResultsPage: View {
    let graph: Graph
    let session: FlowSession
    /// Shows the step a result came from, in the flow beside it.
    let find: (String) -> Void
    @Environment(\.flowActions) private var actions

    var body: some View {
        let outcomes = Outcome.all(in: graph, engine: session.engine)
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    ResultsHeader(graph: graph, session: session, outcomes: outcomes)
                    if let path = session.fileURL?.path, Trigger.node(of: graph) != nil {
                        RunHistory(path: path)
                    }
                    ForEach(session.engine.questions.values.sorted { $0.step < $1.step }) { question in
                        WaitingQuestion(question: question, name: graph.name(of: question.step)) {
                            session.engine.answer(question.step, $0)
                        }
                    }
                    if outcomes.isEmpty {
                        ContentUnavailableView {
                            Label("No Results Yet", systemImage: "checkmark.seal")
                        } description: {
                            Text("Add a Result step, or end the flow on any step, and what it gives shows here.")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                    ForEach(outcomes) { outcome in
                        OutcomeSection(outcome: outcome) { find(outcome.id) }
                            .id(outcome.id)
                    }
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: session.reveal, initial: true) { _, id in
                guard let id else { return }
                withAnimation(Self.reduceMotion ? nil : .smooth) { scroll.scrollTo(id, anchor: .top) }
                session.reveal = nil
            }
        }
        .background(Theme.canvas)
    }

    private static var reduceMotion: Bool { FlowSession.reduceMotion }
}

/// Where the run is, and the exports of everything in the pane. The flow's
/// own name is beside it already, so the pane is just "Results".
private struct ResultsHeader: View {
    let graph: Graph
    let session: FlowSession
    let outcomes: [Outcome]
    @Environment(\.flowActions) private var actions

    var body: some View {
        let engine = session.engine
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Results")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.4)
                status(engine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            ExportMenu(title: actions.title(), description: graph.meta.description, outcomes: outcomes)
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(outcomes.allSatisfy(\.isEmpty))
        }
    }

    @ViewBuilder private func status(_ engine: Engine) -> some View {
        if !engine.questions.isEmpty {
            Label("Waiting for your answer", systemImage: "questionmark.bubble")
        } else if engine.running {
            HStack(spacing: 10) {
                ProgressView(value: engine.progress).frame(width: 100)
                Text(running(engine) ?? "Running").lineLimit(1)
            }
        } else if let took = took(engine) {
            Label(took, systemImage: "cpu")
        } else {
            Text("Runs as soon as it has what it needs.")
        }
    }

    /// The step at work and what it is doing, as the menu bar says it.
    private func running(_ engine: Engine) -> String? {
        guard let id = engine.busy.sorted().first, let def = graph.node(id)?.def else { return nil }
        let name = def.model?.info.name ?? def.title
        guard let doing = activity(engine.state(id), model: def.model.map { ModelHub.shared.state($0) }, name: name) else { return nil }
        // "Preparing Eye for this Mac" names the model already; "Item 3 of 8" doesn't.
        return doing.contains(name) ? doing : "\(name), \(doing.prefix(1).lowercased() + doing.dropFirst())"
    }

    /// "8 steps in 1.3s on this Mac".
    private func took(_ engine: Engine) -> String? {
        let done = graph.nodes.map { engine.state($0.id) }.filter { $0.status == .done }
        guard !done.isEmpty else { return nil }
        let seconds = done.compactMap(\.ms).reduce(0, +) / 1000
        let time = Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds, .milliseconds], width: .narrow, maximumUnitCount: 2))
        return "\(done.count) \(done.count == 1 ? "step" : "steps") in \(time) on this Mac"
    }
}

/// A question the flow waits on, at the top of the page.
private struct WaitingQuestion: View {
    let question: Question
    let name: String
    let answer: (Answer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name.uppercased())
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            QuestionView(question: question, large: true, answer: answer)
        }
        .padding(20)
        .background(DA.Color.accent.opacity(0.07), in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(DA.Color.accent.opacity(0.45)))
    }
}

/// One result: its name and actions, then the result itself, or where it is
/// while it has none.
private struct OutcomeSection: View {
    let outcome: Outcome
    let showStep: () -> Void
    @Environment(\.flowSession) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let model = outcome.model {
                Circle().fill(Theme.model(model).fill).frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }
            Text(outcome.name).font(.title2.weight(.semibold))
            if let summary { Text(summary).foregroundStyle(.secondary) }
            if outcome.state.status == .running { ProgressView().controlSize(.small) }
            Spacer(minLength: 12)
            OutcomeActions(outcome: outcome, showStep: showStep)
        }
        .accessibilityElement(children: .contain)
    }

    /// How much there is, in a few words: "8 photos", "12 rows".
    private var summary: String? {
        switch outcome.content {
        case .photos(let items): items.count == 1 ? "1 photo" : "\(items.count) photos"
        case .table(_, let rows): rows.count == 1 ? "1 row" : "\(rows.count) rows"
        case .value(let v, _) where v.isList || v.isStream: AskStep.counted(v.present)
        default: nil
        }
    }

    @ViewBuilder private var content: some View {
        let state = outcome.state
        if let error = state.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
        } else if state.status == .skipped {
            Text("Not taken on this run.").foregroundStyle(.secondary)
        } else if let content = outcome.content, !outcome.isEmpty {
            OutcomeContent(content: content)
                .opacity(state.status == .running ? 0.5 : 1)
                .animation(.default, value: state.status == .running)
        } else {
            Placeholder(text: waiting)
        }
    }

    private var waiting: String {
        let state = outcome.state
        if let doing = activity(state, model: outcome.model.map { ModelHub.shared.state($0) }, name: outcome.model?.info.name ?? "the model") {
            return doing
        }
        return "Shows here once the steps before it have run."
    }
}

/// Where a result will be, while the flow works toward it.
private struct Placeholder: View {
    let text: String

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(.quaternary.opacity(0.4))
            .frame(height: 120)
            .overlay {
                Text(text).foregroundStyle(.secondary)
            }
    }
}

/// Copy, save, and share one result, and go to the step it came from, as
/// round glass buttons over the page.
private struct OutcomeActions: View {
    let outcome: Outcome
    let showStep: () -> Void
    @State private var copied = false

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                if let value = outcome.value, !outcome.isEmpty {
                    if value.audio == nil, case .value = outcome.content { copy(value) }
                    save(value)
                    share(value)
                }
                Button("Find Step", systemImage: "scope", action: showStep)
                    .help("Show the step this came from")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .fixedSize()
    }

    /// Copies, and says so for a moment.
    private func copy(_ value: Value) -> some View {
        Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
            Exports.copy(value)
            copied = true
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }

    /// The ways the result can be saved, as a menu.
    @ViewBuilder private func save(_ value: Value) -> some View {
        let options = Exports.saveOptions(value, title: outcome.name)
        if !options.isEmpty {
            Menu("Save", systemImage: "square.and.arrow.down") {
                ForEach(options) { option in
                    Button(option.label + "\u{2026}") {
                        let window = NSApp.keyWindow
                        Task { Exports.save(await option.files(), window: window) }
                    }
                }
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
        }
    }

    /// The system share menu. A photo or a recording is written to a file
    /// only once the menu asks for it.
    @ViewBuilder private func share(_ value: Value) -> some View {
        let photos = value.present.compactMap(\.photo)
        if !photos.isEmpty, photos.count == value.present.count {
            ShareLink(items: photos.map(PhotoTransfer.init)) { item in
                SharePreview(item.photo.name, image: Image(decorative: item.photo.thumb, scale: 1))
            }
        } else if let clip = value.audio {
            ShareLink(item: ClipTransfer(clip: clip, name: Exports.slug(outcome.name)), preview: SharePreview(outcome.name))
        } else {
            ShareLink(item: Exports.plainText(value), preview: SharePreview(outcome.name))
        }
    }
}

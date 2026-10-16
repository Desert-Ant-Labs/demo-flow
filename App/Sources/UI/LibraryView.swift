import DesertAntUI
import SwiftUI

/// The library: your flows, then the templates, as a grid of small cards.
/// A flow that starts with a trigger runs on its own once on; its card says
/// so quietly, and a right-click turns it on or off.
struct LibraryView: View {
    @Environment(\.newDocument) private var newDocument
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var group: Example.Group?
    @State private var model: ModelID?
    /// Only the flows that run on their own, split into on and off.
    @State private var automatic = false
    @State private var mine: [SavedFlow] = []
    @State private var center = TriggerCenter.shared
    private let grid = [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                filters
                if automatic { automaticFlows } else { allFlows }
                Text("Book reading from LibriVox, in the public domain. Photos from the Desert Ant Labs library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .tint(DA.Color.accent)
        }
        .background(Theme.canvas)
        .frame(minWidth: 520, minHeight: 420)
        .task(id: center.flows) { mine = await SavedFlow.mine() }
        .task { if Snapshots.show == "automatic" { automatic = true } }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Open…", systemImage: "folder") { NSDocumentController.shared.openDocument(nil) }
                    .help("Open a flow file")
                Button("New Flow", systemImage: "plus") { open(Graph()) }
                    .help("Start a flow from scratch")
            }
        }
    }

    private func fits(_ g: Example.Group, _ models: [ModelID]) -> Bool {
        (group == nil || g == group) && (model == nil || models.contains(model!))
    }

    @ViewBuilder private var allFlows: some View {
        let saved = mine.filter { fits($0.group, $0.models) }
        if !saved.isEmpty {
            section("My flows") {
                ForEach(saved) { flow in card(flow) }
            }
            Text("Templates").font(.title2.weight(.bold)).padding(.top, 8)
        }
        let shown = Example.all.filter { fits($0.group, $0.models) }
        ForEach(Example.Group.allCases, id: \.self) { g in
            let list = shown.filter { $0.group == g }
            if !list.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(g.label).font(.headline)
                    LazyVGrid(columns: grid, spacing: 12) {
                        ForEach(list) { card($0) }
                    }
                }
            }
        }
        if shown.isEmpty {
            Text("No templates match these filters yet.").foregroundStyle(.secondary)
        }
    }

    /// The flows that run on their own, on first, then the templates that can.
    @ViewBuilder private var automaticFlows: some View {
        let own = mine.filter { $0.automatic && fits($0.group, $0.models) }
        let templates = Example.all.filter { $0.automatic && center.entry(template: $0.id) == nil && fits($0.group, $0.models) }
        let on = own.filter { center.isOn($0.url.path) }
        let off = own.filter { !center.isOn($0.url.path) }
        if !on.isEmpty {
            section("On") { ForEach(on) { card($0) } }
        }
        if !off.isEmpty || !templates.isEmpty {
            section("Off") {
                ForEach(off) { card($0) }
                ForEach(templates) { card($0) }
            }
        }
        if on.isEmpty && off.isEmpty && templates.isEmpty {
            Text("No flows that run on their own match these filters.").foregroundStyle(.secondary)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title2.weight(.bold))
            LazyVGrid(columns: grid, spacing: 12) { content() }
        }
    }

    private func card(_ flow: SavedFlow) -> some View {
        let path = flow.url.path
        let trigger = center.triggers.first { $0.flow == .file(path: path) }
        return FlowCard(title: flow.title, detail: "Edited \(flow.edited.formatted(.relative(presentation: .named)))",
                        models: flow.models, state: flow.automatic ? AutoState(path: path) : nil) {
            openSaved(flow.url)
        }
        .contextMenu {
            if flow.automatic {
                Button(center.isOn(path) ? "Turn Off" : "Turn On") { center.setOn(!center.isOn(path), path: path) }
                Divider()
            }
            Button("Open") { openSaved(flow.url) }
            if let trigger { Button("Run Now") { center.runNow(trigger) } }
            Button("Duplicate") { duplicate(flow.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([flow.url]) }
        }
    }

    private func card(_ example: Example) -> some View {
        let copy = center.entry(template: example.id)
        return FlowCard(title: example.title, detail: example.blurb, models: example.models,
                        state: example.automatic ? AutoState(path: copy?.path) : nil) {
            open(example.graph)
        }
        .contextMenu {
            if example.automatic {
                if AutomaticTemplates.isOn(example) {
                    Button("Turn Off") { AutomaticTemplates.turnOff(example) }
                } else {
                    Button("Turn On") { _ = try? AutomaticTemplates.turnOn(example) }
                }
                Divider()
            }
            Button("Open") { open(example.graph) }
        }
    }

    /// Copies the flow next to itself as "name copy", or "name copy 2" when
    /// that is taken, and opens the copy.
    private func duplicate(_ url: URL) {
        let copy = Exports.free(url.deletingPathExtension().lastPathComponent + " copy.flow", in: url.deletingLastPathComponent())
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            NSDocumentController.shared.openDocument(withContentsOf: copy, display: true) { _, _, _ in }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// One row of tags: what an example starts from, then the models it
    /// uses. One of each narrows to both.
    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowRow(spacing: 6) {
                pill("All", on: group == nil && model == nil && !automatic) { group = nil; model = nil; automatic = false }
                pill("Automatic", symbol: "bolt.fill", on: automatic) { automatic.toggle() }
                ForEach(Example.Group.allCases, id: \.self) { g in
                    let count = Example.all.filter { $0.group == g }.count
                    pill("\(g.label) \(count)", on: group == g) { group = group == g ? nil : g }
                }
            }
            FlowRow(spacing: 6) {
                ForEach(ModelID.allCases.filter { m in Example.all.contains { $0.models.contains(m) } }) { m in
                    pill(m.info.name, dot: Theme.model(m).fill, on: model == m) { model = model == m ? nil : m }
                        .help(m.info.about)
                }
            }
        }
    }

    private func pill(_ title: String, dot: Color? = nil, symbol: String? = nil, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
                if let dot {
                    Circle().fill(dot).frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.35)))
                }
                Text(title)
            }
                .font(.callout.weight(on ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(on ? AnyShapeStyle(.primary.opacity(0.12)) : AnyShapeStyle(.clear)))
                .overlay(Capsule().strokeBorder(Theme.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func openSaved(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        dismissWindow(id: "library")
    }

    private func open(_ graph: Graph) {
        newDocument(FlowDocument(graph: graph))
        dismissWindow(id: "library")
    }
}

/// A flow you opened or saved, from the Mac's list of recent documents.
struct SavedFlow: Identifiable, Sendable {
    let url: URL
    let title: String
    let models: [ModelID]
    let group: Example.Group
    let edited: Date
    /// The type of its first input step, which says what a run can hand it.
    let start: String?
    /// What it can take from files dropped on it.
    let takes: [InputKind]

    var id: URL { url }
    var automatic: Bool { start.map(TriggerSteps.isTrigger) ?? false }

    /// Your flows: the ones that run on their own, wherever they are, and the
    /// ones you opened lately.
    @MainActor static func mine() async -> [SavedFlow] {
        let kept = TriggerCenter.shared.flows.map { URL(filePath: $0.path) }
        let recent = await recent()
        let extra = await load(kept.filter { url in !recent.contains { $0.url.standardizedFileURL == url.standardizedFileURL } })
        return (recent + extra).sorted { $0.edited > $1.edited }
    }

    @MainActor static func recent() async -> [SavedFlow] {
        await load(NSDocumentController.shared.recentDocumentURLs)
    }

    private static func load(_ urls: [URL]) async -> [SavedFlow] {
        await Task.detached {
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
            return urls.compactMap { url -> SavedFlow? in
                // A file in a temporary folder was only ever looked at, never kept.
                guard !url.resolvingSymlinksInPath().path.hasPrefix(temporary), !url.path.hasPrefix("/private/tmp/"), !url.path.hasPrefix("/tmp/"),
                      let text = try? String(contentsOf: url, encoding: .utf8), let g = try? FlowFile.read(text) else { return nil }
                let start = g.ordered.first { $0.def?.category == .input }?.type
                let edited = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return SavedFlow(url: url, title: g.meta.title.isEmpty ? url.deletingPathExtension().lastPathComponent : g.meta.title,
                                 models: g.models, group: Example.Group(start: start), edited: edited,
                                 start: TriggerCenter.input(of: g)?.type, takes: g.takes)
            }
            .sorted { $0.edited > $1.edited }
        }.value
    }
}

/// The models a flow runs, each name after its own color.
struct ModelNames: View {
    let models: [ModelID]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(models) { m in
                HStack(spacing: 4) {
                    Circle().fill(Theme.model(m).fill).frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.35)))
                    Text(m.info.name)
                }
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

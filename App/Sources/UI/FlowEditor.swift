import AppKit
import DesertAntUI
import QuickLook
import SwiftUI

/// What the menus can ask of the front window.
@MainActor
final class EditorCommands {
    var run: () -> Void = {}
    var addStep: () -> Void = {}
    var tidy: () -> Void = {}
    var copyLink: () -> Void = {}
    var openInBrowser: () -> Void = {}
    var delete: () -> Void = {}
    var duplicate: () -> Void = {}
    var step: (Int) -> Void = { _ in }
    /// Whether the flow starts with a trigger step and is saved, so it can run on its own.
    var canRunOnItsOwn: () -> Bool = { false }
    var turnOn: (Bool) -> Void = { _ in }
    weak var session: FlowSession?

    var runsOnItsOwn: Bool { session?.fileURL.map { TriggerCenter.shared.isOn($0.path) } ?? false }
}

extension FocusedValues {
    @Entry var flowCommands: EditorCommands?
    /// Whether the front window shows the canvas, which the zoom commands
    /// act on.
    @Entry var canvasShowing: Bool?
}

/// What a run depends on: everything but where the cards sit, how wide, and
/// what they are called.
private struct RunKey: Equatable {
    private static let layoutOnly: Set<String> = ["w", "as", "columns", "label"]

    let nodes: [String]
    let params: [Params]
    let edges: [String]

    init(_ g: Graph) {
        nodes = g.nodes.map { "\($0.id):\($0.type)" }
        params = g.nodes.map { $0.params.filter { !Self.layoutOnly.contains($0.key) } }
        edges = g.edges.map(\.id).sorted()
    }
}

/// One flow's window.
struct FlowEditor: View {
    @Binding var document: FlowDocument
    var fileURL: URL? = nil
    @State private var session = FlowSession()
    @State private var commands = EditorCommands()
    @State private var actions: FlowActions
    /// Steps or Canvas, for this window when it is opened again.
    @SceneStorage("view") private var windowView: String?
    @State private var quickLook: URL?
    @State private var quickLookList: [URL] = []
    @State private var runTask: Task<Void, Never>?
    @State private var layoutTask: Task<Void, Never>?
    @Environment(\.newDocument) private var newDocument
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(document: Binding<FlowDocument>, fileURL: URL? = nil) {
        _document = document
        self.fileURL = fileURL
        _actions = State(initialValue: FlowActions(graph: document.wrappedValue.graph))
    }

    private var graph: Graph { document.graph }

    var body: some View {
        content
            .overlay(alignment: .bottom) { toast }
            .overlay { if graph.nodes.isEmpty { empty } }
            .toolbar { toolbar }
            .inspector(isPresented: $session.showResults) {
                ResultsPanel(graph: graph, session: session) { n in
                    session.show(n.id)
                    if session.view == .canvas { session.focus(n, arranged: graph.meta.arranged) }
                }
                .inspectorColumnWidth(min: 300, ideal: 380, max: 620)
            }
            .sheet(item: $session.palette) { request in
                PaletteView(anchor: request.onlyInputs ? nil : request.after.flatMap { graph.node($0.node) } ?? anchor,
                            onlyInputs: request.onlyInputs) { type in
                    session.palette = nil
                    if let after = request.after { insert(type, after: after.node, after.output, before: request.before) } else { addNode(type) }
                }
            }
            .environment(\.flowActions, actions)
            .environment(\.flowSession, session)
            .environment(\.openQuickLook, OpenQuickLook { all, photo in
                quickLookList = all.map(Exports.file(for:))
                quickLook = Exports.file(for: photo)
            })
            .quickLookPreview($quickLook, in: quickLookList)
            .focusedSceneValue(\.flowCommands, commands)
            .focusedSceneValue(\.canvasShowing, session.view == .canvas)
            .onPasteCommand(of: [.fileURL, .image, .plainText]) { _ in inbox.paste() }
            .onDeleteCommand { deleteSelection() }
            .onExitCommand { session.selection = [] }
            .onChange(of: RunKey(graph)) {
                scheduleRun()
                if let fileURL { TriggerCenter.shared.edited(fileURL.path, graph) }
            }
            .onChange(of: graph) { actions.graph = graph }
            .onChange(of: session.view) { windowView = session.view.rawValue }
            .onChange(of: session.sizes) { scheduleLayout() }
            .onChange(of: session.canvasSize) { if session.homed && !session.touched { session.home(graph, animated: false) } }
            .onChange(of: graph.nodes.count) { scheduleLayout() }
            .onChange(of: fileURL) { session.fileURL = fileURL }
            .background(WindowReader {
                session.window = $0
                session.nameUntitled(graph.meta.title)
            })
            .onDisappear { TriggerCenter.shared.forget(session) }
            .task {
                session.fileURL = fileURL
                if let fileURL, let engine = TriggerCenter.shared.engine(for: fileURL) { session.engine = engine }
                TriggerCenter.shared.watch(session)
                if let view = windowView.flatMap(FlowView.init) { session.restore(view) }
                setUpActions()
                setUpCommands()
                switch Snapshots.show {
                case "results": session.showResults = true
                case "palette": session.palette = .init()
                default: break
                }
                ModelHub.shared.prefetch(graph.models)
                scheduleRun(after: .zero)
                scheduleLayout()
            }
            .frame(minWidth: 760, minHeight: 520)
    }

    @ViewBuilder private var content: some View {
        switch session.view {
        case .canvas:
            CanvasView(graph: $document.graph, session: session, onDropTargeted: inbox.targeted) { urls, at in inbox.drop(urls, at: at) }
        case .steps:
            StepListView(graph: $document.graph, session: session)
                .dropDestination(for: URL.self) { urls, _ in
                    inbox.drop(urls, at: nil)
                    return true
                } isTargeted: { inbox.targeted($0) }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { openWindow(id: "library") } label: {
                Label("Library", systemImage: "square.grid.2x2")
            }
            .help("Your flows and the templates (⇧⌘N)")
        }
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $session.view) {
                Text("Steps").tag(FlowView.steps)
                Text("Canvas").tag(FlowView.canvas)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Show the flow as a list of steps or as a canvas")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { session.palette = .init(onlyInputs: graph.nodes.isEmpty) } label: {
                Label(anchor == nil ? "Add a Step" : "Add Next Step", systemImage: "plus")
            }
            .help(anchor == nil ? "Add a step" : "Add the next step after the selected one")
            if session.view == .canvas {
                Menu {
                    Button("Zoom In") { session.zoom(by: 1.25) }
                    Button("Zoom Out") { session.zoom(by: 0.8) }
                    Button("Show the Whole Flow") { session.home(graph) }
                    Divider()
                    Button("Tidy Up") { tidy() }
                } label: {
                    Label("Zoom", systemImage: "arrow.up.left.and.arrow.down.right")
                } primaryAction: {
                    session.home(graph)
                }
                .help("Show the whole flow")
            }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Copy Link", systemImage: "link") { copyLink() }
                Button("Open in Browser", systemImage: "safari") { NSWorkspace.shared.open(FlowLink.url(for: graph)) }
                Divider()
                Button("Copy as YAML", systemImage: "doc.on.clipboard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(FlowFile.write(graph), forType: .string)
                    session.notify("Copied")
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            } primaryAction: {
                shareLink()
            }
            .help("Share a link to this flow")
            Button { runAgain() } label: {
                if !session.engine.busy.isEmpty {
                    Label { Text("Running") } icon: { DA.Loader(.fillSpiral).frame(width: 16) }
                } else {
                    Label(session.ran ? "Run Again" : "Run", systemImage: "play.fill")
                }
            }
            .help("Run every step again")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button { session.showResults.toggle() } label: { Label("Results", systemImage: "sidebar.right") }
                .help("Show the results beside the flow")
        }
    }

    private var toast: some View {
        Group {
            if let text = session.toast {
                Text(text)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: session.toast)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            if session.droppingOnEmpty {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 34)).foregroundStyle(DA.Color.accent)
                Text("Drop to start with these").font(.title2.weight(.semibold))
                Text("Photos, audio, and text files each become a step the flow starts from.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                emptyIntro
            }
        }
        .frame(maxWidth: session.droppingOnEmpty ? 360 : 560)
        .padding(28)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .overlay {
            if session.droppingOnEmpty {
                RoundedRectangle(cornerRadius: 24).strokeBorder(DA.Color.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            inbox.drop(urls, at: nil)
            return true
        } isTargeted: { inbox.targeted($0) }
    }

    /// The start steps themselves, one click each, rather than a button
    /// that opens a list of them.
    @ViewBuilder private var emptyIntro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How does this flow start?").font(.title2.weight(.semibold))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(Steps.palette.filter { $0.category == .input }, id: \.type) { d in
                    PaletteItem(def: d) { addNode(d.type) }
                }
            }
            HStack {
                Text("Or drop photos, audio, or text files here.").foregroundStyle(.secondary)
                Spacer()
                Button("Browse templates") { openWindow(id: "library") }.buttonStyle(.link)
            }
            .font(.callout)
        }
    }

    // MARK: Editing

    private func setUpActions() {
        actions.updateParams = { id, patch in
            guard let i = document.graph.index(of: id) else { return }
            for (k, v) in patch {
                document.graph.nodes[i].params[k] = v == .null ? nil : v
            }
        }
        actions.remove = { id in remove([id]) }
        actions.addAfter = { source, handle, type in insert(type, after: source, handle, before: nil) }
        actions.wire = { target, handle, value in document.graph.wire(target, handle, from: value) }
        actions.move = { id, after, before in move(id, after: after, before: before) }
        actions.elseIf = { id in addElseIf(id) }
        actions.title = { graph.meta.title.isEmpty ? autoTitle(graph) : graph.meta.title }
        actions.change = { edit in
            var g = document.graph
            edit(&g)
            document.graph = g
        }
    }

    private var inbox: FlowInbox {
        FlowInbox(graph: $document.graph, session: session, actions: actions, newDocument: newDocument)
    }

    /// The steps in the list's order, without notes.
    private var steps: [Node] { graph.ordered.filter { $0.type != "note" } }

    /// The step new steps follow: the one selected, or in the step list the last.
    private var anchor: Node? {
        if session.selection.count == 1, let n = graph.node(session.selection.first!) { return n }
        return session.view == .steps ? steps.last : nil
    }

    /// Whether a text field has the keyboard, so the step shortcuts should
    /// do what they do in text instead.
    private var typing: NSTextView? {
        NSApp.keyWindow?.firstResponder as? NSTextView
    }

    private func remove(_ ids: Set<String>) {
        for id in ids { session.engine.forget(id) }
        document.graph.remove(ids)
        session.selection.subtract(ids)
    }

    /// Commits an edit that added or moved `id`, as one step to undo.
    private func commit(_ g: Graph, showing id: String, animated: Bool = false) {
        if animated && !reduceMotion { withAnimation(.snappy) { document.graph = g } } else { document.graph = g }
        session.keepPlace(of: id, in: g)
        session.show(id)
    }

    private func duplicateSelection() {
        guard session.selection.count == 1, let node = graph.node(session.selection.first!) else { return }
        let id = newNodeID(node.type)
        var g = document.graph
        // A flow laid out by hand keeps its places, so the copy needs one
        // of its own rather than one behind the original.
        let at = session.position(node, arranged: true)
        guard g.duplicate(node.id, as: id, at: graph.meta.arranged ? session.freeSpot(at.x, at.y, in: graph) : nil) else { return }
        commit(g, showing: id)
    }

    /// Selects the step before or after the selected one, in the list's order.
    private func selectStep(_ by: Int) {
        let ordered = steps
        guard !ordered.isEmpty else { return }
        let at = session.selection.first.flatMap { id in ordered.firstIndex { $0.id == id } }
        let next = at.map { min(max($0 + by, 0), ordered.count - 1) } ?? (by > 0 ? 0 : ordered.count - 1)
        session.show(ordered[next].id)
        if session.view == .canvas, !session.inSight(ordered[next], arranged: graph.meta.arranged) {
            session.focus(ordered[next], arranged: graph.meta.arranged)
        }
    }

    private func deleteSelection() {
        guard !session.selection.isEmpty else { return }
        remove(session.selection)
    }

    private func addElseIf(_ parentID: String) {
        let id = newNodeID("if")
        var g = document.graph
        let at = graph.meta.arranged ? graph.node(parentID).map(spot(after:)) : nil
        guard g.addElseIf(under: parentID, id: id, at: at) else { return }
        commit(g, showing: id)
    }

    /// A spot to the right of `node` on the canvas.
    private func spot(after node: Node) -> CGPoint {
        let at = session.position(node, arranged: graph.meta.arranged)
        return session.freeSpot(at.x + (session.sizes[node.id]?.width ?? FlowSession.cardSize.width) + 60, at.y, in: graph)
    }

    private func addNode(_ type: String) {
        let id = newNodeID(type)
        let position = anchor.map(spot(after:))
            ?? session.toCanvas(CGPoint(x: session.canvasSize.width / 2 - FlowSession.cardSize.width / 2, y: session.canvasSize.height / 3))
        var g = document.graph
        guard g.addStep(type, id: id, at: position, after: anchor, session: session) else { return }
        commit(g, showing: id)
        if session.view == .canvas, let node = g.node(id) {
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                session.focus(node, arranged: graph.meta.arranged)
            }
        }
    }

    /// A step after one output of `source`, and before `before` when it is
    /// put into a gap.
    private func insert(_ type: String, after source: String, _ handle: String, before: String?) {
        guard let src = graph.node(source) else { return }
        let id = newNodeID(type)
        var g = document.graph
        guard g.insert(type, id: id, at: spot(after: src), after: source, handle, before: before, session: session) else { return }
        commit(g, showing: id)
    }

    private func move(_ id: String, after: (node: String, output: String), before: String?) {
        var g = document.graph
        switch g.move(id, after: after, before: before, session: session) {
        case .doesNotFit?:
            let name = graph.node(id) == nil ? "This step" : graph.name(of: id)
            session.notify("\(name) can't use what that step makes")
        case .loops?:
            session.notify("That would make the flow loop back on itself")
        case nil:
            commit(g, showing: id, animated: true)
        }
    }

    // MARK: Running and layout

    private func scheduleRun(after delay: Duration = .milliseconds(250)) {
        runTask?.cancel()
        runTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await session.engine.run(document.graph)
        }
    }

    /// Running on purpose is what lets the flow's steps write, move, and
    /// rename files; opening a flow only shows what it would do.
    private func runAgain() {
        session.ran = true
        session.engine.mayWrite = true
        Task { await session.engine.run(document.graph, force: true) }
    }

    /// A flow lays itself out as its cards grow with results, until someone
    /// moves a card by hand, and the view fits it once, after the first layout.
    private func scheduleLayout() {
        layoutTask?.cancel()
        layoutTask = Task {
            try? await Task.sleep(for: .milliseconds(session.homed ? 350 : 120))
            guard !Task.isCancelled else { return }
            if !graph.meta.arranged {
                withAnimation(session.homed && !reduceMotion ? .smooth(duration: 0.3) : nil) { session.lay(graph) }
            }
            if !session.homed, graph.nodes.allSatisfy({ session.sizes[$0.id] != nil }) {
                try? await Task.sleep(for: .milliseconds(80))
                session.home(graph, animated: false)
                session.homed = true
            } else if session.homed, !session.touched, session.view == .canvas {
                session.home(graph)
            }
        }
    }

    private func tidy() {
        session.touched = false
        document.graph.meta.arranged = false
        session.lay(document.graph)
        session.home(document.graph)
    }

    private func copyLink() {
        let url = FlowLink.url(for: graph)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        session.notify("Link copied")
    }

    /// The share menu with the link, from the toolbar.
    private func shareLink() {
        let url = FlowLink.url(for: graph)
        guard let window = NSApp.keyWindow, let view = window.contentView else { return copyLink() }
        let picker = NSSharingServicePicker(items: [url])
        let rect = CGRect(x: view.bounds.maxX - 220, y: view.bounds.maxY - 4, width: 1, height: 1)
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    private func setUpCommands() {
        commands.session = session
        commands.run = { runAgain() }
        commands.addStep = { session.palette = .init(onlyInputs: graph.nodes.isEmpty) }
        commands.tidy = { tidy() }
        commands.copyLink = { copyLink() }
        commands.openInBrowser = { NSWorkspace.shared.open(FlowLink.url(for: graph)) }
        commands.canRunOnItsOwn = { Trigger.node(of: graph) != nil }
        commands.turnOn = { on in Task { await session.turnOn(on, graph: graph) } }
        commands.delete = {
            if let text = typing { text.deleteToBeginningOfLine(nil) } else { deleteSelection() }
        }
        commands.duplicate = { if typing == nil { duplicateSelection() } }
        commands.step = { by in
            guard let text = typing else { return selectStep(by) }
            if by < 0 { text.moveToBeginningOfParagraph(nil) } else { text.moveToEndOfParagraph(nil) }
        }
    }
}

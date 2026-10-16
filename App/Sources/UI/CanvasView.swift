import AppKit
import SwiftUI

/// The flow as a graph: cards you move by their heading, wires you drag from
/// an output to an input. Two fingers pan, a pinch zooms, as in any canvas.
struct CanvasView: View {
    @Binding var graph: Graph
    let session: FlowSession
    var onDropTargeted: (Bool) -> Void = { _ in }
    var onDropFiles: ([URL], CGPoint) -> Void

    // Nothing here reads where the canvas looks: panning and zooming redraw
    // the viewport and the dots, not the cards.
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(pan)
                    .onTapGesture { endEditing(); session.selection = [] }

                Viewport(session: session, content: CanvasCards(graph: $graph, session: session))
            }
            .background(Dots(session: session).allowsHitTesting(false))
            .coordinateSpace(.named("canvas"))
            .clipped()
            .background(ScrollZoomCatcher(session: session))
            .background(zoomInWithoutShift)
            .onChange(of: geo.size, initial: true) { session.canvasSize = geo.size }
            .dropDestination(for: URL.self) { urls, location in
                onDropFiles(urls, session.toCanvas(location))
                return true
            } isTargeted: { onDropTargeted($0) }
        }
        .background(Theme.canvas)
    }

    /// The View menu's Zoom In shows Command-Plus, which on most keyboards
    /// takes Shift too. Command-Equals, the same key without it, zooms in as
    /// well, as it does in other Mac apps.
    private var zoomInWithoutShift: some View {
        Button("Zoom In") { session.zoom(by: 1.25) }
            .keyboardShortcut("=")
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }

    private var pan: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                let start = session.panStart ?? session.offset
                if session.panStart == nil {
                    session.panStart = start
                    session.touched = true
                }
                session.offset = CGSize(width: start.width + g.translation.width, height: start.height + g.translation.height)
            }
            .onEnded { _ in session.panStart = nil }
    }
}

/// Moves and scales the cards to where the canvas looks. Only this redraws as
/// the canvas pans and zooms; the cards inside stay as they are.
private struct Viewport<Content: View>: View {
    let session: FlowSession
    let content: Content

    var body: some View {
        content
            .scaleEffect(session.zoom, anchor: .topLeading)
            .offset(session.offset)
    }
}

/// The title, the cards, and the wires between them, in the canvas's own
/// units, which panning and zooming leave alone.
private struct CanvasCards: View {
    @Binding var graph: Graph
    let session: FlowSession
    @State private var resizing: [String: CGFloat] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            title
            ForEach(graph.nodes) { node in
                card(node)
            }
        }
        .backgroundPreferenceValue(PortAnchors.self) { anchors in
            GeometryReader { proxy in
                let points = anchors.mapValues { proxy[$0] }
                Wires(graph: graph, points: points, cards: cards, busy: session.engine.busy, connecting: session.connecting,
                      zoom: session.zoom, moving: !reduceMotion)
                    .allowsHitTesting(false)
                    .onChange(of: points, initial: true) { session.ports = points }
            }
        }
    }

    /// Where each step's card sits, for wires to go around.
    private var cards: [String: CGRect] {
        Dictionary(uniqueKeysWithValues: graph.nodes.filter { $0.type != "note" }.map { n in
            (n.id, CGRect(origin: session.position(n, arranged: graph.meta.arranged), size: session.sizes[n.id] ?? FlowSession.cardSize))
        })
    }

    /// The flow's title and description, written on the canvas above its
    /// steps, moving and scaling with them like a heading on a whiteboard.
    private var title: some View {
        let nodes = graph.nodes.filter { $0.type != "note" }
        let origin = nodes.reduce(CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)) { p, n in
            let at = session.position(n, arranged: graph.meta.arranged)
            return CGPoint(x: min(p.x, at.x), y: min(p.y, at.y))
        }
        return CanvasTitle(graph: $graph)
            .frame(width: 620, alignment: .leading)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { session.titleSize = $0 }
            // Moved up by its own height rather than aligned by its bottom: an
            // alignment guide would grow the stack upward and push every card
            // down by the title's height, out of the place `home` fits.
            .offset(x: origin.x.isFinite ? origin.x : 0,
                    y: (origin.y.isFinite ? origin.y : 0) - FlowSession.titleGap - session.titleSize.height)
            .opacity(session.homed ? 1 : 0)
    }

    @ViewBuilder private func card(_ node: Node) -> some View {
        let p = session.position(node, arranged: graph.meta.arranged)
        Group {
            if node.type == "note" {
                NoteCard(node: node, selected: session.selection.contains(node.id), drag: move(node))
            } else if let def = node.def {
                NodeCard(node: node, def: def, selected: session.selection.contains(node.id), resizing: resizing[node.id]) { extras in
                    PortsView(node: node, def: def, extras: extras)
                }
                .overlay(alignment: .top) {
                    Color.clear.frame(height: 44).contentShape(Rectangle()).gesture(move(node))
                        .padding(.trailing, 96)
                }
                .overlay(alignment: .trailing) {
                    if def.resizable {
                        ResizeEdge(node: node, live: Binding { resizing[node.id] } set: { resizing[node.id] = $0 })
                    }
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { session.sizes[node.id] = $0 }
        .simultaneousGesture(TapGesture().onEnded {
            if !NSEvent.modifierFlags.isDisjoint(with: [.shift, .command]) {
                session.selection.formSymmetricDifference([node.id])
            } else {
                session.selection = [node.id]
            }
        })
        .accessibilityAction(named: "Select") { session.selection = [node.id] }
        .offset(x: p.x, y: p.y)
        .zIndex(session.selection.contains(node.id) ? 1 : 0)
        .opacity(session.homed ? 1 : 0)
    }

    /// Dragging a card by its heading moves it, and every other selected card
    /// with it when it is one of them.
    private func move(_ node: Node) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("canvas"))
            .onChanged { g in
                session.touched = true
                let d = CGSize(width: g.translation.width / session.zoom, height: g.translation.height / session.zoom)
                for id in moving(with: node) { session.dragging[id] = d }
            }
            .onEnded { g in
                let d = CGSize(width: g.translation.width / session.zoom, height: g.translation.height / session.zoom)
                let ids = moving(with: node)
                var next = graph
                if !next.meta.arranged {
                    for i in next.nodes.indices {
                        next.nodes[i].position = session.autoPositions[next.nodes[i].id] ?? next.nodes[i].position
                    }
                    next.meta.arranged = true
                }
                for id in ids {
                    guard let i = next.index(of: id) else { continue }
                    next.nodes[i].position.x += d.width
                    next.nodes[i].position.y += d.height
                }
                for id in ids { session.dragging[id] = nil }
                graph = next
            }
    }

    private func moving(with node: Node) -> Set<String> {
        session.selection.contains(node.id) ? session.selection : [node.id]
    }
}

/// Drag a wide card's right edge to make it wider.
struct ResizeEdge: View {
    let node: Node
    /// The width while dragging, written to the flow once the drag ends so
    /// one resize is one step to undo.
    @Binding var live: CGFloat?
    @Environment(\.flowActions) private var actions
    @Environment(\.flowSession) private var session
    @State private var start: CGFloat?

    static let widths: ClosedRange<CGFloat> = 260...1000

    var body: some View {
        Color.clear
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: .trailing))
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                .onChanged { g in
                    let start = self.start ?? session?.sizes[node.id]?.width ?? FlowSession.cardSize.width
                    self.start = start
                    let w = start + g.translation.width / (session?.zoom ?? 1)
                    live = min(Self.widths.upperBound, max(Self.widths.lowerBound, w)).rounded()
                }
                .onEnded { _ in
                    if let live { actions.set(node.id, ["w": .number(live)]) }
                    start = nil
                    live = nil
                })
            .offset(x: 4)
    }
}

/// A note on the canvas, for whoever opens the flow.
struct NoteCard<Drag: Gesture>: View {
    let node: Node
    let selected: Bool
    let drag: Drag
    @Environment(\.flowActions) private var actions

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "note.text").font(.caption).opacity(0.6)
                Spacer()
                if selected { IconButton(symbol: "xmark", help: "Remove") { actions.remove(node.id) } }
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .gesture(drag)
            TextEditor(text: ParamBinding(node: node, actions: actions).text("text"))
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 70)
        }
        .padding(12)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.rgb(0xF8DBCA)).shadow(color: .black.opacity(0.12), radius: 8, y: 4))
        .foregroundStyle(Theme.ink)
        .environment(\.colorScheme, .light)
        .rotationEffect(.degrees(-1.5))
        .overlay { if selected { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.ink, lineWidth: 2).rotationEffect(.degrees(-1.5)) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The dot grid behind the cards, moving and scaling with them. One dot is
/// drawn once and tiled, and the grid fades out as the canvas zooms out, where
/// it would be more dots than paper.
struct Dots: View {
    let session: FlowSession

    var body: some View {
        let zoom = session.zoom
        let offset = session.offset
        Canvas { ctx, size in
            let gap = 24 * zoom
            guard gap > 8 else { return }
            let r = max(0.6, 1.2 * zoom)
            let dot = Image(size: CGSize(width: gap, height: gap)) { tile in
                tile.fill(Path(ellipseIn: CGRect(x: gap / 2 - r, y: gap / 2 - r, width: r * 2, height: r * 2)), with: .color(Theme.dot))
            }
            ctx.opacity = min(1, Double(gap - 8) / 8)
            let origin = CGPoint(x: offset.width.truncatingRemainder(dividingBy: gap) - gap / 2,
                                 y: offset.height.truncatingRemainder(dividingBy: gap) - gap / 2)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .tiledImage(dot, origin: origin))
        }
    }
}

/// Every wire, as a curve from an output to an input, in the color of what it
/// carries. A wire into a step that is working moves, unless motion is
/// reduced. A wire that would cross a card on its way goes around it.
struct Wires: View, Equatable {
    let graph: Graph
    let points: [FlowSession.PortKey: CGPoint]
    let cards: [String: CGRect]
    let busy: Set<String>
    let connecting: FlowSession.Connecting?
    let zoom: CGFloat
    var moving = true

    var body: some View {
        // The drawing covers every wire, which can run left of and above the
        // first card, where the view's own frame does not reach.
        let bounds = points.values.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
            .union(cards.values.reduce(CGRect.null) { $0.union($1) })
            .union(connecting.map { CGRect(origin: $0.to, size: .zero) } ?? .null)
            .insetBy(dx: -200, dy: -200)
        // Wider in the canvas's units as it zooms out, so a wire stays
        // visible on screen.
        let width = max(1.5 / zoom, 2.2)
        TimelineView(.animation(paused: busy.isEmpty || !moving)) { context in
            Canvas { ctx, _ in
                guard !bounds.isNull else { return }
                ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
                let phase = moving ? context.date.timeIntervalSinceReferenceDate * 30 : 0
                for e in graph.edges where e != connecting?.lifting {
                    guard let a = points[.init(node: e.source, port: e.sourceHandle, output: true)],
                          let b = points[.init(node: e.target, port: e.targetHandle, output: false)]
                    else { continue }
                    let type = graph.node(e.source)?.def?.outputs.first { $0.id == e.sourceHandle }?.type ?? .any
                    let live = busy.contains(e.target)
                    let around = cards.filter { $0.key != e.source && $0.key != e.target }.map(\.value)
                    ctx.stroke(curve(a, b, lane: WireRoute.lane(from: a, to: b, around: around)),
                               with: .color(Theme.wire(type).opacity(live ? 1 : 0.85)),
                               style: StrokeStyle(lineWidth: width, lineCap: .round,
                                                  dash: live ? [8, 6] : [], dashPhase: live ? -phase : 0))
                }
                if let c = connecting, let a = points[c.from] {
                    ctx.stroke(curve(a, c.to), with: .color(Theme.wire(c.type)),
                               style: StrokeStyle(lineWidth: 2 / zoom, lineCap: .round, dash: [5 / zoom, 4 / zoom]))
                }
            }
            .frame(width: bounds.isNull ? 0 : bounds.width, height: bounds.isNull ? 0 : bounds.height)
            .offset(x: bounds.isNull ? 0 : bounds.minX, y: bounds.isNull ? 0 : bounds.minY)
        }
    }

    /// The plain curve, or around the cards in the way: up or down to a
    /// level lane past them, then back to the input.
    private func curve(_ a: CGPoint, _ b: CGPoint, lane: WireRoute.Lane? = nil) -> Path {
        var p = Path()
        p.move(to: a)
        guard let lane else {
            let (c1, c2) = WireRoute.controls(a, b)
            p.addCurve(to: b, control1: c1, control2: c2)
            return p
        }
        let enter = CGPoint(x: lane.from, y: lane.y), leave = CGPoint(x: lane.to, y: lane.y)
        let inDx = (enter.x - a.x) * 0.6, outDx = (b.x - leave.x) * 0.6
        p.addCurve(to: enter, control1: CGPoint(x: a.x + inDx, y: a.y), control2: CGPoint(x: enter.x - inDx, y: enter.y))
        p.addLine(to: leave)
        p.addCurve(to: b, control1: CGPoint(x: leave.x + outDx, y: leave.y), control2: CGPoint(x: b.x - outDx, y: b.y))
        return p
    }
}

/// Two-finger scrolling pans the canvas and a pinch zooms it, wherever the
/// pointer is, unless what is under it scrolls itself (a long text, a table).
struct ScrollZoomCatcher: NSViewRepresentable {
    let session: FlowSession

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.session = session
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.session = session }

    final class CatcherView: NSView {
        weak var session: FlowSession?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, let session = self.session, event.window === self.window else { return event }
                let local = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(local) else { return event }
                let point = CGPoint(x: local.x, y: self.isFlipped ? local.y : self.bounds.height - local.y)
                if event.type == .magnify {
                    MainActor.assumeIsolated { session.zoom(by: 1 + event.magnification, around: point) }
                    return nil
                }
                if self.innerScroll(at: event.locationInWindow, event: event) { return event }
                MainActor.assumeIsolated {
                    if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                        session.zoom(by: 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1), around: point)
                    } else {
                        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                        session.touched = true
                        session.offset.width += event.scrollingDeltaX * k
                        session.offset.height += event.scrollingDeltaY * k
                    }
                }
                return nil
            }
        }

        /// A scroll view under the pointer that can still move this way keeps
        /// the scroll.
        private func innerScroll(at point: NSPoint, event: NSEvent) -> Bool {
            guard let content = window?.contentView, var view = content.hitTest(content.convert(point, from: nil)) else { return false }
            while let parent = view.superview {
                if let scroll = view as? NSScrollView, let doc = scroll.documentView {
                    let visible = scroll.contentView.bounds
                    let canY = doc.frame.height > visible.height + 1
                    let canX = doc.frame.width > visible.width + 1
                    if (canY && abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)) || (canX && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)) {
                        return true
                    }
                }
                view = parent
            }
            return false
        }
    }
}

/// The title and description as large type on the canvas, edited in place.
struct CanvasTitle: View {
    @Binding var graph: Graph

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BalancedField(prompt: autoTitle(graph), text: $graph.meta.title)
                .font(.system(size: 44, weight: .semibold))
                .kerning(-1.4)
            TextField("Say what this flow does", text: $graph.meta.description, axis: .vertical)
                .font(.system(size: 19))
                .foregroundStyle(.secondary)
            if !graph.nodes.isEmpty { FlowModels(models: graph.models).font(.system(size: 15)) }
        }
        .textFieldStyle(.plain)
    }
}

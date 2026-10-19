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
            .onContinuousHover(coordinateSpace: .named("canvas")) { phase in track(phase) }
            .animation(.easeOut(duration: 0.15), value: session.hover)
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

    /// Lights up the wire under the pointer, or the wires of the step under it.
    private func track(_ phase: HoverPhase) {
        guard !session.onWireLabel, session.connecting == nil else { return }
        var now: FlowSession.CanvasHover?
        if case .active(let location) = phase {
            let point = session.toCanvas(location)
            let cards = session.cards(of: graph)
            if let step = cards.first(where: { $0.value.contains(point) })?.key {
                now = .step(step)
            } else if let line = WireLine.hit(point, in: WireLine.all(in: graph, points: session.ports, cards: cards), zoom: session.zoom) {
                now = .wire(line.id)
            }
        }
        if now != session.hover { session.hover = now }
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
                Wires(lines: WireLine.all(in: graph, points: points, cards: session.cards(of: graph)), busy: session.engine.busy,
                      finished: session.finished, connecting: session.connecting, from: session.connecting.flatMap { points[$0.from] },
                      hover: session.hover, zoom: session.zoom, canvas: Theme.canvas, moving: !reduceMotion)
                    .equatable()
                    .allowsHitTesting(false)
                    .onChange(of: points, initial: true) { session.ports = points }
                    .onChange(of: session.engine.busy) { before, now in
                        // A step that stopped working sends its result on, unless it failed.
                        for id in before.subtracting(now) where session.engine.state(id).status == .done {
                            let at = Date.now
                            session.finished[id] = at
                            // Once its bead has landed, the canvas can stop animating.
                            Task {
                                try? await Task.sleep(for: .seconds(Wires.delivery + 0.1))
                                if session.finished[id] == at { session.finished[id] = nil }
                            }
                        }
                    }
            }
        }
        .overlay(alignment: .topLeading) { wireLabel }
    }

    /// The label of the wire under the pointer, at the wire's middle.
    @ViewBuilder private var wireLabel: some View {
        if case .wire(let id)? = session.hover,
           let line = WireLine.all(in: graph, points: session.ports, cards: session.cards(of: graph)).first(where: { $0.id == id }) {
            let middle = WireRoute.middle(line.corners)
            WireLabel(line: line, graph: graph, zoom: session.zoom, session: session)
                .position(middle)
        }
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

/// One wire as drawn: where it turns, and what it carries.
struct WireLine: Identifiable {
    let edge: Edge
    let corners: [CGPoint]
    let type: PortType
    var id: String { edge.id }
    var path: Path { WireRoute.path(corners) }
}

extension WireLine {
    /// How far a wire stops short of a port's center, so it meets the dot's edge.
    static let gap: CGFloat = 7
    /// How far apart wires sharing a gutter run.
    static let spacing: CGFloat = 7

    /// Every wire between ports that have been laid out. Wires leaving one
    /// output fan out in the order of where they go, so they never overlap.
    static func all(in graph: Graph, points: [FlowSession.PortKey: CGPoint], cards: [String: CGRect]) -> [WireLine] {
        let ends = graph.edges.compactMap { e -> (Edge, CGPoint, CGPoint)? in
            guard let a = points[.init(node: e.source, port: e.sourceHandle, output: true)],
                  let b = points[.init(node: e.target, port: e.targetHandle, output: false)] else { return nil }
            return (e, a, b)
        }
        let fans = Dictionary(grouping: ends) { "\($0.0.source).\($0.0.sourceHandle)" }
        return ends.map { e, a, b in
            let fan = (fans["\(e.source).\(e.sourceHandle)"] ?? []).sorted { $0.2.y < $1.2.y }
            let i = CGFloat(fan.firstIndex { $0.0 == e } ?? 0)
            let spread = (i - CGFloat(fan.count - 1) / 2) * spacing
            let around = cards.filter { $0.key != e.source && $0.key != e.target }.map(\.value)
            let corners = WireRoute.corners(from: CGPoint(x: a.x + gap, y: a.y), to: CGPoint(x: b.x - gap, y: b.y),
                                            source: cards[e.source], target: cards[e.target], around: around, spread: spread)
            let type = graph.node(e.source)?.def?.outputs.first { $0.id == e.sourceHandle }?.type ?? .any
            return WireLine(edge: e, corners: corners, type: type)
        }
    }

    /// The wire under a point, within a few points of it either side.
    static func hit(_ point: CGPoint, in lines: [WireLine], zoom: CGFloat) -> WireLine? {
        let reach = StrokeStyle(lineWidth: 12 / zoom, lineCap: .round, lineJoin: .round)
        return lines.last { $0.path.strokedPath(reach).contains(point) }
    }
}

/// Every wire, in the color of what it carries, brightening toward its
/// input so it reads which way things go, on a halo of the canvas's color so
/// crossings read. The wire under the pointer, or the wires of the step under
/// it, stand out and the rest step back.
///
/// While a step works, beads stream along the wires into it; when it is
/// done, one bright bead carries its result out along each wire it feeds.
/// With Reduce Motion the wires into a working step brighten instead.
struct Wires: View, Equatable {
    let lines: [WireLine]
    let busy: Set<String>
    /// When each step last finished, for the bead that carries its result out.
    let finished: [String: Date]
    let connecting: FlowSession.Connecting?
    let from: CGPoint?
    let hover: FlowSession.CanvasHover?
    let zoom: CGFloat
    let canvas: Color
    var moving = true

    /// How long a finished step's bead takes to cross its wire.
    static let delivery: TimeInterval = 0.7
    /// How fast beads move, in points a second.
    private static let pace: CGFloat = 220

    var body: some View {
        // The drawing covers every wire, which can run left of and above the
        // first card, where the view's own frame does not reach.
        let bounds = lines.flatMap(\.corners).reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
            .union(connecting.map { CGRect(origin: $0.to, size: .zero) } ?? .null)
            .union(from.map { CGRect(origin: $0, size: .zero) } ?? .null)
            .insetBy(dx: -60, dy: -60)
        // Wider in the canvas's units as it zooms out, so a wire stays visible on screen.
        let width = max(1.6 / zoom, 2.6)
        let delivering = finished.values.contains { Date().timeIntervalSince($0) < Self.delivery }
        TimelineView(.animation(paused: !moving || (busy.isEmpty && !delivering))) { context in
            Canvas { ctx, _ in
                guard !bounds.isNull else { return }
                ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
                let now = context.date
                for line in lines where line.edge != connecting?.lifting {
                    draw(line, in: &ctx, width: width, at: now)
                }
                if let c = connecting, let a = from {
                    let corners = WireRoute.corners(from: CGPoint(x: a.x + WireLine.gap, y: a.y), to: c.to)
                    ctx.stroke(WireRoute.path(corners), with: .color(Theme.wire(c.type)),
                               style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [6 / zoom, 5 / zoom]))
                }
            }
            .frame(width: bounds.isNull ? 0 : bounds.width, height: bounds.isNull ? 0 : bounds.height)
            .offset(x: bounds.isNull ? 0 : bounds.minX, y: bounds.isNull ? 0 : bounds.minY)
        }
    }

    private func draw(_ line: WireLine, in ctx: inout GraphicsContext, width: CGFloat, at now: Date) {
        let path = line.path
        let lit = isLit(line)
        let live = busy.contains(line.edge.target)
        let color = Theme.wire(line.type)
        let w = lit == true ? width * 1.6 : width
        let strength = lit == false ? 0.2 : live || lit == true ? 1 : 0.85
        let round = StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round)
        guard let start = line.corners.first, let end = line.corners.last else { return }
        ctx.stroke(path, with: .color(canvas), style: StrokeStyle(lineWidth: w + 4, lineCap: .round, lineJoin: .round))
        ctx.stroke(path, with: .linearGradient(Gradient(colors: [color.opacity(strength * 0.55), color.opacity(strength)]),
                                               startPoint: start, endPoint: end), style: round)
        guard moving, lit != false else { return }
        let length = max(WireRoute.length(line.corners), 1)
        if live {
            // Beads every 46 points, streaming toward the step at work.
            let spacing: CGFloat = 46
            let shift = CGFloat(now.timeIntervalSinceReferenceDate) * Self.pace
            var offset = shift.truncatingRemainder(dividingBy: spacing)
            while offset < length {
                bead(on: path, at: offset / length, color: color, size: w + 2.5, in: &ctx)
                offset += spacing
            }
        }
        if let done = finished[line.edge.source] {
            let t = now.timeIntervalSince(done) / Self.delivery
            if (0..<1).contains(t) {
                // Eases out, so the result lands softly at the input.
                let eased = 1 - pow(1 - t, 3)
                bead(on: path, at: eased, color: color, size: w + 5, in: &ctx, glow: 8)
            }
        }
    }

    private func bead(on path: Path, at t: CGFloat, color: Color, size: CGFloat, in ctx: inout GraphicsContext, glow: CGFloat = 4) {
        guard let point = path.trimmedPath(from: 0, to: min(max(t, 0.0001), 1)).currentPoint else { return }
        var layer = ctx
        layer.addFilter(.shadow(color: color, radius: glow))
        layer.fill(Path(ellipseIn: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)), with: .color(color))
        ctx.fill(Path(ellipseIn: CGRect(x: point.x - size / 4, y: point.y - size / 4, width: size / 2, height: size / 2)),
                 with: .color(.white.opacity(0.85)))
    }

    /// True for a wire to bring out, false for one to step back, nil when nothing is hovered.
    private func isLit(_ line: WireLine) -> Bool? {
        switch hover {
        case .wire(let id)?: line.id == id
        case .step(let id)?: line.edge.source == id || line.edge.target == id
        case nil: nil
        }
    }

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.lines.map(\.corners) == b.lines.map(\.corners) && a.lines.map(\.id) == b.lines.map(\.id) && a.busy == b.busy
            && a.finished == b.finished && a.connecting == b.connecting && a.from == b.from && a.hover == b.hover
            && a.zoom == b.zoom && a.moving == b.moving
    }
}

/// The hovered wire's label at its middle: what is flowing along it, as
/// photos, words, or a number, and where it goes, with a way to take the
/// wire out. It stays the same size on screen at any zoom.
struct WireLabel: View {
    let line: WireLine
    let graph: Graph
    let zoom: CGFloat
    let session: FlowSession
    @Environment(\.flowActions) private var actions

    var body: some View {
        let e = line.edge
        let to = graph.node(e.target)?.def?.inputs.first { $0.id == e.targetHandle }?.label ?? e.targetHandle
        let value = session.engine.state(e.source).outputs?[e.sourceHandle]
        HStack(spacing: 8) {
            if let value { WireValue(value: value) }
            HStack(spacing: 4) {
                Image(systemName: "arrow.right").font(.caption2.weight(.bold)).foregroundStyle(Theme.wire(line.type))
                Text(graph.name(of: e.target)).fontWeight(.medium)
                if to.caseInsensitiveCompare(graph.name(of: e.target)) != .orderedSame { Text(to).foregroundStyle(.secondary) }
            }
            Button {
                actions.change { $0.wire(e.target, e.targetHandle, from: nil) }
                session.hover = nil
                session.onWireLabel = false
            } label: {
                Image(systemName: "xmark").font(.caption2.weight(.bold)).frame(width: 18, height: 18).contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help("Take out this wire")
            .accessibilityLabel("Take out this wire")
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
        .onHover { session.onWireLabel = $0 }
        .scaleEffect(1 / zoom)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

/// What a wire carries, at a glance: a few photos, the start of the words, a
/// number, or how long a recording is.
private struct WireValue: View {
    let value: Value

    var body: some View {
        let items = value.present
        let photos = items.compactMap(\.photo)
        HStack(spacing: 6) {
            if !photos.isEmpty {
                HStack(spacing: -6) {
                    ForEach(photos.prefix(4)) { photo in
                        Image(decorative: photo.thumb, scale: 1).resizable().scaledToFill()
                            .frame(width: 22, height: 22)
                            .clipShape(.rect(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.background, lineWidth: 1.5))
                    }
                }
            }
            Text(summary(items, photos: photos.count))
        }
    }

    private func summary(_ items: [Value], photos: Int) -> String {
        if photos > 0 { return photos == 1 ? "1 photo" : "\(photos) photos" }
        if let clip = value.audio { return String(format: "%.1fs of audio", clip.duration) }
        if items.count > 1 { return AskStep.counted(items) }
        let text = value.asText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 42 ? "\u{201C}" + text.prefix(40) + "\u{2026}\u{201D}" : text.isEmpty ? "Nothing" : "\u{201C}\(text)\u{201D}"
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

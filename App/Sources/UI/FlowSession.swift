import Observation
import SwiftUI

enum FlowView: String { case canvas, steps }

/// What one window knows that its file does not: the run, what is selected,
/// where the canvas looks, how big each card is.
@MainActor
@Observable
final class FlowSession {
    /// A window opened on a triggered run takes that run's engine, results and all.
    var engine = Engine()
    /// The file the window shows, once saved: a flow runs on its own from it.
    var fileURL: URL?
    /// The window, to tell whether a run is out of sight.
    @ObservationIgnored weak var window: NSWindow?

    var selection: Set<String> = []
    /// Steps or Canvas. Each window keeps its own, and a new window opens
    /// the way the last one was switched.
    var view: FlowView = FlowView(rawValue: UserDefaults.standard.string(forKey: "view") ?? "") ?? .steps {
        didSet { if !restoring { UserDefaults.standard.set(view.rawValue, forKey: "view") } }
    }
    @ObservationIgnored private var restoring = false
    var showResults = false
    var palette: PaletteRequest?
    /// The input step files dragged over the window will go into.
    var dropTarget: String?
    /// Files are being dragged over a flow with no steps yet.
    var droppingOnEmpty = false
    /// A step for the step list to scroll to. Set through `show(_:)`.
    var reveal: String?
    var toast: String?
    var ran = false

    var zoom: CGFloat = 1
    var offset: CGSize = .zero
    var canvasSize: CGSize = .zero
    var sizes: [String: CGSize] = [:]
    /// Where steps sit while the flow lays itself out. Once someone moves a
    /// step, the file holds the positions instead.
    var autoPositions: [String: CGPoint] = [:]
    /// Where each port's dot is, in the canvas's units.
    var ports: [PortKey: CGPoint] = [:]
    var dragging: [String: CGSize] = [:]
    var connecting: Connecting?
    var homed = false
    /// What the pointer is over on the canvas, so the wires it concerns light up.
    var hover: CanvasHover?
    /// The pointer is on a wire's label, which keeps that wire lit while it is.
    var onWireLabel = false
    /// When each step last finished, for the canvas to show its result
    /// travelling on along its wires.
    var finished: [String: Date] = [:]
    /// The input a wire being drawn has snapped to.
    var snapped: PortKey?
    var panStart: CGSize?
    var titleSize: CGSize = .zero
    /// Set once someone pans, zooms, or moves a step. Until then the view
    /// keeps the whole flow in sight as its cards grow with results.
    var touched = false

    enum CanvasHover: Equatable {
        case wire(String)
        case step(String)
    }

    /// Where each step's card sits, in the canvas's units.
    func cards(of graph: Graph) -> [String: CGRect] {
        Dictionary(uniqueKeysWithValues: graph.nodes.filter { $0.type != "note" }.map { n in
            (n.id, CGRect(origin: position(n, arranged: graph.meta.arranged), size: sizes[n.id] ?? Self.cardSize))
        })
    }

    struct PortKey: Hashable {
        let node: String
        let port: String
        let output: Bool
    }

    /// A wire being drawn, in the canvas's units.
    struct Connecting: Equatable {
        var from: PortKey
        var type: PortType
        var to: CGPoint
        /// The wire picked up from an input, which is not drawn where it was.
        var lifting: Edge?
    }

    struct PaletteRequest: Identifiable {
        let id = UUID()
        /// Only the start steps, for a new flow.
        var onlyInputs = false
        /// The step and output the new step follows.
        var after: (node: String, output: String)? = nil
        /// The step that took from `after` until now, which takes from the new
        /// step instead, so it goes in between.
        var before: String? = nil
    }

    /// A card's size before it has been measured.
    static let cardSize = CGSize(width: 300, height: 260)
    /// The space between the canvas title and the cards below it.
    static let titleGap: CGFloat = 36

    /// The document the window shows, to save it from here.
    var document: NSDocument? { window.flatMap { NSDocumentController.shared.document(for: $0) } }

    /// Shows an unsaved flow's name in the title bar and the Save dialog. An
    /// empty flow stays Untitled, so macOS can number it.
    func nameUntitled(_ graph: Graph) {
        guard fileURL == nil else { return }
        let name = graph.isUntitled ? nil : graph.name
        DispatchQueue.main.async { self.document?.displayName = name }
    }

    /// Turns the flow on or off. It runs from its file, so turning it on
    /// saves it first, and a flow without a file goes into the Flows folder
    /// under its title.
    func turnOn(_ on: Bool, graph: Graph) async {
        guard on else {
            if let fileURL { TriggerCenter.shared.setOn(false, path: fileURL.path) }
            return
        }
        let url: URL
        do { url = try await save(named: graph.name) } catch {
            notify("The flow could not be saved, so it is still off")
            return
        }
        TriggerCenter.shared.setOn(true, path: url.path, graph: graph)
        // Turning on a flow that records meetings is when to ask for what it
        // needs, so it does not find out mid-call.
        if MeetingPermissions.needed(by: graph) { await MeetingPermissions.ask() }
    }

    private func save(named title: String) async throws -> URL {
        guard let document else { throw StepError("This window has no document") }
        if let fileURL {
            document.save(nil)
            return fileURL
        }
        let url = SaveTo.flowFile(named: title)
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            document.save(to: url, ofType: document.fileType ?? "", for: .saveAsOperation) { error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            }
        }
        fileURL = url
        return url
    }

    /// Shows a window the way it was when it was last open, without making
    /// that the way new windows open.
    func restore(_ view: FlowView) {
        restoring = true
        self.view = view
        restoring = false
    }

    /// Selects a step and, in the step list, scrolls to it.
    func show(_ id: String) {
        selection = [id]
        if view == .steps { reveal = id }
    }

    /// Keeps where a new or moved step went while the flow lays itself out.
    func keepPlace(of id: String, in graph: Graph) {
        if !graph.meta.arranged, let n = graph.node(id) { autoPositions[id] = n.position }
    }

    /// Next to `x, y` if there is room, otherwise below whatever is in the way.
    func freeSpot(_ x: CGFloat, _ y: CGFloat, in graph: Graph) -> CGPoint {
        var y = y
        let boxes = graph.nodes.map { n in
            CGRect(origin: position(n, arranged: graph.meta.arranged), size: sizes[n.id] ?? Self.cardSize)
        }
        while boxes.contains(where: { $0.insetBy(dx: -20, dy: -20).intersects(CGRect(origin: CGPoint(x: x, y: y), size: Self.cardSize)) }) { y += 40 }
        return CGPoint(x: x, y: y)
    }

    func notify(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            if toast == text { toast = nil }
        }
    }

    func position(_ node: Node, arranged: Bool) -> CGPoint {
        let base = arranged ? node.position : (autoPositions[node.id] ?? node.position)
        let drag = dragging[node.id] ?? .zero
        return CGPoint(x: base.x + drag.width, y: base.y + drag.height)
    }

    /// The canvas point under a point in the view.
    func toCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.width) / zoom, y: (p.y - offset.height) / zoom)
    }

    /// Shows the whole flow, at full size when it fits.
    func home(_ graph: Graph, animated: Bool = true) {
        let nodes = graph.nodes.filter { $0.type != "note" }
        guard !nodes.isEmpty, canvasSize.width > 0 else { return }
        let boxes = nodes.map { n -> CGRect in
            CGRect(origin: position(n, arranged: graph.meta.arranged), size: sizes[n.id] ?? Self.cardSize)
        }
        var bounds = boxes.reduce(boxes[0]) { $0.union($1) }
        bounds = bounds.union(CGRect(x: bounds.minX, y: bounds.minY - titleSize.height - Self.titleGap,
                                     width: titleSize.width, height: titleSize.height))
        let pad: CGFloat = 40
        let z = max(0.1, min(1, (canvasSize.width - pad * 2) / bounds.width, (canvasSize.height - pad * 2) / bounds.height))
        let change = {
            self.zoom = z
            self.offset = CGSize(width: (self.canvasSize.width - bounds.width * z) / 2 - bounds.minX * z,
                                 height: pad + max(0, (self.canvasSize.height - pad * 2 - bounds.height * z) / 2) - bounds.minY * z)
        }
        if animated && !Self.reduceMotion { withAnimation(.smooth(duration: 0.35)) { change() } } else { change() }
    }

    func zoom(by factor: CGFloat, around point: CGPoint? = nil) {
        touched = true
        let anchor = point ?? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let before = toCanvas(anchor)
        zoom = max(0.1, min(1.75, zoom * factor))
        offset = CGSize(width: anchor.x - before.x * zoom, height: anchor.y - before.y * zoom)
    }

    /// Whether a step's card is wholly on screen.
    func inSight(_ node: Node, arranged: Bool) -> Bool {
        let p = position(node, arranged: arranged)
        let s = sizes[node.id] ?? Self.cardSize
        let card = CGRect(x: p.x * zoom + offset.width, y: p.y * zoom + offset.height, width: s.width * zoom, height: s.height * zoom)
        return CGRect(origin: .zero, size: canvasSize).contains(card)
    }

    /// Brings one step into view. The view stays there rather than fitting
    /// the whole flow again as cards grow.
    func focus(_ node: Node, arranged: Bool) {
        touched = true
        let p = position(node, arranged: arranged)
        let s = sizes[node.id] ?? Self.cardSize
        withAnimation(Self.reduceMotion ? nil : .smooth(duration: 0.35)) {
            zoom = max(zoom, 0.8)
            offset = CGSize(width: canvasSize.width / 2 - (p.x + s.width / 2) * zoom,
                            height: canvasSize.height / 2 - (p.y + min(s.height, 300) / 2) * zoom)
        }
    }

    /// With Reduce Motion on, the view jumps to where it goes rather than
    /// gliding and zooming there.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func lay(_ graph: Graph) {
        autoPositions = FlowLayout.tidy(graph, sizes: sizes)
    }
}

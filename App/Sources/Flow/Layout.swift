import CoreGraphics
import SwiftUI
import Foundation

/// Lays a flow out left to right: a column per step depth, each column stacked
/// by the cards' real heights and ordered by where their inputs sit, centered
/// on one line. Notes go above.
enum FlowLayout {
    static let gapX: CGFloat = 70
    static let gapY: CGFloat = 36

    static func tidy(_ graph: Graph, sizes: [String: CGSize]) -> [String: CGPoint] {
        let notes = graph.nodes.filter { $0.type == "note" }
        let nodes = graph.nodes.filter { $0.type != "note" }
        let ids = Set(nodes.map(\.id))
        let live = graph.edges.filter { ids.contains($0.source) && ids.contains($0.target) }
        var depth = Dictionary(nodes.map { ($0.id, 0) }, uniquingKeysWith: { a, _ in a })
        for _ in nodes {
            var moved = false
            for e in live where depth[e.target]! < depth[e.source]! + 1 {
                depth[e.target] = depth[e.source]! + 1
                moved = true
            }
            if !moved { break }
        }
        let size = { (n: Node) in sizes[n.id] ?? CGSize(width: 280, height: 320) }
        var columns: [Int: [Node]] = [:]
        for n in nodes { columns[depth[n.id]!, default: []].append(n) }

        var centerY: [String: CGFloat] = [:]
        var position: [String: CGPoint] = [:]
        var x: CGFloat = 0
        for d in columns.keys.sorted() {
            var col = columns[d]!
            let parentY = { (n: Node) -> CGFloat in
                let ys = live.filter { $0.target == n.id }.compactMap { centerY[$0.source] }
                return ys.isEmpty ? n.position.y : ys.reduce(0, +) / CGFloat(ys.count)
            }
            col.sort { parentY($0) < parentY($1) }
            let height = col.map { size($0).height }.reduce(0, +) + gapY * CGFloat(col.count - 1)
            var top = -height / 2
            for n in col {
                position[n.id] = CGPoint(x: x, y: top)
                centerY[n.id] = top + size(n).height / 2
                top += size(n).height + gapY
            }
            x += (col.map { size($0).width }.max() ?? 280) + gapX
        }
        let top = min(position.values.map(\.y).min() ?? 0, 0)
        var noteX: CGFloat = 0
        for n in notes {
            let s = sizes[n.id] ?? CGSize(width: 360, height: 140)
            position[n.id] = CGPoint(x: noteX, y: top - s.height - 48)
            noteX += s.width + 32
        }
        return position
    }
}

/// How a wire gets from an output to an input: a smooth curve that leaves
/// the output and reaches the input level, as in Origami. A wire with a card
/// in its way eases up or down to a lane past it and back, and a wire back
/// to an earlier column runs under both of its cards.
enum WireRoute {
    /// How far a wire keeps from a card it goes around.
    static let clearance: CGFloat = 18
    /// How far a wire runs level out of a port before it turns.
    static let stub: CGFloat = 24

    /// The points a wire turns at, from `a` to `b`, ends included. `spread`
    /// moves the wire's middle stretch aside, so wires that share a gutter
    /// run beside each other instead of on top of each other.
    static func corners(from a: CGPoint, to b: CGPoint, source: CGRect? = nil, target: CGRect? = nil,
                        around cards: [CGRect] = [], spread: CGFloat = 0) -> [CGPoint] {
        guard b.x - a.x >= stub * 2 else {
            // Back to an earlier column: out, down under both cards, and back in.
            let bottom = max(source?.maxY ?? a.y, target?.maxY ?? b.y, a.y, b.y) + clearance + abs(spread)
            let out = a.x + stub, back = b.x - stub
            return [a, CGPoint(x: out, y: a.y), CGPoint(x: out, y: bottom), CGPoint(x: back, y: bottom), CGPoint(x: back, y: b.y), b]
        }
        let boxes = cards.map { $0.insetBy(dx: -clearance, dy: -clearance) }.filter { !$0.contains(a) && !$0.contains(b) }
        let middle = min(max((a.x + b.x) / 2 + spread, a.x + stub), b.x - stub)
        let plain = abs(a.y - b.y) < 1 ? [a, b] : [a, CGPoint(x: middle, y: a.y), CGPoint(x: middle, y: b.y), b]
        guard var span = boxes.first(where: { crosses(plain, $0) }) else { return plain }
        // Take in every card the way over or under would run into, until both are clear.
        while let more = boxes.first(where: { box in
            !span.contains(box) && box.minX < b.x && box.maxX > a.x
                && (crosses(plain, box) || (box.minX < span.maxX && box.maxX > span.minX
                    && [span.minY, span.maxY].contains { box.minY < $0 && box.maxY > $0 }))
        }) {
            span = span.union(more)
        }
        let over = abs(a.y - span.minY) + abs(b.y - span.minY) <= abs(a.y - span.maxY) + abs(b.y - span.maxY)
        // Headroom past the clearance, so the curve up to the lane can lean
        // over the card's corner without touching it.
        let headroom = clearance + abs(spread)
        let lane = over ? span.minY - headroom : span.maxY + headroom
        // Turn in the gutters either side of the cards in the way.
        let up = max(a.x + min(stub, (span.minX - a.x) / 2), a.x + 1)
        let down = min(b.x - min(stub, (b.x - span.maxX) / 2), b.x - 1)
        return [a, CGPoint(x: up, y: a.y), CGPoint(x: up, y: lane), CGPoint(x: down, y: lane), CGPoint(x: down, y: b.y), b]
    }

    /// The wire through its corners as smooth curves. A straight run from
    /// one column to the next is one curve whose pull grows with the distance
    /// it covers; a wire around a card eases into its lane and out of it.
    static func path(_ corners: [CGPoint]) -> Path {
        var path = Path()
        guard let a = corners.first, let b = corners.last else { return path }
        path.move(to: a)
        switch corners.count {
        case 4:
            let pull = max(36, min(abs(b.x - a.x) * 0.5, 220))
            path.addCurve(to: b, control1: CGPoint(x: a.x + pull, y: a.y), control2: CGPoint(x: b.x - pull, y: b.y))
        case 6:
            // Out, along the lane, and back in: each end eases over as far as
            // it climbs, within half the lane, so it never cuts a corner.
            let up = corners[1], laneStart = corners[2], laneEnd = corners[3], down = corners[4]
            let way: CGFloat = laneEnd.x >= laneStart.x ? 1 : -1
            let half = abs(laneEnd.x - laneStart.x) / 2
            let ease1 = min(abs(laneStart.y - a.y) * 0.5, half, 56), ease2 = min(abs(b.y - laneEnd.y) * 0.5, half, 56)
            let enter = CGPoint(x: laneStart.x + way * ease1, y: laneStart.y), leave = CGPoint(x: laneEnd.x - way * ease2, y: laneEnd.y)
            path.addCurve(to: enter, control1: up, control2: laneStart)
            path.addLine(to: leave)
            path.addCurve(to: b, control1: laneEnd, control2: down)
        default:
            for point in corners.dropFirst() { path.addLine(to: point) }
        }
        return path
    }

    /// Where a wire's label goes: halfway along a straight run, or the
    /// middle of the lane of one that goes around.
    static func middle(_ corners: [CGPoint]) -> CGPoint {
        guard let a = corners.first, let b = corners.last else { return .zero }
        if corners.count == 6 {
            return CGPoint(x: (corners[2].x + corners[3].x) / 2, y: corners[2].y)
        }
        return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// About how long a wire is, for moving things along it at an even pace.
    static func length(_ corners: [CGPoint]) -> CGFloat {
        zip(corners, corners.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// Whether the level and upright stretches through `points` cross `box`.
    private static func crosses(_ points: [CGPoint], _ box: CGRect) -> Bool {
        zip(points, points.dropFirst()).contains { p, q in
            box.intersects(CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: max(abs(q.x - p.x), 0.5), height: max(abs(q.y - p.y), 0.5)))
        }
    }
}

import CoreGraphics
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

/// How a wire gets from an output to an input without running behind the
/// cards between them. Columns are centered on one line, so a wire that skips
/// a column would otherwise cross the card in the middle of it.
enum WireRoute {
    /// How far a wire keeps from a card it goes around.
    static let clearance: CGFloat = 18

    /// The stretch a wire runs level, over or under the cards in its way.
    struct Lane: Equatable {
        var y: CGFloat
        var from: CGFloat
        var to: CGFloat
    }

    /// Where the wire from `a` to `b` passes the cards in between, or nil
    /// when the plain curve already misses them. It goes over or under,
    /// whichever is the shorter way round.
    static func lane(from a: CGPoint, to b: CGPoint, around cards: [CGRect]) -> Lane? {
        guard b.x > a.x else { return nil }
        let boxes = cards
            .map { $0.insetBy(dx: -clearance, dy: -clearance) }
            .filter { $0.maxX > a.x && $0.minX < b.x && !$0.contains(a) && !$0.contains(b) }
        let hit = boxes.filter { box in (1..<32).contains { box.contains(point(on: a, b, at: CGFloat($0) / 32)) } }
        guard var span = hit.first else { return nil }
        span = hit.reduce(span) { $0.union($1) }
        // Going over one card can run into the next one along; take those in
        // too, until the way over and the way under are both clear.
        while let more = boxes.first(where: { box in
            !span.contains(box) && box.minX < span.maxX && box.maxX > span.minX
                && [span.minY, span.maxY].contains { box.minY < $0 && box.maxY > $0 }
        }) {
            span = span.union(more)
        }
        let over = abs(a.y - span.minY) + abs(b.y - span.minY) <= abs(a.y - span.maxY) + abs(b.y - span.maxY)
        return Lane(y: over ? span.minY : span.maxY, from: max(a.x, span.minX), to: min(b.x, span.maxX))
    }

    /// A point on the plain wire: a curve leaving `a` and reaching `b` level.
    static func point(on a: CGPoint, _ b: CGPoint, at t: CGFloat) -> CGPoint {
        let (c1, c2) = controls(a, b)
        let u = 1 - t
        return CGPoint(x: u * u * u * a.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * b.x,
                       y: u * u * u * a.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * b.y)
    }

    /// The control points of the plain curve from `a` to `b`.
    static func controls(_ a: CGPoint, _ b: CGPoint) -> (CGPoint, CGPoint) {
        let dx = max(40, abs(b.x - a.x) * 0.5)
        return (CGPoint(x: a.x + dx, y: a.y), CGPoint(x: b.x - dx, y: b.y))
    }
}

import SwiftUI

/// A board to draw on. Every stroke stays until Clear; the stroke a Shapes
/// step reads is the last one.
struct SketchBody: View {
    let node: Node
    let wrapped: Bool
    @Environment(\.flowActions) private var actions
    @State private var live: [CGPoint] = []

    var body: some View {
        let saved = strokes(node.params["strokes"] ?? (wrapped ? node.params["seed"] : nil))
        let size = wrapped ? CGSize(width: 340, height: 260) : sketchSize
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let fit = fitting(saved, into: geo.size, board: size)
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cream)
                    Canvas { ctx, _ in
                        for stroke in saved + [live].filter({ !$0.isEmpty }) {
                            var path = Path()
                            path.addLines(stroke.map(fit.toView))
                            ctx.stroke(path, with: .color(Theme.ink), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                        }
                    }
                    if saved.isEmpty && live.isEmpty {
                        Text("Draw here").foregroundStyle(Theme.ink.opacity(0.35))
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { live.append(fit.toBoard($0.location)) }
                    .onEnded { _ in
                        let stroke = live
                        live = []
                        guard stroke.count > 2 else { return }
                        var patch: Params = ["strokes": strokesJSON(saved + [stroke], wrapped: wrapped)]
                        if wrapped { patch["seed"] = .null } else { patch["points"] = strokesJSON([stroke]).array?.first ?? .array([]) }
                        actions.set(node.id, patch)
                    })
            }
            .aspectRatio(size.width / size.height, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .environment(\.colorScheme, .light)
            if !saved.isEmpty {
                Button("Clear") {
                    actions.set(node.id, wrapped ? ["strokes": .array([]), "seed": .null] : ["strokes": .array([]), "points": .array([])])
                }
                .controlSize(.small)
            }
        }
    }

    /// Strokes keep the board's own coordinates; a seeded whiteboard may hold
    /// strokes outside them, so the view fits whatever is there.
    private func fitting(_ strokes: [[CGPoint]], into view: CGSize, board: CGSize) -> (toView: (CGPoint) -> CGPoint, toBoard: (CGPoint) -> CGPoint) {
        var box = CGRect(origin: .zero, size: board)
        for p in strokes.joined() { box = box.union(CGRect(origin: p, size: .zero)) }
        if box.size != board { box = box.insetBy(dx: -20, dy: -20) }
        let k = min(view.width / box.width, view.height / box.height)
        let dx = (view.width - box.width * k) / 2 - box.minX * k, dy = (view.height - box.height * k) / 2 - box.minY * k
        return ({ CGPoint(x: $0.x * k + dx, y: $0.y * k + dy) },
                { CGPoint(x: (($0.x - dx) / k * 10).rounded() / 10, y: (($0.y - dy) / k * 10).rounded() / 10) })
    }
}

/// Clean shapes over the faint strokes they came from.
struct ShapeBoard: View {
    let shapes: [CleanShape]
    let strokes: [[CGPoint]]

    var body: some View {
        Canvas { ctx, size in
            let all = shapes.flatMap(\.points) + strokes.joined()
            guard !all.isEmpty else { return }
            var box = CGRect(origin: all[0], size: .zero)
            for p in all { box = box.union(CGRect(origin: p, size: .zero)) }
            box = box.insetBy(dx: -max(10, box.width * 0.1), dy: -max(10, box.height * 0.1))
            let k = min(size.width / box.width, size.height / box.height)
            let dx = (size.width - box.width * k) / 2 - box.minX * k, dy = (size.height - box.height * k) / 2 - box.minY * k
            let map = { (p: CGPoint) in CGPoint(x: p.x * k + dx, y: p.y * k + dy) }
            for s in strokes {
                var path = Path()
                path.addLines(s.map(map))
                ctx.stroke(path, with: .color(Theme.ink.opacity(0.25)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            for shape in shapes {
                var path = Path()
                path.addLines(shape.points.map(map))
                if shape.closed { path.closeSubpath() }
                ctx.stroke(path, with: .color(Theme.ink), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cream))
    }
}

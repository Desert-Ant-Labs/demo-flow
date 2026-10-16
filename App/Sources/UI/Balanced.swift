import SwiftUI

/// Wraps a heading so its lines come out about even, rather than full lines
/// and one word left on the last: the narrowest width that takes no more
/// lines than the width offered.
///
/// It takes two views of the same text: the first, hidden, to measure with no
/// limit on its lines, so a limit on the second can't hide a line that the
/// narrower width would need; the second to show.
struct Balanced: Layout {
    var on = true

    func makeCache(subviews: Subviews) -> [CGFloat: CGFloat] { [:] }

    func updateCache(_ cache: inout [CGFloat: CGFloat], subviews: Subviews) {
        cache = [:]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGFloat: CGFloat]) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = balanced(proposal.width, subviews[0], &cache)
        return subviews[1].sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    /// Placed at the width it asked for, which is already balanced.
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGFloat: CGFloat]) {
        for view in subviews { view.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil)) }
    }

    private func balanced(_ offered: CGFloat?, _ measure: LayoutSubview, _ cache: inout [CGFloat: CGFloat]) -> CGFloat? {
        guard on, let offered, offered.isFinite, offered > 0 else { return offered }
        if let known = cache[offered] { return known }
        let height = { (w: CGFloat) in measure.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }
        let target = height(offered)
        let line = measure.sizeThatFits(.unspecified)
        let lines = (target / max(line.height, 1)).rounded()
        guard lines > 1 else {
            cache[offered] = offered
            return offered
        }
        // No narrower than the text spread evenly over its lines.
        var lo = line.width / lines, hi = offered
        while hi - lo > 2 {
            let mid = (lo + hi) / 2
            if height(mid) <= target + 0.5 { hi = mid } else { lo = mid }
        }
        cache[offered] = hi.rounded(.up)
        return hi.rounded(.up)
    }
}

/// A heading edited in place, balanced while it is not being edited. A text
/// field wraps by its own measure whatever width it is given, and a little
/// short of where the same text would, so the balanced text is what shows,
/// and a click swaps in the field.
struct BalancedField: View {
    let prompt: String
    @Binding var text: String
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            TextField(prompt, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($focused)
                .onAppear { focused = true }
                .onChange(of: focused) { if !focused { editing = false } }
        } else {
            let shown = text.isEmpty ? prompt : text
            Balanced {
                Text(shown).hidden()
                Text(shown).foregroundStyle(text.isEmpty ? .tertiary : .primary)
            }
            .contentShape(Rectangle())
            .onTapGesture { editing = true }
            .pointerStyle(.horizontalText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(shown)
            .accessibilityAddTraits([.isHeader, .isButton])
            .accessibilityAction { editing = true }
            .accessibilityHint("Edits the title")
        }
    }
}

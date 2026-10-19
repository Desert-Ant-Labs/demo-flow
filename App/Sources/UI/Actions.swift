import Observation
import SwiftUI

/// The edits a card can make to its flow. They go through the document, so
/// every one of them can be undone.
///
/// One per window, made once: a card that reads it redraws when the flow it
/// reads changes, not each time the window does.
@MainActor
@Observable
final class FlowActions {
    var graph: Graph
    @ObservationIgnored var updateParams: (String, Params) -> Void = { _, _ in }
    @ObservationIgnored var remove: (String) -> Void = { _ in }
    @ObservationIgnored var addAfter: (String, String, String) -> Void = { _, _, _ in }
    @ObservationIgnored var wire: (String, String, String?) -> Void = { _, _, _ in }
    /// Moves a step between two others: after one step's output, before the
    /// step that took it.
    @ObservationIgnored var move: (String, (node: String, output: String), String?) -> Void = { _, _, _ in }
    /// Runs the flow again, for a step whose result was just cleared.
    @ObservationIgnored var rerun: () -> Void = {}
    /// Adds an If under an If's Else, on the same check.
    @ObservationIgnored var elseIf: (String) -> Void = { _ in }
    @ObservationIgnored var title: () -> String = { "" }
    /// Any edit to the flow made on a copy and written back once, so it is
    /// one step to undo.
    @ObservationIgnored var change: ((inout Graph) -> Void) -> Void = { _ in }

    nonisolated init(graph: Graph = Graph()) {
        _graph = graph
    }

    /// For a card shown outside a window, which has nothing to edit.
    nonisolated static let none = FlowActions()

    func set(_ id: String, _ patch: Params) { updateParams(id, patch) }
}

extension EnvironmentValues {
    @Entry var flowActions = FlowActions.none
    @Entry var flowSession: FlowSession? = nil
}

import Foundation
import Observation
import os

/// Where one step is, for its card.
struct StepState: Sendable {
    enum Status: Sendable { case idle, running, done, skipped, error }

    var status: Status = .idle
    var inputs: [String: Value] = [:]
    var outputs: Outputs?
    var error: String?
    /// How the step went when that is worth a word but not an error, as
    /// "3 of 20 photos could not be read".
    var note: String?
    /// For a loop: which item it is on, of how many.
    var item = 0
    var items = 0
    /// For a loop: how many items it ran.
    var count: Int?
    /// Milliseconds spent in the model, or in the step when it has none.
    var ms: Double?
}

/// Runs a flow as a graph. A step runs again only when its settings or what
/// it is given changed, so editing one text box re-runs just what follows it,
/// and a slow transcription upstream is never repeated. Each step waits only
/// on its own inputs, so independent branches run at the same time.
@MainActor
@Observable
final class Engine {
    private nonisolated static let log = Logger(subsystem: "com.desertant.flow", category: "engine")

    private(set) var states: [String: StepState] = [:]
    private(set) var busy: Set<String> = []

    func state(_ id: String) -> StepState { states[id] ?? StepState() }

    /// The steps of the last run that `progress` counts: all but notes.
    private var counted: Set<String> = []

    /// How far the run is, from 0 to 1, counting a step on a list by its items.
    var progress: Double {
        guard !counted.isEmpty else { return 0 }
        let done = counted.reduce(0.0) { sum, id in
            let s = state(id)
            return switch s.status {
            case .done, .skipped, .error: sum + 1
            case .running: sum + (s.items > 0 ? Double(s.item) / Double(s.items) : 0)
            case .idle: sum
            }
        }
        return min(1, done / Double(counted.count))
    }

    var running: Bool { !busy.isEmpty }

    /// What a step computed last, and from what. `stamp` changes whenever the
    /// outputs do, so a step downstream can tell new values from old without
    /// comparing photos or recordings.
    private struct Memo {
        var params: Params
        var signature: [String: Int]
        var outputs: Outputs
        var stamp: Int
        var count: Int?
        var ms: Double?
        var note: String?
        var mayWrite: Bool
    }

    private struct Evaluated {
        var outputs: Outputs
        var stamp: Int
    }

    @ObservationIgnored private var memo: [String: Memo] = [:]
    @ObservationIgnored private var inflight: [String: (params: Params, signature: [String: Int], mayWrite: Bool, task: Task<Memo, Error>)] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var nextStamp = 1
    /// The kinds of step it knows. A test hands it its own.
    @ObservationIgnored private let steps: [String: StepDef]

    /// Whether steps may change files outside the app's own folders. Off for
    /// a flow just opened, which may have come from anyone, until the person
    /// runs it on purpose; on for a flow they turned on to run by itself.
    /// Everything else runs either way, so the cards stay live.
    @ObservationIgnored var mayWrite: Bool

    init(mayWrite: Bool = false, steps: [String: StepDef] = Steps.byType) {
        self.mayWrite = mayWrite
        self.steps = steps
    }

    private func set(_ id: String, _ change: (inout StepState) -> Void) {
        var s = states[id] ?? StepState()
        change(&s)
        states[id] = s
        if s.status == .running { busy.insert(id) } else { busy.remove(id) }
    }

    /// Runs every step that needs it. `force` runs them all again.
    func run(_ graph: Graph, force: Bool = false) async {
        generation += 1
        let gen = generation
        // Reading a file drops the wire that would close a loop and the editor
        // never makes one, so this is a bug somewhere else. It shows on the
        // cards rather than the flow waiting on itself forever.
        guard !graph.hasCycle else {
            Self.log.fault("not running a flow whose wires lead in a circle")
            for node in graph.nodes {
                set(node.id) {
                    $0 = StepState()
                    $0.status = .error
                    $0.error = "The wires in this flow lead in a circle"
                }
            }
            return
        }
        if force { memo.removeAll() }
        counted = Set(graph.nodes.filter { $0.type != "note" && steps[$0.type] != nil }.map(\.id))
        ModelHub.shared.prefetch(graph.models)
        let samples = graph.runsOnSamples
        let mayWrite = mayWrite
        let byID = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var visits: [String: Task<Evaluated, Never>] = [:]

        func visit(_ id: String) -> Task<Evaluated, Never> {
            if let task = visits[id] { return task }
            let task = Task { await evaluate(id) }
            visits[id] = task
            return task
        }

        func evaluate(_ id: String) async -> Evaluated {
            let none = Evaluated(outputs: [:], stamp: 0)
            guard let node = byID[id], let def = steps[node.type] else { return none }
            let incoming = graph.incoming(id).filter { byID[$0.source] != nil }
            var upstream: [Evaluated] = []
            for edge in incoming { upstream.append(await visit(edge.source).value) }
            guard gen == generation else { return none }

            var inputs: [String: Value] = [:]
            var signature: [String: Int] = [:]
            for (edge, from) in zip(incoming, upstream) {
                if let v = from.outputs[edge.sourceHandle] {
                    inputs[edge.targetHandle] = v
                    signature[edge.targetHandle] = from.stamp
                }
            }

            // Optional means it may be left unwired. A wired input that brought
            // nothing (a branch not taken) skips the step, except one that waits
            // for either input.
            let wired = Set(incoming.map(\.targetHandle))
            let empty = def.anyInput
                ? !incoming.isEmpty && inputs.isEmpty
                : wired.contains { inputs[$0] == nil }
            if empty || def.inputs.contains(where: { !$0.optional && inputs[$0.id] == nil }) {
                set(id) {
                    $0 = StepState()
                    $0.status = incoming.isEmpty ? .idle : .skipped
                }
                return none
            }

            let params = node.params
            let given = { (m: Memo) in Evaluated(outputs: Self.spread(def, m.outputs), stamp: m.stamp) }
            // A step that writes runs again once it may, so pressing Run saves.
            let same = { (p: Params, s: [String: Int], w: Bool) in p == params && s == signature && (!def.writes || w == mayWrite) }
            if let m = memo[id], same(m.params, m.signature, m.mayWrite) {
                if states[id]?.status != .done { finish(id, m, inputs: inputs) }
                return given(m)
            }

            let job: Task<Memo, Error>
            if let running = inflight[id], same(running.params, running.signature, running.mayWrite) {
                job = running.task
            } else {
                // The step was still working on settings or inputs that have
                // since changed. That work is stale: it must neither land after
                // the new result nor, by failing, wipe it.
                inflight[id]?.task.cancel()
                let context = RunContext(id: id, samples: samples, mayWrite: mayWrite) { item, items in
                    Task { @MainActor in self.set(id) { $0.item = item; $0.items = items } }
                }
                job = Task {
                    if let model = def.model { try await ModelHub.shared.prepare(model) }
                    let started = ContinuousClock.now
                    let outputs = try await Self.runOne(def, inputs: inputs, params: params, context: context)
                    let ms = def.model == nil ? (ContinuousClock.now - started).inMilliseconds : context.ms
                    self.nextStamp += 1
                    return Memo(params: params, signature: signature, outputs: outputs, stamp: self.nextStamp,
                                count: context.count, ms: ms, note: context.note, mayWrite: mayWrite)
                }
                inflight[id] = (params, signature, mayWrite, job)
            }

            set(id) {
                $0.status = .running
                $0.error = nil
                $0.note = nil
                $0.inputs = inputs
                $0.item = 0
                $0.items = 0
            }
            do {
                let m = try await job.value
                if inflight[id]?.task == job { inflight[id] = nil }
                guard !job.isCancelled else { return none }
                memo[id] = m
                if gen == generation { finish(id, m, inputs: inputs) }
                return given(m)
            } catch {
                if inflight[id]?.task == job { inflight[id] = nil }
                guard !job.isCancelled else { return none }
                memo[id] = nil
                Self.log.error("\(node.type, privacy: .public) \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                if gen == generation {
                    set(id) {
                        $0.status = .error
                        $0.error = error.localizedDescription
                        $0.outputs = nil
                    }
                }
                return none
            }
        }

        for node in graph.nodes { _ = visit(node.id) }
        for task in visits.values { _ = await task.value }
    }

    private func finish(_ id: String, _ m: Memo, inputs: [String: Value]) {
        set(id) {
            $0.status = .done
            $0.outputs = m.outputs
            $0.inputs = inputs
            $0.error = nil
            $0.note = m.note
            $0.count = m.count
            $0.ms = m.ms
        }
    }

    /// A loop arriving at an input that takes one value runs the step once per
    /// item. Other loop inputs of the same length are read at the same index,
    /// and an item that is a hole stays a hole.
    nonisolated private static func runOne(_ def: StepDef, inputs: [String: Value], params: Params, context: RunContext) async throws -> Outputs {
        let loop = def.noMap ? nil : def.inputs.first { !$0.list && inputs[$0.id]?.isStream == true }
        guard let loop, case .stream(let items) = inputs[loop.id] else {
            return try await def.run(StepRun(inputs: inputs, params: params, context: context))
        }
        let aligned = def.inputs.filter { p in
            p.id != loop.id && !p.list && inputs[p.id]?.isStream == true && inputs[p.id]!.items.count == items.count
        }
        var results = [Outputs?](repeating: nil, count: items.count)
        let todo = items.count(where: { $0 != nil })
        context.count = todo
        var done = 0
        var firstError: Error?
        var failed = 0
        for (i, item) in items.enumerated() {
            guard let item else { continue }
            try Task.checkCancellation()
            done += 1
            context.progress(done, todo)
            var one = inputs
            one[loop.id] = item
            for p in aligned { one[p.id] = inputs[p.id]!.items[i] }
            do {
                results[i] = try await def.run(StepRun(inputs: one, params: params, context: context))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One item that fails leaves a hole rather than failing the
                // loop, and the card says how many did.
                firstError = firstError ?? error
                failed += 1
            }
        }
        if let firstError, !results.contains(where: { $0 != nil }) { throw firstError }
        if failed > 0 { context.note = "\(failed) of \(todo) items failed" }
        var outputs: Outputs = [:]
        for port in def.outputs {
            outputs[port.id] = .stream(results.map { $0?[port.id] })
        }
        return outputs
    }

    /// A list output goes on item by item. The engine runs a step that takes
    /// one item once per item, and gives a step that takes a list all of them.
    nonisolated static func spread(_ def: StepDef, _ outputs: Outputs) -> Outputs {
        var out = outputs
        for port in def.outputs where port.each != nil {
            if case .list(let items) = outputs[port.id] { out[port.id] = .stream(items) }
        }
        return out
    }

    /// Drops what a removed step computed.
    func forget(_ id: String) {
        inflight[id]?.task.cancel()
        inflight[id] = nil
        memo[id] = nil
        states[id] = nil
        busy.remove(id)
    }

    /// Drops everything, for a flow that opens in place of another.
    func reset() {
        generation += 1
        for job in inflight.values { job.task.cancel() }
        memo.removeAll()
        inflight.removeAll()
        states.removeAll()
        busy.removeAll()
    }
}

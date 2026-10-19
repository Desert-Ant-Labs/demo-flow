import Foundation

/// What a port carries. `any` fits everything.
enum PortType: String, Sendable {
    case text, audio, image, stroke, any

    func fits(_ input: PortType) -> Bool {
        self == input || self == .any || input == .any
    }
}

struct Port: Identifiable, Hashable, Sendable {
    let id: String
    let type: PortType
    let label: String
    /// Takes a whole list at once rather than running once per item.
    var list = false
    /// May be left unwired.
    var optional = false
    /// For a step with many outputs: the question this one answers.
    var group: String? = nil
    /// A list that goes on item by item: a step after it that takes one
    /// item runs once per item, and one that takes a list gets them all.
    /// Names an item, for the loop's heading.
    var each: String? = nil
}

enum Category: String, CaseIterable, Sendable {
    case input, model, logic, output, note

    var label: String {
        switch self {
        case .input: "Start with"
        case .model: "Models"
        case .logic: "Logic"
        case .output: "Finish with"
        case .note: "Notes"
        }
    }

    /// The pill on a card.
    var kind: String {
        switch self {
        case .input: "Input"
        case .model: "Model"
        case .logic: "Logic"
        case .output: "Output"
        case .note: "Note"
        }
    }
}

/// Which outputs a step with many of them shows.
struct Pick: Sendable {
    var defaults: [String]
    var suggest: [String] = []
    var groups: [(String, String)] = []
}

/// What a step's run gets.
struct StepRun: Sendable {
    var inputs: [String: Value]
    var params: Params
    var context: RunContext
}

/// Progress and timing for one run of one step.
final class RunContext: @unchecked Sendable {
    let id: String
    /// The flow starts from the app's samples, so a step that writes files on
    /// every run writes nothing: opening a template never changes a folder.
    let samples: Bool
    /// Someone asked for this run: they pressed Run in this window, or turned
    /// the flow on to run by itself. Until then a flow just opened, maybe from
    /// a link, changes no file outside the app's own folders.
    let mayWrite: Bool
    /// Reports which item a loop is on, of how many.
    let progress: @Sendable (Int, Int) -> Void
    /// Someone has the flow open in a window and can answer a question at
    /// once. A run a trigger started may have nobody watching.
    let attended: Bool
    /// Puts a question to whoever runs the flow and waits for the answer.
    private let asker: (@Sendable (Question) async throws -> Answer)?
    private let lock = NSLock()
    private var modelTime: Double = 0
    private var itemCount: Int?
    private var remark: String?

    init(id: String, samples: Bool = false, mayWrite: Bool = false, attended: Bool = true,
         asker: (@Sendable (Question) async throws -> Answer)? = nil, progress: @escaping @Sendable (Int, Int) -> Void) {
        self.id = id
        self.samples = samples
        self.mayWrite = mayWrite
        self.attended = attended
        self.asker = asker
        self.progress = progress
    }

    /// Waits for the answer to a question, or throws when the run is cancelled.
    func ask(_ question: Question) async throws -> Answer {
        guard let asker else { throw StepError("Nobody can answer a question here") }
        return try await asker(question)
    }

    /// Whether this run may write, move, or rename these files: always once
    /// someone asked for it, and otherwise only inside the app's own folders.
    func mayChange(_ urls: [URL]) -> Bool {
        mayWrite || urls.allSatisfy(Self.isOwn)
    }

    private static func isOwn(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return [Library.folder(""), Samples.root].contains { folder in
            var root = folder.standardizedFileURL.path(percentEncoded: false)
            if !root.hasSuffix("/") { root += "/" }
            return path.hasPrefix(root)
        }
    }

    /// Milliseconds spent in models, not counting loading them.
    var ms: Double { lock.withLock { modelTime } }

    /// How many items a loop ran.
    var count: Int? {
        get { lock.withLock { itemCount } }
        set { lock.withLock { itemCount = newValue } }
    }

    /// A word for the card on how the step went, short of an error.
    var note: String? {
        get { lock.withLock { remark } }
        set { lock.withLock { remark = newValue } }
    }

    /// Says how many of a batch could not be read, when any could not.
    func missed(_ failed: Int, of total: Int, _ noun: String) {
        guard failed > 0 else { return }
        note = failed == total ? "None of the \(noun) could be read" : "\(failed) of \(total) \(noun) could not be read"
    }

    /// Runs a model call and adds its time to the step's total.
    func timed<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        let started = ContinuousClock.now
        let result = try await work()
        let spent = (ContinuousClock.now - started).inMilliseconds
        lock.withLock { modelTime += spent }
        return result
    }
}

extension Duration {
    var inMilliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}

typealias Outputs = [String: Value]

/// A kind of step: its ports, its settings, and how it runs.
struct StepDef: Sendable {
    let type: String
    let title: String
    let description: String
    let category: Category
    var model: ModelID? = nil
    var inputs: [Port] = []
    var outputs: [Port] = []
    var defaults: Params = [:]
    /// Takes a loop whole instead of running once per item.
    var noMap = false
    /// Runs when either of its inputs brings something.
    var anyInput = false
    var pick: Pick? = nil
    /// The outputs a setting decides on, for a step whose outputs follow its
    /// settings rather than being picked: Ask gives an Answer only when it
    /// asks for one.
    var shows: (@Sendable (Params) -> Set<String>)? = nil
    var width: CGFloat? = nil
    var resizable = false
    var featured = false
    /// Changes files on every run when its settings say so, which waits for
    /// `RunContext.mayWrite`.
    var writes = false
    /// Waits for a person's answer. Running the flow again on purpose keeps
    /// the answer while what it was about stays the same.
    var asks = false
    let run: @Sendable (StepRun) async throws -> Outputs

    /// The outputs this step shows. A wired output stays even when switched off.
    func visibleOutputs(_ params: Params, wired: Set<String> = []) -> [Port] {
        if let shows {
            let on = shows(params)
            return outputs.filter { on.contains($0.id) || wired.contains($0.id) }
        }
        guard let pick else { return outputs }
        let on = Set(params["fields"]?.strings ?? pick.defaults)
        return outputs.filter { on.contains($0.id) || wired.contains($0.id) }
    }
}

struct StepError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Steps {
    static let all: [StepDef] = TriggerSteps.all + InputSteps.all + ModelSteps.all + LogicSteps.all + [AskStep.def, ReadTextStep.def, ConvertStep.def] + OutputSteps.all + FileSteps.all + [LogicSteps.note]
    static let byType: [String: StepDef] = Dictionary(uniqueKeysWithValues: all.map { ($0.type, $0) })
    static let palette = all
}

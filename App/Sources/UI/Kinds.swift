import Foundation

/// What an output carries, as precisely as Flow can tell, so the editor offers
/// only what an input can use. Many outputs are typed `any` for the engine,
/// which lets anything through; this is the editor's stricter reading.
enum Kind: Equatable {
    /// `label` is text too, but a word or two, like a photo type or a
    /// language code: something to sort or show, not to read.
    case text, label, number, yesNo, photo, audio, drawing, file, list, data, unknown

    /// The kind, as the end of "gives …" or "needs …".
    var noun: String {
        switch self {
        case .text: "text"
        case .label: "a short label"
        case .number: "a number"
        case .yesNo: "yes or no"
        case .photo: "a photo"
        case .audio: "audio"
        case .drawing: "a drawing"
        case .file: "a file"
        case .list: "a list"
        case .data: "data"
        case .unknown: "anything"
        }
    }

    init(_ type: PortType) {
        switch type {
        case .text: self = .text
        case .audio: self = .audio
        case .image: self = .photo
        case .stroke: self = .drawing
        case .any: self = .unknown
        }
    }

    /// A value's kind. A stream's items count one at a time, as the steps
    /// after it get them.
    init(of value: Value?) {
        switch value {
        case nil: self = .unknown
        case .text: self = .text
        case .number: self = .number
        case .bool: self = .yesNo
        case .audio: self = .audio
        case .image: self = .photo
        case .file: self = .file
        case .stroke, .shape: self = .drawing
        case .list: self = .list
        case .record: self = .data
        case .stream(let items): self = Kind(of: items.lazy.compactMap { $0 }.first)
        }
    }
}

/// Outputs typed `any` whose kind is known before anything runs.
private let known: [String: [String: Kind]] = [
    "eye": Dictionary(uniqueKeysWithValues:
        (EyeFields.scores.map { ($0, Kind.number) })
        + [("people", .number), ("pets", .number), ("faces", .number), ("animal", .yesNo),
           ("type", .label), ("reason", .label), ("blur", .label), ("sensitive", .label), ("expression", .label), ("shot", .label),
           ("subject", .list), ("scenes", .list), ("crop", .data), ("detail", .data)]),
    "moderator": ["safe": .yesNo, "score": .number],
    "tongue": ["reliable": .yesNo, "language": .label],
    "ear": ["reliable": .yesNo, "language": .label],
    "gist": ["topics": .list, "top": .label],
    "emo": ["list": .list, "emoji": .label],
    "shapes": ["kind": .label],
    "redact": ["found": .list, "count": .number],
    "voz": ["words": .list],
    "who": ["turns": .list, "speakers": .number],
    "readtext": ["lines": .list],
    "best": ["score": .number],
]

/// What one output of a step gives: its declared type, else what it is known
/// to give, else what it gave in the last run.
@MainActor
func outputKind(_ node: Node, _ port: Port, session: FlowSession?) -> Kind {
    if let noun = port.each {
        return ["photo": .photo, "file": .file, "stroke": .drawing, "recording": .audio][noun] ?? .text
    }
    if let k = known[node.type]?[port.id] { return k }
    let declared = Kind(port.type)
    if declared != .unknown { return declared }
    return Kind(of: session?.engine.state(node.id).outputs?[port.id])
}

/// Whether an input can use what an output gives. An input that takes
/// anything takes it, and so does one fed by a kind not known yet.
func accepts(_ input: Port, of def: StepDef?, _ kind: Kind) -> Bool {
    let needs = Kind(input.type)
    if needs == .unknown || kind == .unknown || kind == needs { return true }
    // A short label works wherever text does, except in a model that reads
    // text: Gist finds no topic in "screenshot", nor Redact a name.
    return needs == .text && kind == .label && def?.model == nil
}

/// What an empty input asks for: "Choose a photo".
func choosePrompt(_ input: Port) -> String {
    let needs = Kind(input.type)
    return needs == .unknown ? "Choose a step" : "Choose \(needs.noun)"
}

/// What a step added after `anchor` can take from: the anchor's outputs
/// first, then those of the steps before it, nearest first. Voz added after
/// Ear takes its audio from the recording Ear listened to.
@MainActor
func upstreamOutputs(from anchor: Node, in graph: Graph, session: FlowSession?) -> [(node: Node, port: Port, kind: Kind)] {
    var out: [(node: Node, port: Port, kind: Kind)] = []
    var seen: Set<String> = []
    var queue = [anchor.id]
    while !queue.isEmpty {
        let id = queue.removeFirst()
        guard seen.insert(id).inserted, let n = graph.node(id), let d = n.def else { continue }
        for p in d.visibleOutputs(n.params, wired: graph.wiredFrom(id)) {
            out.append((n, p, outputKind(n, p, session: session)))
        }
        queue += graph.incoming(id).map(\.source)
    }
    return out
}

/// The nearest of `sources` an input can take, if any.
func nearest(for input: Port, of def: StepDef, in sources: [(node: Node, port: Port, kind: Kind)]) -> (node: Node, port: Port, kind: Kind)? {
    sources.first { $0.port.type.fits(input.type) && accepts(input, of: def, $0.kind) }
}

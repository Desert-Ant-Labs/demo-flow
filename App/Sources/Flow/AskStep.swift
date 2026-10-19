import Foundation

/// What Ask asks for.
enum AskKind: String, CaseIterable, Sendable {
    /// Yes or No, for everything that came in at once.
    case confirm
    /// Which of the items go on: each one ticked or not.
    case pick
    /// One of a few answers the flow lists.
    case choose
    /// Words typed in.
    case type

    var label: String {
        switch self {
        case .confirm: "Yes or no"
        case .pick: "Pick the items"
        case .choose: "Choose an answer"
        case .type: "Type an answer"
        }
    }

    /// The question a new Ask step starts with.
    var question: String {
        switch self {
        case .confirm: "Go on with {{items}}?"
        case .pick: "Untick any you don't want to go on."
        case .choose: "Which one?"
        case .type: "What should it say?"
        }
    }

    /// Whether this kind gives an answer of its own besides what came in.
    var answers: Bool { self == .choose || self == .type }

    /// The kind an Ask step's settings name.
    init(_ params: Params) {
        self = params["kind"]?.string.flatMap(AskKind.init(rawValue:)) ?? .confirm
    }
}

/// A question a step waits on until someone answers it: in the step's card,
/// in the floater, or in a notification.
struct Question: Identifiable, Sendable {
    let id = UUID()
    /// The step that asks.
    let step: String
    let kind: AskKind
    let text: String
    /// What the question is about, each shown with it.
    let items: [Value]
    /// The answers to choose from.
    let options: [String]
    /// The typed answer it starts with.
    let suggestion: String
    /// After how long a run nobody watches goes on without an answer, and with which.
    let deadline: Date?
    let fallback: Answer?

    /// What is shown with the question, in a few words: "8 photos".
    var about: String? {
        items.isEmpty ? nil : AskStep.counted(items)
    }
}

/// What a run nobody watches does once its question has waited long enough.
enum Fallback: String, CaseIterable, Sendable {
    /// Goes on as if they agreed to everything.
    case yes
    /// Goes on as if they turned it down.
    case no
    case stop
}

/// How someone answered, or what a run did without them.
enum Answer: Sendable, Equatable {
    case yes, no
    /// The items to go on, by their place among the question's items.
    case picked([Int])
    case chose(String)
    case typed(String)
    /// Stop the run here.
    case stop

    /// The answer as a few words, for the card once it is given.
    func said(_ q: Question) -> String {
        switch self {
        case .yes: "Yes"
        case .no: q.kind == .confirm ? "No" : "Skipped"
        case .picked(let i): "\(i.count) of \(q.items.count) picked"
        case .chose(let s), .typed(let s): s.isEmpty ? "Nothing" : "\u{201C}\(s)\u{201D}"
        case .stop: "Stopped"
        }
    }
}

/// Ask: a step that waits for a person. It sends what came in down Yes or
/// No, keeps only the items someone picks, or gives the answer they chose or
/// typed. The engine keeps the answer like any step's result, so the
/// question comes back only when what it is about changes.
enum AskStep {
    static let def = StepDef(
        type: "ask", title: "Ask", description: "Wait for your answer before going on",
        category: .logic,
        inputs: [Port(id: "value", type: .any, label: "About", optional: true)],
        outputs: [Port(id: "yes", type: .any, label: "Yes"), Port(id: "no", type: .any, label: "No"),
                  Port(id: "answer", type: .text, label: "Answer")],
        defaults: ["kind": .string(AskKind.confirm.rawValue), "question": .string(AskKind.confirm.question),
                   "wait": 0, "fallback": .string(Fallback.no.rawValue)],
        noMap: true,
        shows: { params in
            AskKind(params).answers ? ["yes", "no", "answer"] : ["yes", "no"]
        },
        asks: true
    ) { run in try await ask(run) }

    /// How long a run nobody watches can wait for an answer, in minutes.
    /// 0 waits until someone answers.
    static let waits: [Double] = [0, 5, 60, 1440]

    /// A wait as words: "1 hour", "1 day".
    static func label(forWait minutes: Double) -> String {
        guard minutes > 0 else { return "Until someone answers" }
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide))
    }

    static func ask(_ run: StepRun) async throws -> Outputs {
        let p = run.params
        let kind = AskKind(p)
        let value = run.inputs["value"]
        // A stream keeps its holes, so what goes on lines up with the rest of the flow.
        let slots = value?.items.enumerated().compactMap { i, v in v.map { (i, $0) } } ?? []
        let items = slots.map(\.1)
        let options = (p["options"]?.string ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if kind == .choose && options.isEmpty { throw StepError("Add the answers to choose from") }
        if kind == .pick && value == nil { throw StepError("Wire in the items to pick from") }
        let suggestion = p["answer"]?.string ?? ""
        let wait = max(0, p["wait"]?.number ?? 0)
        let fallback = Self.fallback(Fallback(rawValue: p["fallback"]?.string ?? "") ?? .no, kind: kind, count: items.count,
                                     options: options, suggestion: suggestion)
        let text = Placeholders.fill(p["question"]?.string ?? kind.question) { key in
            switch key {
            case "a": short(value)
            case "count": String(items.count)
            case "items": counted(items)
            default: nil
            }
        }
        let unattended = !run.context.attended && wait > 0
        let question = Question(step: run.context.id, kind: kind, text: text, items: items, options: options, suggestion: suggestion,
                                deadline: unattended ? Date().addingTimeInterval(wait * 60) : nil, fallback: unattended ? fallback : nil)

        let answer: Answer
        if unattended {
            if let given = try await answered(question, run.context, within: wait * 60) {
                answer = given
            } else {
                answer = fallback
                run.context.note = "Nobody answered in \(label(forWait: wait)), so it went on with \(answer.said(question))"
            }
        } else {
            answer = try await run.context.ask(question)
        }
        return try outputs(answer, value: value, slots: slots, kind: kind)
    }

    /// What goes out for an answer.
    static func outputs(_ answer: Answer, value: Value?, slots: [(Int, Value)], kind: AskKind) throws -> Outputs {
        switch answer {
        case .stop:
            throw StepError("Stopped at this question")
        case .yes:
            return ["yes": value ?? .bool(true)]
        case .no:
            return ["no": value ?? .bool(false)]
        case .chose(let s), .typed(let s):
            return ["yes": value ?? .text(s), "answer": .text(s)]
        case .picked(let picked):
            let keep = Set(picked.compactMap { $0 < slots.count ? slots[$0].0 : nil })
            switch value {
            case .stream(let all)?:
                var out: Outputs = [:]
                out["yes"] = Value.sparse(all.enumerated().map { keep.contains($0) ? $1 : nil })
                out["no"] = Value.sparse(all.enumerated().map { keep.contains($0) ? nil : $1 })
                return out
            case .list(let all)?:
                let yes = all.enumerated().filter { keep.contains($0.offset) }.compactMap(\.element)
                let no = all.enumerated().filter { !keep.contains($0.offset) }.compactMap(\.element)
                var out: Outputs = [:]
                if !yes.isEmpty { out["yes"] = .list(yes) }
                if !no.isEmpty { out["no"] = .list(no) }
                return out
            case let one?:
                return keep.contains(0) ? ["yes": one] : ["no": one]
            case nil:
                return [:]
            }
        }
    }

    /// The answer, or nil once `seconds` pass without one.
    private static func answered(_ q: Question, _ context: RunContext, within seconds: Double) async throws -> Answer? {
        try await withThrowingTaskGroup(of: Answer?.self) { group in
            group.addTask { try await context.ask(q) }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            // Whichever ends first: the answer, or the wait. The other is cancelled.
            let first = try await group.next()
            group.cancelAll()
            return first.flatMap { $0 }
        }
    }

    /// The answer a fallback stands for, for this kind of question.
    static func fallback(_ fallback: Fallback, kind: AskKind, count: Int, options: [String], suggestion: String) -> Answer {
        switch (fallback, kind) {
        case (.stop, _): .stop
        case (.yes, .confirm): .yes
        case (.yes, .pick): .picked(Array(0..<count))
        case (.yes, .choose): .chose(options.first ?? "")
        case (.yes, .type): .typed(suggestion)
        case (.no, .pick): .picked([])
        case (.no, _): .no
        }
    }

    /// "8 photos", "1 recording", "3 items", or "this" for nothing wired in.
    static func counted(_ items: [Value]) -> String {
        let n = items.count
        if n == 0 { return "this" }
        let noun: String
        if items.allSatisfy({ $0.photo != nil }) { noun = n == 1 ? "photo" : "photos" }
        else if items.allSatisfy({ $0.audio != nil }) { noun = n == 1 ? "recording" : "recordings" }
        else if items.allSatisfy({ if case .file = $0 { true } else { false } }) { noun = n == 1 ? "file" : "files" }
        else { noun = n == 1 ? "item" : "items" }
        return "\(n) \(noun)"
    }

    /// The value in a few words, for `{{a}}`.
    private static func short(_ value: Value?) -> String {
        let text = value.asText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 80 ? String(text.prefix(79)) + "\u{2026}" : text
    }
}

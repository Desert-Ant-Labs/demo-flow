import Foundation

/// A flow that runs on its own, as its first step says: when a call starts,
/// when files land in a folder, on a schedule, or when a shortcut is pressed.
/// Made from the flow file each time it is read, so the step is the one place
/// it is set; only whether it is on is kept apart, on this Mac.
struct Trigger: Identifiable, Hashable, Sendable {
    var id = UUID()
    var on = true
    var event: Event
    var flow: FlowRef

    enum Event: Hashable, Sendable {
        /// A call starts in one of these apps, by bundle ID prefix. Recording
        /// stops when the app lets go of the microphone.
        case call(apps: [String])
        /// New files in a folder, the ones the flow can take.
        case folder(path: String)
        /// Every day at a time, on the weekdays given (1 is Sunday).
        case schedule(hour: Int, minute: Int, weekdays: Set<Int>)
        /// A key pressed anywhere: to record your voice, take the clipboard,
        /// or just run.
        case shortcut(Shortcut?, takes: String)
    }

    /// A flow file, or one of the templates by its id.
    enum FlowRef: Codable, Hashable, Sendable {
        case file(path: String)
        case template(id: String)
    }
}

extension Trigger {
    /// The trigger as a short title, for its card: "New files in the Inbox folder".
    var title: String {
        switch event {
        case .call(let apps):
            let names = CallApps.names(apps)
            return names.isEmpty ? "Any call" : "Calls in \(names)"
        case .folder(let path):
            return "New files in \(Self.folder(path))"
        case .schedule(let hour, let minute, let weekdays):
            return "\(Schedule.days(weekdays)) at \(Self.time(hour, minute))"
        case .shortcut(let keys, _):
            return keys.map { "Press \($0.display)" } ?? "No shortcut yet"
        }
    }

    /// The trigger as the start of a sentence: "When a call starts in Zoom".
    var when: String {
        switch event {
        case .call(let apps):
            let names = CallApps.names(apps)
            return names.isEmpty ? "When a call starts" : "When a call starts in \(names)"
        case .folder(let path):
            return "When files are added to \(Self.folder(path))"
        case .schedule(let hour, let minute, let weekdays):
            return "\(Schedule.days(weekdays)) at \(Self.time(hour, minute))"
        case .shortcut(let keys, _):
            return keys.map { "When you press \($0.display)" } ?? "When you press its shortcut"
        }
    }

    private static func folder(_ path: String) -> String {
        "the \(URL(filePath: path).lastPathComponent) folder"
    }

    private static func time(_ hour: Int, _ minute: Int) -> String {
        Calendar.current.date(from: DateComponents(hour: hour, minute: minute)).map { $0.formatted(date: .omitted, time: .shortened) } ?? ""
    }

    var symbol: String {
        switch event {
        case .call: "phone"
        case .folder: "folder"
        case .schedule: "clock"
        case .shortcut: "command"
        }
    }

    /// What a flow's first step says about when it runs, if it starts with
    /// one of the trigger steps.
    static func event(of graph: Graph) -> Event? {
        guard let node = graph.ordered.first(where: { TriggerSteps.isTrigger($0.type) }) else { return nil }
        let p = node.params
        switch node.type {
        case "call":
            return .call(apps: p["apps"]?.strings ?? CallApps.allIDs)
        case "watch":
            return .folder(path: (p["folder"]?.string).map { ($0 as NSString).expandingTildeInPath } ?? "")
        case "schedule":
            // The file may have been edited by hand: a day or a time out of
            // range is dropped, not trusted.
            let days = (p["days"]?.array ?? []).compactMap { whole($0, in: 1...7) }
            return .schedule(hour: whole(p["hour"], in: 0...23) ?? 9, minute: whole(p["minute"], in: 0...59) ?? 0, weekdays: Set(days))
        case "shortcut":
            return .shortcut(Shortcut(json: p["keys"]), takes: p["takes"]?.string ?? "voice")
        default:
            return nil
        }
    }

    private static func whole(_ json: JSON?, in range: ClosedRange<Int>) -> Int? {
        guard let n = json?.int, range.contains(n) else { return nil }
        return n
    }

    /// The step that starts a flow, if it has one.
    static func node(of graph: Graph) -> Node? {
        graph.ordered.first { TriggerSteps.isTrigger($0.type) }
    }
}

extension Trigger.FlowRef {
    /// The flow as it is now, read fresh each run so edits count.
    func graph() throws -> Graph {
        switch self {
        case .file(let path):
            return try FlowFile.read(String(contentsOf: URL(filePath: path), encoding: .utf8))
        case .template(let id):
            guard let example = Example.all.first(where: { $0.id == id }) else { throw StepError("That template is gone") }
            return example.graph
        }
    }

    var title: String {
        switch self {
        case .file(let path):
            if let g = try? graph(), !g.meta.title.isEmpty { return g.meta.title }
            return URL(filePath: path).deletingPathExtension().lastPathComponent
        case .template(let id):
            return Example.all.first { $0.id == id }?.title ?? id
        }
    }

    var path: String? {
        if case .file(let path) = self { return path }
        return nil
    }

    var missing: Bool {
        if case .file(let path) = self { return !FileManager.default.fileExists(atPath: path) }
        return false
    }
}

enum Schedule {
    /// When a schedule runs next after `date`: the first time of day on one
    /// of its weekdays. An hour that repeats as the clocks go back counts once.
    static func next(after date: Date, hour: Int, minute: Int, weekdays: Set<Int>, in calendar: Calendar = .current) -> Date? {
        var from = date
        for _ in 0..<8 {
            guard let next = calendar.nextDate(after: from, matching: DateComponents(hour: hour, minute: minute),
                                               matchingPolicy: .nextTime, repeatedTimePolicy: .first) else { return nil }
            if weekdays.isEmpty || weekdays.contains(calendar.component(.weekday, from: next)) { return next }
            from = next
        }
        return nil
    }

    static func days(_ weekdays: Set<Int>) -> String {
        switch weekdays {
        case Set(1...7), []: return "Every day"
        case Set(2...6): return "Weekdays"
        case [1, 7]: return "Weekends"
        default:
            let symbols = Calendar.current.shortWeekdaySymbols
            return weekdays.sorted().compactMap { symbols.indices.contains($0 - 1) ? symbols[$0 - 1] : nil }.joined(separator: ", ")
        }
    }
}

/// The apps a call can start in. Browsers count, for calls on the web.
enum CallApps {
    struct App: Identifiable, Hashable {
        let name: String
        let ids: [String]
        var id: String { name }
    }

    static let all: [App] = [
        App(name: "Zoom", ids: ["us.zoom.xos"]),
        App(name: "Microsoft Teams", ids: ["com.microsoft.teams"]),
        App(name: "FaceTime", ids: ["com.apple.FaceTime", "com.apple.avconferenced"]),
        App(name: "Slack", ids: ["com.tinyspeck.slackmacgap"]),
        App(name: "Webex", ids: ["Cisco-Systems.Spark", "com.webex.meetingmanager"]),
        App(name: "Discord", ids: ["com.hnc.Discord"]),
        App(name: "Browsers", ids: ["com.google.Chrome", "com.apple.Safari", "com.apple.WebKit", "company.thebrowser.Browser",
                                    "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser"]),
    ]

    static var allIDs: [String] { all.flatMap(\.ids) }

    static func names(_ ids: [String]) -> String {
        let chosen = all.filter { app in app.ids.contains { ids.contains($0) } }
        if chosen.count == all.count { return "" }
        let names = chosen.map(\.name)
        return names.count <= 2 ? names.joined(separator: " or ") : names.dropLast().joined(separator: ", ") + " or " + names.last!
    }

    static func name(of bundleID: String) -> String {
        all.first { $0.ids.contains { bundleID.hasPrefix($0) } }?.name ?? bundleID
    }
}

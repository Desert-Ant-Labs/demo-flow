import AppKit
import Foundation
import Observation
import os

/// Keeps the flows that run on their own, watches for what sets them off, and
/// runs them in the background. Lives as long as the app, in the menu bar.
/// Which flows those are is kept on this Mac, by path; when each runs is read
/// from the flow's first step.
@MainActor
@Observable
final class TriggerCenter {
    static let shared = TriggerCenter()
    private static let log = Logger(subsystem: "com.desertant.flow", category: "triggers")

    /// The flows turned on or off on this Mac, by path.
    private(set) var flows: [Automatic] = []
    /// The ones whose file starts with a trigger step, as read from the file.
    private(set) var triggers: [Trigger] = []
    /// This launch's runs, newest first: the live ones, and the ones that
    /// ended, until a newer run replaces them.
    private(set) var runs: [FlowRun] = []
    private(set) var history: [RunRecord] = []
    /// What the menu bar icon shows. Set by the clock, never read back by it,
    /// so the icon redraws only when this changes.
    private(set) var indicator = Indicator.idle
    /// Watched folders that aren't there, which are looked for until they're back.
    private(set) var missingFolders: Set<String> = []
    var paused = false {
        didSet { UserDefaults.standard.set(paused, forKey: "triggersPaused"); apply() }
    }

    @ObservationIgnored private var watchers: [UUID: FolderWatcher] = [:]
    /// Files that showed up while a folder trigger's flow ran, by trigger.
    @ObservationIgnored private var held: [UUID: [URL]] = [:]
    @ObservationIgnored private var seen: [UUID: [String]] = [:]
    /// When each schedule runs next, for the event it was worked out from.
    @ObservationIgnored private var upcoming: [UUID: (event: Trigger.Event, date: Date)] = [:]
    /// Calls already recorded, so each call is caught once.
    @ObservationIgnored private var caught: Set<pid_t> = []
    @ObservationIgnored private var quiet: [UUID: Int] = [:]
    /// The last run waiting or running for each trigger, which the next one waits for.
    @ObservationIgnored private var lanes: [UUID: (ticket: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var started = false

    private static var folder: URL { Library.folder("Triggers") }

    private init() {}

    var live: [FlowRun] { runs.filter(\.live) }

    func start() {
        guard !started else { return }
        started = true
        paused = UserDefaults.standard.bool(forKey: "triggersPaused")
        history = load("history.json") ?? []
        flows = load("automatic.json") ?? []
        let kept = Set(flows.map(\.id))
        seen = (load("seen.json") ?? [:]).filter { kept.contains($0.key) }
        reload()
        Notifications.setUp()
        Floater.shared.start()
        clock = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick += 1
                self?.tick(checks: tick.isMultiple(of: 2))
            }
        }
        Demo.start()
    }

    // MARK: Flows that run on their own

    struct Automatic: Codable, Identifiable, Hashable, Sendable {
        var id = UUID()
        var path: String
        var on: Bool
        /// The template it was saved from, so the Library can show that
        /// template as on.
        var template: String?
    }

    func entry(for path: String) -> Automatic? {
        let path = URL(filePath: path).standardizedFileURL.path
        return flows.first { URL(filePath: $0.path).standardizedFileURL.path == path }
    }

    func entry(template id: String) -> Automatic? {
        flows.first { $0.template == id && FileManager.default.fileExists(atPath: $0.path) }
    }

    func isOn(_ path: String) -> Bool { entry(for: path)?.on ?? false }

    /// Turns a saved flow on or off. A flow turned on for the first time is
    /// kept from now on, by path.
    func setOn(_ on: Bool, path: String, template: String? = nil, graph: Graph? = nil) {
        if let graph { drafts[path] = (graph, Date()) }
        let id = entry(for: path)?.id
        if let i = flows.firstIndex(where: { $0.id == id }) {
            // Turned on again, its folder starts from what is there now.
            if on && !flows[i].on { seen[flows[i].id] = nil }
            flows[i].on = on
        } else {
            flows.append(Automatic(path: path, on: on, template: template))
        }
        store(flows, "automatic.json")
        reload()
        guard let trigger = triggers.first(where: { $0.flow == .file(path: path) }), on else { return }
        if trigger.isCall { MeetingCalendar.ask() }
        Notifications.askPermission()
    }

    func toggle(_ trigger: Trigger) {
        guard case .file(let path) = trigger.flow else { return }
        setOn(!trigger.on, path: path)
    }

    /// Forgets a flow that was moved or deleted.
    func forget(path: String) {
        guard let id = entry(for: path)?.id else { return }
        flows.removeAll { $0.id == id }
        seen[id] = nil
        drafts[path] = nil
        store(flows, "automatic.json")
        store(seen, "seen.json")
        reload()
    }

    /// Unsaved edits to a kept flow, so a changed folder or shortcut counts
    /// before the window saves. A draft lasts until the file is saved after
    /// it or its window closes; while it lasts, the flow runs as it says too,
    /// so what sets the flow off and what runs never disagree.
    @ObservationIgnored private var drafts: [String: (graph: Graph, at: Date)] = [:]

    func edited(_ path: String, _ graph: Graph) {
        guard entry(for: path) != nil else { return }
        drafts[path] = (graph, Date())
        reload()
    }

    /// A flow as it runs now: its draft while there is one, or its file.
    private func graph(of flow: Trigger.FlowRef) throws -> Graph {
        if case .file(let path) = flow, let draft = drafts[path] {
            let saved = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            if saved.map({ $0 < draft.at }) ?? true { return draft.graph }
            drafts[path] = nil
        }
        return try flow.graph()
    }

    /// Reads each kept flow's first step, and starts or stops what watches for it.
    func reload() {
        triggers = flows.compactMap { entry in
            guard let graph = try? self.graph(of: .file(path: entry.path)),
                  let event = Trigger.event(of: graph) else { return nil }
            return Trigger(id: entry.id, on: entry.on, event: event, flow: .file(path: entry.path))
        }
        apply()
    }

    /// Files a run wrote into the folder its trigger watches, as a renamed
    /// screenshot, so they aren't picked up as new. A run on dropped files
    /// has no folder of its own, and nothing to remember.
    private func remember(_ names: [String], for id: UUID) {
        guard !names.isEmpty, watchers[id] != nil || seen[id] != nil else { return }
        watchers[id]?.remember(names)
        seen[id] = Array(watchers[id]?.known ?? Set(seen[id] ?? []).union(names))
        store(seen, "seen.json")
    }

    /// Lets go of the files held while a folder trigger's flow ran: drops
    /// the ones this run wrote itself, and once no run of the trigger is
    /// left, runs on the rest.
    private func release(_ run: FlowRun) {
        let id = run.trigger.id
        let written = Set(run.changes.map(\.url.lastPathComponent))
        held[id]?.removeAll { written.contains($0.lastPathComponent) }
        guard !runs.contains(where: { $0.live && $0.trigger.id == id }), let waiting = held.removeValue(forKey: id) else { return }
        let rest = waiting.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !rest.isEmpty { found(rest, for: id) }
    }

    /// Starts or stops each folder watch to match the triggers.
    private func apply() {
        guard started else { return }
        let folders = Dictionary(uniqueKeysWithValues: triggers.compactMap { t -> (UUID, String)? in
            guard t.on, !paused, case .folder(let path) = t.event else { return nil }
            return (t.id, path)
        })
        for (id, watcher) in watchers where folders[id] != watcher.folder.path {
            watcher.stop()
            watchers[id] = nil
            missingFolders.remove(watcher.folder.path)
            // A different folder starts from what is in it now.
            if folders[id] != nil { seen[id] = nil }
        }
        for (id, path) in folders where watchers[id] == nil {
            let watcher = FolderWatcher(folder: URL(filePath: path), seen: seen[id].map(Set.init)) { [weak self] gone in
                if gone { self?.missingFolders.insert(path) } else { self?.missingFolders.remove(path) }
            } found: { [weak self] urls in
                self?.found(urls, for: id)
            }
            watchers[id] = watcher
            watcher.start()
            if seen[id] == nil, !watcher.missing {
                seen[id] = Array(watcher.known)
                store(seen, "seen.json")
            }
        }
        var keys: [Shortcut: () -> Void] = [:]
        for trigger in triggers where trigger.on && !paused {
            guard case .shortcut(let shortcut?, _) = trigger.event, keys[shortcut] == nil else { continue }
            keys[shortcut] = { [weak self] in self?.pressed(trigger.id) }
        }
        HotKeys.shared.set(keys)
    }

    /// Flows that would take the same shortcut, which only one of them gets.
    func clashes(_ shortcut: Shortcut, besides path: String) -> String? {
        triggers.first { t in
            guard t.on, t.flow != .file(path: path), case .shortcut(shortcut?, _) = t.event else { return false }
            return true
        }?.flow.title
    }

    // MARK: Watching

    private func tick(checks: Bool) {
        let now = currentIndicator()
        if now != indicator { indicator = now }
        guard checks else { return }
        checkCalls()
        checkSchedules()
    }

    private func checkCalls() {
        let callTriggers = triggers.filter { $0.on && !paused && $0.isCall }
        let recording = runs.filter { $0.app != nil && $0.pid != nil }
        guard !callTriggers.isEmpty || !recording.isEmpty else { return }
        let users = Microphone.users()
        for run in recording {
            if users.contains(where: { $0.pid == run.pid }) {
                quiet[run.id] = 0
            } else {
                // Two quiet checks in a row, so a moment of silence or a device switch does not end it.
                quiet[run.id, default: 0] += 1
                if quiet[run.id] == 2 { stop(run) }
            }
        }
        caught.formIntersection(users.map(\.pid))
        // A call is recorded once, since the microphone can't be recorded
        // twice, and each flow that waits for it runs on that recording.
        var recorded: [pid_t: FlowRun] = [:]
        for trigger in callTriggers where !runs.contains(where: { $0.trigger.id == trigger.id && $0.live }) {
            guard case .call(let apps) = trigger.event,
                  let user = users.first(where: { u in apps.contains { u.bundleID.hasPrefix($0) } }),
                  !caught.contains(user.pid) else { continue }
            if let run = recorded[user.pid] {
                run.alsoFor.append(trigger)
                continue
            }
            let app = CallApps.name(of: user.bundleID)
            let run = begin(trigger, .recording(app: app))
            run.pid = user.pid
            let event = MeetingCalendar.now()
            run.noteTitle = event?.title ?? "\(app) call"
            recorded[user.pid] = run
            Task { await record(run, app: app, people: event?.people ?? [], guests: event?.guests ?? []) }
        }
        caught.formUnion(recorded.keys)
    }

    /// Runs each schedule when its next time has come. Keeping that time,
    /// rather than looking for a check in the right minute, means a Mac that
    /// slept through it runs it once on waking, if it is not long past.
    private func checkSchedules() {
        let now = Date()
        var due: [UUID: (event: Trigger.Event, date: Date)] = [:]
        for trigger in triggers where trigger.on && !paused {
            guard case .schedule(let hour, let minute, let weekdays) = trigger.event else { continue }
            let next = { Schedule.next(after: $0, hour: hour, minute: minute, weekdays: weekdays) }
            // A schedule just turned on or changed counts from now.
            guard let kept = upcoming[trigger.id].flatMap({ $0.event == trigger.event ? $0.date : nil }) ?? next(now) else { continue }
            if kept <= now {
                if now.timeIntervalSince(kept) < Self.grace { start(trigger, files: []) }
                if let date = next(now) { due[trigger.id] = (trigger.event, date) }
            } else {
                due[trigger.id] = (trigger.event, kept)
            }
        }
        upcoming = due
    }

    /// How late a schedule that was slept through may still run.
    private static let grace: TimeInterval = 60 * 60

    private func found(_ urls: [URL], for id: UUID) {
        guard let trigger = triggers.first(where: { $0.id == id }) else { return }
        if let watcher = watchers[id] {
            seen[id] = Array(watcher.known)
            store(seen, "seen.json")
        }
        // While its flow runs, what shows up may be the flow's own work, as a
        // renamed file; it waits for the run to say.
        if runs.contains(where: { $0.live && $0.trigger.id == id }) {
            held[id, default: []] += urls
            return
        }
        guard let graph = try? self.graph(of: trigger.flow), let input = Self.input(of: graph) else { return }
        let kinds = InputKind.of(input, in: graph)
        let usable = urls.filter { url in kinds.contains { $0.takes(url) } }
        guard !usable.isEmpty else { return }
        let batches = input.type == "watch" || kinds.contains(where: \.batches)
        for files in batches ? [usable] : usable.map({ [$0] }) {
            start(trigger, files: files)
        }
    }

    /// Runs a trigger's flow on what it caught.
    private func start(_ trigger: Trigger, files: [URL]) {
        let run = begin(trigger, .running)
        run.files = files
        launch(run)
    }

    @discardableResult
    private func begin(_ trigger: Trigger, _ phase: FlowRun.Phase) -> FlowRun {
        let run = FlowRun(trigger: trigger, phase: phase)
        add(run)
        return run
    }

    private func add(_ run: FlowRun) {
        runs.removeAll { !$0.live && $0.trigger.id == run.trigger.id }
        runs.insert(run, at: 0)
    }

    /// Puts a run made up by `Demo` in the list as if its trigger had fired:
    /// a running one runs, an ended one goes into the history.
    func pretend(_ run: FlowRun) {
        add(run)
        switch run.phase {
        case .running: launch(run)
        case .finished, .failed: ended(run)
        case .recording: break
        }
    }

    // MARK: Actions

    /// Runs a trigger's flow now, by hand, with its saved inputs.
    func runNow(_ trigger: Trigger) {
        let run = begin(trigger, .running)
        launch(run)
    }

    /// Runs a stopped run again on what it caught.
    func retry(_ run: FlowRun) {
        guard case .failed = run.phase else { return }
        // It takes the failed run's place in the list.
        let again = begin(run.trigger, .running)
        again.files = run.files
        again.take = run.take
        again.clipboard = run.clipboard
        again.noteTitle = run.noteTitle
        again.note = run.note
        launch(again)
    }

    func run(_ id: UUID) -> FlowRun? { runs.first { $0.id == id } }

    /// Runs a flow once on files someone brought to it, as a folder trigger would.
    func run(_ flow: Trigger.FlowRef, on files: [URL]) {
        start(Trigger(event: .folder(path: ""), flow: flow), files: files)
    }

    // MARK: Calls

    /// The note being recorded from the microphone, if one is.
    var capturing: FlowRun? { runs.first { $0.live && $0.app != nil && $0.pid == nil && !$0.isCall } }

    /// A flow's shortcut was pressed: records your voice until it is pressed
    /// again, takes what is on the clipboard, or just runs.
    func pressed(_ id: UUID) {
        guard let trigger = triggers.first(where: { $0.id == id }), case .shortcut(_, let takes) = trigger.event else { return }
        if let run = runs.first(where: { $0.live && $0.trigger.id == id && $0.app != nil }) { return stop(run) }
        switch takes {
        case "voice": capture(trigger)
        case "clipboard":
            let run = begin(trigger, .running)
            run.clipboard = Clipboard.read()
            launch(run)
        default: runNow(trigger)
        }
    }

    /// Records from the microphone alone, as the flow's first step says, until
    /// `stop(_:)` runs the flow on it or `discard(_:)` drops it.
    @discardableResult
    func capture(_ trigger: Trigger) -> FlowRun {
        let run = begin(trigger, .recording(app: trigger.flow.title))
        Task {
            let recorder = Recorder()
            run.recorder = recorder
            do {
                try await recorder.start(options(for: trigger)) { run.made = $0 }
                run.transcript = recorder.transcript
            } catch {
                failStart(run, recorder, error)
            }
        }
        return run
    }

    private func record(_ run: FlowRun, app: String, people: [String], guests: [String]) async {
        let recorder = MeetingRecorder()
        run.recorder = recorder
        var options = self.options(for: run.trigger)
        options.vocabulary = people
        options.guests = guests
        do {
            try await recorder.start(options) { run.made = $0 }
            run.transcript = recorder.transcript
        } catch {
            failStart(run, recorder, error)
        }
    }

    /// A recorder that could not start ends its run, unless the run was
    /// stopped or thrown away while it started: that takes care of it then.
    private func failStart(_ run: FlowRun, _ recorder: any TakeRecorder, _ error: Error) {
        guard run.recorder === recorder else {
            run.startError = error
            return
        }
        run.recorder = nil
        fail(run, error)
    }

    /// How a call is recorded for a flow: as its Record step says, or kept
    /// whole for a flow that starts from an audio file.
    private func options(for trigger: Trigger) -> RecordingOptions {
        guard let graph = try? self.graph(of: trigger.flow), let input = Self.input(of: graph), ["record", "call", "shortcut"].contains(input.type) else { return .init() }
        return Recording.options(input.params)
    }

    /// Stops recording a call, as when it ends, and runs the flow on it.
    func stop(_ run: FlowRun) {
        guard run.app != nil else { return }
        let recorder = run.recorder
        run.recorder = nil
        quiet[run.id] = nil
        run.set(.running)
        Task {
            do {
                if let recorder {
                    var take: Take
                    do {
                        take = try await recorder.stop()
                    } catch {
                        // The recording could not be saved, but the words
                        // were handed over: the flow runs on those, and the
                        // result says what was lost.
                        guard let made = run.made, !made.isEmpty else { throw error }
                        take = made
                        run.note = Self.plain(error)
                    }
                    // A recording that ended on its own, as when the
                    // microphone went away, handed over what it made then.
                    if take.isEmpty, let made = run.made { take = made }
                    if take.isEmpty { throw run.startError ?? StepError("Flow heard nothing in the recording") }
                    run.take = take
                    run.files = take.audio.map { [$0] } ?? []
                }
                run.transcript = nil
                launch(run)
                for trigger in run.alsoFor {
                    let other = begin(trigger, .running)
                    other.take = run.take
                    other.files = run.files
                    other.noteTitle = run.noteTitle
                    other.note = run.note
                    launch(other)
                }
            } catch {
                fail(run, error)
            }
        }
    }

    /// Stops recording a call and throws the recording away.
    func discard(_ run: FlowRun) {
        let recorder = run.recorder
        run.recorder = nil
        runs.removeAll { $0 === run }
        Notifications.remove(run)
        Task {
            if let url = try? await recorder?.stop().audio { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: Running

    /// Runs a run's flow once the runs of its trigger before it are done, so
    /// thirty recordings dropped at once don't start thirty engines.
    private func launch(_ run: FlowRun) {
        let id = run.trigger.id, ticket = UUID()
        let before = lanes[id]?.task
        let task = Task {
            await before?.value
            await go(run)
            if lanes[id]?.ticket == ticket { lanes[id] = nil }
        }
        lanes[id] = (ticket, task)
    }

    private func go(_ run: FlowRun) async {
        run.set(.running)
        do {
            if run.trigger.flow.missing { throw StepError("The flow file has moved or been deleted") }
            var graph = try self.graph(of: run.trigger.flow)
            if let take = run.take {
                try Self.fill(&graph, with: take)
            } else if let clipboard = run.clipboard {
                Self.fill(&graph, with: clipboard)
            } else if !run.files.isEmpty {
                try Self.fill(&graph, with: run.files)
            }
            if let title = run.noteTitle, let input = Self.input(of: graph), Self.records(input),
               let i = graph.nodes.firstIndex(where: { $0.id == input.id }) {
                graph.nodes[i].params["title"] = .string(title)
            }
            let file = Self.runFile(run.title)
            try FlowFile.write(graph).write(to: file, atomically: true, encoding: .utf8)
            run.graph = graph
            run.file = file
            // A flow turned on to run by itself writes as it was set up to.
            let engine = Engine(mayWrite: true)
            engine.attended = false
            engine.asked = { [weak run] question in if let run { Notifications.ask(run, question) } }
            engine.settled = { question in Notifications.withdraw(question) }
            run.engine = engine
            let journal = FileJournal()
            await FileJournal.$current.withValue(journal) { await engine.run(graph) }
            run.changes = journal.changes
            if run.trigger.isFolder { remember(run.changes.map(\.url.lastPathComponent), for: run.trigger.id) }
            let delivered = graph.nodes.contains { $0.def?.category == .output && engine.state($0.id).status == .done }
            if let error = graph.ordered.lazy.compactMap({ engine.state($0.id).error }).first, !delivered {
                throw StepError(error)
            }
            if let photo = Self.firstPhoto(graph, engine) { run.thumbnail = Self.thumbnail(photo, next: file) }
            let summary = run.changes.sentence ?? Self.summary(graph, engine)
            run.set(.finished(run.note.map { "\(summary.hasSuffix(".") ? summary : summary + ".") \($0)" } ?? summary))
            ended(run)
        } catch {
            fail(run, error)
        }
    }

    private func fail(_ run: FlowRun, _ error: Error) {
        run.set(.failed(Self.plain(error)))
        ended(run)
    }

    /// Keeps a run that ended in the history and says how it went, once,
    /// however many ways it was told to end.
    private func ended(_ run: FlowRun) {
        let summary: String, failed: Bool
        switch run.phase {
        case .finished(let s): (summary, failed) = (s, false)
        case .failed(let s): (summary, failed) = (s, true)
        default: return
        }
        guard !run.kept else { return }
        run.kept = true
        if run.trigger.isFolder { release(run) }
        history.insert(RunRecord(id: run.id, title: run.title, date: Date(), summary: summary, file: run.file?.path ?? "",
                                 failed: failed, thumbnail: run.thumbnail?.path,
                                 changes: run.changes, trigger: run.trigger.id,
                                 flow: run.trigger.flow.path), at: 0)
        history = Array(history.prefix(200))
        store(history, "history.json")
        Notifications.show(run)
    }

    /// An error as a sentence someone can act on.
    private static func plain(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return text.hasSuffix(".") ? text : text + "."
    }

    // MARK: Quitting

    /// Asks before Flow quits while a run is live: a call being recorded
    /// would stop without its notes, and a flow cut off partway would leave
    /// files moved with no way to undo it. For the app delegate's
    /// `applicationShouldTerminate(_:)`.
    func shouldQuit() -> NSApplication.TerminateReply {
        let live = live
        guard let first = live.first else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = live.count == 1 ? "Quit while “\(first.title)” is running?" : "Quit while \(live.count) flows are running?"
        alert.informativeText = live.contains(where: { $0.app != nil })
            ? "The recording stops now, and the flow won't run on it."
            : "The flow stops partway, and what it already did to files can't be undone from Flow."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    // MARK: Windows

    private final class Watched {
        weak var session: FlowSession?
        init(_ session: FlowSession) { self.session = session }
    }

    @ObservationIgnored private var editors: [ObjectIdentifier: Watched] = [:]

    func watch(_ session: FlowSession) { editors[ObjectIdentifier(session)] = Watched(session) }
    /// A window closed. Edits it didn't save are gone with it, so its flow
    /// goes back to running as its file says.
    func forget(_ session: FlowSession) {
        editors[ObjectIdentifier(session)] = nil
        if let path = session.fileURL?.path, drafts.removeValue(forKey: path) != nil { reload() }
    }

    var watchedSessions: [FlowSession] { editors.values.compactMap(\.session) }

    /// Flows running in a window nobody can see: minimized, hidden, or behind others.
    var unseen: [FlowSession] {
        watchedSessions.filter { session in
            guard session.engine.running, let window = session.window else { return false }
            return !window.occlusionState.contains(.visible) || window.isMiniaturized || NSApp.isHidden
        }
    }

    /// The engine a run left, for the window that opens its file.
    func engine(for url: URL) -> Engine? {
        runs.first { $0.file?.standardizedFileURL == url.standardizedFileURL }?.engine
    }

    // MARK: Undo

    /// Puts back what a run did to files, and says how that went.
    func undo(_ run: FlowRun) {
        guard run.canUndo else { return }
        let outcome = revert(run.changes, trigger: run.trigger.id, record: run.id)
        run.undone = true
        run.set(.finished(outcome.sentence))
    }

    /// The same, for a run kept from before Flow last opened.
    func undo(_ record: RunRecord) {
        guard record.canUndo else { return }
        if let run = run(record.id) { return undo(run) }
        _ = revert(record.changes, trigger: nil, record: record.id)
    }

    private func revert(_ changes: [FileChange], trigger: UUID?, record id: UUID) -> Undo.Outcome {
        let outcome = Undo.revert(changes)
        let names = outcome.restored.map(\.lastPathComponent)
        for t in triggers where t.id == trigger || trigger == nil {
            guard case .folder(let path) = t.event,
                  outcome.restored.contains(where: { $0.deletingLastPathComponent().path == URL(filePath: path).path }) else { continue }
            remember(names, for: t.id)
        }
        if let i = history.firstIndex(where: { $0.id == id }) {
            history[i].undone = true
            store(history, "history.json")
        }
        return outcome
    }

    // MARK: Storage

    private func load<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: Self.folder.appending(path: name)) else { return nil }
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            Self.log.error("could not read \(name): \(error)")
            return nil
        }
    }

    private func store<T: Encodable>(_ value: T, _ name: String) {
        do { try JSONEncoder().encode(value).write(to: Self.folder.appending(path: name), options: .atomic) } catch {
            Self.log.error("could not write \(name): \(error)")
        }
    }
}

extension Trigger {
    var isCall: Bool {
        if case .call = event { return true }
        return false
    }

    var isFolder: Bool {
        if case .folder = event { return true }
        return false
    }
}

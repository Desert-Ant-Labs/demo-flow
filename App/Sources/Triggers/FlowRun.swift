import AppKit
import Foundation
import Observation

/// One flow set off on its own, from recording and running to its result.
/// Each run is saved as a flow of its own with what set it off filled in, so
/// opening it shows the results.
@MainActor
@Observable
final class FlowRun: Identifiable {
    enum Phase: Equatable {
        case recording(app: String)
        case running
        case finished(String)
        /// Stopped, with the reason in plain words.
        case failed(String)
    }

    let id = UUID()
    let trigger: Trigger
    let title: String
    private(set) var phase: Phase
    /// When the phase began, for the time shown next to it.
    private(set) var since = Date()
    /// What the trigger caught: new files, or the call's recording once it stops.
    var files: [URL] = []
    /// What the call left: its words, and the recording when it is kept.
    var take: Take?
    /// What was on the clipboard when a shortcut that takes it was pressed.
    var clipboard: Clipboard?
    /// The call app's process, while its call is recorded.
    var pid: pid_t?
    /// Other call flows that run on this call's recording once it stops.
    var alsoFor: [Trigger] = []
    /// What the notes are called: the calendar event of the call, or "Zoom call".
    var noteTitle: String?
    var engine: Engine?
    var graph: Graph?
    /// The saved run, which opens with its results.
    var file: URL?
    /// A small JPEG of the first photo the flow ended with.
    var thumbnail: URL?
    /// What the flow did to files, to say what changed and to undo it.
    var changes: [FileChange] = []
    var undone = false
    /// The files the flow left, which open as its result.
    var result: [URL] { changes.results }
    var canUndo: Bool { !changes.isEmpty && !undone }
    @ObservationIgnored var recorder: (any TakeRecorder)?
    /// What the recorder handed over when it ended, which holds the words
    /// even when the recording itself could not be saved.
    @ObservationIgnored var made: Take?
    /// Why the recorder could not start, for a run stopped while it started.
    @ObservationIgnored var startError: Error?
    /// What went wrong without stopping the run, said with its result.
    var note: String?
    /// Whether it is in the history yet, so it goes in once.
    @ObservationIgnored var kept = false
    /// The words of the call so far, while it records.
    var transcript: LiveTranscript?

    init(trigger: Trigger, phase: Phase) {
        self.trigger = trigger
        self.title = trigger.flow.title
        self.phase = phase
    }

    func set(_ phase: Phase) {
        guard phase != self.phase else { return }
        self.phase = phase
        since = Date()
    }

    var live: Bool {
        switch phase {
        case .recording, .running: true
        case .finished, .failed: false
        }
    }

    var isCall: Bool { trigger.isCall }

    var app: String? {
        if case .recording(let app) = phase { return app }
        return nil
    }

    /// What is being recorded, as a title: "Zoom call", or a note's own name.
    var recordingTitle: String? {
        guard let app else { return nil }
        return isCall ? "\(app) call" : app
    }

    var progress: Double { engine?.progress ?? 0 }

    /// The step running now, by name.
    var step: String? {
        guard let engine, let graph, let id = engine.busy.first, let def = graph.node(id)?.def else { return nil }
        return def.model?.info.name ?? def.title
    }

    /// What the running step is doing: a download, or which item of how many.
    var detail: String? {
        guard let engine, let graph, let id = engine.busy.first, let def = graph.node(id)?.def else { return nil }
        let doing = activity(engine.state(id), model: def.model.map { ModelHub.shared.state($0) }, name: def.model?.info.name ?? def.title)
        return doing == "Working" ? nil : doing
    }

    /// The phase as a short word, for a chip.
    var state: String {
        switch phase {
        case .recording: "Recording"
        case .running: "Running"
        case .finished: "Done"
        case .failed: "Stopped"
        }
    }
}

/// What records a run's audio: a call with system audio, or a note from the
/// microphone alone.
@MainActor
protocol TakeRecorder: AnyObject {
    var transcript: LiveTranscript? { get }
    /// How loud it is right now, 0 to 1.
    var level: Double { get }
    func stop() async throws -> Take
}

extension MeetingRecorder: TakeRecorder {
    var level: Double { max(microphoneLevel, systemLevel) }
}

extension Recorder: TakeRecorder {}

/// A finished run, kept across launches for the menu bar, the window's Runs,
/// and Undo.
struct RunRecord: Codable, Identifiable, Sendable {
    var id = UUID()
    let title: String
    let date: Date
    let summary: String
    /// The saved run, which opens with its results.
    let file: String
    let failed: Bool
    /// A small JPEG of the first photo it ended with, when it had one.
    var thumbnail: String?
    var changes: [FileChange] = []
    var undone = false
    /// The trigger that ran it.
    var trigger = UUID()
    /// The flow file it ran. A template run on dropped files has none.
    var flow: String?

    var result: [URL] { changes.results }
    var canUndo: Bool { !changes.isEmpty && !undone }
}

/// Text and files from the clipboard, for a shortcut that takes them.
struct Clipboard: Sendable {
    var text: String?
    var files: [URL]

    @MainActor static func read() -> Clipboard {
        let board = NSPasteboard.general
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return Clipboard(text: files.isEmpty ? board.string(forType: .string) : nil, files: files)
    }
}

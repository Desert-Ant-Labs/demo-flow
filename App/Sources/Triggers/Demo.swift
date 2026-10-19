import AppKit
import Foundation
import SwiftUI

/// `FLOW_DEMO_RUN=record|run|fail|undo|drop|ask` walks a made-up run through its
/// states, to see the pill, the menu, and the notifications without a real
/// call. Built into every build, since the screenshots come from a release
/// build, and does nothing unless the variable is set.
@MainActor
enum Demo {
    nonisolated static let active = ProcessInfo.processInfo.environment["FLOW_DEMO_RUN"] != nil
    /// What the microphone menu shows in a demo on a Mac with none, as the
    /// headless Mac the screenshots are taken on.
    nonisolated static let microphone = "MacBook Pro Microphone"

    static func start() {
        guard let mode = ProcessInfo.processInfo.environment["FLOW_DEMO_RUN"] else { return }
        let photos = ["two-women-taking-selfie", "woman-looking-up-blue-sky", "two-women-laughing-with-phones"]
            .map { Samples.url("/samples/people/\($0).jpg") }
        let call = Trigger(event: .call(apps: CallApps.allIDs), flow: .template(id: "smiles"))
        let folder = Trigger(event: .folder(path: photos[0].deletingLastPathComponent().path), flow: .template(id: "smiles"))
        let broken = Trigger(event: .folder(path: "/tmp"), flow: .file(path: "/tmp/Moved away.flow"))
        MenuPreview.show()
        Task {
            try? await Task.sleep(for: .seconds(1))
            switch mode {
            case "record": recording(call, then: photos)
            case "fail": running(broken, on: photos)
            case "undo": renamed(folder, photos)
            case "drop": Floater.shared.drop(photos)
            case "ask":
                // The receipts template, which asks which of the photos Eye found are receipts.
                let trip = (1...23).map { Samples.url(String(format: "/samples/photos/%03d.jpg", $0)) }
                let run = running(Trigger(event: .folder(path: trip[0].deletingLastPathComponent().path), flow: .template(id: "file-receipts")), on: trip)
                // `FLOW_DEMO_REVIEW=1` opens the question in its window once it is asked.
                if ProcessInfo.processInfo.environment["FLOW_DEMO_REVIEW"] != nil {
                    Task {
                        while run.question == nil { try? await Task.sleep(for: .milliseconds(200)) }
                        AskWindow.shared.show(run)
                    }
                }
            default: running(folder, on: photos)
            }
        }
    }

    @discardableResult
    private static func running(_ trigger: Trigger, on files: [URL]) -> FlowRun {
        let run = FlowRun(trigger: trigger, phase: .running)
        run.files = files
        TriggerCenter.shared.pretend(run)
        return run
    }

    /// Three screenshots renamed, done, with Undo.
    private static func renamed(_ trigger: Trigger, _ photos: [URL]) {
        let dir = URL.temporaryDirectory.appending(path: "Flow demo \(UUID().uuidString.prefix(4))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shots = photos.enumerated().map { i, url in
            let shot = dir.appending(path: "Screenshot 2026-10-14 at 21.0\(i).jpg")
            try? FileManager.default.copyItem(at: url, to: shot)
            return shot
        }
        let journal = FileJournal()
        FileJournal.$current.withValue(journal) {
            _ = try? FileOps.apply(shots, to: ["Selfie at the market", "Blue sky portrait", "Two friends laughing"].map { dir.appending(path: "2026-10-14 \($0).jpg") }, .move)
        }
        let run = FlowRun(trigger: trigger, phase: .running)
        run.changes = journal.changes
        if let first = run.result.first, let photo = try? Media.photo(first) {
            run.thumbnail = TriggerCenter.thumbnail(photo, next: dir.appending(path: "run.flow"))
        }
        run.set(.finished(run.changes.sentence ?? "Done"))
        TriggerCenter.shared.pretend(run)
    }

    /// Looks like a call being recorded for a while, then runs on photos in
    /// its place: you in the room and two people on the call, with two
    /// invited. `FLOW_DEMO_HUD=1` opens its words in a window too, `named`
    /// names the two, and `naming` starts naming the second.
    private static func recording(_ trigger: Trigger, then files: [URL]) {
        let run = FlowRun(trigger: trigger, phase: .recording(app: "Zoom"))
        TriggerCenter.shared.pretend(run)
        let transcript = LiveTranscript(RecordingOptions(transcribes: true, labelsSpeakers: true, guests: ["Maya Chen", "Daniel Okafor"]),
                                        sides: [.room, .call], transcribing: false)
        run.transcript = transcript
        let hud = ProcessInfo.processInfo.environment["FLOW_DEMO_HUD"]
        if hud != nil { TranscriptHUD.shared.open(run) }
        if hud == "named" {
            transcript.rename(Side.call.first, to: "Maya Chen")
            transcript.rename(Side.call.first + 1, to: "Daniel Okafor")
        }
        Task {
            let lines = [
                (0, "Thanks for joining. Let's start with pricing for the new plan, then hiring."),
                (1, "Sounds good. The team wants to keep the free tier and move exports to the paid plan."),
                (2, "I'd keep exports free for the first month, so people see what they get."),
                (0, "That works if the limits stay generous. Can you send the numbers by Friday?"),
                (1, "Yes, I'll have them by Thursday."),
            ]
            // You on the microphone; the two guests, voices 0 and 1, on the call.
            var words: [Transcript.Word] = [], sides: [Side] = [], turns: [SpeakerTurn] = [], t = 0.0
            for (speaker, line) in lines {
                let start = t
                for word in line.split(separator: " ") {
                    words.append(.init(text: String(word), start: t, end: t + 0.3))
                    sides.append(speaker == 0 ? .room : .call)
                    t += 0.35
                }
                if speaker > 0 { turns.append(SpeakerTurn(start: start, end: t, speaker: speaker - 1)) }
                t += 0.6
            }
            for n in 1...words.count {
                try? await Task.sleep(for: .milliseconds(180))
                let settled = n == words.count ? n : max(0, n - 4)
                for side in [Side.room, .call] {
                    let mine = words.indices.prefix(n).filter { sides[$0] == side }
                    transcript.show(side, mine.map { words[$0] }, settled: mine.filter { $0 < settled }.count,
                                    turns: turns.filter { side == .call && $0.start < words[n - 1].end })
                }
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["FLOW_DEMO_SECONDS"] ?? "") ?? 8))
            run.files = files
            run.transcript = nil
            TriggerCenter.shared.stop(run)
        }
    }
}

/// The menu bar panel in a plain window, for `FLOW_DEMO_RUN`, so it can be
/// looked at without clicking the menu bar.
@MainActor
enum MenuPreview {
    private static var window: NSWindow?

    static func show() {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 340, height: 400),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Menu preview"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: MenuBarView().fixedSize())
        window.setContentSize(window.contentView?.fittingSize ?? .zero)
        window.orderFrontRegardless()
        self.window = window
    }
}

import Foundation
import Testing
@testable import Flow

@Suite struct UndoTests {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func journaled(_ body: () throws -> Void) rethrows -> [FileChange] {
        let journal = FileJournal()
        try FileJournal.$current.withValue(journal) { try body() }
        return journal.changes
    }

    private let remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }

    @Test func aRenameIsUndone() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shot = dir.appending(path: "Screenshot 1.png")
        try Data([1]).write(to: shot)
        let changes = try journaled { try FileOps.apply([shot], to: [dir.appending(path: "Receipt.png")], .move) }
        #expect(changes.map(\.kind) == [.moved])
        #expect(changes.sentence == "Renamed 1 screenshot")
        #expect(changes.results.map(\.lastPathComponent) == ["Receipt.png"])
        let outcome = Undo.revert(changes, remove: remove)
        #expect(outcome.undone == 1 && outcome.kept == 0)
        #expect(FileManager.default.fileExists(atPath: shot.path))
        #expect(outcome.restored.map(\.lastPathComponent) == ["Screenshot 1.png"])
    }

    @Test func aRenameIsLeftWhenTheOldNameIsTaken() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "a.txt")
        try Data("a".utf8).write(to: a)
        let changes = try journaled { try FileOps.apply([a], to: [dir.appending(path: "b.txt")], .move) }
        try Data("new".utf8).write(to: a)
        let outcome = Undo.revert(changes, remove: remove)
        #expect(outcome.undone == 0 && outcome.kept == 1)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "b.txt").path))
    }

    @Test func aCopyIsRemovedUnlessItChanged() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "photo.jpg")
        try Data([1, 2]).write(to: a)
        let first = try journaled { try FileOps.apply([a], to: [dir.appending(path: "out/first.jpg")], .copy) }
        let second = try journaled { try FileOps.apply([a], to: [dir.appending(path: "out/second.jpg")], .copy) }
        #expect(first.sentence == "Copied 1 photo to out")
        try Data([9, 9, 9]).write(to: dir.appending(path: "out/second.jpg"))
        #expect(Undo.revert(first, remove: remove).undone == 1)
        #expect(Undo.revert(second, remove: remove).kept == 1)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "out/first.jpg").path))
        #expect(FileManager.default.fileExists(atPath: a.path))
    }

    @Test func aWrittenNoteIsRemovedButAReplacedFileIsNot() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FolderWriter.write(.text("old"), to: dir, name: "kept")
        let changes = try journaled {
            try FolderWriter.write(.text("# Weekly review\n\nWords"), to: dir, name: "2026-10-14 Weekly review")
            try FolderWriter.write(.text("new"), to: dir, name: "kept")
        }
        #expect(changes.count == 1)
        #expect(changes.sentence == "Saved 2026-10-14 Weekly review to \(dir.lastPathComponent)")
        #expect(changes.results.map(\.lastPathComponent) == ["2026-10-14 Weekly review.md"])
        #expect(Undo.revert(changes, remove: remove) == Undo.Outcome(undone: 1, kept: 0, restored: []))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "kept.txt").path))
    }

    @Test func nothingIsJournaledOutsideARun() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "a.txt")
        try Data("a".utf8).write(to: a)
        let journal = FileJournal()
        try FileOps.apply([a], to: [dir.appending(path: "b.txt")], .move)
        #expect(journal.changes.isEmpty)
    }

    @Test func aRecordingIsNamed() {
        #expect(Recording.title(["source": "meeting"], transcript: "") == "Meeting")
        #expect(Recording.title(["source": "meeting", "title": "Weekly design review"], transcript: "x") == "Weekly design review")
        #expect(Recording.title([:], transcript: "hello there, this is a test of notes") == "Hello there this is a test")
        #expect(Recording.title([:], transcript: "") == "Note")
    }

    @Test func theNoteFileTakesTheTitle() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let def = OutputSteps.folder
        let params = def.defaults.merging(["folder": .string(dir.path), "name": "{{date}} {{a}}"]) { $1 }
        _ = try await def.run(StepRun(inputs: ["value": .text("# Weekly design review\n\nWords"), "a": .text("Weekly design review: Q3/Q4")],
                                      params: params, context: RunContext(id: "t", mayWrite: true) { _, _ in }))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["\(Placeholders.now("date")) Weekly design review- Q3-Q4.md"])
    }

    @Test func theCallingEventIsPicked() {
        let now = Date()
        let event = { (title: String, from: Double, to: Double, call: Bool, allDay: Bool) in
            MeetingCalendar.Event(title: title, start: now.addingTimeInterval(from * 60), end: now.addingTimeInterval(to * 60), allDay: allDay, call: call)
        }
        let events = [
            event("Focus time", -60, 60, false, false),
            event("Weekly design review", -5, 25, true, false),
            event("Offsite", -600, 600, true, true),
            event("Lunch", 30, 60, false, false),
        ]
        #expect(MeetingCalendar.Event.pick(events, at: now)?.title == "Weekly design review")
        #expect(MeetingCalendar.Event.pick([events[0]], at: now)?.title == "Focus time")
        #expect(MeetingCalendar.Event.pick([events[2], events[3]], at: now) == nil)
        #expect(MeetingCalendar.Event.hasCallLink(["https://us02web.zoom.us/j/123", nil]))
    }

    @Test func resultsGoInsideSaveTo() {
        let defaults = UserDefaults.standard
        let before = defaults.string(forKey: SaveTo.key)
        defer { defaults.set(before, forKey: SaveTo.key) }
        defaults.set("~/Results", forKey: SaveTo.key)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(SaveTo.resolve("Meeting notes").path == home + "/Results/Meeting notes")
        #expect(SaveTo.resolve("~/Elsewhere").path == home + "/Elsewhere")
        #expect(SaveTo.resolve("/tmp/x").path == "/tmp/x")
        let g = Example.all.first { $0.id == "meeting" }!.graph
        #expect(g.node("save")?.params["folder"]?.string == "Meeting notes")
    }

}

import Foundation
import Testing
@testable import Flow

@MainActor @Suite struct TriggerTests {
    private func template(_ id: String) -> Graph { Example.all.first { $0.id == id }!.graph }

    @Test func newFilesGoIntoTheWatchStep() throws {
        var g = template("name-screenshots")
        try TriggerCenter.fill(&g, with: [URL(filePath: "/tmp/Screenshot.png")])
        #expect(g.node("in")?.params["files"]?.strings == ["/tmp/Screenshot.png"])
        #expect(InputKind.of(g.node("in")!, in: g) == [.photos])
    }

    @Test func aFlowSaysWhenItRunsInItsFirstStep() throws {
        #expect(Trigger.event(of: template("meeting")) == .call(apps: CallApps.allIDs))
        #expect(Trigger.event(of: template("quick-note")) == .shortcut(.standard, takes: "voice"))
        guard case .folder(let path) = Trigger.event(of: template("file-receipts-as-they-arrive")) else { throw StepError("no folder") }
        #expect(path.hasSuffix("/Downloads"))
        #expect(Trigger.event(of: template("smiles")) == nil)
    }

    @Test func runsRememberTheirFlow() throws {
        let record = RunRecord(title: "Notes", date: .now, summary: "Saved", file: "/tmp/run.flow", failed: false, flow: "/tmp/Notes.flow")
        let back = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(record))
        #expect(back.flow == "/tmp/Notes.flow")
    }

    @Test func shortcutsKeepTheirKeysInTheFile() throws {
        let keys = Shortcut(keyCode: 45, key: "N", command: true, option: true)
        #expect(Shortcut(json: keys.json) == keys)
    }

    @Test func aHandEditedShortcutDoesNotCrash() {
        #expect(Shortcut(json: .object(["code": -1, "key": "N"])) == nil)
        #expect(Shortcut(json: .object(["code": 1e12, "key": "N"])) == nil)
        #expect(Shortcut(json: .object(["code": .number(.infinity), "key": "N"])) == nil)
    }

    @Test func aHandEditedScheduleKeepsWhatMakesSense() {
        var g = Graph()
        g.nodes = [Node(id: "when", type: "schedule", position: .zero,
                        params: ["hour": 99, "minute": -5, "days": [0, 2, 8, 1e30]])]
        #expect(Trigger.event(of: g) == .schedule(hour: 9, minute: 0, weekdays: [2]))
        #expect(Schedule.days([0, 2, 8]) == Calendar.current.shortWeekdaySymbols[1])
    }

    @Test func aScheduleRunsOnItsDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let date = { (d: Int, h: Int, m: Int) in calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))! }
        // Thursday the 15th, after nine: Friday at nine, then Monday.
        let friday = Schedule.next(after: date(15, 10, 0), hour: 9, minute: 0, weekdays: Set(2...6), in: calendar)
        #expect(friday == date(16, 9, 0))
        #expect(Schedule.next(after: friday!, hour: 9, minute: 0, weekdays: Set(2...6), in: calendar) == date(19, 9, 0))
    }

    @Test func anHourThatRepeatsRunsOnce() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        // The clocks go back at three on the 25th, so half past two comes twice.
        let first = Schedule.next(after: calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 1))!,
                                  hour: 2, minute: 30, weekdays: [], in: calendar)!
        let next = Schedule.next(after: first, hour: 2, minute: 30, weekdays: [], in: calendar)!
        #expect(next.timeIntervalSince(first) > 24 * 3600)
    }

    @Test func runsInTheSameSecondKeepTheirOwnFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let first = TriggerCenter.runFile("Smiles", in: dir)
        try Data().write(to: first)
        let second = TriggerCenter.runFile("Smiles", in: dir)
        #expect(second != first)
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    @Test func newPhotosReplaceTheSamples() throws {
        var g = template("smiles")
        let urls = [URL(filePath: "/tmp/a.jpg"), URL(filePath: "/tmp/b.heic")]
        try TriggerCenter.fill(&g, with: urls)
        let input = TriggerCenter.input(of: g)!
        #expect(input.params["samples"]?.strings == [])
        #expect(input.params["files"]?.strings == ["/tmp/a.jpg", "/tmp/b.heic"])
    }

    @Test func aFlowWithNothingToFillSaysSo() {
        var g = Graph()
        #expect(throws: StepError.self) { try TriggerCenter.fill(&g, with: [URL(filePath: "/tmp/a.jpg")]) }
    }

    @Test func eachInputTakesItsOwnKindOfFile() {
        #expect(InputKind.photos.takes(URL(filePath: "/x/a.HEIC")))
        #expect(!InputKind.photos.takes(URL(filePath: "/x/a.m4a")))
        #expect(InputKind.audio.takes(URL(filePath: "/x/a.m4a")))
        #expect(InputKind.text.takes(URL(filePath: "/x/a.md")))
    }

    @Test func callAppsAreNamedPlainly() {
        #expect(CallApps.names(CallApps.allIDs) == "")
        #expect(CallApps.names(["us.zoom.xos", "com.microsoft.teams"]) == "Zoom or Microsoft Teams")
        #expect(CallApps.name(of: "com.google.Chrome.helper") == "Browsers")
    }

    @Test func theMicrophoneListDoesNotCrash() {
        _ = Microphone.users()
    }
}

/// Folder watching against a real folder, so these wait a few seconds for
/// files to settle.
@MainActor @Suite(.serialized) struct FolderWatcherTests {
    private final class Found {
        var names: [[String]] = []
    }

    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ name: String, in dir: URL) throws {
        try Data("x".utf8).write(to: dir.appending(path: name))
    }

    private func wait(until done: () -> Bool) async {
        for _ in 0..<40 where !done() { try? await Task.sleep(for: .milliseconds(250)) }
    }

    @Test func filesAlreadyThereDoNotCount() async throws {
        let dir = try folder()
        try write("old.txt", in: dir)
        let found = Found()
        let watcher = FolderWatcher(folder: dir, seen: nil) { found.names.append($0.map(\.lastPathComponent)) }
        watcher.start()
        defer { watcher.stop() }
        try write("new.txt", in: dir)
        await wait { !found.names.isEmpty }
        #expect(found.names == [["new.txt"]])
    }

    @Test func aNameThatComesBackCountsAgain() async throws {
        let dir = try folder()
        let found = Found()
        let watcher = FolderWatcher(folder: dir, seen: nil) { found.names.append($0.map(\.lastPathComponent)) }
        watcher.start()
        defer { watcher.stop() }
        try write("scan.pdf", in: dir)
        await wait { found.names.count == 1 }
        try FileManager.default.removeItem(at: dir.appending(path: "scan.pdf"))
        try await Task.sleep(for: .seconds(3))
        try write("scan.pdf", in: dir)
        await wait { found.names.count == 2 }
        #expect(found.names == [["scan.pdf"], ["scan.pdf"]])
    }

    @Test func aFolderThatComesBackIsWatchedAgain() async throws {
        let dir = try folder()
        try FileManager.default.removeItem(at: dir)
        let found = Found()
        let watcher = FolderWatcher(folder: dir, seen: []) { found.names.append($0.map(\.lastPathComponent)) }
        watcher.start()
        defer { watcher.stop() }
        #expect(watcher.missing)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write("there.txt", in: dir)
        await wait { !watcher.missing }
        #expect(!watcher.missing)
        try write("new.txt", in: dir)
        await wait { !found.names.isEmpty }
        #expect(found.names == [["new.txt"]])
    }
}

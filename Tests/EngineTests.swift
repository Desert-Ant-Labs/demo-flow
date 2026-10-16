import Foundation
import Testing
@testable import Flow

private func folder() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct LoadingTests {
    @Test func twoStepsWithOneIDAreRefused() {
        let yaml = """
        flow: 1
        steps:
          - id: a
            type: text
          - id: a
            type: text
        """
        #expect(throws: FlowFile.SameID.self) { try FlowFile.read(yaml) }
    }

    @Test func aLoopInAFileIsBrokenOnLoad() throws {
        let yaml = """
        flow: 1
        steps:
          - id: a
            type: template
            uses:
              a: b.text
          - id: b
            type: template
            uses:
              a: a.text
        """
        let graph = try FlowFile.read(yaml)
        #expect(graph.edges.count == 1)
        #expect(!graph.hasCycle)
    }

    @MainActor @Test func theEngineDoesNotWaitOnALoop() async {
        var graph = Graph()
        graph.nodes = ["a", "b"].map { Node(id: $0, type: "template", position: .zero, params: ["template": "x"]) }
        graph.edges = [Edge(source: "a", sourceHandle: "text", target: "b", targetHandle: "a"),
                       Edge(source: "b", sourceHandle: "text", target: "a", targetHandle: "a")]
        #expect(graph.hasCycle)
        let engine = Engine()
        await engine.run(graph)
        #expect(engine.state("a").status == .error)
    }

    @MainActor @Test func theEngineRunsWithADuplicateID() async {
        var graph = Graph()
        graph.nodes = [Node(id: "a", type: "text", position: .zero, params: ["text": "hi"]),
                       Node(id: "a", type: "text", position: .zero, params: ["text": "hi"])]
        let engine = Engine()
        await engine.run(graph)
        _ = FlowLayout.tidy(graph, sizes: [:])
        #expect(engine.state("a").status == .done)
    }
}

@Suite struct FileStepTests {
    @Test func datesAreInThisMacsTimeZone() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "a.txt")
        try Data("a".utf8).write(to: url)
        let made = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.creationDate: made, .modificationDate: made], ofItemAtPath: url.path)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: made)
        let day = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        let time = String(format: "%02d.%02d.%02d", c.hour!, c.minute!, c.second!)
        #expect(FileOps.names(for: [url], pattern: "{{date}} {{time}}") == ["\(day) \(time).txt"])
    }

    @Test func copyingAgainMakesNoSecondCopy() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "a.txt"), b = dir.appending(path: "b.txt")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        let target = dir.appending(path: "out/same.txt")
        #expect(try FileOps.apply([a], to: [target], .copy)[0].lastPathComponent == "same.txt")
        #expect(try FileOps.apply([a], to: [target], .copy)[0].lastPathComponent == "same.txt")
        #expect(try FileOps.apply([b], to: [target], .copy)[0].lastPathComponent == "same-2.txt")
        #expect(try FileOps.apply([b], to: [target], .copy)[0].lastPathComponent == "same-2.txt")
        #expect(FileOps.contents(of: target.deletingLastPathComponent()).count == 2)
    }

    @Test func renamingOnlyTheCaseWorks() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let from = dir.appending(path: "photo.jpg")
        try Data("a".utf8).write(to: from)
        let done = try FileOps.apply([from], to: [dir.appending(path: "Photo.jpg")], .move)
        #expect(done[0].lastPathComponent == "Photo.jpg")
        #expect(FileOps.contents(of: dir).map(\.lastPathComponent) == ["Photo.jpg"])
    }

    @Test func anEmptySubfolderPatternMakesNoSubfolder() {
        let url = URL(filePath: "/tmp/x/IMG_1.jpg")
        let plan = FileSteps.copyPlan(["files": .list([.file(url)]), "a": .list([nil])],
                                      ["folder": "/tmp/out", "subfolder": "{{a}}"])
        #expect(plan.targets == [URL(filePath: "/tmp/out/IMG_1.jpg")])
    }
}

@Suite struct ConvertNameTests {
    @Test func twoTablesGetTwoFiles() throws {
        let one = Value.list([.record([("name", .text("Ana"))])])
        let two = Value.list([.record([("name", .text("Bo"))])])
        let a = try #require(ConvertStep.convert(one, to: .csv).fileURL)
        let b = try #require(ConvertStep.convert(two, to: .csv).fileURL)
        let again = try #require(ConvertStep.convert(one, to: .csv).fileURL)
        #expect(a != b)
        #expect(a == again)
    }

    @Test func csvQuotesWhatNeedsIt() {
        let rows: [Value] = [.record([("a", .text("x\ty")), ("b", .number(0.25))])]
        #expect(CSV.text(rows) == "a,b\nx\ty,0.25")
        #expect(CSV.text(rows, separator: "\t") == "a\tb\nx y\t0.25")
    }
}

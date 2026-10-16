import Foundation
import Testing
@testable import Flow

@Suite struct SamplePickerTests {
    @Test func featuredSamplesAreAFewThatExist() {
        #expect(Samples.featured.count == 12)
        #expect(Set(Samples.featured).count == Samples.featured.count)
        #expect(Samples.featured.allSatisfy { FileManager.default.fileExists(atPath: Samples.url($0).path) })
        // A new Photos step starts with the portraits, which the grid has to show.
        #expect(Set(Samples.portraits).isSubset(of: Samples.featured))
    }

    @Test func aFlowsPicksAreToppedUpWithTheirKind() {
        #expect(Samples.grid(around: []) == Samples.featured)
        let faces = Samples.people.prefix(8).map { $0 }
        let grid = Samples.grid(around: faces)
        #expect(grid.count == 12)
        #expect(Array(grid.prefix(8)) == faces)
        #expect(grid.allSatisfy { $0.hasPrefix("/samples/people/") })
        let many = Samples.people.prefix(14).map { $0 }
        #expect(Samples.grid(around: many).count == 18)
    }
}

@Suite struct DuplicateTests {
    @Test func aSecondCopyGetsANumber() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Exports.free("Notes copy.flow", in: dir).lastPathComponent == "Notes copy.flow")
        try Data().write(to: dir.appending(path: "Notes copy.flow"))
        #expect(Exports.free("Notes copy.flow", in: dir).lastPathComponent == "Notes copy 2.flow")
    }
}

@MainActor
@Suite struct MeetingPermissionTests {
    @Test func onlyFlowsThatRecordMeetingsAsk() {
        var graph = Graph()
        graph.nodes = [Node(id: "a", type: "record", position: .zero, params: ["source": .string("microphone")])]
        #expect(!MeetingPermissions.needed(by: graph))
        graph.nodes = [Node(id: "a", type: "record", position: .zero, params: ["source": .string("meeting")])]
        #expect(MeetingPermissions.needed(by: graph))
        graph.nodes = [Node(id: "a", type: "call", position: .zero, params: [:])]
        #expect(MeetingPermissions.needed(by: graph))
    }
}

@Suite struct AcknowledgementsTests {
    @Test func theAppCarriesEveryLicense() throws {
        let resources = try #require(Bundle.main.resourceURL)
        #expect(FileManager.default.fileExists(atPath: resources.appending(path: "THIRD_PARTY_NOTICES.md").path))
        let licenses = try FileManager.default.contentsOfDirectory(atPath: resources.appending(path: "LICENSES").path)
        for name in ["Sparkle.txt", "Yams.txt", "swift-numerics.txt", "webrtc-audio-processing.txt", "webrtc-PATENTS.txt", "abseil-cpp.txt", "desert-ant-core.md"] {
            #expect(licenses.contains(name), "\(name) is missing")
        }
    }
}

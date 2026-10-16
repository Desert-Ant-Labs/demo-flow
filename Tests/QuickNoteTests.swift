import Carbon.HIToolbox
import Foundation
import Testing
@testable import Flow

@Suite struct ShortcutTests {
    @Test func showsModifiersInApplesOrder() {
        let s = Shortcut(keyCode: UInt32(kVK_ANSI_N), key: "N", command: true, option: true, control: true, shift: true)
        #expect(s.display == "⌃⌥⇧⌘N")
        #expect(Shortcut.standard.display == "⌥⌘N")
    }

    @Test func carbonModifiersMatchTheKeys() {
        #expect(Shortcut.standard.carbonModifiers == UInt32(cmdKey | optionKey))
    }

    @Test func keepsItsShapeOnDisk() throws {
        let back = try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(Shortcut.standard))
        #expect(back == .standard)
    }
}

@MainActor @Suite struct QuickNoteTemplateTests {
    @Test func recordsWordsNotAudioAndSavesANote() throws {
        let g = Example.all.first { $0.id == "quick-note" }!.graph
        let input = try #require(TriggerCenter.input(of: g))
        #expect(input.type == "shortcut")
        #expect(Shortcut(json: input.params["keys"]) == .standard)
        #expect(!Recording.isMeeting(input.params))
        #expect(Recording.transcribes(input.params))
        #expect(!Recording.keeps(input.params))
        #expect(g.nodes.contains { $0.type == "folder" })
    }

    @Test func filesAreDescribedPlainly() {
        let photos = [URL(filePath: "/x/a.jpg"), URL(filePath: "/x/b.heic")]
        #expect(FlowPickerView.describe(photos) == "2 photos")
        #expect(FlowPickerView.describe([URL(filePath: "/x/a.m4a")]) == "a recording")
        #expect(FlowPickerView.describe(photos + [URL(filePath: "/x/c.m4a")]) == "3 files")
    }
}

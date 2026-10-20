import AVFoundation
import Foundation
import Testing
import Transcript
@testable import Flow

private func words(_ text: String, every seconds: Double = 0.3) -> [TimedWord] {
    text.split(separator: " ").enumerated().map { i, w in
        TimedWord(text: (i == 0 ? "" : " ") + w, start: Double(i) * seconds, end: Double(i) * seconds + seconds * 0.9)
    }
}

@Suite struct CaptionTests {
    @Test func aLongSentenceBreaksIntoTwoBalancedLines() {
        let spoken = words("We built the whole feature on device, so nothing ever leaves the phone at all.")
        let cues = Captions.cues(from: spoken, sentences: Sentence.sentences(from: spoken))
        #expect(cues.count == 1)
        let lines = cues[0].text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.count <= Captions.lineLength })
        #expect(lines[0].hasSuffix(","))
    }

    @Test func captionsAreWrittenAsSRTAndWebVTT() {
        let cues = [Caption(start: 1, end: 2.5, text: "Hello"), Caption(start: 3661.2, end: 3662, text: "Again")]
        #expect(CaptionFile.srt(cues) == "1\n00:00:01,000 --> 00:00:02,500\nHello\n\n2\n01:01:01,200 --> 01:01:02,000\nAgain\n")
        #expect(CaptionFile.vtt(cues).hasPrefix("WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nHello\n"))
    }

    @Test func turnsNameTheVoiceWhenItChanges() async throws {
        let spoken = words("Hi there. Good to see you.")
        let record = { (w: TimedWord) in Value.record([("text", .text(w.text)), ("start", .number(w.start)), ("end", .number(w.end))]) }
        let turns: Value = .list([.record([("speaker", .text("Anna")), ("start", .number(0)), ("end", .number(0.55))]),
                                  .record([("speaker", .text("Ben")), ("start", .number(0.55)), ("end", .number(2))])])
        let out = try await CaptionsStep.def.run(StepRun(inputs: ["words": .list(spoken.map(record)), "turns": turns], params: [:],
                                                         context: RunContext(id: "t") { _, _ in }))
        #expect(out["srt"].asText.contains("Anna: Hi there."))
        #expect(out["srt"].asText.contains("Ben: Good to see you."))
        #expect(out["vtt"].asText.contains("<v Ben>Good to see you."))
    }

    @Test func aVoiceChangeNeverOverlapsTheCaptions() {
        let lines = [SpokenLine(start: 10, end: 10.4, speaker: 0, text: "Yes."), SpokenLine(start: 10.6, end: 12, speaker: 1, text: "Then we start.")]
        let cues = Captions.cues(from: lines, words: [])
        #expect(cues[0].cue.end <= cues[1].cue.start)
    }

    @Test func aTallFrameShowsAFewWordsAtATime() {
        let frame = CaptionFrame(CGSize(width: 1080, height: 1920), style: CaptionStyle())
        let cues = ClipCaptions.social(words("one two three four five six seven eight nine"), pacing: frame.pacing)
        #expect(frame.pacing.lines == 1)
        #expect(cues.allSatisfy { $0.text.split(separator: " ").count <= 5 && !$0.text.contains("\n") })
        #expect(zip(cues, cues.dropFirst()).allSatisfy { $0.end <= $1.start })
    }

    @Test func wordsMoveOntoTheClipsOwnTimeline() {
        let spoken = words("a b c d e f", every: 1)
        let shifted = ClipCaptions.shift(spoken, into: [TimeRange(start: 1, end: 2), TimeRange(start: 4, end: 5)])
        #expect(shifted.map { $0.text.trimmingCharacters(in: .whitespaces) } == ["b", "e"])
        #expect(shifted.map(\.start) == [0, 1])
    }

    @Test func styleSettingsAreCheckedAsTheCLIChecksThem() throws {
        let style = try CaptionStyle(["style": "box", "position": "top", "color": "#ffcc00", "weight": "semibold", "lines": 1])
        #expect(style.look == .box && style.position == .top && style.weight == 600 && style.lines == 1)
        #expect(style.color.components?.prefix(3).map { ($0 * 255).rounded() } == [255, 204, 0])
        #expect(throws: StepError.self) { try CaptionStyle(["style": "glow"]) }
        #expect(throws: StepError.self) { try CaptionStyle(["size": 0.5]) }
    }

    @Test(arguments: [CaptionStyle.Quality.high, .medium])
    func captionsAreBurnedIntoThePicture(quality: CaptionStyle.Quality) async throws {
        let source = try await grayVideo(CGSize(width: 360, height: 640), seconds: 2)
        let clip = source.deletingLastPathComponent().appending(path: "clip-\(quality.rawValue).mp4")
        var style = CaptionStyle()
        style.quality = quality
        try await Burner.cut(source, ranges: [TimeRange(start: 0, end: 2)], words: words("Hello there."), style: style, to: clip)
        let info = try await Cutter.info(clip)
        #expect(info.hasVideo && info.size == CGSize(width: 360, height: 640))
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip))
        let (image, _) = try await generator.image(at: CMTime(seconds: 0.4, preferredTimescale: 600))
        #expect(brightPixels(image, rows: 360..<640) > 50)
        #expect(brightPixels(image, rows: 0..<300) == 0)
    }
}

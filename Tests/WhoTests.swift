import Foundation
import Testing
@testable import Flow

private let modelTests = Testing.ConditionTrait.enabled(
    if: ProcessInfo.processInfo.environment["FLOW_MODEL_TESTS"] == "1",
    "Set FLOW_MODEL_TESTS=1 to run the real models")

private func word(_ text: String, _ start: Double, _ end: Double) -> Transcript.Word {
    Transcript.Word(text: text, start: start, end: end)
}

@Suite struct SpeakerTests {
    private let turns = [SpeakerTurn(start: 0, end: 2, speaker: 0), SpeakerTurn(start: 2, end: 4, speaker: 1)]

    @Test func eachWordGoesToTheVoiceItOverlapsMost() {
        let words = [word("Hi", 0.1, 0.4), word("there", 1.8, 2.6), word("yes", 4.5, 4.8)]
        #expect(Speakers.assign(words, turns) == [0, 1, 1])
    }

    @Test func theTranscriptBreaksWhereTheVoiceChanges() {
        let words = [word("Hi", 0.1, 0.4), word("all", 0.5, 0.9), word("Hello", 2.2, 2.6)]
        #expect(Speakers.label(words, turns) == "Speaker 1: Hi all\n\nSpeaker 2: Hello")
    }

    @MainActor @Test func theLiveWordsBreakByVoiceWithTheUnsettledOnesApart() {
        let live = LiveTranscript(RecordingOptions(transcribes: true, labelsSpeakers: true), transcribing: false)
        live.show(.room, [word("Hi", 0.1, 0.4), word("all", 0.5, 0.9), word("Hello", 2.2, 2.6), word("there", 2.7, 3)], settled: 3, turns: turns)
        #expect(live.paragraphs.map(\.speaker) == [0, 1])
        #expect(live.paragraphs[1].settled == ["Hello"])
        #expect(live.paragraphs[1].tentative == ["there"])
        #expect(live.committed == "Hi all Hello")
    }

    @Test func linesAreSentencesWithTheVoiceThatSaidThem() {
        let words = [word("Hi", 0.1, 0.4), word("all.", 0.5, 0.9), word("Welcome", 1.0, 1.5), word("back.", 1.5, 1.9),
                     word("Thanks.", 2.2, 2.6)]
        let lines = Speakers.lines(words, turns)
        #expect(lines.map(\.text) == ["Hi all.", "Welcome back.", "Thanks."])
        #expect(lines.map(\.speaker) == [0, 0, 1])
        #expect(Speakers.paragraphs(lines).map { $0.lines.count } == [2, 1])
    }

    @Test func aWordOrTwoBetweenOneVoiceIsJitter() {
        let turns = [SpeakerTurn(start: 0, end: 1, speaker: 0), SpeakerTurn(start: 1, end: 1.3, speaker: 1), SpeakerTurn(start: 1.3, end: 3, speaker: 0)]
        let words = [word("So", 0.2, 0.5), word("the", 0.6, 0.9), word("plan", 1.0, 1.25), word("is", 1.4, 1.6), word("set.", 1.7, 2.0)]
        #expect(Speakers.lines(words, turns).map(\.speaker) == [0])
    }

    @Test func listedNamesGoToTheVoicesInOrder() {
        #expect(Speakers.names(listed: "Anna, Ben,") == [0: "Anna", 1: "Ben"])
        let joined = Speakers.join([SpeakerTurn(start: 0, end: 1, speaker: 0), SpeakerTurn(start: 1.5, end: 2, speaker: 0), SpeakerTurn(start: 4, end: 5, speaker: 0)])
        #expect(joined == [SpeakerTurn(start: 0, end: 2, speaker: 0), SpeakerTurn(start: 4, end: 5, speaker: 0)])
    }

    @Test func theOnlyVoiceInTheRoomIsYou() {
        let names = Speakers.names([0, 1, 2], local: [1], guests: [], given: [:])
        #expect(names == [0: "Speaker 1", 1: "You", 2: "Speaker 2"])
    }

    @Test func voicesInTheRoomAreNumberedWhenThereAreSeveral() {
        let names = Speakers.names([0, 1, 2], local: [0, 1], guests: [], given: [:])
        #expect(names == [0: "Speaker 1", 1: "Speaker 2", 2: "Speaker 3"])
    }

    @Test func theOnlyVoiceOnTheCallIsTheOnlyGuest() {
        #expect(Speakers.names([0, 1], local: [0], guests: ["Maya Chen"], given: [:]) == [0: "You", 1: "Maya Chen"])
        #expect(Speakers.names([0, 1, 2], local: [0], guests: ["Maya Chen"], given: [:])[1] == "Speaker 1")
    }

    @Test func aGivenNameWinsAndKeepsTheOthersNumbers() {
        let names = Speakers.names([0, 1, 2], local: nil, guests: [], given: [1: "Daniel"])
        #expect(names == [0: "Speaker 1", 1: "Daniel", 2: "Speaker 3"])
        #expect(Speakers.label([word("Hi", 0.1, 0.4), word("Hello", 2.2, 2.6)], turns, names: names) == "Speaker 1: Hi\n\nDaniel: Hello")
    }

    @Test func namesStayWithTheRecording() {
        var transcript = Transcript(text: "Hi Hello", words: [word("Hi", 0.1, 0.4), word("Hello", 2.2, 2.6)])
        transcript.turns = turns
        transcript.names = [0: "You", 1: "Maya Chen"]
        let params = Recording.params(Take(transcript: transcript))
        #expect(Recording.names(params["names"]) == [0: "You", 1: "Maya Chen"])
    }

    @Test func aNewPassKeepsEachVoicesNumber() {
        let swapped = [SpeakerTurn(start: 0, end: 2, speaker: 1), SpeakerTurn(start: 2, end: 4, speaker: 0), SpeakerTurn(start: 4, end: 6, speaker: 2)]
        let steady = Speakers.steady(swapped, after: turns)
        #expect(steady.map(\.speaker) == [0, 1, 2])
    }

    @Test func turnsSurviveTheRecordStepsSettings() async throws {
        var transcript = Transcript(text: "Hi Hello", words: [word("Hi", 0.1, 0.4), word("Hello", 2.2, 2.6)])
        transcript.turns = turns
        var params = Recording.params(Take(audio: nil, transcript: transcript))
        params["source"] = "meeting"
        let out = try await Recording.outputs(params)
        #expect(out["labeled"]?.asText == "Speaker 1: Hi\n\nSpeaker 2: Hello")
        #expect(InputSteps.record.models(params) == [.voz, .who])
    }

    @Test func callsTellVoicesApartAndNotesDoNot() {
        #expect(Recording.labelsSpeakers(TriggerSteps.call.defaults))
        #expect(!Recording.labelsSpeakers(TriggerSteps.shortcut.defaults))
    }
}

@Suite(modelTests) struct WhoModelTests {
    @Test func anInterviewHasTwoVoices() async throws {
        try await ModelHub.shared.prepare(.who)
        let clip = try await Media.audio(Samples.url("/samples/clear/interview.wav"))
        let turns = try await ModelHub.who.diarize(clip.samples, sampleRate: clip.sampleRate)
        #expect(Set(turns.map(\.speaker)).count == 2)
    }
}

@Suite struct SideTests {
    private let you = [word("Can", 0.0, 0.2), word("you", 0.3, 0.5), word("hear", 0.6, 0.8), word("me?", 0.9, 1.1)]
    private let them = [word("Yes,", 1.5, 1.7), word("loud", 1.8, 2.0), word("and", 2.1, 2.2), word("clear.", 2.3, 2.6)]

    @Test func eachSideKeepsItsOwnVoicesInTheOrderTheySpoke() {
        let said = Heard.merge([.room: Heard(words: you, settled: 4), .call: Heard(words: them, settled: 2)], voices: true)
        #expect(said.map(\.word.text) == ["Can", "you", "hear", "me?", "Yes,", "loud", "and", "clear."])
        #expect(said.map(\.word.speaker) == [0, 0, 0, 0, 100, 100, 100, 100])
        #expect(said.map(\.settled) == [true, true, true, true, true, true, false, false])
    }

    @Test func whoSplitsTheCallButNotTheRoom() {
        let turns = [SpeakerTurn(start: 1.4, end: 2.05, speaker: 0), SpeakerTurn(start: 2.05, end: 2.7, speaker: 1)]
        let said = Heard.merge([.room: Heard(words: you), .call: Heard(words: them, turns: turns)], voices: true)
        #expect(said.compactMap(\.word.speaker).suffix(4) == [100, 100, 101, 101])
        let names = Speakers.names(Set(said.compactMap(\.word.speaker)).sorted(), local: [0], guests: [], given: [:])
        #expect(names == [0: "You", 100: "Speaker 1", 101: "Speaker 2"])
    }

    @Test func theCallsEchoInTheRoomIsDropped() {
        // What AEC3 left of the call, made out by Voz on the microphone a moment later.
        let echo = [word("loud", 1.86, 2.0), word("and", 2.15, 2.25)]
        let said = Heard.merge([.room: Heard(words: you + echo), .call: Heard(words: them)], voices: true)
        #expect(said.filter { $0.word.speaker == 0 }.map(\.word.text) == ["Can", "you", "hear", "me?"])
        // The same words said back later are not echo.
        let later = [word("Loud", 4.0, 4.2), word("and", 4.3, 4.4), word("clear.", 4.5, 4.8)]
        #expect(Heard.merge([.room: Heard(words: later), .call: Heard(words: them)], voices: true).count == 7)
    }

    @Test func voicesFromWhereTheyWereHeardAreSavedWithTheWords() {
        let said = Heard.merge([.room: Heard(words: you), .call: Heard(words: them)], voices: true)
        var transcript = Transcript(text: "", words: said.map(\.word))
        transcript.names = [0: "You", 100: "Maya Chen"]
        let back = Recording.words(Recording.params(Take(transcript: transcript))["words"])
        #expect(back.map(\.speaker) == said.map(\.word.speaker))
        #expect(transcript.labeled == "You: Can you hear me?\n\nMaya Chen: Yes, loud and clear.")
    }
}

@Suite struct AssignTests {
    /// What `Speakers.assign` finds, the long way: every turn for every word.
    private func everyTurn(_ word: Transcript.Word, _ turns: [SpeakerTurn]) -> Int {
        func overlap(_ t: SpeakerTurn) -> Double { max(0, min(word.end, t.end) - max(word.start, t.start)) }
        let best = turns.max { overlap($0) < overlap($1) }!
        if overlap(best) > 0 { return best.speaker }
        let middle = (word.start + word.end) / 2
        func distance(_ t: SpeakerTurn) -> Double { middle < t.start ? t.start - middle : middle > t.end ? middle - t.end : 0 }
        return turns.min { distance($0) < distance($1) }!.speaker
    }

    @Test func searchingByTimeFindsWhatEveryTurnWould() {
        var random = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            var turns: [SpeakerTurn] = [], at = 0.0
            for _ in 0..<40 {
                at += Double.random(in: 0...3, using: &random)
                turns.append(SpeakerTurn(start: at, end: at + Double.random(in: 0.2...8, using: &random), speaker: Int.random(in: 0..<4, using: &random)))
            }
            let words = (0..<200).map { _ in
                let start = Double.random(in: -5...(at + 15), using: &random)
                return Transcript.Word(text: "a", start: start, end: start + Double.random(in: 0.05...0.6, using: &random))
            }
            #expect(Speakers.assign(words, turns) == words.map { everyTurn($0, turns) })
        }
    }
}

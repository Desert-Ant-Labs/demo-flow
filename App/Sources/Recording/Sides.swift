import Foundation

/// Where a recording's audio was heard: in the room, on the microphone, or
/// on the call, as the Mac plays it. On a call the two are kept apart from
/// capture to transcript, so whether a voice is you or a guest comes from
/// where it was heard, never from a guess about the mixed audio.
///
/// A voice's number says its side: the room's voices count from 0, the
/// call's from `Side.call.first`.
enum Side: Int, CaseIterable, Sendable {
    case room, call

    /// The number of this side's first voice.
    var first: Int { rawValue * 100 }

    static func of(_ voice: Int) -> Side { voice >= Side.call.first ? .call : .room }
}

/// What one side has heard so far: Voz's words, the first `settled` of
/// them settled, and Who's turns over that side's audio alone.
struct Heard: Sendable {
    var words: [Transcript.Word] = []
    var settled = 0
    var turns: [SpeakerTurn] = []

    /// A word with whether Voz has settled it.
    struct Said: Sendable {
        let word: Transcript.Word
        let settled: Bool
    }

    /// Every side's words in the order they were said. With `voices`, each
    /// word gets its voice: Who's turns on its own side, numbered for that
    /// side, or the side's first voice before Who has listened.
    ///
    /// Words the room heard at the moment the call said them are dropped:
    /// the call's echo off the speakers, what is left of it once AEC3 has
    /// taken out the rest, that Voz still made out.
    static func merge(_ sides: [Side: Heard], voices: Bool) -> [Said] {
        var echo = Echo(sides[.call]?.words ?? [])
        var said: [Said] = []
        for side in Side.allCases {
            guard let heard = sides[side] else { continue }
            let speakers = voices ? Speakers.assign(heard.words, heard.turns) : []
            for (i, word) in heard.words.enumerated() {
                if side == .room, echo.of(word) { continue }
                var word = word
                if voices { word.speaker = speakers[i] + side.first }
                said.append(Said(word: word, settled: i < heard.settled))
            }
        }
        return said.sorted { $0.word.start < $1.word.start }
    }

    /// Who's turns from every side, numbered for their side.
    static func turns(_ sides: [Side: Heard]) -> [SpeakerTurn] {
        sides.flatMap { side, heard in
            heard.turns.map { SpeakerTurn(start: $0.start, end: $0.end, speaker: $0.speaker + side.first) }
        }.sorted { $0.start < $1.start }
    }

    /// Echo reaches the microphone within a few hundredths of a second of
    /// playing; this allows for Voz placing the two copies a little apart.
    static let echoWindow = -0.25...0.6

    /// The call's words by when they were said, to tell which of the room's
    /// are their echo. Merging runs on every word Voz writes, so a room word
    /// looks only at the call's words near it, found by time, and a word's
    /// text is made comparable only when there is something to compare it with.
    private struct Echo {
        private let call: [Transcript.Word]
        private var texts: [Int: String] = [:]

        init(_ call: [Transcript.Word]) {
            self.call = call.sorted { $0.start < $1.start }
        }

        /// Whether the call said the same word as the room just as the room heard it.
        mutating func of(_ word: Transcript.Word) -> Bool {
            var i = call.first(atLeast: word.start - Heard.echoWindow.upperBound, \.start)
            guard i < call.count, call[i].start <= word.start - Heard.echoWindow.lowerBound else { return false }
            let text = Heard.normalized(word.text)
            guard !text.isEmpty else { return false }
            while i < call.count, call[i].start <= word.start - Heard.echoWindow.lowerBound {
                if text == texts[i] ?? normalize(i) { return true }
                i += 1
            }
            return false
        }

        private mutating func normalize(_ i: Int) -> String {
            let text = Heard.normalized(call[i].text)
            texts[i] = text
            return text
        }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }
}

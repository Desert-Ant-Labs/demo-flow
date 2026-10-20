import Foundation
import Transcript

/// Captions from words with times: SRT and WebVTT, with each voice named
/// when turns from Who come in too.
enum CaptionsStep {
    static let def = StepDef(
        type: "captions", title: "Captions", description: "SRT and WebVTT captions from words with timings",
        category: .logic,
        inputs: [Port(id: "words", type: .any, label: "Words with timings", list: true),
                 Port(id: "turns", type: .any, label: "Turns", list: true, optional: true)],
        outputs: [Port(id: "srt", type: .text, label: "SRT"), Port(id: "vtt", type: .text, label: "WebVTT")],
        noMap: true
    ) { run in
        let words = timedWords(run.inputs["words"])
        guard !words.isEmpty else { throw StepError("Captions need words with timings, as Voz gives them") }
        var names: [String] = []
        let turns = (run.inputs["turns"]?.present ?? []).compactMap { t -> SpeakerTurn? in
            guard let start = t["start"]?.asNumber, let end = t["end"]?.asNumber else { return nil }
            let name = t["speaker"].asText
            if !names.contains(name) { names.append(name) }
            return SpeakerTurn(start: start, end: end, speaker: names.firstIndex(of: name)!)
        }
        guard !turns.isEmpty else {
            let cues = Captions.cues(from: words.timed, sentences: Sentence.sentences(from: words.timed))
            return ["srt": .text(CaptionFile.srt(cues)), "vtt": .text(CaptionFile.vtt(cues))]
        }
        let cues = Captions.cues(from: Speakers.lines(words, turns), words: words.timed)
        let byNumber = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.offset, $0.element) })
        return ["srt": .text(CaptionFile.srt(cues, names: byNumber)), "vtt": .text(CaptionFile.vtt(cues, names: byNumber))]
    }
}

/// One caption on screen.
struct Caption: Sendable, Equatable {
    let start: Double
    let end: Double
    let text: String
}

/// Captions cut the way broadcasters cut them: at most two lines of 42
/// characters, on screen for 1-7s, broken at the end of a sentence first, then
/// at a comma, then at the widest pause between words.
enum Captions {
    static let lineLength = 42
    static let maxDuration = 7.0
    static let minDuration = 1.0
    static let closeGap = 0.3

    static func cues(from words: [TimedWord], sentences: [Sentence]) -> [Caption] {
        var cues: [Caption] = []
        for sentence in sentences {
            let inside = words.filter { $0.start >= sentence.start - 0.001 && $0.end <= sentence.end + 0.001 }
            guard !inside.isEmpty else {
                cues.append(Caption(start: sentence.start, end: sentence.end, text: sentence.text))
                continue
            }
            for chunk in split(inside) {
                cues.append(Caption(start: chunk.first!.start, end: chunk.last!.end, text: layout(chunk)))
            }
        }
        return settle(cues)
    }

    /// Captions that never straddle two voices, each named when it changes.
    static func cues(from lines: [SpokenLine], words: [TimedWord]) -> [(cue: Caption, speaker: Int)] {
        let cues = Speakers.paragraphs(lines).flatMap { paragraph in
            let lines = paragraph.lines
            let sentences = lines.enumerated().map { Sentence(id: $0.offset, text: $0.element.text, start: $0.element.start, end: $0.element.end) }
            let start = lines.first!.start, end = lines.last!.end
            let inside = words.filter { $0.start >= start - 0.001 && $0.end <= end + 0.001 }
            let cues = inside.isEmpty ? sentences.map { Caption(start: $0.start, end: $0.end, text: $0.text) } : Self.cues(from: inside, sentences: sentences)
            return cues.map { (cue: $0, speaker: paragraph.speaker) }
        }
        return cues.indices.map { i in
            guard i + 1 < cues.count, cues[i].cue.end > cues[i + 1].cue.start else { return cues[i] }
            let cue = cues[i].cue
            return (Caption(start: cue.start, end: max(cues[i + 1].cue.start, cue.start + 0.01), text: cue.text), cues[i].speaker)
        }
    }

    /// Words as a caption: one line, or two balanced ones.
    static func layout(_ words: [TimedWord], lineLength: Int = lineLength) -> String {
        let text = join(words)
        guard text.count > lineLength else { return text }
        let parts = words.map { $0.text.trimmingCharacters(in: .whitespaces) }
        var best = 0, bestScore = Int.max
        for i in 1..<parts.count {
            let a = parts[..<i].joined(separator: " "), b = parts[i...].joined(separator: " ")
            guard a.count <= lineLength, b.count <= lineLength else { continue }
            let score = abs(a.count - b.count) - (parts[i - 1].last.map { ",;:".contains($0) } == true ? 8 : 0)
            if score < bestScore { (best, bestScore) = (i, score) }
        }
        guard best > 0 else { return text }
        return parts[..<best].joined(separator: " ") + "\n" + parts[best...].joined(separator: " ")
    }

    static func join(_ words: [TimedWord]) -> String {
        words.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    private static func split(_ words: [TimedWord]) -> [[TimedWord]] {
        guard !fits(words), words.count > 1 else { return [words] }
        var best = words.count / 2, bestScore = -Double.infinity
        for i in 1..<words.count {
            let gap = words[i].start - words[i - 1].end
            let comma = words[i - 1].text.trimmingCharacters(in: .whitespaces).last.map { ",;:".contains($0) } == true ? 1.0 : 0
            let balance = 1 - abs(Double(i) / Double(words.count) - 0.5)
            let score = gap * 2 + comma + balance * 0.5
            if score > bestScore { (best, bestScore) = (i, score) }
        }
        return split(Array(words[..<best])) + split(Array(words[best...]))
    }

    private static func fits(_ words: [TimedWord]) -> Bool {
        guard let first = words.first, let last = words.last else { return true }
        guard last.end - first.start <= maxDuration else { return false }
        return layout(words).split(separator: "\n").allSatisfy { $0.count <= lineLength }
    }

    /// No overlaps, short cues held for a second, tiny gaps closed.
    private static func settle(_ cues: [Caption]) -> [Caption] {
        var out: [Caption] = []
        for (i, cue) in cues.enumerated() {
            let start = max(cue.start, out.last?.end ?? cue.start)
            let next = i + 1 < cues.count ? cues[i + 1].start : .infinity
            var end = max(cue.end, cue.start + minDuration)
            if next - end < closeGap { end = next }
            end = min(end, next)
            out.append(Caption(start: start, end: end > start ? end : start + 0.5, text: cue.text))
        }
        return out
    }
}

/// Captions as the files players read.
enum CaptionFile {
    static func srt(_ cues: [Caption]) -> String {
        cues.enumerated().map { "\($0.offset + 1)\n\(stamp($0.element.start, ",")) --> \(stamp($0.element.end, ","))\n\($0.element.text)\n" }
            .joined(separator: "\n")
    }

    static func vtt(_ cues: [Caption]) -> String {
        "WEBVTT\n\n" + cues.map { "\(stamp($0.start, ".")) --> \(stamp($0.end, "."))\n\($0.text)\n" }.joined(separator: "\n")
    }

    /// SRT with the speaker named when the voice changes.
    static func srt(_ cues: [(cue: Caption, speaker: Int)], names: [Int: String]) -> String {
        srt(cues.enumerated().map { i, c in
            i > 0 && cues[i - 1].speaker == c.speaker ? c.cue : Caption(start: c.cue.start, end: c.cue.end, text: "\(Speakers.name(c.speaker, names)): \(c.cue.text)")
        })
    }

    /// WebVTT with a voice span on every cue.
    static func vtt(_ cues: [(cue: Caption, speaker: Int)], names: [Int: String]) -> String {
        vtt(cues.map { Caption(start: $0.cue.start, end: $0.cue.end, text: "<v \(Speakers.name($0.speaker, names))>\($0.cue.text)") })
    }

    private static func stamp(_ seconds: Double, _ separator: String) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d\(separator)%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}

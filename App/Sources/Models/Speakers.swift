import Foundation

/// Putting Voz's words and Who's turns together, and keeping speaker numbers
/// steady while Who listens again to a call that is still going.
enum Speakers {
    static func name(_ speaker: Int, _ names: [Int: String] = [:]) -> String { names[speaker] ?? "Speaker \(speaker + 1)" }

    /// What each voice is called: the name it was given, else "You" when it
    /// is the only voice on the microphone, else the guest when it is the only
    /// voice on the call and one person was invited, else "Speaker" and a
    /// number, counting only the voices left to number.
    static func names(_ speakers: [Int], local: Set<Int>?, guests: [String], given: [Int: String]) -> [Int: String] {
        let speakers = Set(speakers).sorted()
        var auto: [Int: String] = [:]
        if let local {
            let here = speakers.filter(local.contains), there = speakers.filter { !local.contains($0) }
            if here.count == 1 { auto[here[0]] = "You" }
            if there.count == 1, guests.count == 1 { auto[there[0]] = guests[0] }
        }
        var names: [Int: String] = [:], number = 0
        for speaker in speakers {
            if let name = auto[speaker] {
                names[speaker] = name
            } else {
                number += 1
                names[speaker] = "Speaker \(number)"
            }
            if let name = given[speaker] { names[speaker] = name }
        }
        return names
    }

    /// Whether anyone was told apart: by Who's turns, or by the words' own voices.
    static func told(_ words: [Transcript.Word], _ turns: [SpeakerTurn]) -> Bool {
        !turns.isEmpty || words.contains { $0.speaker != nil }
    }

    /// The speaker of each word: its own when it has one, else the turn it
    /// overlaps most, or the nearest one.
    ///
    /// It runs on every word of a call each time Voz writes more, so each
    /// word looks only at the turns near it: with the turns in order, those
    /// it can overlap start before it ends and no longer before it than the
    /// longest turn lasts, and the nearest is the next to start or the one
    /// before that ends last.
    static func assign(_ words: [Transcript.Word], _ turns: [SpeakerTurn]) -> [Int] {
        guard !turns.isEmpty else { return words.map { $0.speaker ?? 0 } }
        let turns = turns.sorted { $0.start < $1.start }
        let longest = turns.map { $0.end - $0.start }.max()!
        // The turn that ends last of each one and those before it.
        var last: [Int] = []
        for i in turns.indices { last.append(i > 0 && turns[last[i - 1]].end >= turns[i].end ? last[i - 1] : i) }
        return words.map { word in
            if let speaker = word.speaker { return speaker }
            var best: Int?, most = 0.0
            var i = turns.first(atLeast: word.end, \.start) - 1
            while i >= 0, turns[i].start >= word.start - longest {
                let shared = overlap(word, turns[i])
                // Ties go to the earlier turn.
                if shared > 0, shared >= most { (best, most) = (i, shared) }
                i -= 1
            }
            if let best { return turns[best].speaker }
            let middle = (word.start + word.end) / 2
            let next = turns.first(atLeast: middle, \.start)
            let before = next > 0 ? last[next - 1] : nil
            if let before, next == turns.count || distance(middle, turns[before]) <= distance(middle, turns[next]) { return turns[before].speaker }
            return turns[next].speaker
        }
    }

    static func label(_ words: [Transcript.Word], _ turns: [SpeakerTurn], names: [Int: String] = [:]) -> String {
        var paragraphs: [(speaker: Int, words: [String])] = []
        for (word, speaker) in zip(words, assign(words, turns)) {
            if paragraphs.last?.speaker == speaker { paragraphs[paragraphs.count - 1].words.append(word.text) } else { paragraphs.append((speaker, [word.text])) }
        }
        return paragraphs.map { "\(name($0.speaker, names)): \($0.words.joined(separator: " "))" }.joined(separator: "\n\n")
    }

    /// Renumbers a new pass so each voice keeps the number it had in the last
    /// one: the pairing with the most shared time first, then new voices after.
    static func steady(_ turns: [SpeakerTurn], after previous: [SpeakerTurn]) -> [SpeakerTurn] {
        guard !previous.isEmpty else { return turns }
        let new = Set(turns.map(\.speaker)), old = Set(previous.map(\.speaker))
        var shared: [(new: Int, old: Int, time: Double)] = []
        for n in new {
            for o in old {
                let time = turns.filter { $0.speaker == n }.reduce(0.0) { sum, a in
                    sum + previous.filter { $0.speaker == o }.reduce(0.0) { $0 + max(0, min(a.end, $1.end) - max(a.start, $1.start)) }
                }
                if time > 0 { shared.append((n, o, time)) }
            }
        }
        var map: [Int: Int] = [:], taken = Set<Int>()
        for pair in shared.sorted(by: { $0.time > $1.time }) where map[pair.new] == nil && !taken.contains(pair.old) {
            map[pair.new] = pair.old
            taken.insert(pair.old)
        }
        var next = (old.max() ?? -1) + 1
        for n in new.sorted() where map[n] == nil {
            map[n] = next
            next += 1
        }
        return turns.map { SpeakerTurn(start: $0.start, end: $0.end, speaker: map[$0.speaker]!) }
    }

    private static func overlap(_ word: Transcript.Word, _ turn: SpeakerTurn) -> Double {
        max(0, min(word.end, turn.end) - max(word.start, turn.start))
    }

    private static func distance(_ time: Double, _ turn: SpeakerTurn) -> Double {
        time < turn.start ? turn.start - time : time > turn.end ? time - turn.end : 0
    }
}

extension Array {
    /// The first index whose key is at least `value`, in an array in order of
    /// that key, found by halving.
    func first(atLeast value: Double, _ key: (Element) -> Double) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if key(self[middle]) < value { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

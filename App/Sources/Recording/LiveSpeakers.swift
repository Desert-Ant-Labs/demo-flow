import Foundation

/// Who listening along to a recording while it is made. The audio goes to a
/// scratch file Who reads every so often, and the file is deleted once the
/// last pass is done, so with the recording not kept nothing heard stays.
/// Who renumbers voices on every pass; `Speakers.steady` keeps each one's
/// number from the pass before.
///
/// While recording, a pass hears a sample of each known voice, then the last
/// 30s, and only runs once someone has spoken. The last pass hears it all.
actor LiveSpeakers {
    static let every = 5.0
    static let window = 30.0
    /// About -40 dBFS.
    static let voice: Float = 0.01
    /// Seconds of each known voice a pass hears first.
    static let sample = 6.0
    /// Seconds a voice speaks in a pass to count as someone new.
    static let newVoice = 3.0

    private let file: URL
    private let handle: FileHandle
    private var count = 0
    private var listenedAt = 0
    private var spoken = 0
    private(set) var pass: Task<Void, Never>?
    /// Set once the scratch file cannot be written, as when the disk is full.
    private var full = false
    private var turns: [SpeakerTurn] = []
    private var passes: [Int: Int] = [:]

    /// A voice heard in one pass only may be Who splitting someone, so it shows as its neighbor.
    var shown: [SpeakerTurn] {
        Speakers.fold(turns, known: Set(passes.filter { $0.value > 1 }.keys), least: .infinity)
    }

    init() throws {
        file = RecordingFolder.url.appending(path: "\(RecordingFolder.speakers)\(UUID().uuidString).f32")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        handle = try FileHandle(forWritingTo: file)
    }

    /// Takes audio at `AudioFeed.rate`, and listens again once enough is new.
    /// When the audio can no longer be written, Who keeps what it heard so far.
    func append(_ samples: [Float]) {
        guard !full else { return }
        do {
            try samples.withUnsafeBytes { try handle.write(contentsOf: $0) }
        } catch {
            full = true
            return
        }
        count += samples.count
        spoken += Self.spoken(samples)
        guard pass == nil, Double(count - listenedAt) >= Self.every * AudioFeed.rate, spoken >= Int(AudioFeed.rate) else { return }
        pass = Task {
            await listen(from: max(0, count - Int(Self.window * AudioFeed.rate)))
            pass = nil
        }
    }

    /// The last pass, over everything, then the scratch file goes.
    func finish() async -> [SpeakerTurn] {
        await pass?.value
        await listen(from: 0)
        discard()
        return turns
    }

    nonisolated func discard() {
        try? handle.close()
        try? FileManager.default.removeItem(at: file)
    }

    /// Listens to everything from sample `from` on, and keeps the turns
    /// before it from the passes before.
    private func listen(from: Int) async {
        let upTo = count
        guard upTo - from > Int(AudioFeed.rate), let recent = read(from..<upTo) else { return }
        listenedAt = upTo
        spoken = 0
        var audio: [Float] = [], known: [SpeakerTurn] = []
        if from > 0 {
            for (voice, range) in Self.samples(turns) {
                guard let sample = read(range) else { continue }
                known.append(SpeakerTurn(start: seconds(audio.count), end: seconds(audio.count + sample.count), speaker: voice))
                audio += sample + [Float](repeating: 0, count: Int(AudioFeed.rate))
            }
        }
        let start = seconds(from), shift = start - seconds(audio.count)
        guard let now = try? await ModelHub.who.diarize(audio + recent, sampleRate: AudioFeed.rate) else { return }
        let same = Speakers.same(now, samples: known)
        if !same.isEmpty {
            let one = { (t: SpeakerTurn) in SpeakerTurn(start: t.start, end: t.end, speaker: same[t.speaker] ?? t.speaker) }
            turns = turns.map(one)
            known = known.map(one)
            for (gone, kept) in same { passes[kept, default: 0] += passes.removeValue(forKey: gone) ?? 0 }
        }
        let earlier = turns.compactMap { $0.start < start ? SpeakerTurn(start: $0.start, end: min($0.end, start), speaker: $0.speaker) : nil }
        let before = turns.compactMap { $0.end > start ? SpeakerTurn(start: max($0.start, start) - shift, end: $0.end - shift, speaker: $0.speaker) : nil }
        let placed = Speakers.fold(Speakers.steady(now, after: known + before), known: Set(turns.map(\.speaker)), least: Self.newVoice)
        turns = earlier + placed.compactMap {
            $0.end + shift > start ? SpeakerTurn(start: max($0.start + shift, start), end: $0.end + shift, speaker: $0.speaker) : nil
        }
        for voice in Set(placed.map(\.speaker)) { passes[voice, default: 0] += 1 }
    }

    /// Each voice's clearest stretch: its longest turn nobody talks over.
    private static func samples(_ turns: [SpeakerTurn]) -> [(voice: Int, range: Range<Int>)] {
        Dictionary(grouping: turns, by: \.speaker).sorted { $0.key < $1.key }.map { voice, own in
            let clear = own.filter { turn in !turns.contains { $0.speaker != voice && $0.start < turn.end && turn.start < $0.end } }
            let best = (clear.isEmpty ? own : clear).max { $0.end - $0.start < $1.end - $1.start }!
            let middle = (best.start + best.end) / 2, half = min(best.end - best.start, sample) / 2
            return (voice, Int((middle - half) * AudioFeed.rate)..<Int((middle + half) * AudioFeed.rate))
        }
    }

    private static func spoken(_ samples: [Float]) -> Int {
        let frame = Int(AudioFeed.rate / 50)
        return stride(from: 0, to: samples.count, by: frame).reduce(0) { total, start in
            let part = samples[start..<min(start + frame, samples.count)]
            let power = part.reduce(0) { $0 + $1 * $1 } / Float(part.count)
            return power.squareRoot() >= voice ? total + part.count : total
        }
    }

    private func seconds(_ samples: Int) -> Double { Double(samples) / AudioFeed.rate }

    private func read(_ range: Range<Int>) -> [Float]? {
        guard !range.isEmpty, let data = try? Data(contentsOf: file, options: .alwaysMapped), data.count >= range.upperBound * 4 else { return nil }
        return data[(range.lowerBound * 4)..<(range.upperBound * 4)].withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

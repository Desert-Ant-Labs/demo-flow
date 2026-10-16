import Foundation

/// Who listening along to a recording while it is made. The audio goes to a
/// scratch file Who reads every so often, and the file is deleted once the
/// last pass is done, so with the recording not kept nothing heard stays.
/// Who renumbers voices on every pass; `Speakers.steady` keeps each one's
/// number from the pass before.
///
/// While it records, a pass listens to the last few minutes only, so a long
/// call costs no more each time than a short one. The last pass listens to
/// all of it, which is what the saved labels come from.
actor LiveSpeakers {
    static let every = 25.0
    /// How far back a pass listens while it records: long enough for Who to
    /// tell the voices apart, and to match them with the pass before.
    static let window = 300.0

    private let file: URL
    private let handle: FileHandle
    private var count = 0
    private var listenedAt = 0
    private var pass: Task<Void, Never>?
    /// Set once the scratch file cannot be written, as when the disk is full.
    private var full = false
    private(set) var turns: [SpeakerTurn] = []

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
        guard pass == nil, Double(count - listenedAt) >= Self.every * AudioFeed.rate else { return }
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
        guard upTo - from > Int(AudioFeed.rate), let samples = read(from, upTo) else { return }
        listenedAt = upTo
        guard let heard = try? await ModelHub.who.diarize(samples, sampleRate: AudioFeed.rate) else { return }
        let offset = Double(from) / AudioFeed.rate
        let earlier = turns.compactMap { $0.start < offset ? SpeakerTurn(start: $0.start, end: min($0.end, offset), speaker: $0.speaker) : nil }
        let now = heard.map { SpeakerTurn(start: $0.start + offset, end: $0.end + offset, speaker: $0.speaker) }
        turns = earlier + Speakers.steady(now, after: turns)
    }

    private func read(_ from: Int, _ upTo: Int) -> [Float]? {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped), data.count >= upTo * 4 else { return nil }
        return data[(from * 4)..<(upTo * 4)].withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

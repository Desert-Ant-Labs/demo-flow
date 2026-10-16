import AVFoundation
import CoreMedia
import EchoCancel
import Foundation
import ScreenCaptureKit

/// Takes the stream's audio as it comes, on its own queue: the microphone
/// as the room and what the Mac plays as the call, lined up on one clock.
///
/// The call also reaches the microphone through the speakers, a moment
/// later and more quietly, and would be heard twice, the second time as if
/// someone in the room said it. So WebRTC's echo canceller takes what played
/// back out of the microphone before anything else hears it. With headphones
/// on nothing leaks and it leaves the microphone alone.
///
/// Everything it writes is touched only on `queue`, and the loudness only
/// under `lock`, which is what makes it safe to share.
final class MeetingCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// What both files hold, whatever each source sends.
    static let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    let queue = DispatchQueue(label: "com.desertant.flow.meeting")
    /// Called when the stream ends on its own, as when permission is taken away.
    var stopped: (@Sendable (Error) -> Void)?
    private let heardURL: URL, mixedURL: URL
    private let keeping: Bool
    private let feeds: [Side: AudioFeed]
    private var heard = false
    private var file: AVAudioFile?
    private var converters: [SCStreamOutputType: AVAudioConverter] = [:]
    /// The timestamp of the first sound from either source: the start of both files.
    private var origin: Double?
    private var closed = false
    /// Why the kept recording stopped being written, as when the disk is full.
    private var writeError: Error?
    private let lock = NSLock()
    private var loudness = (system: 0.0, microphone: 0.0)

    /// Each source's audio not yet handed on, from frame `start` on the shared clock.
    private struct Lane {
        var start: AVAudioFramePosition
        var samples: [Float] = []
        var end: AVAudioFramePosition { start + AVAudioFramePosition(samples.count) }
    }
    private var lanes: [SCStreamOutputType: Lane] = [:]
    /// Where on the shared clock the audio handed on has reached, always a
    /// whole number of the canceller's frames.
    private var fed: AVAudioFramePosition = 0
    private let canceller = EchoCanceller(sampleRate: Int(MeetingCapture.format.sampleRate))
    /// The canceller's 10 ms frame.
    private static let frame = AVAudioFramePosition(format.sampleRate / 100)

    static let silent = "Flow heard nothing. Check the microphone, and allow Desert Ant Flow under Screen and System Audio Recording in System Settings."

    init(heard: URL, mixed: URL, keeping: Bool, feeds: [Side: AudioFeed]) {
        heardURL = heard
        mixedURL = mixed
        self.keeping = keeping
        self.feeds = feeds
    }

    var levels: (system: Double, microphone: Double) { lock.withLock { loudness } }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stopped?(error)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let buffer = AVAudioPCMBuffer(sample) else { return }
        take(buffer, type, at: sample.presentationTimeStamp.seconds)
    }

    /// One source's audio, heard at `time` on the stream's clock. Only on `queue`.
    func take(_ buffer: AVAudioPCMBuffer, _ type: SCStreamOutputType, at time: Double) {
        guard type == .audio || type == .microphone, !closed, let pcm = convert(buffer, type) else { return }
        let start = origin ?? time
        origin = start
        heard = true
        let due = AVAudioFramePosition((time - start) * Self.format.sampleRate)
        place(pcm, type, at: due)
        let now = max(0, min(1, (Self.decibels(pcm) + 50) / 50))
        lock.withLock {
            if type == .audio { loudness.system = max(loudness.system * 0.85, now) }
            else { loudness.microphone = max(loudness.microphone * 0.85, now) }
        }
    }

    /// Lines the sources up on the shared clock as they come. A source may run
    /// up to a second behind the other before its missing part counts as
    /// silence, a source not heard from yet too, so the first to arrive is
    /// not handed on before the other's first audio from the same moment.
    private func place(_ pcm: AVAudioPCMBuffer, _ type: SCStreamOutputType, at due: AVAudioFramePosition) {
        guard let data = pcm.floatChannelData?[0] else { return }
        var lane = lanes[type] ?? Lane(start: max(due, fed))
        if lane.samples.isEmpty, lane.start < fed { lane.start = fed }
        if due - lane.end > Self.frame { lane.samples += repeatElement(0, count: Int(due - lane.end)) }
        lane.samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(pcm.frameLength)))
        lanes[type] = lane
        let ends = [SCStreamOutputType.microphone, .audio].map { lanes[$0]?.end ?? fed }
        flush(upTo: max(ends.min()!, ends.max()! - AVAudioFramePosition(Self.format.sampleRate)))
    }

    /// Hands on everything up to `end` in whole frames, or with `last`, all of
    /// it, the tail made up with silence: the echo taken out of the room, each
    /// side to its own feed, and the two mixed into the kept recording.
    private func flush(upTo end: AVAudioFramePosition, last: Bool = false) {
        let limit = (last ? end + Self.frame - 1 : end) / Self.frame * Self.frame
        guard limit > fed else { return }
        let n = Int(limit - fed)
        var room = [Float](repeating: 0, count: n), call = room
        for (type, var lane) in lanes {
            let from = max(0, Int(fed - lane.start)), to = min(lane.samples.count, Int(limit - lane.start))
            if from < to {
                for i in from..<to {
                    let k = Int(lane.start) + i - Int(fed)
                    if type == .microphone { room[k] = lane.samples[i] } else { call[k] = lane.samples[i] }
                }
            }
            let used = max(0, min(lane.samples.count, Int(limit - lane.start)))
            lane.samples.removeFirst(used)
            lane.start += AVAudioFramePosition(used)
            if lane.samples.isEmpty { lane.start = max(lane.start, limit) }
            lanes[type] = lane
        }
        fed = limit
        canceller?.cancel(&room, played: call)
        // Both sides from the same moment, silence and all, so their words
        // keep the times they were said at.
        if let feed = feeds[.room], let pcm = Self.buffer(room) { feed.push(pcm) }
        if let feed = feeds[.call], let pcm = Self.buffer(call) { feed.push(pcm) }
        if keeping, let pcm = Self.buffer(zip(room, call).map { max(-1, min(1, $0 + $1)) }) { write(pcm) }
    }

    private static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        samples.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        return pcm
    }

    /// Stops at the first failure, so the recording never has a hole in it,
    /// and `mix` says why it is short.
    private func write(_ pcm: AVAudioPCMBuffer) {
        guard writeError == nil else { return }
        do {
            let file = try file ?? AVAudioFile(forWriting: heardURL, settings: Self.format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            self.file = file
            try file.write(from: pcm)
        } catch {
            writeError = error
            file = nil
        }
    }

    /// Removes the files of a recording that never started.
    func discard() {
        queue.sync {
            closed = true
            file = nil
        }
        try? FileManager.default.removeItem(at: heardURL)
    }

    /// The mix as one recording: kept from clipping and saved as M4A, a slice
    /// at a time so a long call never sits in memory whole. The working file
    /// is removed either way.
    func mix() async throws -> URL? {
        let (heard, writeError) = queue.sync {
            closed = true
            flush(upTo: lanes.values.map(\.end).max() ?? fed, last: true)
            file?.close()
            file = nil
            return (self.heard, self.writeError)
        }
        for feed in feeds.values { feed.finish() }
        guard keeping else {
            if !heard { throw StepError(Self.silent) }
            return nil
        }
        let fm = FileManager.default
        defer { try? fm.removeItem(at: heardURL) }
        if let writeError { throw StepError("Flow could not save the recording: \(writeError.localizedDescription)") }
        guard fm.fileExists(atPath: heardURL.path) else { throw StepError(Self.silent) }
        let source = try AVAudioFile(forReading: heardURL)
        guard source.length > 0 else { throw StepError(Self.silent) }
        let slice: AVAudioFrameCount = 1 << 16
        guard let mixed = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: slice)
        else { throw StepError("The meeting could not be mixed") }

        func eachSlice(_ body: (AVAudioPCMBuffer) throws -> Void) throws {
            source.framePosition = 0
            while source.framePosition < source.length {
                try source.read(into: mixed, frameCount: slice)
                try body(mixed)
            }
        }

        var peak: Float = 0
        try eachSlice { b in
            let x = b.floatChannelData![0]
            for i in 0..<Int(b.frameLength) { peak = max(peak, abs(x[i])) }
        }
        let gain: Float = peak > 0.99 ? 0.99 / peak : 1
        try? fm.removeItem(at: mixedURL)
        do {
            let out = try AVAudioFile(forWriting: mixedURL, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.format.sampleRate,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 192_000,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            try eachSlice { b in
                if gain != 1 {
                    let x = b.floatChannelData![0]
                    for i in 0..<Int(b.frameLength) { x[i] *= gain }
                }
                try out.write(from: b)
            }
            out.close()
        } catch {
            try? fm.removeItem(at: mixedURL)
            throw error
        }
        return mixedURL
    }

    /// The buffer as `format`: one channel at 48kHz.
    private func convert(_ buffer: AVAudioPCMBuffer, _ type: SCStreamOutputType) -> AVAudioPCMBuffer? {
        if buffer.format == Self.format { return buffer }
        // A source can change format mid-call, as when another microphone is chosen.
        if converters[type]?.inputFormat != buffer.format { converters[type] = AVAudioConverter(from: buffer.format, to: Self.format) }
        guard let converter = converters[type] else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.format.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    private static func decibels(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -100 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        return Double(20 * log10(max(rms, 1e-6)))
    }
}

extension AVAudioPCMBuffer {
    /// A capture's audio as a buffer, in the format it came in.
    convenience init?(_ sample: CMSampleBuffer) {
        guard sample.isValid, sample.numSamples > 0,
              var description = sample.formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &description)
        else { return nil }
        self.init(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples))
        frameLength = AVAudioFrameCount(sample.numSamples)
        do {
            try sample.copyPCMData(fromRange: 0..<sample.numSamples, into: mutableAudioBufferList)
        } catch {
            return nil
        }
    }
}

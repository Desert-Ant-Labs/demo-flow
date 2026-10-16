import AVFoundation
import Foundation
import ScreenCaptureKit
import Testing
@testable import Flow

/// The two sources lined up on one clock, without ScreenCaptureKit: the
/// buffers are handed to the capture as the stream would.
@Suite struct MeetingCaptureTests {
    private static let rate = MeetingCapture.format.sampleRate

    private func tone(_ seconds: Double) throws -> AVAudioPCMBuffer {
        let n = AVAudioFrameCount(seconds * Self.rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: MeetingCapture.format, frameCapacity: n))
        buffer.frameLength = n
        for i in 0..<Int(n) { buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.5 }
        return buffer
    }

    private func silence(_ seconds: Double) throws -> AVAudioPCMBuffer {
        let buffer = try tone(seconds)
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = 0 }
        return buffer
    }

    /// The power of `samples` at `AudioFeed.rate` between two times.
    private func power(_ samples: [Float], _ from: Double, _ to: Double) -> Float {
        let part = samples[Int(from * AudioFeed.rate)..<min(samples.count, Int(to * AudioFeed.rate))]
        return part.reduce(0) { $0 + $1 * $1 } / Float(max(1, part.count))
    }

    @Test func eachSourceLandsWhenItWasHeardWithSilenceBetween() async throws {
        var streams: [Side: AsyncStream<[Float]>] = [:], feeds: [Side: AudioFeed] = [:]
        for side in Side.allCases {
            let (stream, continuation) = AsyncStream<[Float]>.makeStream()
            streams[side] = stream
            feeds[side] = AudioFeed(continuation)
        }
        let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let capture = MeetingCapture(heard: scratch.appending(path: "heard.caf"), mixed: scratch.appending(path: "mixed.m4a"), keeping: false, feeds: feeds)
        // A tenth of a second at a time, the room quiet for three seconds and
        // the call playing from 0.5 s to 0.7 s and from 2 s to 2.2 s, sending
        // nothing at all in between.
        let quiet = try silence(0.1), playing = try tone(0.1)
        capture.queue.sync {
            for tenth in 0..<30 {
                let time = 100 + Double(tenth) / 10
                capture.take(quiet, .microphone, at: time)
                if tenth < 7 { capture.take(tenth < 5 ? quiet : playing, .audio, at: time) }
                if (20..<22).contains(tenth) { capture.take(playing, .audio, at: time) }
            }
        }
        _ = try await capture.mix()

        var heard: [Side: [Float]] = [:]
        for (side, stream) in streams { for await chunk in stream { heard[side, default: []] += chunk } }
        let room = try #require(heard[.room]), played = try #require(heard[.call])
        #expect(abs(room.count - played.count) < 100, "Both sides cover the same time")
        #expect(abs(Double(played.count) / AudioFeed.rate - 3) < 0.05)
        #expect(power(played, 0.52, 0.68) > 0.05)
        #expect(power(played, 2.02, 2.18) > 0.05)
        #expect(power(played, 0, 0.45) < 1e-4, "Nothing before the call first plays")
        #expect(power(played, 0.75, 1.95) < 1e-4, "The gap stays silent, so the second part keeps its time")
        #expect(power(room, 0, 3) < 1e-4)
    }
}

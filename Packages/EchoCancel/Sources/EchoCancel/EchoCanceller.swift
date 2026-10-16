import Foundation
import WebRTCEchoCancel

/// Takes what the speakers play back out of what the microphone hears, with
/// WebRTC's AEC3. It finds the delay between the two and the room's echo on
/// its own, and leaves the microphone alone when nothing leaks into it, as
/// with headphones on.
///
/// AEC3 takes out most of the echo, not all, and a transcriber makes words of
/// even a faint trace. So, as a call app would, it then mutes what is left of
/// a stretch that was nearly all echo: where cancelling took the microphone
/// down by more than `residue`, nobody in the room was talking over it. Where
/// someone was, their voice is not in what played, and little comes out.
///
/// AEC3 needs the first second or two of the call talking to learn the room,
/// and lets echo through meanwhile. So for the first `learning` the call
/// talks, the microphone counts only between its words.
///
/// Feed it both sides of the same stretch of time, a frame at a time: what
/// played first, then what the microphone heard. Not safe to share between
/// threads.
public final class EchoCanceller {
    private let handle: OpaquePointer
    /// The samples in one frame: 10 ms.
    public let frame: Int
    /// How far cancelling takes a stretch down, in power, before it counts as
    /// echo: 6 dB, so someone in the room as loud as the echo still counts.
    public static let residue: Float = 6
    /// How many frames a stretch counts as speech for after it last did, so word ends stay.
    static let hold = 8
    /// How many frames of the call talking it takes AEC3 to learn the room: 3 s.
    static let learning = 300
    /// The power below which nothing is playing: -60 dB.
    static let quiet: Float = 1e-6

    private var before: Float = 0, after: Float = 0
    private var gain: Float = 1
    private var held = 0
    private var learnt = 0

    /// For mono audio at 16, 32 or 48 kHz.
    public init?(sampleRate: Int) {
        guard let handle = echo_cancel_create(Int32(sampleRate)) else { return nil }
        self.handle = handle
        frame = Int(echo_cancel_frame(handle))
    }

    deinit { echo_cancel_destroy(handle) }

    /// The microphone without the echo of what played, over any whole number
    /// of frames. Both arrays are the same length.
    public func cancel(_ microphone: inout [Float], played: [Float]) {
        precondition(microphone.count == played.count && microphone.count % frame == 0)
        played.withUnsafeBufferPointer { played in
            microphone.withUnsafeMutableBufferPointer { microphone in
                for at in stride(from: 0, to: microphone.count, by: frame) {
                    let heard = power(UnsafeBufferPointer(microphone), at)
                    let sounding = power(played, at) > Self.quiet
                    let playing = learnt < Self.learning && sounding
                    if playing { learnt += 1 }
                    let rendered = echo_cancel_render(handle, played.baseAddress! + at)
                    let captured = echo_cancel_capture(handle, microphone.baseAddress! + at)
                    // A frame AEC3 could not take the echo out of still holds
                    // all of it, so while the call plays it counts as echo.
                    let failed = (rendered != 0 || captured != 0) && sounding
                    mute(microphone, at, heard: heard, echo: playing || failed)
                }
            }
        }
    }

    private func power(_ x: UnsafeBufferPointer<Float>, _ at: Int) -> Float {
        var sum: Float = 0
        for i in at..<(at + frame) { sum += x[i] * x[i] }
        return sum / Float(frame)
    }

    /// Fades out a frame that cancelling took down past `residue`, and back in
    /// once it does not, over a frame, so it never clicks.
    private func mute(_ x: UnsafeMutableBufferPointer<Float>, _ at: Int, heard: Float, echo forced: Bool) {
        // Over the last few frames, so one frame of a word does not decide it.
        before = 0.6 * before + 0.4 * heard
        after = 0.6 * after + 0.4 * power(UnsafeBufferPointer(x), at)
        let echo = forced || after * pow(10, Self.residue / 10) < before
        held = echo ? max(0, held - 1) : Self.hold
        let target: Float = held > 0 ? 1 : 0
        let step = (target - gain) / Float(frame)
        for i in at..<(at + frame) {
            gain += step
            x[i] *= gain
        }
    }
}

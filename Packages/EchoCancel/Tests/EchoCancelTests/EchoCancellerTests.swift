import EchoCancel
import Foundation
import Testing

/// Speech-like noise: random, most of it below 2 kHz, and loud and quiet in syllables.
private func voice(_ seconds: Double, seed: UInt64, rate: Int = 48_000) -> [Float] {
    var state = seed
    var low: Float = 0
    return (0..<Int(seconds * Double(rate))).map { i in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let noise = Float(Int64(bitPattern: state >> 11) % 2000) / 2000 - 0.5
        low += 0.2 * (noise - low)
        let t = Float(i) / Float(rate)
        let syllable: Float = 0.5 + 0.5 * sin(t * 2 * .pi * 4)
        return 1.2 * low * syllable
    }
}

/// What a room makes of `played` on its way to the microphone: later, quieter, and smeared.
private func echo(of played: [Float], delay: Int = 1_200) -> [Float] {
    played.indices.map { i in
        let a = i >= delay ? played[i - delay] : 0
        let b = i >= delay + 700 ? played[i - delay - 700] : 0
        return 0.3 * a + 0.12 * b
    }
}

private func power(_ x: ArraySlice<Float>) -> Float { x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count)) }

@Test func theCallIsTakenOutOfTheMicrophone() throws {
    let canceller = try #require(EchoCanceller(sampleRate: 48_000))
    let played = voice(8, seed: 1)
    var microphone = echo(of: played)
    let raw = microphone
    canceller.cancel(&microphone, played: played)
    // Once it has learned the room, nothing is left of the call.
    #expect(power(microphone[(2 * 48_000)...]) < power(raw[(2 * 48_000)...]) / 10_000)
}

@Test func someoneInTheRoomIsKept() throws {
    let canceller = try #require(EchoCanceller(sampleRate: 48_000))
    // The call talks for three seconds, then you answer while it is quiet.
    let rate = 48_000
    let played = voice(3, seed: 1) + [Float](repeating: 0, count: 3 * rate)
    let you = [Float](repeating: 0, count: 3 * rate) + voice(3, seed: 2)
    var microphone = zip(echo(of: played), you).map { $0 + $1 }
    canceller.cancel(&microphone, played: played)
    let kept = power(microphone[(4 * rate)...]), said = power(you[(4 * rate)...])
    #expect(kept > said * 0.7)
    #expect(kept < said * 1.3)
}

@Test func talkingOverTheCallIsKept() throws {
    let canceller = try #require(EchoCanceller(sampleRate: 48_000))
    let rate = 48_000
    let played = voice(8, seed: 1)
    // You start answering four seconds in, while the call is still talking.
    let you = [Float](repeating: 0, count: 4 * rate) + voice(4, seed: 2)
    var microphone = zip(echo(of: played), you).map { $0 + $1 }
    canceller.cancel(&microphone, played: played)
    let kept = power(microphone[(5 * rate)...]), said = power(you[(5 * rate)...])
    #expect(kept > said * 0.5)
}

@Test func withNothingPlayingTheMicrophoneIsLeftAlone() throws {
    let canceller = try #require(EchoCanceller(sampleRate: 48_000))
    let you = voice(4, seed: 2)
    var microphone = you
    canceller.cancel(&microphone, played: [Float](repeating: 0, count: you.count))
    let kept = power(microphone[48_000...]), said = power(you[48_000...])
    #expect(kept > said * 0.7)
    #expect(kept < said * 1.3)
}

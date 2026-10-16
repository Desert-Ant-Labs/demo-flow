import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Records a meeting: the microphone, and everything this Mac plays, which
/// is every other person on the call, whatever app the call is in.
///
/// System audio comes from ScreenCaptureKit, the only way an app can hear
/// it, so macOS asks once for screen and system audio recording; no picture
/// is kept. The two are kept apart as the room and the call (see `Side` and
/// `MeetingCapture`). Kept, they are mixed into one recording. Transcribed,
/// each is handed to Voz on its own, and without a kept recording nothing
/// heard is written to disk.
@MainActor
@Observable
final class MeetingRecorder {
    enum Phase { case idle, starting, recording, mixing }

    private(set) var phase = Phase.idle
    private var started = Date()
    private var stream: SCStream?
    private var capture: MeetingCapture?
    private var finished: ((Take) -> Void)?
    private var waiting: [CheckedContinuation<Take, Error>] = []
    /// Whether `stop` was asked for while it was still starting.
    private var stopAsked = false
    /// Why the stream ended on its own, if it did.
    private var ended: Error?
    /// The words so far, while a transcribed meeting records.
    private(set) var transcript: LiveTranscript?

    var recording: Bool { phase == .recording }
    var busy: Bool { phase == .starting || phase == .mixing }
    var seconds: Double { recording ? Date().timeIntervalSince(started) : 0 }
    var microphoneLevel: Double { capture?.levels.microphone ?? 0 }
    var systemLevel: Double { capture?.levels.system ?? 0 }

    /// Whether macOS has said Flow may record system audio. Cached by macOS,
    /// so it can read false until Flow restarts after the permission is given.
    static var mayRecordSystemAudio: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks the way recording does, which is what brings up macOS's dialog the
    /// first time, and reports whether Flow can hear the Mac now.
    static func askForSystemAudio() async -> Bool {
        if mayRecordSystemAudio { return true }
        return (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)) != nil
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    static let permissionMessage = "Flow could not record system audio. Allow Flow under Screen and System Audio Recording in System Settings, Privacy and Security, then try again."

    /// Starts recording. `finished` gets what it made when it ends, whether
    /// stopped or cut short.
    func start(_ options: RecordingOptions = .init(), then finished: @escaping (Take) -> Void) async throws {
        guard phase == .idle else { return }
        phase = .starting
        do {
            // Voz only starts once the stream runs, so one that never does
            // leaves nothing waiting on audio that will not come.
            let transcript = options.transcribes ? LiveTranscript(options, sides: [.room, .call], transcribing: false) : nil
            try await begin(keeping: options.keepsRecording || !options.transcribes, feeds: transcript?.feeds ?? [:])
            transcript?.begin()
            self.transcript = transcript
            self.finished = finished
            started = Date()
            phase = .recording
        } catch {
            phase = .idle
            settle(.success(Take()))
            let declined = (error as? SCStreamError)?.code == .userDeclined
            throw declined || !Self.mayRecordSystemAudio ? StepError(Self.permissionMessage) : error
        }
        // Stopped while macOS was still asking, as when the call ended then.
        if stopAsked { _ = try? await stop() }
    }

    private func begin(keeping: Bool, feeds: [Side: AudioFeed]) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw StepError("No display to record system audio from") }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(MeetingCapture.format.sampleRate)
        config.channelCount = 1
        if let mic = Recorder.device { config.microphoneCaptureDeviceID = mic.uniqueID }
        // The stream needs a picture to run; keep it as small and as rare as it goes.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let folder = RecordingFolder.url
        let stamp = RecordingFolder.stamp()
        let capture = MeetingCapture(
            heard: folder.appending(path: "\(RecordingFolder.meeting)\(stamp).caf"),
            mixed: folder.appending(path: "Meeting \(stamp).m4a"),
            keeping: keeping, feeds: feeds)
        capture.stopped = { [weak self] error in
            Task { @MainActor in
                self?.ended = error
                _ = try? await self?.stop()
            }
        }
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: capture)
        try stream.addStreamOutput(capture, type: .audio, sampleHandlerQueue: capture.queue)
        try stream.addStreamOutput(capture, type: .microphone, sampleHandlerQueue: capture.queue)
        do {
            try await stream.startCapture()
        } catch {
            capture.discard()
            throw error
        }
        self.stream = stream
        self.capture = capture
    }

    /// Stops, then mixes the kept recording and settles the transcript.
    /// Asked while still starting, it waits for the start and stops then.
    /// `finished` gets whatever was made even when part of it failed, as
    /// the words when the recording could not be saved.
    @discardableResult
    func stop() async throws -> Take {
        switch phase {
        case .idle: return Take()
        case .starting:
            stopAsked = true
            return try await withCheckedThrowingContinuation { waiting.append($0) }
        case .mixing: return try await withCheckedThrowingContinuation { waiting.append($0) }
        case .recording: break
        }
        phase = .mixing
        let stream = stream, capture = capture, transcript = transcript
        self.stream = nil
        self.capture = nil
        var stopError = ended
        do { try await stream?.stopCapture() } catch { stopError = stopError ?? error }
        // The words are settled whether or not the recording could be mixed.
        var audio: URL?
        var mixing: Error?
        do { audio = try await capture?.mix() } catch { mixing = error }
        let words = await transcript?.finish()
        let take = Take(audio: audio, transcript: words)
        let result: Result<Take, Error>
        if let mixing {
            result = .failure(mixing)
        } else if take.isEmpty {
            result = .failure(StepError(transcript?.failure ?? stopError?.localizedDescription ?? "Flow heard no words in the recording."))
        } else {
            result = .success(take)
        }
        self.transcript = nil
        ended = nil
        phase = .idle
        finished?(take)
        finished = nil
        settle(result)
        return try result.get()
    }

    private func settle(_ result: Result<Take, Error>) {
        stopAsked = false
        for w in waiting { w.resume(with: result) }
        waiting = []
    }
}

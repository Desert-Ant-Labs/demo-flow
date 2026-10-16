import AppKit
import AVFoundation

/// Records from a microphone into a file the flow keeps, transcribes it as
/// it records, or both. It records with a capture session rather than
/// AVAudioRecorder, which only ever takes the Mac's default input: this one
/// records from the microphone chosen in the Record step, and remembers it
/// for this Mac.
@MainActor
@Observable
final class Recorder {
    enum Phase { case idle, starting, recording, stopping }

    private(set) var phase = Phase.idle
    private var started = Date()
    private var session: AVCaptureSession?
    private var fileOutput: AVCaptureAudioFileOutput?
    private var dataOutput: AVCaptureAudioDataOutput?
    private var delegate: RecordingDelegate?
    private var tap: SampleTap?
    private var waiting: [CheckedContinuation<Take, Never>] = []
    /// Whether `stop` was asked for while it was still starting.
    private var stopAsked = false
    /// What hears the microphone go away when no file output would.
    private var observers: [NSObjectProtocol] = []
    /// Called with what was made once a recording ends, whether stopped or
    /// cut short, as when the microphone is unplugged.
    private var finished: ((Take) -> Void)?
    /// The words so far, while a transcribed recording records.
    private(set) var transcript: LiveTranscript?
    private static let queue = DispatchQueue(label: "com.desertant.flow.recorder")

    var recording: Bool { phase == .recording }
    var busy: Bool { phase == .starting || phase == .stopping }
    var seconds: Double { recording ? Date().timeIntervalSince(started) : 0 }

    static let deviceKey = "recordingDevice"
    static let noAccess = "Flow has no access to the microphone. Allow it in System Settings, Privacy and Security."

    /// Every microphone this Mac can record from, built in and plugged in.
    static var devices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    /// The one chosen, or the Mac's default when none is, or it is unplugged.
    static var device: AVCaptureDevice? {
        let id = UserDefaults.standard.string(forKey: deviceKey)
        return devices.first { $0.uniqueID == id } ?? AVCaptureDevice.default(for: .audio)
    }

    /// How loud the microphone is right now, 0 to 1, for a level meter.
    var level: Double {
        let connection = (fileOutput as AVCaptureOutput?)?.connections.first ?? dataOutput?.connections.first
        guard recording, let channel = connection?.audioChannels.first else { return 0 }
        return max(0, min(1, (Double(channel.averagePowerLevel) + 50) / 50))
    }

    func start(_ options: RecordingOptions = .init(), then finished: @escaping (Take) -> Void) async throws {
        guard phase == .idle else { return }
        phase = .starting
        do {
            guard let device = Self.device else { throw StepError("This Mac has no microphone to record from") }
            let session = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw StepError("\(device.localizedName) is not available") }
            session.addInput(input)
            let keeps = options.keepsRecording || !options.transcribes
            let fileOutput = keeps ? AVCaptureAudioFileOutput() : nil
            // Voz only starts once the session runs; see `MeetingRecorder.start`.
            let transcript = options.transcribes ? LiveTranscript(options, transcribing: false) : nil
            let dataOutput = transcript.map { _ in AVCaptureAudioDataOutput() }
            for output in [fileOutput as AVCaptureOutput?, dataOutput].compactMap({ $0 }) {
                guard session.canAddOutput(output) else { throw StepError("\(device.localizedName) is not available") }
                session.addOutput(output)
            }
            if fileOutput == nil {
                // The file output ends itself when the microphone goes, as
                // when it is unplugged. Without one, the session says so.
                observers = [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification].map { name in
                    NotificationCenter.default.addObserver(forName: name, object: session, queue: .main) { [weak self] _ in
                        Task { @MainActor in await self?.stop() }
                    }
                }
            }
            let tap = transcript.map { SampleTap(feed: $0.feed) }
            if let tap { dataOutput?.setSampleBufferDelegate(tap, queue: Self.queue) }
            nonisolated(unsafe) let running = session
            await withCheckedContinuation { done in
                Self.queue.async {
                    running.startRunning()
                    done.resume()
                }
            }
            if let fileOutput {
                let url = RecordingFolder.url.appending(path: "Recording \(RecordingFolder.stamp()).m4a")
                let delegate = RecordingDelegate { [weak self] url in self?.ended(url) }
                fileOutput.startRecording(to: url, outputFileType: .m4a, recordingDelegate: delegate)
                self.delegate = delegate
            }
            transcript?.begin()
            self.session = session
            self.fileOutput = fileOutput
            self.dataOutput = dataOutput
            self.tap = tap
            self.transcript = transcript
            self.finished = finished
            started = Date()
            phase = .recording
        } catch {
            phase = .idle
            stopAsked = false
            for w in waiting { w.resume(returning: Take()) }
            waiting = []
            throw error
        }
        // Stopped while it was starting, as with a shortcut pressed twice.
        if stopAsked {
            stopAsked = false
            await stop()
        }
    }

    /// Stops, and returns what was made once its file is written and its
    /// words are settled. Asked while still starting, it waits for the
    /// start and stops then.
    @discardableResult
    func stop() async -> Take {
        switch phase {
        case .idle: return Take()
        case .starting: stopAsked = true
        case .recording:
            phase = .stopping
            if let fileOutput { fileOutput.stopRecording() } else { ended(nil) }
        case .stopping: break
        }
        return await withCheckedContinuation { waiting.append($0) }
    }

    private func ended(_ url: URL?) {
        let session = session, transcript = transcript
        self.session = nil
        fileOutput = nil
        dataOutput = nil
        delegate = nil
        tap = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let session {
            nonisolated(unsafe) let stopping = session
            Self.queue.async { stopping.stopRunning() }
        }
        Task {
            let take = Take(audio: url, transcript: await transcript?.finish())
            self.transcript = nil
            phase = .idle
            finished?(take)
            finished = nil
            for w in waiting { w.resume(returning: take) }
            waiting = []
        }
    }
}

/// Hands the microphone's buffers to Voz as they come.
final class SampleTap: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, Sendable {
    private let feed: AudioFeed

    init(feed: AudioFeed) { self.feed = feed }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let buffer = AVAudioPCMBuffer(sample) { feed.push(buffer) }
    }
}

/// Hears when a recording's file is complete, and tells the recorder on the
/// main actor.
final class RecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, Sendable {
    private let done: @MainActor @Sendable (URL?) -> Void

    init(done: @escaping @MainActor @Sendable (URL?) -> Void) { self.done = done }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        // An error can still mean the file is complete, as when the
        // microphone is unplugged mid-sentence: what was heard is kept.
        let file = FileManager.default.fileExists(atPath: url.path) ? url : nil
        let done = done
        Task { @MainActor in done(file) }
    }
}

/// The recorders of one window's Record steps, kept apart from the cards that
/// show them, so a recording carries on while the window switches between the
/// canvas and the step list. When the window closes, whatever is still
/// recording is stopped and its file stays in the Recordings folder.
@MainActor
final class Recordings {
    private var microphones: [String: Recorder] = [:]
    private var meetings: [String: MeetingRecorder] = [:]

    func microphone(_ node: String) -> Recorder {
        if let r = microphones[node] { return r }
        let r = Recorder()
        microphones[node] = r
        return r
    }

    func meeting(_ node: String) -> MeetingRecorder {
        if let r = meetings[node] { return r }
        let r = MeetingRecorder()
        meetings[node] = r
        return r
    }

    private func finishAll() {
        let mics = Array(microphones.values), calls = Array(meetings.values)
        Task {
            for r in mics { await r.stop() }
            for r in calls { _ = try? await r.stop() }
        }
    }

    private struct Entry {
        weak var owner: AnyObject?
        let recordings: Recordings
    }

    /// For a Record step shown outside a window's session.
    static let loose = Recordings()

    private static var windows: [ObjectIdentifier: Entry] = [:]
    private static var watching = false

    /// The recordings of the window a session belongs to.
    static func of(_ session: FlowSession?) -> Recordings {
        session.map { of(owner: $0) } ?? loose
    }

    private static func of(owner: AnyObject) -> Recordings {
        if let entry = windows[ObjectIdentifier(owner)], entry.owner === owner { return entry.recordings }
        sweep()
        watch()
        let recordings = Recordings()
        windows[ObjectIdentifier(owner)] = Entry(owner: owner, recordings: recordings)
        return recordings
    }

    /// Finishes the recordings of windows that have gone.
    private static func sweep() {
        for (key, entry) in windows where entry.owner == nil {
            entry.recordings.finishAll()
            windows[key] = nil
        }
    }

    /// A window's session goes a moment after the window closes.
    private static func watch() {
        guard !watching else { return }
        watching = true
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                for wait in [1, 5] {
                    try? await Task.sleep(for: .seconds(wait))
                    sweep()
                }
            }
        }
    }
}

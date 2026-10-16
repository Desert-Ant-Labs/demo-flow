import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Asks for the microphone, then starts `recorder`, which hands what it made
/// to `use` once the recording ends. Returns what went wrong, if anything.
@MainActor
func startMicrophone(_ recorder: Recorder, _ options: RecordingOptions = .init(), use: @escaping (Take) -> Void) async -> String? {
    guard await AVCaptureDevice.requestAccess(for: .audio) else { return Recorder.noAccess }
    do {
        try await recorder.start(options) { if !$0.isEmpty { use($0) } }
        return nil
    } catch {
        return error.localizedDescription
    }
}

/// An audio file: a sample, one of your own, or one recorded here.
struct AudioBody: View {
    let node: Node
    let state: StepState
    @Environment(\.flowActions) private var actions
    @Environment(\.flowSession) private var session
    @State private var error: String?

    var body: some View {
        let recorder = Recordings.of(session).microphone(node.id)
        let file = node.params["file"]?.string
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: Binding(
                get: { file == nil ? node.params["sample"]?.string ?? "" : "" },
                set: { actions.set(node.id, ["sample": .string($0), "file": .null]) }
            )) {
                if let file { Text(URL(filePath: file).lastPathComponent).tag("") } else { Text("Choose a sample").tag("") }
                ForEach(Samples.audio, id: \.path) { Text($0.label).tag($0.path) }
            }
            .labelsHidden()
            HStack {
                Button(recorder.recording ? "Stop" : "Record", systemImage: recorder.recording ? "stop.fill" : "mic") { toggle(recorder) }
                    .tint(recorder.recording ? Theme.danger : nil)
                    .disabled(recorder.busy)
                Button("Open…", systemImage: "folder") {
                    if let url = openPanel([.audio, .movie], multiple: false, prompt: "Use").first { use(url) }
                }
            }
            .controlSize(.small)
            if recorder.recording {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Label(String(format: "Recording %.0fs", recorder.seconds), systemImage: "record.circle").foregroundStyle(Theme.danger)
                }
            }
            if let error { Text(error).foregroundStyle(Theme.danger).font(.caption) }
            if let clip = state.outputs?["audio"]?.audio { AudioPlayerView(clip: clip) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audiovisualContent) ?? false }) else { return false }
            use(url)
            return true
        }
    }

    private func use(_ url: URL) {
        actions.set(node.id, ["file": .string(Samples.path(for: url)), "sample": .null])
    }

    private func toggle(_ recorder: Recorder) {
        error = nil
        if recorder.recording {
            Task { await recorder.stop() }
            return
        }
        let use = use
        Task { error = await startMicrophone(recorder) { if let url = $0.audio { use(url) } } }
    }
}

/// The Record step, laid out like a voice memo: a record button, then while
/// recording a waveform of what it hears, the time, and the words as Voz
/// writes them, and once stopped the recording and the transcript.
struct RecordBody: View {
    let node: Node
    let state: StepState
    /// Off for the steps that record on their own, which only record one way.
    var showsSource = true
    @Environment(\.flowActions) private var actions
    @Environment(\.flowSession) private var session
    @State private var levels: [Double] = []
    @State private var error: String?

    /// Just the microphone, or a meeting: the microphone and system audio.
    private var isMeeting: Bool { Recording.isMeeting(node.params) }

    var body: some View {
        let recorder = Recordings.of(session).microphone(node.id)
        let meeting = Recordings.of(session).meeting(node.id)
        let recording = recorder.recording || meeting.recording
        VStack(alignment: .leading, spacing: 10) {
            if !recording, showsSource {
                Picker("", selection: Binding(get: { node.params["source"]?.string ?? "microphone" }, set: { source in
                    var params = node.params
                    params["source"] = .string(source)
                    params["transcribe"] = nil
                    params["keep"] = nil
                    change(["source": .string(source), "transcribe": .null, "keep": .null], showing: params)
                })) {
                    Text("Microphone").tag("microphone")
                    Text("Microphone and system audio").tag("meeting")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if !recording { settings }
            HStack(spacing: 12) {
                recordButton(recorder, meeting)
                if meeting.recording {
                    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                        VStack(alignment: .leading, spacing: 5) {
                            LevelBar(label: "You", level: meeting.microphoneLevel)
                            LevelBar(label: "Others", level: meeting.systemLevel)
                        }
                    }
                    clock { meeting.seconds }
                } else if recorder.recording {
                    LiveWaveform(levels: levels)
                        .frame(height: 32)
                    clock { recorder.seconds }
                } else if meeting.phase == .mixing || recorder.phase == .stopping {
                    Text(Recording.transcribes(node.params) ? "Writing the last words…" : "Putting the meeting together…")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else if let clip = state.outputs?["audio"]?.audio {
                    AudioPlayerView(clip: clip)
                } else if state.outputs?["text"] != nil {
                    Label("Transcribed", systemImage: "text.quote").font(.callout.weight(.semibold))
                    Spacer(minLength: 0)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(showsSource ? "Record" : "Try it").font(.callout.weight(.semibold))
                        Text(!showsSource ? "Record now, without waiting for it to start on its own."
                             : isMeeting ? "For meetings and calls." : "Click to start, and again to stop.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            if let live = meeting.transcript ?? recorder.transcript {
                LiveTranscriptView(transcript: live)
            } else if !recording, let text = state.outputs?["text"]?.string, !text.isEmpty {
                Text(text)
                    .font(.callout)
                    .lineLimit(4)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !recording {
                HStack(spacing: 12) {
                    MicrophoneMenu()
                    if isMeeting { MeetingPermissions() }
                }
            }
            if let error { Text(error).foregroundStyle(Theme.danger).font(.caption) }
        }
        .task(id: recorder.recording) {
            levels = []
            while recorder.recording, !Task.isCancelled {
                levels.append(recorder.level)
                if levels.count > 120 { levels.removeFirst(levels.count - 120) }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func clock(_ seconds: @escaping () -> Double) -> some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            Text(Duration.seconds(seconds()).formatted(.time(pattern: .minuteSecond)))
                .font(.callout.monospacedDigit())
                .foregroundStyle(Theme.danger)
        }
    }

    private func recordButton(_ recorder: Recorder, _ meeting: MeetingRecorder) -> some View {
        let has = state.outputs?["audio"] != nil
        let recording = recorder.recording || meeting.recording
        return Button { toggle(recorder, meeting) } label: {
            ZStack {
                Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 2)
                if recording {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Theme.danger).frame(width: 13, height: 13)
                } else {
                    Circle().fill(Theme.danger).frame(width: 22, height: 22)
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(recorder.busy || meeting.busy)
        .help(recording ? "Stop" : has ? "Record again" : "Record")
        .accessibilityLabel(recording ? "Stop" : has ? "Record again" : "Record")
        .animation(.snappy(duration: 0.2), value: recording)
    }

    /// Transcribe, tell voices apart, and keep: what the step makes of a recording.
    private var settings: some View {
        let transcribes = Recording.transcribes(node.params)
        return VStack(alignment: .leading, spacing: 4) {
            Toggle("Transcribe as it records", isOn: Binding(get: { transcribes }, set: { on in
                var params = node.params
                params["transcribe"] = .bool(on)
                change(["transcribe": .bool(on)], showing: params)
            }))
            Toggle("Who said what", isOn: Binding(get: { Recording.labelsSpeakers(node.params) }, set: { on in
                var params = node.params
                params["speakers"] = .bool(on)
                change(["speakers": .bool(on)], showing: params)
            }))
            .disabled(!transcribes)
            .help("Who tells the voices apart as it records")
            Toggle("Keep the recording", isOn: Binding(get: { Recording.keeps(node.params) }, set: { on in
                var params = node.params
                params["keep"] = .bool(on)
                change(["keep": .bool(on)], showing: params)
            }))
            .disabled(!transcribes)
            .help(transcribes ? "Without it, only the words are kept" : "Without a transcript, the recording is what the step gives")
        }
        .font(.callout)
        .toggleStyle(.checkbox)
    }

    /// Changes the settings, and shows the outputs that go with them.
    private func change(_ patch: Params, showing params: Params) {
        var patch = patch
        patch["fields"] = Recording.fields(params)
        actions.set(node.id, patch)
    }

    private func use(_ take: Take) {
        actions.set(node.id, Recording.params(take))
    }

    private func toggle(_ recorder: Recorder, _ meeting: MeetingRecorder) {
        error = nil
        if meeting.recording {
            Task {
                do { try await meeting.stop() } catch { self.error = error.localizedDescription }
            }
            return
        }
        if recorder.recording {
            Task { await recorder.stop() }
            return
        }
        let use = use
        let options = Recording.options(node.params)
        if !isMeeting {
            Task { error = await startMicrophone(recorder, options, use: use) }
            return
        }
        Task {
            guard await MeetingPermissions.ask().microphone else {
                error = Recorder.noAccess
                return
            }
            do {
                try await meeting.start(options) { if !$0.isEmpty { use($0) } }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// The words Voz has written so far, the last few lines, with the words it
/// may still change in a lighter tone.
struct LiveTranscriptView: View {
    let transcript: LiveTranscript

    var body: some View {
        Group {
            if let failure = transcript.failure {
                Text(failure).foregroundStyle(Theme.danger)
            } else if transcript.text.isEmpty {
                Text("Listening…").foregroundStyle(.secondary)
            } else {
                Text("\(Text(String(transcript.committed.suffix(400))))\(Text(transcript.committed.isEmpty ? "" : " "))\(Text(transcript.tentative).foregroundStyle(.secondary))")
            }
        }
        .font(.callout)
        .lineLimit(3)
        .truncationMode(.head)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.smooth(duration: 0.2), value: transcript.text)
    }
}

/// The last few seconds of what the microphone heard, newest on the right.
struct LiveWaveform: View {
    let levels: [Double]

    var body: some View {
        Canvas { ctx, size in
            let gap: CGFloat = 3, width: CGFloat = 2
            let fit = Int(size.width / gap)
            let shown = levels.suffix(fit)
            var x = size.width - CGFloat(shown.count) * gap
            for level in shown {
                let h = max(2, CGFloat(level) * size.height)
                let bar = CGRect(x: x, y: (size.height - h) / 2, width: width, height: h)
                ctx.fill(Path(roundedRect: bar, cornerRadius: 1), with: .color(Theme.danger))
                x += gap
            }
        }
    }
}

/// Which microphone Record listens to. The choice belongs to this Mac, not
/// to the flow, which may open on a Mac with other microphones.
struct MicrophoneMenu: View {
    @AppStorage(Recorder.deviceKey) private var chosen = ""

    var body: some View {
        let devices = Recorder.devices
        let current = devices.first { $0.uniqueID == chosen } ?? Recorder.device
        ChoiceMenu {
            HStack(spacing: 5) {
                Image(systemName: "mic")
                Text(current?.localizedName ?? (Demo.active ? Demo.microphone : "No microphone"))
            }
            .font(.caption)
        } content: {
            Picker("", selection: $chosen) {
                Text("Mac's default").tag("")
                Divider()
                ForEach(devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .help("The microphone to record from")
    }
}

/// A labeled meter, for the two sides of a meeting.
struct LevelBar: View {
    let label: String
    let level: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            Capsule().fill(.primary.opacity(0.1))
                .frame(height: 5)
                .overlay(alignment: .leading) {
                    GeometryReader { g in Capsule().fill(Theme.danger).frame(width: g.size.width * level) }
                }
        }
    }
}

/// What a meeting needs from macOS, each with a check or a way to allow it.
/// Flow asks only when you start a meeting, click Allow, or turn on a flow
/// that records one, never just because a meeting step is on screen.
struct MeetingPermissions: View {
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var system = MeetingRecorder.mayRecordSystemAudio
    @State private var asked = Self.askedThisLaunch
    private static var askedThisLaunch = false

    /// Asks macOS for both, which brings up its dialogs the first time.
    @discardableResult
    static func ask() async -> (microphone: Bool, system: Bool) {
        askedThisLaunch = true
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        return (microphone, await MeetingRecorder.askForSystemAudio())
    }

    /// Whether a flow records a meeting when it runs on its own.
    static func needed(by graph: Graph) -> Bool {
        graph.nodes.contains { $0.type == "call" || ($0.type == "record" && Recording.isMeeting($0.params)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Side by side when the card has room, one under the other when not.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { items }
                VStack(alignment: .leading, spacing: 4) { items }
            }
            if asked && !system {
                HStack(spacing: 4) {
                    Text("Turn on Flow under Screen and System Audio Recording, then reopen Flow.")
                    Button("Open System Settings") { NSWorkspace.shared.open(MeetingRecorder.settingsURL) }.buttonStyle(.link)
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        // macOS's dialogs and System Settings both take Flow out of focus, so
        // coming back is when the answer may have changed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            system = MeetingRecorder.mayRecordSystemAudio
            asked = Self.askedThisLaunch
        }
    }

    @ViewBuilder private var items: some View {
        item("Microphone", allowed: microphone) {
            Task { microphone = await AVCaptureDevice.requestAccess(for: .audio) }
        }
        item("System audio", allowed: system) {
            Task { await askForSystemAudio() }
        }
    }

    private func askForSystemAudio() async {
        Self.askedThisLaunch = true
        system = await MeetingRecorder.askForSystemAudio()
        asked = true
    }

    @ViewBuilder
    private func item(_ name: String, allowed: Bool, allow: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: allowed ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(allowed ? Theme.success : Theme.danger)
            Text(name)
            if !allowed { Button("Allow…", action: allow).buttonStyle(.link) }
        }
        .fixedSize()
        .help(allowed ? "\(name) is allowed" : "Flow needs this to record a meeting")
    }
}

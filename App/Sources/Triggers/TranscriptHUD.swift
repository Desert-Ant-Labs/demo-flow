import AppKit
import Observation
import SwiftUI

/// A call's words in a window of their own, opened from the floater: dark,
/// see-through, and blurring what is behind it, over every app and space, wherever it was dragged and as large
/// as it was made. The words grow with ⌘+ or a pinch and shrink with ⌘−, and
/// the window goes when the call ends. Clicking it leaves the call app in front.
@MainActor
@Observable
final class TranscriptHUD {
    static let shared = TranscriptHUD()
    /// It has the keyboard, to type a name or to close it with Escape.
    private(set) var isKey = false
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private weak var run: FlowRun?
    /// Counts the opens, so a call followed by an earlier open is let go.
    @ObservationIgnored private var generation = 0
    /// The app that had the keyboard before a name was typed, to give it back.
    @ObservationIgnored private var previous: NSRunningApplication?

    private init() {}

    var isOpen: Bool { panel?.isVisible == true }

    func toggle(_ run: FlowRun) {
        if isOpen, self.run === run { close() } else { open(run) }
    }

    func open(_ run: FlowRun) {
        guard case .recording = run.phase, let transcript = run.transcript else { return }
        self.run = run
        let panel = panel ?? makePanel()
        self.panel = panel
        // What is behind it blurs, so the words read over any window while it stays see-through.
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        let words = FirstClickHostingView(rootView: TranscriptHUDView(run: run, transcript: transcript))
        words.frame = blur.bounds
        words.autoresizingMask = [.width, .height]
        blur.addSubview(words)
        panel.contentView = blur
        panel.orderFrontRegardless()
        generation += 1
        follow(run, generation)
    }

    func close() {
        run = nil
        generation += 1
        unfocus()
        panel?.orderOut(nil)
        // The words stop being drawn, and stop following the transcript, until it opens again.
        panel?.contentView = nil
    }

    /// Takes the keyboard, to type a name, without bringing Flow forward.
    func focus() {
        guard let panel else { return }
        let front = NSWorkspace.shared.frontmostApplication
        previous = front == .current ? nil : front
        panel.makeKey()
    }

    /// Gives the keyboard back to the app that had it, so a key pressed next
    /// reaches the call and not the words.
    func unfocus() {
        guard let panel, panel.isKeyWindow else { return }
        panel.resignKey()
        if let previous {
            NSApp.yieldActivation(to: previous)
            previous.activate()
        }
        previous = nil
    }

    /// Closes once the call stops recording.
    private func follow(_ run: FlowRun, _ generation: Int) {
        withObservationTracking {
            _ = run.phase
            _ = run.transcript
        } onChange: {
            Task { @MainActor in
                let hud = TranscriptHUD.shared
                guard hud.generation == generation, hud.run === run else { return }
                if case .recording = run.phase, run.transcript != nil { hud.follow(run, generation) } else { hud.close() }
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 240),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Transcript"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 280, height: 120)
        panel.appearance = NSAppearance(named: .darkAqua)
        // Low in the middle of the screen, as subtitles are, until it is moved.
        let visible = (Snapshots.sharpScreen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.midX - 280, y: visible.minY + 80))
        panel.setFrameAutosaveName("Transcript")
        for (name, key) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { _ in
                MainActor.assumeIsolated { TranscriptHUD.shared.isKey = key }
            }
        }
        return panel
    }
}

struct TranscriptHUDView: View {
    let run: FlowRun
    let transcript: LiveTranscript
    @AppStorage("transcript.size") private var size = 22.0
    @State private var hovering = false
    @State private var pinch = 1.0
    /// The voice being named.
    @State private var naming: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let sizes = 14.0...56.0

    private var shown: Double { min(max(size * pinch, Self.sizes.lowerBound), Self.sizes.upperBound) }

    var body: some View {
        let names = transcript.names
        let paragraphs = transcript.paragraphs
        ScrollView {
            // Not lazy: rows of wrapping text not yet drawn would be guessed
            // at, and the words held at the bottom would jump as they grow.
            VStack(alignment: .leading, spacing: shown * 0.7) {
                if paragraphs.isEmpty {
                    Text(transcript.failure ?? "Listening…")
                        .font(.system(size: shown, weight: .medium))
                        .foregroundStyle(Color.cream.opacity(0.5))
                }
                ForEach(paragraphs) { paragraph in
                    ParagraphView(paragraph: paragraph, name: paragraph.speaker.map { Speakers.name($0, names) }, size: shown) {
                        guard let speaker = paragraph.speaker else { return }
                        TranscriptHUD.shared.focus()
                        withAnimation(Floater.spring) { naming = speaker }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 44)
            .padding(.bottom, naming == nil ? 20 : 150)
            // Each new word, counted rather than compared.
            .animation(.smooth(duration: 0.25), value: transcript.said.count)
        }
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(hovering ? .automatic : .hidden)
        // Older words fade out at the top instead of being cut.
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.22)], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .top) { header }
        .overlay(alignment: .bottom) {
            if let speaker = naming {
                NameVoice(speaker: speaker, transcript: transcript, done: stopNaming)
                    .id(speaker)
                    .padding(10)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color.ink.opacity(0.4))
        .ignoresSafeArea()
        .onHover { hovering = $0 }
        .gesture(MagnifyGesture()
            .onChanged { pinch = $0.magnification }
            .onEnded { _ in
                size = shown
                pinch = 1
            })
        .environment(\.colorScheme, .dark)
        // Escape lets go of a name being typed first, then closes.
        .onExitCommand { if naming != nil { stopNaming() } else { TranscriptHUD.shared.close() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcript of \(run.recordingTitle ?? run.title)")
        .accessibilityAction(named: "Close") { TranscriptHUD.shared.close() }
        .accessibilityAction(named: "Larger words") { step(1.15) }
        .accessibilityAction(named: "Smaller words") { step(1 / 1.15) }
        .task {
            // FLOW_DEMO_HUD=naming shows naming the second voice on the call, for screenshots.
            guard ProcessInfo.processInfo.environment["FLOW_DEMO_HUD"] == "naming" else { return }
            try? await Task.sleep(for: .seconds(14))
            withAnimation(Floater.spring) { naming = Side.call.first + 1 }
        }
    }

    /// The call, how long it has gone, and the controls, shown while the
    /// pointer is over it or it has the keyboard.
    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.clayRed).frame(width: 8, height: 8)
            Text(run.recordingTitle ?? run.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.cream)
                .lineLimit(1)
            Text(run.since, style: .timer)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Color.cream.opacity(0.6))
            Spacer(minLength: 8)
            QuietButton(symbol: "textformat.size.smaller", help: "Smaller words") { step(1 / 1.15) }
                .keyboardShortcut("-", modifiers: .command)
            QuietButton(symbol: "textformat.size.larger", help: "Larger words") { step(1.15) }
                .keyboardShortcut("=", modifiers: .command)
            QuietButton(symbol: "xmark", help: "Close the transcript") { TranscriptHUD.shared.close() }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(LinearGradient(colors: [Color.ink.opacity(0.7), Color.ink.opacity(0)], startPoint: .top, endPoint: .bottom))
        .opacity(hovering || TranscriptHUD.shared.isKey ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: hovering || TranscriptHUD.shared.isKey)
    }

    /// Done naming, saved or not: the keyboard goes back to the call.
    private func stopNaming() {
        withAnimation(Floater.spring) { naming = nil }
        TranscriptHUD.shared.unfocus()
    }

    private func step(_ factor: Double) {
        size = min(max((size * factor).rounded(), Self.sizes.lowerBound), Self.sizes.upperBound)
    }
}

/// Light brand tones that read on the dark glass, one per voice: the
/// room's from the first, the call's from the second, so you and the first
/// guest never share one.
private func voiceColor(_ speaker: Int) -> Color {
    let tones: [UInt32] = [0xF8DBCA, 0xC3D3CE, 0xD6D0C3, 0xADB49C, 0xE9A88C]
    let side = Side.of(speaker)
    return Theme.rgb(tones[(speaker - side.first + side.rawValue) % tones.count])
}

/// One voice's words: its name in its own color, which renames it when
/// clicked, then the words, with the ones Voz may still change dimmer.
private struct ParagraphView: View {
    let paragraph: LiveTranscript.Paragraph
    let name: String?
    let size: Double
    let rename: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.15) {
            if let speaker = paragraph.speaker, let name {
                Button(action: rename) {
                    HStack(spacing: 5) {
                        Text(name)
                        Image(systemName: "pencil")
                            .font(.system(size: max(9, size * 0.45), weight: .bold))
                            .opacity(hovering ? 0.9 : 0)
                    }
                    .font(.system(size: max(11, size * 0.6), weight: .semibold))
                    .foregroundStyle(voiceColor(speaker))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .pointerStyle(.link)
                .help("Name this voice")
            }
            let settled = paragraph.settled.joined(separator: " ")
            let tentative = paragraph.tentative.joined(separator: " ")
            Text("\(Text(settled))\(Text(settled.isEmpty || tentative.isEmpty ? "" : " "))\(Text(tentative).foregroundStyle(Color.cream.opacity(0.55)))")
                .font(.system(size: size, weight: .medium))
                .lineSpacing(size * 0.18)
                .foregroundStyle(Color.cream)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
    }
}

/// Names one voice, at the bottom of the window where it stays put while
/// the words go on: what the voice said last, to tell which one it is, a
/// field for the name, and the people invited to the call to pick from.
private struct NameVoice: View {
    let speaker: Int
    let transcript: LiveTranscript
    let done: () -> Void
    @State private var name = ""
    @FocusState private var focused: Bool

    /// The voice's last words.
    private var said: String? {
        guard let last = transcript.paragraphs.last(where: { $0.speaker == speaker }) else { return nil }
        let words = last.settled + last.tentative
        return (words.count > 12 ? "…" : "") + words.suffix(12).joined(separator: " ")
    }

    /// Who could it be: the guests, and you, not yet given to another voice.
    private var suggestions: [String] {
        let taken = Set(transcript.names.filter { $0.key != speaker }.values)
        return (transcript.guests + ["You"]).filter { !taken.contains($0) && $0 != transcript.names[speaker] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(voiceColor(speaker)).frame(width: 10, height: 10)
                TextField("Name", text: $name, prompt: Text(transcript.names[speaker] ?? "Name").foregroundStyle(Color.cream.opacity(0.4)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.cream)
                    .focused($focused)
                    .onSubmit { save(name) }
                    .onExitCommand(perform: done)
                Button("Done") { save(name) }
                    .buttonStyle(GlassCapsuleButtonStyle())
                QuietButton(symbol: "xmark", help: "Cancel", action: done)
            }
            if let said {
                Text("“\(said)”")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.cream.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if !suggestions.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { person in
                            Button { save(person) } label: {
                                Text(person)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.cream)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.cream.opacity(0.12), in: .capsule)
                                    .contentShape(.capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.ink.opacity(0.85), in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.cream.opacity(0.12)))
        .onAppear {
            name = transcript.given[speaker] ?? ""
            focused = true
        }
    }

    private func save(_ name: String) {
        transcript.rename(speaker, to: name)
        done()
    }
}

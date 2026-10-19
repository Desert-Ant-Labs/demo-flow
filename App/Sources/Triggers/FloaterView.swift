import SwiftUI

struct FloaterView: View {
    let floater: Floater
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The circle sits beside the pill's first line, or its last when it opens upward.
        HStack(alignment: floater.opensDown ? .top : .bottom, spacing: 8) {
            if floater.opensLeft { side }
            circle
                .overlay {
                    if floater.targeted {
                        Circle().strokeBorder(Color.brandAccent, lineWidth: 2.5).padding(-3)
                    }
                }
                .scaleEffect(floater.targeted ? 1.12 : 1)
                .onTapGesture { floater.tap() }
                .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { _ in floater.dragged() }
                    .onEnded { _ in floater.dropped() })
                .frame(height: Floater.row)
            if !floater.opensLeft { side }
        }
        .onHover { floater.hover($0) }
        .padding(Floater.margin)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            floater.drop(files)
            return true
        } isTargeted: { floater.target($0) }
        .scaleEffect(floater.shown || reduceMotion ? 1 : 0.6)
        .opacity(floater.shown ? 1 : 0)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var circle: some View {
        if let run = floater.run, floater.offer == nil {
            FloaterCircle(run: run, others: floater.others, levels: floater.levels)
        } else {
            RestingCircle()
        }
    }

    @ViewBuilder private var side: some View {
        if floater.expanded {
            Group {
                if let offer = floater.offer {
                    DropChooser(offer: offer, floater: floater)
                } else if let run = floater.run {
                    FloaterPill(run: run)
                } else {
                    RestingPill()
                }
            }
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .scale(scale: 0.85, anchor: floater.opensLeft ? .trailing : .leading).combined(with: .opacity),
                removal: .opacity))
        }
    }
}

/// The circle between runs: the ant mark, waiting for files.
private struct RestingCircle: View {
    var body: some View {
        AntMark()
            .fill(Color.cream.opacity(0.9))
            .frame(width: 12, height: 13)
            .frame(width: Floater.circle, height: Floater.circle)
            .background(Color.ink.opacity(0.55), in: .circle)
            .glassEffect(.regular.tint(Color.ink.opacity(0.85)), in: .circle)
            .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
            .contentShape(.circle)
            .accessibilityLabel("Flow")
            .accessibilityAddTraits(.isButton)
    }
}

/// What the resting circle says on hover.
private struct RestingPill: View {
    var body: some View {
        HStack(spacing: 12) {
            Badge(symbol: "arrow.down.doc", size: 30)
            Text("Drop files here to run a flow on them")
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Color.cream)
                .fixedSize()
            QuietButton(symbol: "list.bullet", help: "Show in the menu bar") { MenuBarPanel.open() }
        }
        .floaterPill()
    }
}

/// The flows that can take the dropped files, one click each.
private struct DropChooser: View {
    let offer: DropOffer
    let floater: Floater

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Badge(symbol: "arrow.down.doc", size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(offer.choices.isEmpty ? "No flow takes these files" : "Run a flow on \(offer.what)")
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(Color.cream)
                    if offer.choices.isEmpty {
                        Text("Flows start from photos, recordings, or text.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.cream.opacity(0.6))
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: 260, alignment: .leading)
                Spacer(minLength: 4)
                QuietButton(symbol: "xmark", help: "Cancel") { floater.cancelOffer() }
            }
            if !offer.choices.isEmpty {
                VStack(spacing: 2) {
                    ForEach(offer.choices) { choice in
                        ChoiceRow(choice: choice, first: choice == offer.choices.first) { floater.choose(choice) }
                    }
                }
                .padding(.leading, 36)
            }
        }
        .frame(width: 330, alignment: .leading)
        .floaterPill()
    }
}

private struct ChoiceRow: View {
    let choice: DropOffer.Choice
    let first: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(choice.title)
                    .font(.system(size: 12, weight: first ? .semibold : .medium))
                    .foregroundStyle(Color.cream.opacity(hovering || first ? 1 : 0.8))
                    .lineLimit(1)
                Spacer(minLength: 6)
                HStack(spacing: 3) {
                    ForEach(choice.models.prefix(3)) { m in
                        Circle().fill(Theme.model(m).fill).frame(width: 6, height: 6)
                            .overlay(Circle().strokeBorder(Color.cream.opacity(0.35), lineWidth: 0.5))
                    }
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.cream.opacity(hovering ? 0.9 : 0.35))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.cream.opacity(hovering ? 0.12 : first ? 0.06 : 0), in: .rect(cornerRadius: 10))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension View {
    /// The dark glass pill the floater opens into, as Redactor's.
    func floaterPill() -> some View {
        padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .fixedSize()
            .background(Color.ink.opacity(0.55), in: .rect(cornerRadius: 22))
            .glassEffect(.regular.tint(Color.ink.opacity(0.85)), in: .rect(cornerRadius: 22))
            .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
    }
}

/// The circle: dark glass with the state inside, and red while it records,
/// as the badge in the pill is.
private struct FloaterCircle: View {
    let run: FlowRun
    let others: Int
    let levels: Levels

    private var recording: Bool {
        if case .recording = run.phase { true } else { false }
    }

    var body: some View {
        ZStack {
            switch run.phase {
            case .recording:
                LevelBars(levels: levels.history)
            case .running where run.question != nil:
                Image(systemName: "questionmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.cream)
            case .running:
                ProgressRing(progress: run.progress, size: Floater.circle - 6, line: 2.5)
                AntMark().fill(Color.cream).frame(width: 12, height: 13)
            case .finished:
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.cream)
            case .failed:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.ember)
            }
        }
        .frame(width: Floater.circle, height: Floater.circle)
        .contentTransition(.symbolEffect(.replace))
        .background(recording ? Color.clayRed : Color.ink.opacity(0.55), in: .circle)
        .glassEffect(recording ? .identity : .regular.tint(Color.ink.opacity(0.85)), in: .circle)
        .overlay(alignment: .topLeading) {
            if others > 0 {
                Text("\(others + 1)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.ink)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Color.cream, in: .capsule)
                    .offset(x: -4, y: -4)
            }
        }
        .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
        .contentShape(.circle)
        .animation(Floater.spring, value: run.phase)
        .help(run.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(run.title), \(run.state)")
        .accessibilityAddTraits(.isButton)
    }
}

/// Five bars of the call's loudness, newest on the right. With Reduce
/// Motion they hold still in a fixed wave, since they would otherwise move
/// for as long as the call goes.
private struct LevelBars: View {
    let levels: [Double]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let still = [0.25, 0.6, 0.9, 0.6, 0.25]

    var body: some View {
        let levels = reduceMotion ? Self.still : levels
        HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.cream)
                    .frame(width: 2.5, height: 4 + 12 * levels[i])
            }
        }
        .frame(height: 16)
        .animation(reduceMotion ? nil : .smooth(duration: 0.12), value: levels)
    }
}

/// The words and the actions, in Redactor's pill: a round badge, one bold
/// line, a glass capsule button, and a quiet close.
private struct FloaterPill: View {
    let run: FlowRun
    private var center: TriggerCenter { .shared }

    var body: some View {
        if let question = run.question {
            FloaterQuestion(run: run, question: question)
        } else {
            progress
        }
    }

    private var progress: some View {
        HStack(spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 2) {
                line
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Color.cream)
                if case .failed(let reason) = run.phase {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.cream.opacity(0.65))
                        .lineLimit(2)
                        .frame(maxWidth: 240, alignment: .leading)
                }
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 4)
            actions
        }
        .floaterPill()
    }

    @ViewBuilder private var badge: some View {
        switch run.phase {
        case .recording:
            Badge(symbol: "waveform", size: 30, disc: .clayRed, ink: .cream)
        case .running:
            ZStack {
                Circle().fill(Color.cream)
                ProgressRing(progress: run.progress, size: 20, line: 2, color: .ink)
            }
            .frame(width: 30, height: 30)
        case .finished:
            if let thumbnail = run.thumbnail, let image = NSImage(contentsOf: thumbnail) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 30, height: 30)
                    .clipShape(.circle)
                    .overlay(Circle().strokeBorder(Color.cream.opacity(0.25)))
            } else {
                Badge(symbol: "checkmark", size: 30)
            }
        case .failed:
            Badge(symbol: "exclamationmark", size: 30, disc: .ember, ink: .ink)
        }
    }


    @ViewBuilder private var line: some View {
        switch run.phase {
        case .recording(let app):
            HStack(spacing: 6) {
                Text(run.recordingTitle ?? app)
                Text(run.since, style: .timer)
                    .monospacedDigit()
                    .foregroundStyle(Color.cream.opacity(0.6))
            }
        case .running:
            HStack(spacing: 6) {
                Text(run.isCall ? "Making notes" : run.title)
                Text(run.detail ?? run.step ?? "\(Int(run.progress * 100))%")
                    .foregroundStyle(Color.cream.opacity(0.6))
                    .monospacedDigit()
            }
        case .finished(let summary):
            HStack(spacing: 6) {
                Text(run.title)
                Text(summary).foregroundStyle(Color.cream.opacity(0.6))
            }
            .frame(maxWidth: 300, alignment: .leading)
        case .failed:
            Text("\(run.title) stopped")
        }
    }

    @ViewBuilder private var actions: some View {
        switch run.phase {
        case .recording:
            if run.transcript != nil {
                QuietButton(symbol: "captions.bubble", help: "Show the words as they are said") { TranscriptHUD.shared.toggle(run) }
            }
            Button("Stop") { center.stop(run) }
                .buttonStyle(GlassCapsuleButtonStyle())
                .help("Stop recording and run \(run.title)")
            QuietButton(symbol: "trash", help: "Discard the recording") { center.discard(run) }
        case .running:
            QuietButton(symbol: "list.bullet", help: "Show in the menu bar") { MenuBarPanel.open() }
        case .finished:
            if run.canUndo {
                QuietTextButton(title: "Undo", help: "Put the files back as they were") { center.undo(run) }
            }
            if run.file != nil || !run.result.isEmpty {
                Button("Open") { center.openResult(run); Floater.shared.finish() }
                    .buttonStyle(GlassCapsuleButtonStyle())
            }
            QuietButton(symbol: "xmark", help: "Dismiss") { Floater.shared.finish() }
        case .failed:
            Button("Try again") { center.retry(run) }
                .buttonStyle(GlassCapsuleButtonStyle())
            QuietButton(symbol: "xmark", help: "Dismiss") { Floater.shared.finish() }
        }
    }
}

/// A run's question in the pill. Yes and No, and a few short answers, are a
/// click here; picking items or typing opens the review window, since the
/// pill never takes the keyboard from the app in front.
private struct FloaterQuestion: View {
    let run: FlowRun
    let question: Question

    /// Answers that fit in the pill as buttons.
    private var inline: [String]? {
        guard question.kind == .choose, question.options.count <= 3,
              question.options.allSatisfy({ $0.count <= 14 }) else { return nil }
        return question.options
    }

    var body: some View {
        HStack(spacing: 12) {
            Badge(symbol: "questionmark", size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(question.text)
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Color.cream)
                    .lineLimit(2)
                Text([run.title, question.about].compactMap { $0 }.joined(separator: " \u{00B7} "))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.cream.opacity(0.6))
                    .lineLimit(1)
            }
            .frame(maxWidth: 260, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            actions
        }
        .floaterPill()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(run.title) asks: \(question.text)")
    }

    @ViewBuilder private var actions: some View {
        switch question.kind {
        case .confirm:
            if !question.items.isEmpty {
                QuietButton(symbol: "rectangle.expand.vertical", help: "Show what it asks about") { AskWindow.shared.show(run) }
            }
            QuietTextButton(title: "No", help: "Answer no") { run.answer(.no) }
            Button("Yes") { run.answer(.yes) }
                .buttonStyle(GlassCapsuleButtonStyle())
        case .choose where inline != nil:
            ForEach(inline ?? [], id: \.self) { option in
                Button(option) { run.answer(.chose(option)) }
                    .buttonStyle(GlassCapsuleButtonStyle())
            }
        case .pick, .choose, .type:
            Button(question.kind == .type ? "Answer" : "Review") { AskWindow.shared.show(run) }
                .buttonStyle(GlassCapsuleButtonStyle())
        }
        QuietButton(symbol: "stop.fill", help: "Stop \(run.title)") { run.answer(.stop) }
    }
}

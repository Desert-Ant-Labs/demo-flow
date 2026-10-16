import AppKit
import os
import SwiftUI

/// The menu bar icon: the ant when nothing runs, a ring that fills while a
/// flow runs out of sight, and a record mark while a call is recorded. It
/// redraws only when `TriggerCenter.indicator` changes; a clock in the label
/// itself keeps the menu bar laying out without end.
struct MenuBarLabel: View {
    var body: some View {
        let indicator = TriggerCenter.shared.indicator
        Group {
            switch indicator {
            case .idle: Image(nsImage: AntMark.menuImage)
            case .recording: Image(systemName: "record.circle")
            case .progress(let step): Image(nsImage: Ring.images[step])
            }
        }
        .accessibilityLabel("Desert Ant Flow")
        .accessibilityValue(indicator == .recording ? "Recording" : indicator == .idle ? "" : "Running a flow")
    }
}

/// Opens the menu bar panel, as a click on the menu bar icon would. SwiftUI
/// has no way to open a `MenuBarExtra` window, so this clicks the status
/// item's button, found in the window AppKit puts it in. That window and
/// button are not public; if a later macOS draws them otherwise, nothing
/// opens, which is logged, and the icon in the menu bar still works.
enum MenuBarPanel {
    private static let log = Logger(subsystem: "com.desertant.flow", category: "menu")

    @MainActor static func open() {
        for window in NSApp.windows where window.className.contains("StatusBar") {
            if let button = find(in: window.contentView) {
                button.performClick(nil)
                return
            }
        }
        log.error("The menu bar icon's button was not found, so the menu did not open")
    }

    @MainActor private static func find(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton { return button }
        return view.subviews.lazy.compactMap { find(in: $0) }.first
    }
}

/// A small progress ring for the menu bar, drawn as a template image so it
/// takes the menu bar's color.
enum Ring {
    static let steps = 12
    static let images = (0...steps).map { image(Double($0) / Double(steps)) }

    private static func image(_ progress: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let inset = rect.insetBy(dx: 1.5, dy: 1.5)
            let track = NSBezierPath(ovalIn: inset)
            track.lineWidth = 2
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: inset.width / 2,
                          startAngle: 90, endAngle: 90 - 360 * max(0.04, progress), clockwise: true)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

extension TriggerCenter {
    enum Indicator: Equatable {
        case idle
        case recording
        /// How far, in twelfths, so the icon changes only when it shows.
        case progress(Int)
    }

    /// What the menu bar icon shows now: a call being recorded, how far the
    /// flows running out of sight are together, or nothing.
    func currentIndicator() -> Indicator {
        if runs.contains(where: { $0.app != nil }) { return .recording }
        let engines = runs.filter { $0.phase == .running }.compactMap(\.engine) + unseen.map(\.engine)
        guard !engines.isEmpty else { return .idle }
        let progress = engines.map(\.progress).reduce(0, +) / Double(engines.count)
        return .progress(Int((progress * Double(Ring.steps)).rounded(.down)))
    }
}

/// The menu, in Redactor's language: the mark and the name, a card for each
/// run that is live, the recent results, and a quiet footer.
struct MenuBarView: View {
    @Bindable private var center = TriggerCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Header(paused: $center.paused)
            let live = center.live
            if live.isEmpty && center.unseen.isEmpty {
                IdleCard(triggers: center.triggers)
            } else {
                ForEach(live) { RunCard(run: $0) }
                ForEach(center.unseen.map { (ObjectIdentifier($0), $0) }, id: \.0) { WindowCard(session: $0.1) }
            }
            ShortcutRows()
            if !center.history.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.cream.opacity(0.5))
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                    ForEach(center.history.prefix(4)) { RecentRow(record: $0) }
                }
            }
            DropRow()
            Divider().overlay(Color.cream.opacity(0.12))
            Footer()
        }
        .padding(16)
        .frame(width: 340)
        .foregroundStyle(Color.cream)
        // The system menu material is gray under any text; ink matches the floater.
        .background(Color.ink.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }
}

private struct Header: View {
    @Binding var paused: Bool

    var body: some View {
        HStack(spacing: 8) {
            AntMark().fill(Color.cream).frame(width: 12, height: 13)
            Text("Flow")
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.4)
            Spacer()
            Segments(options: [(false, "On"), (true, "Paused")], selection: $paused)
                .fixedSize()
                .help("Pause every flow that runs on its own")
        }
    }
}

/// Two or three choices as a glass thumb on a soft track, as Redactor's mode picker.
private struct Segments<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                Button { selection = value } label: {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.cream.opacity(selection == value ? 1 : 0.55))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background {
                            if selection == value {
                                Capsule()
                                    .fill(Color.cream.opacity(0.14))
                                    .glassEffect(.regular, in: .capsule)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.cream.opacity(0.08), in: .capsule)
        .animation(.smooth(duration: 0.25), value: selection)
    }
}

/// One card: a round badge, a title and a line under it, and an action.
private struct Card<Leading: View, Actions: View>: View {
    let title: String
    let detail: Text?
    @ViewBuilder let leading: Leading
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            leading.frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(-0.2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    detail
                        .font(.caption)
                        .foregroundStyle(Color.cream.opacity(0.65))
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cream.opacity(0.07), in: .rect(cornerRadius: 14))
    }
}

private struct IdleCard: View {
    let triggers: [Trigger]
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let on = triggers.filter(\.on).count
        Card(title: "Nothing running",
             detail: Text(on == 0 ? "No flows run on their own yet" : on == 1 ? "1 flow runs on its own" : "\(on) flows run on their own")) {
            Badge(symbol: "checkmark", size: 34, disc: .sage, ink: .ink)
        } actions: {
            Button("Library") { NSApp.activate(); openWindow(id: "library") }
                .buttonStyle(GlassCapsuleButtonStyle())
        }
    }
}

private struct RunCard: View {
    let run: FlowRun
    private var center: TriggerCenter { .shared }

    var body: some View {
        switch run.phase {
        case .recording(let app):
            Card(title: run.recordingTitle ?? app, detail: Text("Recording, \(Text(run.since, style: .timer))")) {
                Badge(symbol: "waveform", size: 34, disc: .clayRed, ink: .cream)
            } actions: {
                HStack(spacing: 4) {
                    Button("Stop") { center.stop(run) }.buttonStyle(GlassCapsuleButtonStyle())
                    QuietButton(symbol: "trash", help: "Discard the recording") { center.discard(run) }
                }
            }
        case .running:
            Card(title: run.title, detail: Text([run.step, run.detail].compactMap { $0 }.joined(separator: ", ").nonEmpty ?? "Starting")) {
                ZStack {
                    Circle().fill(Color.cream.opacity(0.1))
                    ProgressRing(progress: run.progress, size: 26, line: 2.5)
                }
            } actions: {
                Text("\(Int(run.progress * 100))%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.cream.opacity(0.65))
            }
        case .finished, .failed:
            EmptyView()
        }
    }
}

/// The flows that start with a shortcut, with their keys: pressing one here
/// does what the keys do anywhere.
private struct ShortcutRows: View {
    private var center: TriggerCenter { .shared }

    var body: some View {
        let shortcuts = center.triggers.compactMap { t -> (Trigger, Shortcut)? in
            guard t.on, case .shortcut(let keys?, _) = t.event else { return nil }
            return (t, keys)
        }
        if !shortcuts.isEmpty {
            VStack(spacing: 4) {
                ForEach(shortcuts, id: \.0.id) { trigger, keys in
                    ShortcutRow(title: trigger.flow.title, keys: keys, recording: center.runs.contains { $0.live && $0.trigger.id == trigger.id && $0.app != nil }) {
                        center.pressed(trigger.id)
                    }
                }
            }
        }
    }
}

private struct ShortcutRow: View {
    let title: String
    let keys: Shortcut
    let recording: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Badge(symbol: recording ? "stop.fill" : "command", size: 30, disc: .cream.opacity(0.12), ink: .cream)
                Text(recording ? "Stop \(title)" : title)
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(-0.2)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(keys.display)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.cream.opacity(0.6))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.cream.opacity(0.1), in: .rect(cornerRadius: 6))
            }
            .padding(10)
            .background(Color.cream.opacity(hovering ? 0.1 : 0.07), in: .rect(cornerRadius: 14))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
    }
}

/// Files dropped here go to the chooser of flows that can take them.
private struct DropRow: View {
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 12, weight: .semibold))
            Text("Drop files to run a flow")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(Color.cream.opacity(targeted ? 0.9 : 0.5))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.cream.opacity(targeted ? 0.08 : 0), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.cream.opacity(targeted ? 0.5 : 0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .animation(.smooth(duration: 0.15), value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            FlowPicker.show(for: files)
            return true
        } isTargeted: { targeted = $0 }
    }
}

/// A flow running in a window that is out of sight.
private struct WindowCard: View {
    let session: FlowSession

    var body: some View {
        Card(title: session.window?.title ?? "A flow", detail: Text("In a window out of sight")) {
            ZStack {
                Circle().fill(Color.cream.opacity(0.1))
                ProgressRing(progress: session.engine.progress, size: 26, line: 2.5)
            }
        } actions: {
            Button("Show") { session.window?.makeKeyAndOrderFront(nil); NSApp.activate() }
                .buttonStyle(GlassCapsuleButtonStyle())
        }
    }
}

private struct RecentRow: View {
    let record: RunRecord
    @State private var hovering = false

    /// Undo sits beside the row's button rather than in it, and VoiceOver
    /// has it as an action on the row, since it shows only on hover.
    var body: some View {
        HStack(spacing: 8) {
            Button { TriggerCenter.shared.openResult(record) } label: {
                HStack(spacing: 10) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 1) {
                        Text(record.title)
                            .font(.system(size: 12, weight: .semibold))
                        Text(record.summary)
                            .font(.caption)
                            .foregroundStyle(record.failed ? Color.ember : Color.cream.opacity(0.6))
                    }
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    if !undoShown {
                        Text(record.date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                            .font(.caption)
                            .foregroundStyle(Color.cream.opacity(0.45))
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityActions {
                if record.canUndo {
                    Button("Undo") { TriggerCenter.shared.undo(record) }
                }
            }
            if undoShown {
                Button("Undo") { TriggerCenter.shared.undo(record) }
                    .buttonStyle(GlassCapsuleButtonStyle())
                    .controlSize(.small)
                    .help("Put the files back as they were")
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.cream.opacity(hovering ? 0.07 : 0), in: .rect(cornerRadius: 14))
        .onHover { hovering = $0 }
    }

    private var undoShown: Bool { record.canUndo && hovering }

    @ViewBuilder private var thumbnail: some View {
        if let path = record.thumbnail, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(.circle)
        } else {
            Badge(symbol: record.failed ? "exclamationmark" : "checkmark", size: 34,
                  disc: record.failed ? .ember : .cream.opacity(0.12), ink: record.failed ? .ink : .cream)
        }
    }
}

/// A menu bar app is never active on its own, so a window it opens would
/// land behind the frontmost app without the activate.
private struct Footer: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack {
            Button("Settings…") {
                NSApp.activate()
                openSettings()
            }
            .keyboardShortcut(",")
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.cream.opacity(0.7))
        .font(.callout)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

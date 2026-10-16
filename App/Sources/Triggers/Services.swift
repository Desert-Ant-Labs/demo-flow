import AppKit
import DesertAntUI
import SwiftUI

/// The Finder's Run Flow on Files service. The files come to a small chooser
/// with the flows that can take them.
@MainActor
final class Services: NSObject {
    static let shared = Services()

    @objc func runFlow(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "No files to run a flow on" as NSString
            return
        }
        FlowPicker.show(for: urls)
    }
}

/// A flow that can take some files, for the chooser.
struct PickableFlow: Identifiable, Sendable {
    let ref: Trigger.FlowRef
    let title: String
    let models: [ModelID]
    /// How many of the files it takes.
    let takes: Int
    var id: Trigger.FlowRef { ref }

    /// The user's flows, then the templates, that take at least one of the files.
    @MainActor static func fitting(_ files: [URL]) async -> [PickableFlow] {
        let mine = await SavedFlow.recent()
        func pick(_ ref: Trigger.FlowRef, _ title: String, _ graph: Graph?) -> PickableFlow? {
            guard let graph else { return nil }
            let kinds = graph.takes
            let takes = files.filter { file in kinds.contains { $0.takes(file) } }.count
            return takes > 0 ? PickableFlow(ref: ref, title: title, models: graph.models, takes: takes) : nil
        }
        let own = mine.compactMap { saved in
            pick(.file(path: saved.url.path), saved.title, try? Trigger.FlowRef.file(path: saved.url.path).graph())
        }
        let templates = Example.all.compactMap { pick(.template(id: $0.id), $0.title, $0.graph) }
        return own + templates
    }
}

/// The chooser, in a small panel in front of whatever app the files came from.
@MainActor
enum FlowPicker {
    private static var panel: NSPanel?

    static func show(for files: [URL]) {
        panel?.close()
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView, .closable],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.contentViewController = NSHostingController(rootView: FlowPickerView(files: files) { close() })
        panel.center()
        self.panel = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    static func close() {
        panel?.close()
        panel = nil
    }
}

struct FlowPickerView: View {
    let files: [URL]
    let done: () -> Void
    @State private var flows: [PickableFlow]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                AntMark().fill(Color.cream).frame(width: 12, height: 13)
                Text("Run a flow on \(Self.describe(files))")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.4)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
            Group {
                if let flows, flows.isEmpty {
                    Text("No flow can take these files.")
                        .font(.callout)
                        .foregroundStyle(Color.cream.opacity(0.6))
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else if let flows {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(flows) { flow in
                                PickRow(flow: flow, total: files.count) {
                                    TriggerCenter.shared.run(flow.ref, on: files)
                                    done()
                                }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: 340)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 80)
                }
            }
            Divider().overlay(Color.cream.opacity(0.12))
            HStack {
                Spacer()
                Button("Cancel", action: done)
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .foregroundStyle(Color.cream.opacity(0.7))
                    .font(.callout)
            }
        }
        .padding(16)
        .padding(.top, 8)
        .frame(width: 360)
        .foregroundStyle(Color.cream)
        .background(Color.ink.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .task { flows = await PickableFlow.fitting(files) }
    }

    /// "3 photos", "a recording", "4 files".
    static func describe(_ files: [URL]) -> String {
        let kinds: [(InputKind, String, String)] = [(.photo, "a photo", "photos"), (.audio, "a recording", "recordings"), (.text, "a text", "texts")]
        for (kind, one, many) in kinds where files.allSatisfy(kind.takes) {
            return files.count == 1 ? one : "\(files.count) \(many)"
        }
        return files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
    }
}

private struct PickRow: View {
    let flow: PickableFlow
    let total: Int
    let run: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: run) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(flow.title)
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(-0.2)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        ForEach(flow.models) { m in
                            HStack(spacing: 4) {
                                Circle().fill(Theme.model(m).fill).frame(width: 7, height: 7)
                                    .overlay(Circle().strokeBorder(Color.cream.opacity(0.25)))
                                Text(m.info.name)
                            }
                        }
                        if flow.takes < total { Text("\(flow.takes) of \(total)") }
                    }
                    .font(.caption)
                    .foregroundStyle(Color.cream.opacity(0.55))
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(hovering ? 0.8 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.cream.opacity(hovering ? 0.08 : 0), in: .rect(cornerRadius: 12))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
    }
}

import AppKit
import SwiftUI

/// A window for a question from a run nobody had open: bigger photos to pick
/// from, room to type, and Return to answer. It goes once the question does.
@MainActor
final class AskWindow {
    static let shared = AskWindow()

    private var window: NSWindow?

    private init() {}

    func show(_ run: FlowRun) {
        let content = NSHostingController(rootView: AskWindowView(run: run) { [weak self] in self?.window?.close() })
        // The window keeps the size it was given or left at, rather than
        // shrinking to the smallest the question fits in.
        content.sizingOptions = []
        let window = window ?? make()
        let frame = window.frame
        window.contentViewController = content
        window.setFrame(frame, display: false)
        window.title = run.title
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func make() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 420, height: 260)
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        window.setFrameAutosaveName("Ask")
        return window
    }
}

private struct AskWindowView: View {
    let run: FlowRun
    let close: () -> Void

    var body: some View {
        Group {
            if let question = run.question {
                ScrollView {
                    QuestionView(question: question, large: true) { run.answer($0) }
                        .padding(24)
                }
            } else {
                ContentUnavailableView("Answered", systemImage: "checkmark.bubble",
                                       description: Text("\(run.title) has gone on."))
            }
        }
        .frame(minWidth: 420, maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
        .onChange(of: run.question?.id) { _, now in
            if now == nil { close() }
        }
    }
}

import AppKit
import SwiftUI

/// Hands over the window a view is in, each time it moves into one.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> Probe { Probe(found: found) }
    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
        let found: (NSWindow) -> Void

        init(found: @escaping (NSWindow) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { found(window) }
        }
    }
}

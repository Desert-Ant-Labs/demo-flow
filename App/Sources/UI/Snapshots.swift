import AppKit
import SwiftUI

/// For checking the app without a person at it: with FLOW_SNAPSHOT set to a
/// folder, the app opens FLOW_EXAMPLE (an example id or a .flow file), waits
/// FLOW_WAIT seconds for it to run, writes a picture of every window there,
/// and quits. FLOW_VIEW=steps shows the step list, FLOW_DARK=1 dark mode,
/// FLOW_KEEP=1 leaves the app open afterward, and FLOW_SCALE and FLOW_HIDPI
/// (below) make sharp pictures on a 1x display. These work in the Release
/// build, since that is the one the screenshots show, and do nothing without
/// FLOW_SNAPSHOT.
@MainActor
enum Snapshots {
    /// FLOW_SHOW=results or palette opens that too, as do settings,
    /// card-colors, automatic and runs:<path to a flow file>.
    static var show: String? {
        folder == nil ? nil : ProcessInfo.processInfo.environment["FLOW_SHOW"]
    }

    static var folder: URL? {
        ProcessInfo.processInfo.environment["FLOW_SNAPSHOT"].map { URL(filePath: $0) }
    }

    static func start() {
        guard let folder else { return }
        let env = ProcessInfo.processInfo.environment
        if let dark = env["FLOW_DARK"] { NSApp.appearance = NSAppearance(named: dark == "1" ? .darkAqua : .aqua) }
        // In the arguments domain, which outranks what is saved and is never
        // written to disk, so the view you chose is still there afterward.
        if let view = env["FLOW_VIEW"] {
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments["view"] = view
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let name = env["FLOW_EXAMPLE"], let file = flowFile(name) {
            NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { _, _, _ in }
        }
        let wait = Double(env["FLOW_WAIT"] ?? "") ?? 8
        Task {
            if env["FLOW_HIDPI"] == "1" {
                try? await Task.sleep(for: .seconds(2))
                moveToSharpestScreen()
            }
            try? await Task.sleep(for: .seconds(wait))
            capture(to: folder, tag: "final")
            // Exits rather than terminates: a sheet or a save prompt would hold up a quit.
            if env["FLOW_KEEP"] != "1" { exit(0) }
        }
    }

    /// FLOW_HIDPI=1 moves the windows to the sharpest screen, such as a virtual
    /// 2x one, so `screencapture -l` from outside the app gets 2x pixels and
    /// the Liquid Glass that `cacheDisplay` can't draw.
    static var sharpScreen: NSScreen? {
        guard folder != nil, ProcessInfo.processInfo.environment["FLOW_HIDPI"] == "1",
              let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }),
              screen.backingScaleFactor > 1 else { return nil }
        return screen
    }

    private static func moveToSharpestScreen() {
        guard let screen = sharpScreen else { return }
        // FLOW_SIZE=1100x1800 sizes the flow windows, tall enough for a whole step list.
        let given = ProcessInfo.processInfo.environment["FLOW_SIZE"]?.split(separator: "x").compactMap { Double($0) }
        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
            if let given, given.count == 2, window.title.hasSuffix(".flow") {
                window.setContentSize(NSSize(width: given[0], height: given[1]))
            }
            let size = window.frame.size, area = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
        }
    }

    /// FLOW_SCALE=2 draws at 2x on a 1x display too.
    private static func capture(to folder: URL, tag: String) {
        let scale = Double(ProcessInfo.processInfo.environment["FLOW_SCALE"] ?? "")
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = bitmap(for: view, scale: scale ?? window.backingScaleFactor) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = window.title.isEmpty ? "window-\(i)" : window.title.replacingOccurrences(of: "/", with: "-")
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(tag)-\(name).png"))
        }
    }

    private static func bitmap(for view: NSView, scale: Double) -> NSBitmapImageRep? {
        let size = view.bounds.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size
        return rep
    }

    /// A .flow or .yml path as it is, or an example's id written out as a file.
    private static func flowFile(_ name: String) -> URL? {
        if name.hasSuffix(".flow") || name.hasSuffix(".yml") { return URL(filePath: name) }
        guard let example = Example.all.first(where: { $0.id == name }) else { return nil }
        let file = FileManager.default.temporaryDirectory.appending(path: "\(name).flow")
        try? example.text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}

/// A flow's runs in a window of their own, for checking how they look:
/// FLOW_SHOW=runs:<path to a flow file>.
@MainActor
enum RunsPreview {
    private static var window: NSWindow?

    static func show(_ path: String) {
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 380, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Runs preview"
        window.contentView = NSHostingView(rootView: ScrollView { RunHistory(path: path).padding(16) }.frame(width: 380, height: 520).background(Theme.canvas))
        window.orderFrontRegardless()
        self.window = window
    }
}

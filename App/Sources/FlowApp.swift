import AppKit
import DesertAntUI
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The examples open at launch instead of an empty flow.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    /// Asks first while a flow is running, so a call being recorded or files
    /// being moved are not cut off by a stray Quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        TriggerCenter.shared.shouldQuit()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Snapshots.start()
        guard !FlowApp.testing else { return }
        Task.detached(priority: .utility) { RecordingFolder.sweep() }
        TriggerCenter.shared.start()
        NSApp.servicesProvider = Services.shared
        NSUpdateDynamicServices()
        if Snapshots.show == "card-colors" { CardColors.show() }
        if let show = Snapshots.show, show.hasPrefix("runs:") { RunsPreview.show(String(show.dropFirst("runs:".count))) }
        if Snapshots.show == "settings" {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Settings"
            window.makeKeyAndOrderFront(nil)
        }
    }
}

@main
struct FlowApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    /// The tests run inside the app, where the menu bar and triggers have no
    /// place; the menu bar keeps the test runner from connecting.
    static let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    @State private var menuBar = !FlowApp.testing

    init() {
        _ = Updates.shared
    }

    var body: some Scene {
        DocumentGroup(newDocument: FlowDocument()) { file in
            FlowEditor(document: file.$document, fileURL: file.fileURL)
                .task { if Snapshots.folder == nil { MoveToApplications.offer() } }
        }
        .defaultSize(width: 1320, height: 860)
        .commands { FlowCommands() }

        Window("Library", id: "library") {
            LibraryView()
        }
        .defaultSize(width: 1120, height: 800)
        .defaultLaunchBehavior(.presented)

        MenuBarExtra(isInserted: $menuBar) {
            MenuBarView()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }

        Window("About Desert Ant Flow", id: About.windowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Acknowledgements", id: About.acknowledgementsID) {
            AcknowledgementsView()
        }
        .defaultSize(width: 640, height: 720)
    }
}

struct FlowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.newDocument) private var newDocument
    @FocusedValue(\.flowCommands) private var editor
    /// Zooming and tidying are for the canvas; in Steps they would change a
    /// canvas nobody is looking at.
    @FocusedValue(\.canvasShowing) private var canvasShowing

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Desert Ant Flow") { openWindow(id: About.windowID) }
            Button("Check for Updates…") { Updates.shared.check() }
        }
        CommandGroup(after: .newItem) {
            Button("New from Template…") { openWindow(id: "library") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Open Link from Clipboard") { openLink() }
                .keyboardShortcut("o", modifiers: [.command, .option])
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy Link to Flow") { editor?.copyLink() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(editor == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Steps") { editor?.session?.view = .steps }.keyboardShortcut("1")
            Button("Canvas") { editor?.session?.view = .canvas }.keyboardShortcut("2")
            Divider()
            Button("Zoom In") { editor?.session?.zoom(by: 1.25) }.keyboardShortcut("+").disabled(canvasShowing != true)
            Button("Zoom Out") { editor?.session?.zoom(by: 0.8) }.keyboardShortcut("-").disabled(canvasShowing != true)
            Button("Tidy Up") { editor?.tidy() }.keyboardShortcut("t", modifiers: [.command, .option]).disabled(canvasShowing != true)
            Button("Show Results") { editor?.session?.showResults.toggle() }.keyboardShortcut("r", modifiers: [.command, .control])
            Divider()
        }
        CommandMenu("Flow") {
            Button("Run Again") { editor?.run() }.keyboardShortcut("r").disabled(editor == nil)
            Button("Add Step…") { editor?.addStep() }.keyboardShortcut("k").disabled(editor == nil)
            Button("Duplicate Step") { editor?.duplicate() }.keyboardShortcut("d").disabled(editor == nil)
            Button("Delete Step") { editor?.delete() }.keyboardShortcut(.delete).disabled(editor == nil)
            Divider()
            Button("Previous Step") { editor?.step(-1) }.keyboardShortcut(.upArrow, modifiers: .option).disabled(editor == nil)
            Button("Next Step") { editor?.step(1) }.keyboardShortcut(.downArrow, modifiers: .option).disabled(editor == nil)
            Divider()
            Button(editor?.runsOnItsOwn == true ? "Turn Off Automatic Runs" : "Turn On Automatic Runs") {
                if let editor { editor.turnOn(!editor.runsOnItsOwn) }
            }
            .disabled(editor?.canRunOnItsOwn() != true)
            Divider()
            Button("Open in Browser") { editor?.openInBrowser() }.disabled(editor == nil)
        }
        CommandGroup(replacing: .help) {
            Link("Desert Ant Labs Models", destination: URL(string: "https://desertant.com/models/")!)
            Link("Desert Ant Flow on the Web", destination: FlowLink.site)
        }
    }

    private func openLink() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        if let code = FlowLink.code(in: text), let g = try? FlowLink.graph(from: code) {
            newDocument(FlowDocument(graph: g))
        } else if FlowFile.looksLikeFlow(text), let g = try? FlowFile.read(text) {
            newDocument(FlowDocument(graph: g))
        } else if let id = FlowLink.example(in: text), let e = Example.all.first(where: { $0.id == id }) {
            newDocument(FlowDocument(graph: e.graph))
        } else {
            NSSound.beep()
        }
    }
}

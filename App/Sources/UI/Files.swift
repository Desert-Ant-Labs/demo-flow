import AppKit
import UniformTypeIdentifiers

/// Where files this app makes for you are kept: recordings, and photos from
/// your Photos library.
enum Library {
    static func folder(_ name: String) -> URL {
        let dir = URL.applicationSupportDirectory.appending(path: "Flow").appending(path: name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

@MainActor
func openPanel(_ types: [UTType], multiple: Bool, prompt: String) -> [URL] {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = types
    panel.allowsMultipleSelection = multiple
    panel.prompt = prompt
    return panel.runModal() == .OK ? panel.urls : []
}

/// Picks a folder, for the steps that write into one.
@MainActor
func chooseFolder(prompt: String = "Use This Folder") -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.prompt = prompt
    return panel.runModal() == .OK ? panel.url : nil
}

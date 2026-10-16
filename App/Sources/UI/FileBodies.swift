import SwiftUI
import UniformTypeIdentifiers

/// A folder setting: its name, a button to change it, and a way to the Finder.
struct FolderField: View {
    let path: String?
    let choose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(path.map { Samples.url($0).lastPathComponent } ?? "No folder yet")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(path == nil ? .secondary : .primary)
                .help(path ?? "")
            Spacer()
            Button(path == nil ? "Choose…" : "Change…", action: choose)
            if let path {
                Button("Show in Finder", systemImage: "arrow.forward.circle") {
                    NSWorkspace.shared.activateFileViewerSelecting([Samples.url(path)])
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
        }
    }
}

struct FilesBody: View {
    let node: Node
    let state: StepState
    @Environment(\.flowActions) private var actions
    @State private var targeted = false

    var body: some View {
        let files = node.params["files"]?.strings ?? []
        let folders = node.params["folders"]?.strings ?? []
        let count = state.outputs?["files"]?.present.count ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(count == 1 ? "**1** file" : "**\(count)** files").font(.callout)
                Spacer()
                Button("Add Files…") { add(openPanel([.item], multiple: true, prompt: "Add")) }
                Button("Add Folder…") { if let url = chooseFolder(prompt: "Add") { addFolder(url) } }
            }
            ForEach(folders, id: \.self) { path in
                row(path, folder: true) { remove("folders", path) }
            }
            ForEach(files.prefix(8), id: \.self) { path in
                row(path, folder: false) { remove("files", path) }
            }
            if files.count > 8 {
                Text("\(files.count - 8) more").font(.caption).foregroundStyle(.secondary)
            }
            if files.isEmpty && folders.isEmpty {
                Text("Drop files or a folder here.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4])))
            }
        }
        .controlSize(.small)
        .padding(targeted ? 4 : 0)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(targeted ? Color.accentColor : .clear, lineWidth: 2))
        .dropDestination(for: URL.self) { urls, _ in
            // One change per list: the node is what it was when the drop
            // began, so adding one at a time would keep only the last.
            let isFolder = { (url: URL) in (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            append(urls.filter(isFolder).map(Samples.path(for:)), to: "folders")
            add(urls.filter { !isFolder($0) })
            return true
        } isTargeted: { targeted = $0 }
    }

    private func row(_ path: String, folder: Bool, remove: @escaping () -> Void) -> some View {
        HStack {
            FileLabel(url: Samples.url(path))
            if folder { Text("folder").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("Remove", systemImage: "minus.circle", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
    }

    /// Adds to a list, leaving out what is already in it, since the rows are
    /// told apart by their paths.
    private func add(_ urls: [URL]) {
        append(urls.map(Samples.path(for:)), to: "files")
    }

    private func addFolder(_ url: URL) {
        append([Samples.path(for: url)], to: "folders")
    }

    private func append(_ paths: [String], to key: String) {
        guard !paths.isEmpty else { return }
        var seen = Set<String>()
        let list = ((node.params[key]?.strings ?? []) + paths).filter { seen.insert($0).inserted }
        actions.set(node.id, [key: .array(list.map { .string($0) })])
    }

    private func remove(_ key: String, _ path: String) {
        let list = node.params[key]?.strings ?? []
        actions.set(node.id, [key: .array(list.filter { $0 != path }.map { .string($0) })])
    }
}

/// The pattern, with suggestions that show what the first file would be
/// called, a preview of every new name, and the button that renames.
struct RenameBody: View {
    let node: Node
    let state: StepState
    @Environment(\.flowActions) private var actions
    @State private var done: String?
    @State private var working = false

    var body: some View {
        let p = ParamBinding(node: node, actions: actions)
        let urls = (state.inputs["files"]?.present ?? []).compactMap(\.fileURL)
        let a = state.inputs["a"]?.items ?? []
        let names = state.outputs?["names"]?.present.map(\.asText) ?? []
        let inPlace = node.params["mode"]?.string == "rename"
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                TextField("Pattern", text: p.text("pattern", "{{date}}-{{n}}"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Menu("Suggestions") {
                    ForEach(FileOps.suggestions(usesA: state.inputs["a"] != nil), id: \.self) { pattern in
                        Button {
                            actions.set(node.id, ["pattern": .string(pattern)])
                        } label: {
                            Text(pattern)
                            if let first = urls.first {
                                Text(FileOps.names(for: [first], pattern: pattern, a: Array(a.prefix(1)))[0])
                            }
                        }
                    }
                }
                .fixedSize()
            }
            Text("{{name}}, {{n}}, {{date}} as YYYY-MM-DD, {{time}}, and {{a}} from the step wired in.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !names.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    ForEach(Array(zip(urls, names).prefix(6).enumerated()), id: \.offset) { _, pair in
                        GridRow {
                            Text(pair.0.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                            Text(pair.1).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .font(.callout)
                if names.count > 6 { Text("\(names.count - 6) more").font(.caption).foregroundStyle(.secondary) }
            }
            Picker("", selection: p.text("mode", "copy")) {
                Text("Copy into a folder").tag("copy")
                Text("Rename in place").tag("rename")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if !inPlace {
                FolderField(path: node.params["folder"]?.string) {
                    if let url = chooseFolder() { actions.set(node.id, ["folder": .string(Samples.path(for: url))]) }
                }
            }
            HStack {
                Toggle(inPlace ? "Rename on every run" : "Copy on every run", isOn: p.bool("auto"))
                if let done { Text(done).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(working ? (inPlace ? "Renaming…" : "Copying…") : "\(inPlace ? "Rename" : "Copy") \(fileCountTitle(names.count))") { apply(urls, names, inPlace) }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || names.isEmpty || (!inPlace && node.params["folder"]?.string == nil))
            }
        }
        .controlSize(.small)
    }

    private func apply(_ urls: [URL], _ names: [String], _ inPlace: Bool) {
        let targets = zip(urls, names).map { url, name in
            (inPlace ? url.deletingLastPathComponent() : Samples.url(node.params["folder"]?.string ?? "")).appending(path: name)
        }
        working = true
        Task {
            done = await fileWork { try FileOps.apply(urls, to: targets, inPlace ? .move : .copy) } summary: {
                "\(inPlace ? "Renamed" : "Copied") \(fileCount($0.count))"
            }
            working = false
        }
    }
}

struct CopyBody: View {
    let node: Node
    let state: StepState
    @Environment(\.flowActions) private var actions
    @State private var done: String?
    @State private var working = false

    var body: some View {
        let p = ParamBinding(node: node, actions: actions)
        let move = node.params["mode"]?.string == "move"
        let plan = FileSteps.copyPlan(state.inputs, node.params)
        let folder = node.params["folder"]?.string
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: p.text("mode", "copy")) {
                Text("Copy").tag("copy")
                Text("Move").tag("move")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            FolderField(path: folder) {
                if let url = chooseFolder() { actions.set(node.id, ["folder": .string(Samples.path(for: url))]) }
            }
            HStack(spacing: 6) {
                TextField("Subfolder, like {{a}} or {{date}}", text: p.text("subfolder"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Menu("Suggestions") {
                    ForEach(state.inputs["a"] != nil ? ["{{a}}", "{{date}}/{{a}}", "{{a}}/{{date}}"] : ["{{date}}", ""], id: \.self) { pattern in
                        Button(pattern.isEmpty ? "No subfolders" : pattern) { actions.set(node.id, ["subfolder": .string(pattern)]) }
                    }
                }
                .fixedSize()
            }
            if folder != nil, !plan.targets.isEmpty {
                let root = Self.trimmed(Samples.url(folder!))
                let groups = Dictionary(grouping: plan.targets) { Self.trimmed($0.deletingLastPathComponent()) }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(groups.keys.sorted().prefix(6), id: \.self) { dir in
                        let name = dir == root ? "This folder" : String(dir.dropFirst(root.count + 1))
                        Text("\(Image(systemName: "folder")) \(name): \(groups[dir]!.count)")
                    }
                }
                .font(.callout)
            }
            HStack {
                if !move {
                    Toggle("Copy on every run", isOn: p.bool("auto"))
                }
                Spacer()
                if let done { Text(done).font(.caption).foregroundStyle(.secondary) }
                Button(working ? (move ? "Moving…" : "Copying…") : "\(move ? "Move" : "Copy") \(fileCountTitle(plan.files.count))") { apply(plan, move) }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || plan.files.isEmpty || folder == nil)
            }
        }
        .controlSize(.small)
    }

    /// A folder's path without the trailing slash some URLs keep.
    private static func trimmed(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private func apply(_ plan: (files: [URL], targets: [URL]), _ move: Bool) {
        working = true
        Task {
            done = await fileWork { try FileOps.apply(plan.files, to: plan.targets, move ? .move : .copy) } summary: {
                "\(move ? "Moved" : "Copied") \(fileCount($0.count))"
            }
            working = false
        }
    }
}

/// Where Save to folder writes, and when.
struct FolderBody: View {
    let node: Node
    let state: StepState
    @Environment(\.flowActions) private var actions
    @State private var saved: String?
    @State private var working = false

    var body: some View {
        let p = ParamBinding(node: node, actions: actions)
        let path = node.params["folder"]?.string
        VStack(alignment: .leading, spacing: 10) {
            FolderField(path: path) {
                if let url = chooseFolder() { actions.set(node.id, ["folder": .string(Samples.path(for: url))]) }
            }
            LabeledContent("File name") {
                TextField("result", text: p.text("name", "result")).textFieldStyle(.roundedBorder)
            }
            HStack {
                Toggle("Save on every run", isOn: Binding(get: { node.params["auto"]?.bool ?? true },
                                                         set: { actions.set(node.id, ["auto": .bool($0)]) }))
                Spacer()
                if let saved { Text(saved).font(.caption).foregroundStyle(.secondary) }
                Button(working ? "Saving…" : "Save Now") { saveNow() }
                    .disabled(working || path == nil || state.inputs["value"] == nil)
            }
        }
        .controlSize(.small)
    }

    private func saveNow() {
        guard let path = node.params["folder"]?.string, let value = state.inputs["value"] else { return }
        let folder = SaveTo.resolve(path)
        let name = SaveTo.fileName(node.params["name"]?.string ?? "result", a: state.inputs["a"]?.present.first)
        working = true
        Task {
            saved = await fileWork { try FolderWriter.write(value, to: folder, name: name) } summary: {
                $0.count == 1 ? "Saved \($0[0].lastPathComponent)" : "Saved \(fileCount($0.count))"
            }
            working = false
        }
    }
}

/// Runs file work away from the main actor, so a big copy does not hold up
/// the window, and says what came of it: a summary, or what went wrong.
@MainActor
private func fileWork(_ work: @escaping @Sendable () throws -> [URL], summary: ([URL]) -> String) async -> String {
    switch await Task.detached(operation: { Result(catching: work) }).value {
    case .success(let urls): summary(urls)
    case .failure(let error): error.localizedDescription
    }
}

/// "1 file" or "3 files".
private func fileCount(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }

/// "1 File" or "3 Files", for a button.
private func fileCountTitle(_ n: Int) -> String { n == 1 ? "1 File" : "\(n) Files" }

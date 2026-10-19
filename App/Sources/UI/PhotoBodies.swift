import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Copies photos picked from the Photos library into the app's folder, so a
/// flow can name them by path like any other file.
func importPhotos(_ items: [PhotosPickerItem]) async -> [URL] {
    var urls: [URL] = []
    for item in items {
        guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
        let url = Library.folder("Photos").appending(path: "\(item.itemIdentifier ?? UUID().uuidString).\(ext)".replacingOccurrences(of: "/", with: "-"))
        if (try? data.write(to: url)) != nil { urls.append(url) }
    }
    return urls
}

struct Thumb: View {
    let url: URL
    var on = false
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) } else { Color.primary.opacity(0.06) }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(on ? Color.accentColor : .clear, lineWidth: 2.5))
            .opacity(on ? 1 : 0.55)
            if on {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(3)
            }
        }
        .task(id: url) {
            let url = url
            image = await Task.detached { () -> NSImage? in
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 240,
                      ] as CFDictionary)
                else { return nil }
                return NSImage(cgImage: cg, size: .zero)
            }.value
        }
    }
}

struct PhotoBody: View {
    let node: Node
    let state: StepState
    @Environment(\.flowActions) private var actions
    @State private var picked: PhotosPickerItem?

    var body: some View {
        let current = node.params["file"]?.string == nil ? node.params["sample"]?.string : nil
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(Samples.portraits, id: \.self) { path in
                    SampleThumb(path: path, on: current == path) { actions.set(node.id, ["sample": .string(path), "file": .null]) }
                }
            }
            HStack {
                Button("Open…", systemImage: "folder") {
                    if let url = openPanel([.image], multiple: false, prompt: "Use").first { use(url) }
                }
                PhotosPicker(selection: $picked, matching: .images) { Label("Photos", systemImage: "photo.on.rectangle") }
            }
            .controlSize(.small)
            if let photo = state.outputs?["image"]?.photo { PhotoView(photo: photo, all: [photo]) }
        }
        .onChange(of: picked) {
            guard let item = picked else { return }
            picked = nil
            Task { if let url = await importPhotos([item]).first { use(url) } }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) ?? false }) else { return false }
            use(url)
            return true
        }
    }

    private func use(_ url: URL) {
        actions.set(node.id, ["file": .string(Samples.path(for: url)), "sample": .null])
    }
}

/// A sample to tick on or off, which VoiceOver reads by what it shows.
private struct SampleThumb: View {
    let path: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { Thumb(url: Samples.thumb(path), on: on) }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.name(path))
            .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// "two women taking selfie" for a portrait, "Trip photo 5" for the trip.
    static func name(_ path: String) -> String {
        let name = URL(filePath: path).deletingPathExtension().lastPathComponent
        if let n = Int(name) { return "Trip photo \(n)" }
        return name.replacingOccurrences(of: "-", with: " ")
    }
}

/// Several photos: samples chosen in a sheet, or your own. The card shows
/// what the flow uses.
struct PhotosBody: View {
    let node: Node
    @Environment(\.flowActions) private var actions
    @State private var picked: [PhotosPickerItem] = []
    @State private var targeted = false
    @State private var choosing = false
    @State private var gridHeight: CGFloat?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    var body: some View {
        let samples = node.params["samples"]?.strings ?? []
        let files = node.params["files"]?.strings ?? []
        let own = !files.isEmpty
        let shown = own ? files : samples
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if own {
                    Text("**\(files.count)** of your photos").font(.callout)
                    Button("Use the samples") { useSamples() }.buttonStyle(.link)
                } else {
                    Text(samples.count == 1 ? "**1** sample" : "**\(samples.count)** samples").font(.callout)
                    Button("Choose Samples…") { choosing = true }.buttonStyle(.link)
                }
                Spacer()
                Menu {
                    Button(own ? "Add Photos…" : "Use Your Own Photos…") { choose(replacing: !own) }
                    if own { Button("Replace All…") { choose(replacing: true) } }
                } label: {
                    Label(own ? "Add" : "Use Your Own", systemImage: own ? "plus" : "photo.badge.plus")
                } primaryAction: {
                    choose(replacing: !own)
                }
                .fixedSize()
                PhotosPicker(selection: $picked, matching: .images) { Image(systemName: "photo.on.rectangle") }
                    .help(own ? "Add from Photos" : "Use photos from Photos")
            }
            .controlSize(.small)
            if !shown.isEmpty {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(shown, id: \.self) { path in
                            Button { remove(path, own: own) } label: {
                                Thumb(url: own ? Samples.url(path) : Samples.thumb(path), on: true)
                            }
                            .buttonStyle(.plain)
                            .help("Remove \(own ? URL(filePath: path).lastPathComponent : SampleThumb.name(path))")
                            .accessibilityLabel(own ? URL(filePath: path).lastPathComponent : SampleThumb.name(path))
                            .accessibilityAddTraits(.isSelected)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { gridHeight = $0 }
                }
                .frame(height: min(260, gridHeight ?? 260))
            }
            Text(own ? "Click a photo to remove it. Drop photos here to replace them all." : "Click a photo to remove it. Drop photos here to use your own.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(targeted ? 4 : 0)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(targeted ? Color.accentColor : .clear, style: StrokeStyle(lineWidth: 2, dash: [5])))
        .sheet(isPresented: $choosing) {
            SamplePicker(selected: samples) { set($0) }
        }
        .onChange(of: picked) {
            let items = picked
            guard !items.isEmpty else { return }
            picked = []
            let replacing = !own
            Task { use(await importPhotos(items), replacing: replacing) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let images = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) ?? false }
            use(images, replacing: true)
            return !images.isEmpty
        } isTargeted: { targeted = $0 }
    }

    private func set(_ samples: [String]) {
        actions.set(node.id, ["samples": .array(samples.map { .string($0) })])
    }

    private func remove(_ path: String, own: Bool) {
        let key = own ? "files" : "samples"
        let paths = (node.params[key]?.strings ?? []).filter { $0 != path }
        actions.set(node.id, [key: .array(paths.map { .string($0) })])
    }

    private func choose(replacing: Bool) {
        use(openPanel([.image], multiple: true, prompt: replacing ? "Use" : "Add"), replacing: replacing)
    }

    /// Your photos in place of what is there, or added to them. A photo
    /// already in the list is not added twice.
    private func use(_ urls: [URL], replacing: Bool) {
        guard !urls.isEmpty else { return }
        let files = replacing ? [] : node.params["files"]?.strings ?? []
        var seen = Set<String>()
        let paths = (files + urls.map(Samples.path(for:))).filter { seen.insert($0).inserted }
        actions.set(node.id, ["samples": .array([]), "files": .array(paths.map { .string($0) })])
    }

    private func useSamples() {
        actions.set(node.id, ["files": .array([]), "samples": InputSteps.photos.defaults["samples"] ?? .array([])])
    }
}

/// Every sample, to tick on and off without the flow running each time.
/// The flow gets the picks when you press Use.
private struct SamplePicker: View {
    let use: ([String]) -> Void
    @State private var picks: [String]
    @Environment(\.dismiss) private var dismiss

    init(selected: [String], use: @escaping ([String]) -> Void) {
        self.use = use
        _picks = State(initialValue: selected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Choose samples").font(.title2.weight(.semibold)).padding([.horizontal, .top], 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("Trip", Samples.trip)
                    section("People", Samples.people)
                }
                .padding(20)
            }
            Divider()
            HStack {
                Text(picks.count == 1 ? "1 selected" : "\(picks.count) selected").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(picks.count == 1 ? "Use 1 Photo" : "Use \(picks.count) Photos") {
                    use(picks)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picks.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 600, height: 620)
    }

    private func section(_ title: String, _ paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(title).font(.headline)
                Button("All") { picks += paths.filter { !picks.contains($0) } }.buttonStyle(.link)
                Button("None") { picks.removeAll { paths.contains($0) } }.buttonStyle(.link)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                ForEach(paths, id: \.self) { path in
                    SampleThumb(path: path, on: picks.contains(path)) {
                        if picks.contains(path) { picks.removeAll { $0 == path } } else { picks.append(path) }
                    }
                }
            }
        }
    }
}

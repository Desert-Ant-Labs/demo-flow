import AVFoundation
import Combine
import SwiftUI

/// What a value is, for picking how to show it and how wide its card is.
enum ValueKind: String, CaseIterable {
    case auto, empty, text, document, markdown, number, audio, image, gallery, scored, table, list, json

    static let modes: [(ValueKind, String)] = [
        (.auto, "Best fit"), (.document, "Document"), (.markdown, "Markdown"), (.gallery, "Gallery"),
        (.table, "Table"), (.text, "Plain text"), (.json, "Raw data"),
    ]

    var width: CGFloat {
        switch self {
        case .gallery: 460
        case .table: 560
        case .document, .markdown: 440
        case .image: 360
        case .json: 380
        case .list: 340
        case .scored, .audio, .text: 320
        case .number: 260
        default: 300
        }
    }
}

func looksLikeMarkdown(_ s: String) -> Bool {
    s.contains(#/(?m)^(#{1,6} |\s*[-*] |\s*\d+\. |> )|\*\*[^*]+\*\*/#)
}

/// A list of records with a label and a score: bars.
func scored(_ items: [Value]) -> [(label: String, score: Double)]? {
    guard let first = items.first, case .record(let fields) = first else { return nil }
    let keys = fields.map(\.0)
    guard let label = ["emoji", "name", "label", "language", "text", "slug", "kind"].first(where: keys.contains),
          let score = ["score", "confidence", "probability", "share"].first(where: keys.contains)
    else { return nil }
    return items.map { item in
        var name = item[label].asText
        if label == "language" { name = languageName(name) }
        return (name, item[score]?.asNumber ?? 0)
    }
}

func kind(of value: Value?) -> ValueKind {
    guard let value else { return .empty }
    switch value {
    case .text(let s): return looksLikeMarkdown(s) ? .markdown : s.count > 280 ? .document : .text
    case .number, .bool: return .number
    case .audio: return .audio
    case .image: return .image
    case .list, .stream:
        let xs = value.present
        if !xs.isEmpty && xs.allSatisfy({ $0.photo != nil }) { return .gallery }
        if scored(xs) != nil { return .scored }
        if !xs.isEmpty && xs.allSatisfy(\.isRecord) { return .table }
        return .list
    default: return .json
    }
}

/// Redact's placeholders read as tags wherever they end up downstream.
func marked(_ text: String) -> AttributedString {
    var out = AttributedString()
    var rest = Substring(text)
    while let m = rest.firstMatch(of: #/\[([A-Z_]+)_\d+\]/#) {
        out += AttributedString(String(rest[rest.startIndex..<m.range.lowerBound]))
        var tag = AttributedString(" " + m.output.1.replacingOccurrences(of: "_", with: " ").lowercased() + " ")
        tag.backgroundColor = Theme.rgb(0xDB704C, 0.22)
        tag.font = .callout.weight(.medium)
        out += tag
        rest = rest[m.range.upperBound...]
    }
    out += AttributedString(String(rest))
    return out
}

/// Any value, small, for a card.
struct ValueView: View {
    let value: Value?
    var compact = true

    var body: some View {
        switch value {
        case nil:
            Text("Nothing yet").foregroundStyle(.secondary)
        case .text(let s):
            if s.isEmpty { Text("Empty").foregroundStyle(.secondary) } else {
                Text(marked(s)).lineLimit(compact ? 8 : nil).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        case .number(let n):
            Text(Value.format(n)).font(.title2.monospacedDigit().weight(.medium))
        case .bool(let b):
            Pill(text: b ? "Yes" : "No", good: b)
        case .audio(let clip):
            AudioPlayerView(clip: clip)
        case .image(let photo):
            PhotoView(photo: photo, all: [photo])
        case .file(let url):
            FileLabel(url: url)
        case .stroke:
            Text("A stroke").foregroundStyle(.secondary)
        case .shape(let s):
            Text(s.kind.capitalized)
        case .list, .stream:
            let xs = value!.present
            if !xs.isEmpty && xs.allSatisfy({ $0.photo != nil }) {
                GalleryGrid(photos: xs.compactMap(\.photo), compact: compact)
            } else if let bars = scored(xs) {
                Bars(items: bars)
            } else if !xs.isEmpty && xs.allSatisfy({ ($0.string?.count ?? 9) <= 4 }) {
                Text(xs.map(\.asText).joined(separator: " ")).font(.system(size: 30))
            } else {
                ItemList(items: xs, compact: compact)
            }
        case .record:
            JSONText(value: value!)
        }
    }
}

struct Pill: View {
    let text: String
    var good: Bool? = nil

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(good == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
    }

    private var color: Color {
        switch good {
        case true: Theme.success
        case false: Theme.danger
        default: .secondary
        }
    }
}

struct Bars: View {
    let items: [(label: String, score: Double)]
    var limit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.prefix(limit).enumerated()), id: \.offset) { _, item in
                HStack(spacing: 8) {
                    Text(item.label).lineLimit(1).frame(minWidth: 70, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.primary.opacity(0.1))
                            Capsule().fill(.primary.opacity(0.75)).frame(width: max(3, geo.size.width * min(1, item.score)))
                        }
                    }
                    .frame(height: 6)
                    Text("\(Int((item.score * 100).rounded()))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .trailing)
                }
            }
        }
    }
}

struct ItemList: View {
    let items: [Value]
    var compact = true
    @State private var all = false

    var body: some View {
        let cap = all ? items.count : compact ? 6 : 200
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.prefix(cap).enumerated()), id: \.offset) { i, v in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(i + 1)").font(.caption.monospaced()).foregroundStyle(.tertiary).frame(minWidth: 14, alignment: .trailing)
                    ValueView(value: v, compact: true)
                }
            }
            if items.count > cap {
                Button("\(items.count - cap) more") { all = true }.buttonStyle(.link)
            }
        }
    }
}

/// A step's results, one numbered row per item it ran on.
struct ItemRows<Row: View>: View {
    let items: [Value?]
    @ViewBuilder let row: (Value) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, v in
                if let v {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1)").font(.caption.monospaced()).foregroundStyle(.tertiary).frame(minWidth: 14, alignment: .trailing)
                        row(v)
                    }
                }
            }
        }
    }
}

struct JSONText: View {
    let value: Value
    var body: some View {
        Text(value.jsonText())
            .font(.caption.monospaced())
            .lineLimit(14)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A photo. A click opens Quick Look on it, and the arrow keys move through
/// the others shown with it.
struct PhotoView: View {
    let photo: Photo
    var all: [Photo]
    var caption: String? = nil
    var square = false
    @Environment(\.openQuickLook) private var quickLook

    var body: some View {
        Button { quickLook(all, photo) } label: {
            if square {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { Image(decorative: photo.thumb, scale: 1).resizable().scaledToFill() }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
            } else {
                Image(decorative: photo.thumb, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.plain)
        .help(caption ?? photo.name)
        .accessibilityLabel(caption ?? photo.name)
        .draggable(PhotoTransfer(photo: photo))
    }
}

struct GalleryGrid: View {
    let photos: [Photo]
    var captions: [String?] = []
    var compact = false

    var body: some View {
        let shown = compact ? Array(photos.prefix(6)) : photos
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 74 : 120), spacing: 8)], spacing: 8) {
                ForEach(Array(shown.enumerated()), id: \.offset) { i, p in
                    VStack(alignment: .leading, spacing: 3) {
                        PhotoView(photo: p, all: photos, caption: caption(i), square: true)
                        if let c = caption(i) {
                            Text(c).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if photos.count > shown.count {
                Text("\(photos.count - shown.count) more").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private func caption(_ i: Int) -> String? {
        i < captions.count ? captions[i] : nil
    }
}

/// Plays a recording in place.
struct AudioPlayerView: View {
    let clip: AudioClip
    /// The waveform's height: small on a card, larger on the Results page.
    var height: CGFloat = 28
    @State private var player = ClipPlayer()
    @State private var peaks: [Float] = []

    var body: some View {
        HStack(spacing: 10) {
            Button {
                player.toggle(clip)
            } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill")
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help(player.playing ? "Pause" : "Play")
            .accessibilityLabel(player.playing ? "Pause" : "Play")
            TimelineView(.animation(paused: !player.playing)) { _ in
                Waveform(peaks: peaks, progress: player.progress)
                    .frame(height: height)
            }
            Text(String(format: "%.1fs", clip.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .task(id: ObjectIdentifier(clip)) {
            let clip = clip
            peaks = await Task.detached { Waveform.peaks(clip.samples) }.value
        }
        .onDisappear { player.stop() }
        .onChange(of: ObjectIdentifier(clip)) { player.stop() }
    }
}

/// One recording's playback. Only one plays at a time: starting one pauses
/// whichever was playing, as two voices at once would be hard to follow.
@MainActor @Observable
final class ClipPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playing = false
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private static weak var current: ClipPlayer?

    /// How far along it is, from 0 to 1. Read while drawing, not observed.
    var progress: Double {
        guard let player, playing else { return 0 }
        return player.currentTime / max(player.duration, 0.01)
    }

    func toggle(_ clip: AudioClip) {
        if playing {
            player?.pause()
            playing = false
            return
        }
        if player == nil {
            player = try? AVAudioPlayer(data: Media.wav(clip))
            player?.delegate = self
        }
        guard let player else { return }
        if let other = Self.current, other !== self { other.pause() }
        Self.current = self
        playing = player.play()
    }

    /// Stops and lets go of the recording, for when the card goes or its
    /// recording changes.
    func stop() {
        player?.stop()
        player = nil
        playing = false
    }

    private func pause() {
        player?.pause()
        playing = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playing = false }
    }
}

/// A recording's loudness as bars, the part already played darker.
struct Waveform: View {
    /// The loudest sample in each of a few hundred equal slices.
    let peaks: [Float]
    var progress: Double

    /// Worked out once per recording, so drawing never reads the samples.
    nonisolated static func peaks(_ samples: [Float], count: Int = 400) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let step = max(1, samples.count / count)
        return stride(from: 0, to: samples.count, by: step).map { start in
            samples[start..<min(samples.count, start + step)].reduce(Float(0)) { max($0, abs($1)) }
        }
    }

    var body: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty else { return }
            let bars = max(1, Int(size.width / 3))
            for i in 0..<bars {
                let from = i * peaks.count / bars, to = max(from + 1, (i + 1) * peaks.count / bars)
                guard from < peaks.count else { break }
                let peak = peaks[from..<min(peaks.count, to)].max() ?? 0
                let h = max(2, CGFloat(min(1, peak * 1.6)) * size.height)
                let rect = CGRect(x: CGFloat(i) * 3, y: (size.height - h) / 2, width: 2, height: h)
                let played = Double(i) / Double(bars) < progress
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.primary.opacity(played ? 0.85 : 0.35)))
            }
        }
    }
}

/// A large view of a value, inside the Result step (`ResultBody`) and the
/// results page (`ResultsPage`).
struct ResultView: View {
    let value: Value?
    var mode: ValueKind = .auto

    var body: some View {
        let k = mode == .auto ? kind(of: value) : mode
        let text: String? = {
            switch value {
            case .text(let s): s
            case .list, .stream: value!.present.map { $0.string ?? $0.jsonText(pretty: false) }.joined(separator: "\n\n")
            default: nil
            }
        }()
        switch k {
        case .markdown where text != nil:
            MarkdownView(text: text!)
        case .document where text != nil:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(text!.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, p in
                    Text(marked(p)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 14))
            .lineSpacing(3)
            .textSelection(.enabled)
        case .gallery:
            GalleryGrid(photos: value?.present.compactMap(\.photo) ?? [])
        case .table:
            RecordTable(rows: value?.present ?? [])
        case .text:
            Text(value?.string.map(marked) ?? AttributedString(value?.jsonText() ?? "")).textSelection(.enabled)
        case .json:
            Text(value?.jsonText() ?? "").font(.caption.monospaced()).textSelection(.enabled)
        default:
            ValueView(value: value, compact: false)
        }
    }
}

/// A list of records as a table, its columns from their fields.
struct RecordTable: View {
    let rows: [Value]

    var body: some View {
        let keys: [String] = {
            var seen: [String] = []
            for r in rows {
                if case .record(let f) = r { for (k, _) in f where !seen.contains(k) { seen.append(k) } } else if !seen.contains("value") { seen.append("value") }
            }
            return Array(seen.prefix(6))
        }()
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                ForEach(keys, id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                GridRow {
                    ForEach(keys, id: \.self) { k in
                        if case .record = r { ValueView(value: r[k]) } else { ValueView(value: k == "value" ? r : nil) }
                    }
                }
            }
        }
    }
}

/// Headings, lists, and paragraphs, with inline markdown inside them.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                block
            }
        }
        .textSelection(.enabled)
    }

    private var blocks: [AnyView] {
        text.components(separatedBy: "\n").compactMap { raw -> AnyView? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            if let m = line.firstMatch(of: #/^(#{1,6})\s+(.*)$/#) {
                let size: CGFloat = [22, 19, 16, 15, 14, 13][m.output.1.count - 1]
                return AnyView(Text(inline(String(m.output.2))).font(.system(size: size, weight: .semibold)).padding(.top, 4))
            }
            if let m = line.firstMatch(of: #/^[-*]\s+(.*)$/#) {
                return AnyView(HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); Text(inline(String(m.output.1))) })
            }
            if let m = line.firstMatch(of: #/^(\d+)\.\s+(.*)$/#) {
                return AnyView(HStack(alignment: .firstTextBaseline, spacing: 6) { Text("\(m.output.1)."); Text(inline(String(m.output.2))) })
            }
            if line.hasPrefix(">") {
                return AnyView(Text(inline(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))).italic().foregroundStyle(.secondary))
            }
            return AnyView(Text(inline(line)).fixedSize(horizontal: false, vertical: true))
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// A file by its Finder icon and name. A click shows it in the Finder.
struct FileLabel: View {
    let url: URL

    var body: some View {
        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
            Label {
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                    .resizable()
                    .frame(width: 16, height: 16)
            }
        }
        .buttonStyle(.plain)
        .help(url.path(percentEncoded: false))
    }
}

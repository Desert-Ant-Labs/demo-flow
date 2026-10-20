import SwiftUI

/// What a step gave, small, on its card.
struct StepPreview: View {
    let node: Node
    let state: StepState

    static func has(_ type: String) -> Bool {
        ModelSteps.all.contains { $0.type == type } || ["if", "merge", "list", "best", "template"].contains(type)
    }

    var body: some View {
        let o = state.outputs ?? [:]
        switch node.type {
        case "voz", "redact", "who":
            primary(o["text"])
        case "ear", "tongue":
            if case .stream(let items) = o["language"] {
                ItemRows(items: items) { Text(languageName($0.asText)) }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(languageName(o["language"].asText)).font(.title2.weight(.semibold))
                        let sure = o["reliable"]?.asText == "true"
                        Pill(text: sure ? "Sure" : "Unsure", good: sure ? true : nil)
                    }
                    if let bars = scored(o["candidates"]?.present ?? []) { Bars(items: bars, limit: 3) }
                }
            }
        case "gist":
            if case .stream(let items) = o["topics"] {
                ItemRows(items: items) { list in Text(list.present.map { $0["name"].asText }.joined(separator: ", ")) }
            } else if let bars = scored(o["topics"]?.present ?? []) {
                Bars(items: bars)
            }
        case "emo":
            if case .stream(let items) = o["emoji"] {
                ItemRows(items: items) { Text($0.asText).font(.title3) }
            } else {
                Text(o["emoji"].asText).font(.system(size: 40))
            }
        case "shapes":
            ShapesPreview(state: state)
        case "moderator":
            if case .stream = o["safe"] { ValueView(value: o["safe"]) } else {
                let safe = o["safe"]?.asText == "true"
                HStack {
                    Text(safe ? "Safe to show" : "Flagged").font(.title3.weight(.semibold))
                    Pill(text: "\(Int(((o["score"]?.asNumber ?? 0) * 100).rounded()))", good: safe)
                }
            }
        case "eye":
            EyePreview(node: node, state: state)
        case "uhm":
            let fillers = o["fillers"]?.present ?? []
            VStack(alignment: .leading, spacing: 6) {
                Text(fillers.count == 1 ? "1 filler word" : "\(fillers.count) filler words").font(.title3.weight(.semibold))
                ForEach(Array(fillers.prefix(5).enumerated()), id: \.offset) { _, f in
                    Text("\(f["type"].asText) at \(clock(f["start"]?.asNumber ?? 0))").foregroundStyle(.secondary)
                }
            }
        case "clips":
            ItemRows(items: o["clips"]?.items ?? []) { clip in
                VStack(alignment: .leading, spacing: 2) {
                    if case .file(let url)? = clip["file"] { FileLabel(url: url) }
                    Text("\(clock(clip["durationSec"]?.asNumber ?? 0)), \(clip["text"].asText)").lineLimit(2).foregroundStyle(.secondary)
                }
            }
        case "duplicates":
            Text("\(o["keep"]?.present.count ?? 0) to keep, \(o["others"]?.present.count ?? 0) near-duplicates").foregroundStyle(.secondary)
        case "if":
            if state.inputs["value"]?.isStream == true {
                Text("\(o["yes"]?.present.count ?? 0) to If, \(o["no"]?.present.count ?? 0) to Else").foregroundStyle(.secondary)
            } else {
                Pill(text: o["yes"] != nil ? "If" : "Else", good: o["yes"] != nil)
            }
        case "merge": ValueView(value: o["value"])
        case "list": ValueView(value: o["result"])
        case "best": ValueView(value: o["best"])
        case "template": primary(o["text"])
        default: EmptyView()
        }
    }

    @ViewBuilder private func primary(_ v: Value?) -> some View {
        if case .stream(let items) = v {
            ItemRows(items: items) { ValueView(value: $0) }
        } else {
            ValueView(value: v)
        }
    }
}

struct ShapesPreview: View {
    let state: StepState

    var body: some View {
        if case .stream = state.outputs?["kind"] {
            let kinds = state.outputs?["kind"]?.present.map { $0.asText == "none" ? "Not a shape" : $0.asText.capitalized } ?? []
            Text(kinds.joined(separator: ", "))
        } else if case .stroke(let stroke) = state.inputs["stroke"] {
            let shape: CleanShape? = if case .shape(let s) = state.outputs?["shape"] { s } else { nil }
            VStack(alignment: .leading, spacing: 8) {
                ShapeBoard(shapes: shape.map { [$0] } ?? [], strokes: [stroke.points]).frame(height: 130)
                Text(shape?.kind.capitalized ?? "Not a shape").font(.title3.weight(.semibold))
            }
        }
    }
}

/// The photo with Eye's boxes on it, its best guesses, and the fields chosen.
struct EyePreview: View {
    let node: Node
    let state: StepState
    @State private var reading: PhotoReading?

    var body: some View {
        let o = state.outputs ?? [:]
        let fields = node.params["fields"]?.strings ?? EyeFields.defaults
        if o["detail"]?.isStream == true || o.values.contains(where: \.isStream) {
            let f = fields.first { $0 != "detail" && $0 != "crop" } ?? "subject"
            if case .stream(let items) = o[f] {
                let photos = state.inputs["image"]?.items ?? []
                VStack(alignment: .leading, spacing: 6) {
                    Text(EyeFields.byID[f]?.label ?? f).font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(photos.enumerated()), id: \.offset) { i, p in
                        if let photo = p?.photo {
                            HStack(spacing: 10) {
                                Image(decorative: photo.thumb, scale: 1)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 28, height: 28)
                                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                let v = i < items.count ? items[i] : nil
                                Text(v == nil && EyeFields.byID[f]?.group == "faces" ? "No face" : fmt(v, f))
                                    .monospacedDigit()
                                    .opacity(v == nil ? 0.6 : 1)
                            }
                        }
                    }
                }
            }
        } else if let photo = state.inputs["image"]?.photo {
            VStack(alignment: .leading, spacing: 10) {
                Image(decorative: photo.thumb, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay { boxes }
                    .frame(maxWidth: .infinity, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                if fields.contains("subject"), let reading {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(EyeFields.byID["subject"]!.label).font(.caption).foregroundStyle(.secondary)
                        Bars(items: guesses(reading), limit: 3)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(fields.filter { !["detail", "scenes", "crop", "subject"].contains($0) }, id: \.self) { f in
                        GridRow {
                            Text(EyeFields.byID[f]?.label ?? f).foregroundStyle(.secondary)
                            Text(fmt(o[f], f))
                        }
                    }
                }
                .font(.callout)
                if fields.contains("scenes"), let bars = scored(o["scenes"]?.present ?? []) { Bars(items: bars, limit: 3) }
            }
            .task(id: ObjectIdentifier(photo)) { reading = await EyeReadings.shared.reading(for: photo) }
        }
    }

    private var boxes: some View {
        GeometryReader { geo in
            if let r = reading {
                let all: [(PhotoReading.Box, Color, Bool)] = surePeople(r).map { ($0.box, Theme.rgb(0xC3D3CE), false) }
                    + surePets(r).map { ($0.box, Theme.rgb(0xDB704C), false) }
                    + sureFaces(r).map { ($0.box, Theme.rgb(0xF8DBCA), true) }
                ForEach(Array(all.enumerated()), id: \.offset) { _, item in
                    let (b, color, dashed) = item
                    Rectangle()
                        .strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [4, 3] : []))
                        .frame(width: (b.x1 - b.x0) * geo.size.width, height: (b.y1 - b.y0) * geo.size.height)
                        .offset(x: b.x0 * geo.size.width, y: b.y0 * geo.size.height)
                }
            }
        }
    }

    /// Counts as numbers, every other number as the score it is.
    private func fmt(_ v: Value?, _ field: String) -> String {
        switch v {
        case nil: "None"
        case .text(let s): s.isEmpty ? "None" : s
        case .number(let n): isScore("eye", field) ? "\(Int((n * 100).rounded()))%" : Value.format(n)
        case .bool(let b): b ? "Yes" : "No"
        case .list(let l): l.compactMap { $0?.asText }.joined(separator: ", ")
        default: v!.asText
        }
    }
}

/// Seconds as minutes and seconds, as 1:05.
private func clock(_ seconds: Double) -> String {
    Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
}

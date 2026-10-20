import Foundation
import Transcript

/// The moments worth sharing, cut out of the recording or video the sound came
/// from, with captions burned in or written beside each clip.
enum ClipsStep {
    static let def = StepDef(
        type: "clips", title: "Clips", description: "Cut the moments worth sharing, with captions",
        category: .model, model: .clips,
        inputs: [Port(id: "audio", type: .audio, label: "Recording or video"),
                 Port(id: "words", type: .any, label: "Words with timings", list: true)],
        outputs: [Port(id: "files", type: .any, label: "Clip files"), Port(id: "clips", type: .any, label: "Clips", each: "clip")],
        defaults: ["captions": "off", "position": "bottom", "align": "center", "weight": "bold", "color": "white", "style": "shadow",
                   "quality": "high"],
        pick: Pick(defaults: ["files"])
    ) { run in
        guard let audio = run.inputs["audio"]?.audio, let source = audio.file else {
            throw StepError("Clips cut a recording or a video, and this sound has no file")
        }
        let words = timedWords(run.inputs["words"]).timed
        let sentences = Sentence.sentences(from: words)
        guard sentences.count >= 3 else { throw StepError("Clips need at least three sentences to choose from") }
        let asked = run.params["captions"]?.string ?? "off"
        guard var captions = CaptionMode(rawValue: asked) else { throw StepError("Captions are burn, srt, or off, not \(asked)") }
        let style = try CaptionStyle(run.params)
        let info = try await Cutter.info(source)
        if captions == .burn, !info.hasVideo {
            captions = .srt
            run.context.note = "\(source.lastPathComponent) has no picture, so the captions are written beside each clip"
        }

        let moments = try await run.context.timed { try await ModelHub.clips.moments(in: sentences, count: run.params["count"]?.int) }
        let folder = try Media.scratch()
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = clipExtension(source, video: info.hasVideo)
        var files: [Value] = [], clips: [Value] = []
        for (i, moment) in moments.enumerated() {
            run.context.progress(i, moments.count)
            var clip = folder.appending(path: "\(stem)_clip-\(i + 1).\(ext)")
            let spoken = ClipCaptions.shift(words, into: moment.ranges)
            var fields: [(String, Value)] = [("id", .number(Double(i + 1))), ("start", .number(moment.start)), ("end", .number(moment.end)),
                                             ("durationSec", .number(moment.duration)), ("text", .text(moment.text)), ("score", .number(moment.score))]
            if captions == .burn {
                try await Burner.cut(source, ranges: moment.ranges, words: spoken, style: style, to: clip)
            } else {
                clip = try await Cutter.cut(source, ranges: moment.ranges, to: clip)
            }
            files.append(.file(clip))
            fields.append(("file", .file(clip)))
            if captions == .srt {
                let srt = clip.deletingPathExtension().appendingPathExtension("srt")
                try CaptionFile.srt(Captions.cues(from: spoken, sentences: Sentence.sentences(from: spoken))).write(to: srt, atomically: true, encoding: .utf8)
                files.append(.file(srt))
                fields.append(("captions", .file(srt)))
            }
            clips.append(.record(fields))
        }
        return ["files": .list(files), "clips": .list(clips)]
    }

    /// A clip keeps its source's container where a cut can write it, else MP4
    /// for video and M4A for sound.
    private static func clipExtension(_ source: URL, video: Bool) -> String {
        let ext = source.pathExtension.lowercased()
        if video { return ["mov", "mp4", "m4v"].contains(ext) ? ext : "mp4" }
        return ["m4a", "wav", "aif", "aiff", "caf"].contains(ext) ? ext : "m4a"
    }
}

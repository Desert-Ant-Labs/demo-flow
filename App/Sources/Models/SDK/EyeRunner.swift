import CoreGraphics
import Foundation
import Eye

final class EyeRunner: ModelRunner {
    private let eye = Eye()
    private let serial = Serial()

    func isDownloaded() -> Bool { eye.isDownloaded() }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await eye.download(progress: progress)
        // Core ML specializes the photo function on its first prediction, which
        // takes most of a minute. Paying it here keeps it out of the first photo.
        let gray = try ImagePixels(width: 64, height: 64, rgb: [UInt8](repeating: 128, count: 64 * 64 * 3))
        let eye = eye
        _ = try await serial.run { try await eye.analyze(gray) }
    }

    func analyze(_ image: CGImage) async throws -> PhotoReading {
        let eye = eye
        return try await serial.run {
            let a = try await eye.analyze(image)
            guard let details = a.details else { throw StepError("Eye returned nothing for this photo") }
            return Self.reading(details)
        }
    }

    /// Groups of near-duplicates, best first, as indices into `images`. With a
    /// capture time for every photo, only photos taken close together count.
    func duplicates(_ images: [CGImage], dates: [Double]?, progress: (Int) -> Void) async throws -> [[Int]] {
        let eye = eye
        var analyses: [Analysis] = []
        for (i, image) in images.enumerated() {
            progress(i)
            analyses.append(try await serial.run { try await eye.analyze(image) })
        }
        return Eye.duplicates(in: analyses, dates: dates)
    }

    private static func box(_ b: Box) -> PhotoReading.Box {
        .init(x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1)
    }

    private static func reading(_ a: Details) -> PhotoReading {
        var r = PhotoReading()
        if let p = a.photo {
            r.type = p.type
            r.reject = p.reject
            r.sensitive = p.sensitive
            r.scenes = p.scenes
            r.blur = p.blur
            r.aesthetic = p.aesthetic
            r.keeper = p.keeper
            r.cover = p.cover
        }
        if let l = a.layout {
            r.people = l.people.map { .init(confidence: $0.confidence, box: box($0.box)) }
            r.pets = l.pets.map { .init(confidence: $0.confidence, box: box($0.box)) }
            r.shot = l.shot
            r.crops = l.crops.map { (box($0.box), $0.score) }
        }
        r.faces = (a.faces ?? []).map {
            .init(confidence: $0.confidence, box: box($0.box), smile: $0.smile, eyesOpen: $0.eyesOpen,
                  looking: $0.looking, expression: $0.expression)
        }
        r.sharpness = a.sharpness?.score
        r.detail = detail(a)
        return r
    }

    /// Everything Eye said, as data, without the embedding and the grids.
    private static func detail(_ a: Details) -> Value {
        func scores(_ d: [String: Double]) -> Value {
            .record(d.sorted { $0.value > $1.value }.map { ($0.key, .number($0.value)) })
        }
        func boxValue(_ b: Box) -> Value {
            .record([("x0", .number(b.x0)), ("y0", .number(b.y0)), ("x1", .number(b.x1)), ("y1", .number(b.y1))])
        }
        var fields: [(String, Value)] = []
        if let p = a.photo {
            fields.append(("photo", .record([
                ("aesthetic", .number(p.aesthetic)), ("keeper", .number(p.keeper)), ("cover", .number(p.cover)),
                ("bokeh", .number(p.bokeh)), ("type", scores(p.type)), ("reject", scores(p.reject)),
                ("sensitive", scores(p.sensitive)), ("blur", scores(p.blur)),
                ("scenes", scores(p.scenes.filter { $0.value >= 0.05 })),
            ])))
        }
        if let l = a.layout {
            let found = { (list: [Detection]) -> Value in
                .list(list.map { .record([("label", .text($0.label)), ("confidence", .number($0.confidence)), ("box", boxValue($0.box))]) })
            }
            fields.append(("layout", .record([
                ("people", found(l.people)), ("pets", found(l.pets)), ("shot", scores(l.shot)),
                ("crops", .list(l.crops.map { .record([("box", boxValue($0.box)), ("score", .number($0.score))]) })),
            ])))
        }
        if let faces = a.faces {
            fields.append(("faces", .list(faces.map { f in
                .record([
                    ("box", boxValue(f.box)), ("confidence", .number(f.confidence)), ("smile", .number(f.smile)),
                    ("eyesOpen", .number(f.eyesOpen)), ("looking", .number(f.looking)), ("expression", scores(f.expression)),
                ])
            })))
        }
        if let s = a.sharpness { fields.append(("sharpness", .number(s.score))) }
        return .record(fields)
    }
}

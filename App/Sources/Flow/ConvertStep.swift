import AppKit
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The formats Convert writes, grouped by what they hold.
enum FileFormat: String, CaseIterable, Sendable {
    case jpeg, png, heic, tiff, m4a, wav, aiff, txt, md, rtf, html, csv, json

    enum Group: String, CaseIterable, Sendable {
        case photo, audio, text, data

        /// What a value of this kind is called in a sentence.
        var noun: String {
            switch self {
            case .photo: "a photo"
            case .audio: "a recording"
            case .text: "text"
            case .data: "a table"
            }
        }

        var label: String {
            switch self {
            case .photo: "Photo"
            case .audio: "Audio"
            case .text: "Text"
            case .data: "Table or data"
            }
        }
    }

    var label: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .tiff: "TIFF"
        case .m4a: "M4A"
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .txt: "Plain text"
        case .md: "Markdown"
        case .rtf: "Rich text (RTF)"
        case .html: "Web page (HTML)"
        case .csv: "Spreadsheet (CSV)"
        case .json: "Data (JSON)"
        }
    }

    var ext: String { self == .jpeg ? "jpg" : rawValue }

    var group: Group {
        switch self {
        case .jpeg, .png, .heic, .tiff: .photo
        case .m4a, .wav, .aiff: .audio
        case .txt, .md, .rtf, .html: .text
        case .csv, .json: .data
        }
    }

    static func of(_ group: Group) -> [FileFormat] { allCases.filter { $0.group == group } }

    /// What a value can be written as.
    static func group(of value: Value?) -> Group? {
        switch value {
        case .image: .photo
        case .audio: .audio
        case .text, .number, .bool: .text
        case .record: .data
        case .list(let l), .stream(let l):
            l.lazy.compactMap { $0 }.first.flatMap { item in
                if case .record = item { return .data }
                return group(of: item)
            }
        default: nil
        }
    }
}

enum ConvertStep {
    static let def = StepDef(
        type: "convert", title: "Convert", description: "Photos to JPEG, PNG, or HEIC, audio to M4A or WAV, text to Markdown or RTF, tables to CSV",
        category: .logic,
        inputs: [Port(id: "value", type: .any, label: "Value")],
        outputs: [Port(id: "file", type: .any, label: "File")],
        defaults: ["to": ""]
    ) { run in
        guard let value = run.inputs["value"] else { return [:] }
        let chosen = FileFormat(rawValue: run.params["to"]?.string ?? "")
        if case .list(let items) = value, FileFormat.group(of: value) != .data {
            let files = try items.compactMap { try $0.map { try convert($0, to: chosen) } }
            return ["file": .list(files)]
        }
        return ["file": try convert(value, to: chosen)]
    }

    /// One value as a file in `format`, or in the first format of its kind
    /// when none is chosen. A photo stays a photo, read from its new file.
    static func convert(_ value: Value, to chosen: FileFormat?) throws -> Value {
        guard let group = FileFormat.group(of: value) else { throw StepError("Convert takes photos, audio, text, or a table") }
        let format = chosen ?? FileFormat.of(group)[0]
        guard format.group == group else {
            let choices = FileFormat.of(group).map(\.label).formatted(.list(type: .or))
            throw StepError("Choose a format for \(group.noun): \(choices)")
        }
        let folder = Library.folder("Converted").appending(path: format.rawValue)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        switch value {
        case .image(let photo):
            let source = photo.file?.standardizedFileURL.path(percentEncoded: false)
                ?? fingerprint(photo.image.dataProvider?.data as Data? ?? Data())
            let url = place(stem(photo.name, "photo"), format, in: folder, from: source)
            try writePhoto(photo, format, to: url)
            FileMark.set(url, sourceMark, source)
            return .image(try Media.photo(url))
        case .audio(let clip):
            let source = clip.samples.withUnsafeBytes { fingerprint($0) }
            let url = place(stem(clip.name, "recording"), format, in: folder, from: source)
            try writeAudio(clip, format, to: url)
            FileMark.set(url, sourceMark, source)
            return .file(url)
        case .record, .list, .stream:
            let text = format == .csv ? CSV.text(value.present.isEmpty ? [value] : value.present) : value.jsonText()
            let url = folder.appending(path: "table-\(fingerprint(text.utf8))." + format.ext)
            try Data(text.utf8).write(to: url, options: .atomic)
            return .file(url)
        default:
            let text = value.asText
            let source = fingerprint(text.utf8)
            let url = place(stem(String(text.prefix(40)), "text"), format, in: folder, from: source)
            try writeText(text, format, to: url)
            FileMark.set(url, sourceMark, source)
            return .file(url)
        }
    }

    /// Where a converted file goes: under its own name, unless something else
    /// converted earlier already has that name, and then with a number. Two
    /// IMG_0001.jpg from different folders never overwrite each other, and
    /// the same photo converted again keeps one file.
    private static func place(_ stem: String, _ format: FileFormat, in folder: URL, from source: String) -> URL {
        var url = folder.appending(path: stem + "." + format.ext), k = 2
        while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)), FileMark.get(url, sourceMark) != source {
            url = folder.appending(path: "\(stem)-\(k)." + format.ext)
            k += 1
        }
        return url
    }

    /// What a converted file was made from: the original's path, or for a
    /// photo, recording, or text without one, a fingerprint of it.
    private static let sourceMark = "com.desertant.flow.source"

    /// A name for the new file from the old one, without its extension or
    /// anything a file name cannot hold.
    private static func stem(_ name: String, _ fallback: String) -> String {
        let s = (name as NSString).deletingPathExtension
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? fallback : s
    }

    /// From the original file at full size when there is one, keeping what
    /// the camera wrote into it; otherwise from the working copy.
    private static func writePhoto(_ photo: Photo, _ format: FileFormat, to url: URL) throws {
        let type: UTType = switch format {
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        default: .jpeg
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw StepError("This Mac cannot write \(format.label)")
        }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        if let file = photo.file, let source = CGImageSourceCreateWithURL(file as CFURL, nil) {
            CGImageDestinationAddImageFromSource(dest, source, 0, options)
        } else {
            CGImageDestinationAddImage(dest, photo.image, options)
        }
        guard CGImageDestinationFinalize(dest) else { throw StepError("The \(format.label) could not be written") }
    }

    static func writeAudio(_ clip: AudioClip, _ format: FileFormat, to url: URL) throws {
        if format == .wav { return try Media.wav(clip).write(to: url, options: .atomic) }
        let settings: [String: Any] = format == .m4a
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: clip.sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 192_000]
            : [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: clip.sampleRate, AVNumberOfChannelsKey: 1,
               AVLinearPCMBitDepthKey: 16, AVLinearPCMIsBigEndianKey: true, AVLinearPCMIsFloatKey: false]
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(clip.samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { throw StepError("The \(format.label) could not be written") }
        clip.samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: clip.samples.count) }
        buffer.frameLength = AVAudioFrameCount(clip.samples.count)
        try file.write(from: buffer)
    }

    private static func writeText(_ text: String, _ format: FileFormat, to url: URL) throws {
        let data: Data
        switch format {
        case .rtf, .html:
            let s = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)])
            let type: NSAttributedString.DocumentType = format == .rtf ? .rtf : .html
            data = try s.data(from: NSRange(location: 0, length: s.length), documentAttributes: [.documentType: type])
        default:
            data = Data(text.utf8)
        }
        try data.write(to: url, options: .atomic)
    }

    /// Eight hex digits that stay the same for the same bytes, so two tables
    /// get two files and the same table run again keeps one.
    private static func fingerprint(_ bytes: some Sequence<UInt8>) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(String(hash, radix: 16).suffix(8))
    }
}

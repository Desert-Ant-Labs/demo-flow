import AVFoundation
import Transcript
import UniformTypeIdentifiers

extension Media {
    static func isVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
    }

    /// A new folder in this launch's temporary folder.
    static func scratch() throws -> URL {
        let folder = Exports.folder.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The sound written to a file named `stem`, put back into the picture
    /// of `source` when that is a video.
    static func written(_ clip: AudioClip, stem: String, picture source: URL?) async throws -> AudioClip {
        let folder = try scratch()
        let file = folder.appending(path: "\(stem).wav")
        try wav(clip).write(to: file)
        guard let source, isVideo(source) else {
            return AudioClip(samples: clip.samples, sampleRate: clip.sampleRate, name: clip.name, file: file)
        }
        let sound = folder.appending(path: "\(stem).m4a")
        try await Cutter.export(AVURLAsset(url: file), preset: AVAssetExportPresetAppleM4A, as: .m4a, to: sound)
        let video = try await Cutter.replaceAudio(of: source, with: sound, to: folder.appending(path: "\(stem).\(source.pathExtension)"))
        return AudioClip(samples: clip.samples, sampleRate: clip.sampleRate, name: clip.name, file: video)
    }
}

/// Writing recordings and videos out of the files they came from, the way the
/// CLI does on a Mac: cuts copy the tracks as they are, and a picture keeps
/// its size and frame rate.
enum Cutter {
    struct Info: Sendable {
        let hasVideo: Bool
        let hasAudio: Bool
        /// The picture as it plays, turned the way the file says to show it.
        let size: CGSize
    }

    static func info(_ source: URL) async throws -> Info {
        let asset = AVURLAsset(url: source)
        guard try await asset.load(.isReadable) else { throw StepError("\(source.lastPathComponent) can't be read") }
        let video = try await asset.loadTracks(withMediaType: .video).first
        var size = CGSize.zero
        if let video {
            let (natural, transform) = try await video.load(.naturalSize, .preferredTransform)
            let turned = natural.applying(transform)
            size = CGSize(width: abs(turned.width).rounded(), height: abs(turned.height).rounded())
        }
        return Info(hasVideo: video != nil, hasAudio: try await !asset.loadTracks(withMediaType: .audio).isEmpty, size: size)
    }

    /// The ranges of `source` end to end, and the file written: `destination`,
    /// or the same name as MP4 or M4A when its container can't hold the
    /// tracks as they are. A video cut lands on keyframes.
    static func cut(_ source: URL, ranges: [TimeRange], to destination: URL) async throws -> URL {
        let composition = try await composition(of: AVURLAsset(url: source), keeping: ranges)
        let video = try await !composition.loadTracks(withMediaType: .video).isEmpty
        let type = fileType(destination) ?? (video ? .mp4 : .m4a)
        let fits = await AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)?
            .compatibleFileTypes.contains(type) ?? false
        if fits {
            do {
                try await export(composition, preset: AVAssetExportPresetPassthrough, as: type, to: destination)
                return destination
            } catch {
                // Passthrough stops on some AAC ranges, as one that starts in
                // the first 0.1s of an m4a. The same range re-encoded works.
            }
        }
        let encoded = destination.deletingPathExtension().appendingPathExtension(video ? "mp4" : "m4a")
        try await export(composition, preset: video ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A,
                         as: video ? .mp4 : .m4a, to: encoded)
        return encoded
    }

    /// `video`'s picture with `audio` as its sound, and the file written:
    /// `destination`, or the same name as MP4 when re-encoded.
    static func replaceAudio(of video: URL, with audio: URL, to destination: URL) async throws -> URL {
        let picture = AVURLAsset(url: video), sound = AVURLAsset(url: audio)
        guard let sourceVideo = try await picture.loadTracks(withMediaType: .video).first,
              let sourceAudio = try await sound.loadTracks(withMediaType: .audio).first
        else { throw StepError("\(video.lastPathComponent) has no picture to keep") }
        let length = try await picture.load(.duration)
        let composition = AVMutableComposition()
        let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try track?.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: sourceVideo, at: .zero)
        track?.preferredTransform = try await sourceVideo.load(.preferredTransform)
        let soundLength = try await sound.load(.duration)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(length, soundLength)), of: sourceAudio, at: .zero)
        do {
            try await export(composition, preset: AVAssetExportPresetPassthrough, as: fileType(destination) ?? .mp4, to: destination)
            return destination
        } catch {
            let encoded = destination.deletingPathExtension().appendingPathExtension("mp4")
            try await export(composition, preset: AVAssetExportPresetHighestQuality, as: .mp4, to: encoded)
            return encoded
        }
    }

    static func composition(of asset: AVAsset, keeping ranges: [TimeRange]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        let sourceVideo = try await asset.loadTracks(withMediaType: .video).first
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
        guard sourceVideo != nil || sourceAudio != nil else { throw StepError("That file has nothing to play") }
        let whole = try await CMTimeRange(start: .zero, duration: asset.load(.duration))
        let video = sourceVideo.flatMap { _ in composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) }
        let audio = sourceAudio.flatMap { _ in composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
        var cursor = CMTime.zero
        for range in ranges {
            let span = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 600),
                                   duration: CMTime(seconds: range.duration, preferredTimescale: 600)).intersection(whole)
            guard span.duration > .zero else { continue }
            if let sourceVideo, let video { try video.insertTimeRange(span, of: sourceVideo, at: cursor) }
            if let sourceAudio, let audio { try audio.insertTimeRange(span, of: sourceAudio, at: cursor) }
            cursor = cursor + span.duration
        }
        guard cursor > .zero else { throw StepError("That clip lies outside the recording") }
        if let sourceVideo, let video { video.preferredTransform = try await sourceVideo.load(.preferredTransform) }
        return composition
    }

    static func export(_ asset: AVAsset, preset: String, as type: AVFileType, videoComposition: AVVideoComposition? = nil,
                       to destination: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw StepError("\(destination.lastPathComponent) can't be written")
        }
        session.videoComposition = videoComposition
        try? FileManager.default.removeItem(at: destination)
        do {
            try await session.export(to: destination, as: type)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func fileType(_ url: URL) -> AVFileType? {
        switch url.pathExtension.lowercased() {
        case "mov": .mov
        case "mp4": .mp4
        case "m4v": .m4v
        case "m4a": .m4a
        case "wav": .wav
        case "aif", "aiff": .aiff
        case "caf": .caf
        default: nil
        }
    }
}

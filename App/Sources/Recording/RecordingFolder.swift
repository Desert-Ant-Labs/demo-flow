import Foundation

/// Where recordings are kept, along with the hidden scratch files a
/// recording works in while it records.
enum RecordingFolder {
    static var url: URL { Library.folder("Recordings") }

    /// The start of a meeting's working file and of Who's scratch file.
    static let meeting = ".Meeting ", speakers = ".speakers-"

    /// The time a recording's files are named after, with dots for colons,
    /// which Finder shows as slashes.
    static func stamp(_ date: Date = .now) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: ".")
    }

    /// Removes scratch files left by a recording that never finished, as when
    /// Flow quit in the middle of it. A recording writes its scratch files all
    /// the time it runs, and mixing one takes far less than ten minutes, so
    /// one untouched for that long is no longer in use, even by another copy
    /// of Flow.
    static func sweep() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files where [meeting, speakers].contains(where: file.lastPathComponent.hasPrefix) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < Date.now.addingTimeInterval(-600) { try? fm.removeItem(at: file) }
        }
    }
}

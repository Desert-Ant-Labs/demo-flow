import CoreAudio
import Foundation
import UniformTypeIdentifiers

/// Which apps are using a microphone, from Core Audio's list of processes.
/// A call starts when a call app takes input and ends when it lets go.
enum Microphone {
    struct User: Hashable {
        let pid: pid_t
        let bundleID: String
    }

    static func users() -> Set<User> {
        var users = Set<User>()
        for process in processes() where bool(process, kAudioProcessPropertyIsRunningInput) {
            let pid = pid_t(bitPattern: number(process, kAudioProcessPropertyPID) ?? 0)
            guard pid != getpid(), let id = string(process, kAudioProcessPropertyBundleID), !id.isEmpty else { continue }
            users.insert(User(pid: pid, bundleID: id))
        }
        return users
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func processes() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func number(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func bool(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        (number(object, selector) ?? 0) != 0
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var result: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return nil }
        return result?.takeRetainedValue() as String?
    }
}

/// Tells about new files in a folder once they have stopped growing. Files
/// already there when it starts, or seen before, do not count. A folder that
/// is missing, or goes away, is looked for again until it is back.
@MainActor
final class FolderWatcher {
    let folder: URL
    /// Whether the folder is gone, so nothing in it can be watched.
    private(set) var missing = false
    private var seen: Set<String>
    /// Whether the files in the folder when it opens are old ones: on the
    /// first start without a saved list, and whenever the folder comes back.
    private var fresh: Bool
    private let found: ([URL]) -> Void
    private let lost: (Bool) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var settle: Task<Void, Never>?
    private var retry: Task<Void, Never>?

    /// Without `seen`, it starts from the files there now.
    init(folder: URL, seen: Set<String>?, lost: @escaping (Bool) -> Void = { _ in }, found: @escaping ([URL]) -> Void) {
        self.folder = folder
        self.seen = seen ?? []
        self.fresh = seen == nil
        self.lost = lost
        self.found = found
    }

    /// The regular files in the folder, or nil when it can't be read.
    private static func files(in folder: URL) -> [URL]? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return nil }
        return urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    func start() {
        guard source == nil else { return }
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return gone() }
        if fresh, let files = Self.files(in: folder) {
            seen.formUnion(files.map(\.lastPathComponent))
            fresh = false
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            let events = source?.data ?? []
            MainActor.assumeIsolated {
                // The folder itself was deleted or moved: what is open is no
                // longer the folder at this path.
                if events.isDisjoint(with: [.delete, .rename]) { self?.changed() } else { self?.gone() }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        if missing {
            missing = false
            lost(false)
        }
        changed()
    }

    func stop() {
        source?.cancel()
        source = nil
        settle?.cancel()
        retry?.cancel()
    }

    /// Looks for the folder every few seconds until it is back. What is in
    /// it then was not seen arriving, so it doesn't count as new.
    private func gone() {
        stop()
        fresh = true
        if !missing {
            missing = true
            lost(true)
        }
        retry = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                if FileManager.default.fileExists(atPath: self.folder.path) { return self.start() }
            }
        }
    }

    var known: Set<String> { seen }

    /// Names a flow wrote into the folder, which are not new files to run on.
    func remember(_ names: some Sequence<String>) { seen.formUnion(names) }

    private func changed() {
        settle?.cancel()
        settle = Task { [weak self] in
            guard let self else { return }
            var sizes: [URL: Int] = [:]
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let files = Self.files(in: self.folder) else { return }
                // Names no longer in the folder are let go, so a file that
                // comes back under the same name, like a scanner's scan.pdf
                // once the flow has filed the last one, counts as new.
                self.seen.formIntersection(files.map(\.lastPathComponent))
                let new = files.filter { !self.seen.contains($0.lastPathComponent) }
                guard !new.isEmpty else { return }
                let now = Dictionary(new.map { ($0, (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1) }, uniquingKeysWith: { a, _ in a })
                if now == sizes {
                    self.seen.formUnion(new.map(\.lastPathComponent))
                    self.found(new.sorted { $0.lastPathComponent < $1.lastPathComponent })
                    return
                }
                sizes = now
            }
        }
    }
}

/// What kind of file an input step takes, to pick the ones a flow can use.
enum InputKind {
    case photos, photo, audio, text

    init?(_ type: String) {
        switch type {
        case "photos": self = .photos
        case "image": self = .photo
        case "audio", "record": self = .audio
        case "text": self = .text
        default: return nil
        }
    }

    func takes(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        switch self {
        case .photos, .photo: return type.conforms(to: .image)
        case .audio: return type.conforms(to: .audio) || type.conforms(to: .audiovisualContent)
        case .text: return type.conforms(to: .text)
        }
    }

    /// Several files go to Photos at once; every other input runs once a file.
    var batches: Bool { self == .photos }

    /// What a flow's first step can take from files: for When files arrive,
    /// the kinds its wired outputs hand on.
    static func of(_ node: Node, in graph: Graph) -> [InputKind] {
        switch node.type {
        case "shortcut" where (node.params["takes"]?.string ?? "voice") != "clipboard":
            return []
        case "watch", "shortcut":
            let wired = graph.edges.filter { $0.source == node.id }.map(\.sourceHandle)
            let kinds: [InputKind] = wired.compactMap {
                switch $0 {
                case "photos": .photos
                case "audio": .audio
                case "text": .text
                case "files": nil
                default: nil
                }
            }
            let unique = kinds.reduce(into: [InputKind]()) { if !$0.contains($1) { $0.append($1) } }
            return unique.isEmpty ? [.photos, .audio, .text] : unique
        default: return InputKind(node.type).map { [$0] } ?? []
        }
    }
}

extension Graph {
    /// What the flow's first step can take from files, if anything.
    var takes: [InputKind] {
        TriggerCenter.input(of: self).map { InputKind.of($0, in: self) } ?? []
    }
}

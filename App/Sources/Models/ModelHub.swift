import CoreGraphics
import Foundation
import Observation
import Transcript

/// Every model, made once, and how far along each one is. A flow asks for its
/// models as it opens, so they load while you look at it.
@MainActor
@Observable
final class ModelHub {
    static let shared = ModelHub()

    enum State: Equatable {
        case idle
        case downloading(Double)
        /// Loading and specializing for this Mac: the long wait on a first run.
        case preparing
        case ready
        case failed(String)

        var isWorking: Bool {
            switch self {
            case .downloading, .preparing: true
            default: false
            }
        }
    }

    private(set) var states: [ModelID: State] = [:]
    @ObservationIgnored private var tasks: [ModelID: Task<Void, Error>] = [:]

    nonisolated static let voz = VozRunner()
    nonisolated static let clear = ClearRunner()
    nonisolated static let ear = EarRunner()
    nonisolated static let redact = RedactRunner()
    nonisolated static let gist = GistRunner()
    nonisolated static let emo = EmoRunner()
    nonisolated static let tongue = TongueRunner()
    nonisolated static let toxic = ToxicRunner()
    nonisolated static let shapes = ShapesRunner()
    nonisolated static let moderator = ModeratorRunner()
    nonisolated static let eye = EyeRunner()
    nonisolated static let face = FaceRunner()
    nonisolated static let who = WhoRunner()
    nonisolated static let uhm = UhmRunner()
    nonisolated static let clips = ClipsRunner()

    nonisolated static func runner(_ id: ModelID) -> any ModelRunner {
        switch id {
        case .voz: voz
        case .clear: clear
        case .ear: ear
        case .redact: redact
        case .gist: gist
        case .emo: emo
        case .tongue: tongue
        case .toxic: toxic
        case .shapes: shapes
        case .moderator: moderator
        case .eye: eye
        case .face: face
        case .who: who
        case .uhm: uhm
        case .clips: clips
        }
    }

    func state(_ id: ModelID) -> State { states[id] ?? .idle }

    /// Returns once the model is downloaded and loaded. A second call waits on
    /// the first.
    func prepare(_ id: ModelID) async throws {
        if let task = tasks[id] { return try await task.value }
        let runner = Self.runner(id)
        states[id] = runner.isDownloaded() ? .preparing : .downloading(0)
        let task = Task {
            do {
                try await runner.prepare { fraction in
                    Task { @MainActor in
                        // Progress arrives out of order; it only ever moves forward.
                        guard case .downloading(let shown) = ModelHub.shared.state(id), fraction > shown else { return }
                        ModelHub.shared.states[id] = fraction < 1 ? .downloading(fraction) : .preparing
                    }
                }
                try? await Self.warm(id)
                states[id] = .ready
            } catch {
                states[id] = .failed(error.localizedDescription)
                tasks[id] = nil
                throw error
            }
        }
        tasks[id] = task
        try await task.value
    }

    /// Starts loading without waiting, as a flow opens.
    func prefetch(_ ids: [ModelID]) {
        for id in ids where tasks[id] == nil {
            Task { try? await prepare(id) }
        }
    }

    /// Downloads and warms every model in the background as the app opens.
    func prepareAll() {
        Task(priority: .background) {
            for id in ModelID.allCases { try? await prepare(id) }
        }
    }

    /// Core ML specializes a model on its first run, which can take a minute.
    private nonisolated static func warm(_ id: ModelID) async throws {
        let silence = [Float](repeating: 0, count: 32_000)
        switch id {
        case .voz: _ = try await voz.transcribe(silence, sampleRate: 16_000)
        case .clear: _ = try await clear.enhance([Float](repeating: 0, count: 48_000), loudness: "off")
        case .ear: _ = try await ear.identify(silence, sampleRate: 16_000)
        case .redact: _ = try await redact.find(in: "Call Anna on Friday.", confidence: 0.6)
        case .gist: _ = try await gist.classify("A short note about the weekend.", topK: 1)
        case .emo: _ = try await emo.suggestions("Great news", limit: 1)
        case .tongue: _ = try await tongue.detect("Hello there")
        case .toxic: _ = try await toxic.analyze("Have a nice day.")
        case .shapes: _ = try await shapes.recognize((0..<24).map { CGPoint(x: cos(Double($0) / 4) * 50, y: sin(Double($0) / 4) * 50) })
        case .moderator: _ = try await moderator.analyze(gray, threshold: 0.5)
        case .eye: _ = try await eye.analyze(gray)
        case .face: _ = try await face.people(in: [gray]) { _ in }
        case .who: _ = try await who.diarize(silence, sampleRate: 16_000)
        case .uhm: _ = try await uhm.fillers(silence)
        case .clips:
            let lines = ["We started this in a garage.", "Nobody thought it would work.", "Now it runs on every phone."]
            _ = try await clips.moments(in: lines.enumerated().map { Sentence(id: $0.offset, text: $0.element, start: Double($0.offset) * 3, end: Double($0.offset) * 3 + 2.5) }, count: 1)
        }
    }

    private nonisolated static let gray: CGImage = {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return context.makeImage()!
    }()

    /// Starts a failed model over.
    func retry(_ id: ModelID) {
        guard case .failed = state(id) else { return }
        states[id] = .idle
        prefetch([id])
    }
}

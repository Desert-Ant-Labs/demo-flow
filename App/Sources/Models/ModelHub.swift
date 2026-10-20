import Foundation
import Observation

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
    nonisolated static let shapes = ShapesRunner()
    nonisolated static let moderator = ModeratorRunner()
    nonisolated static let eye = EyeRunner()
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
        case .shapes: shapes
        case .moderator: moderator
        case .eye: eye
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

    /// Starts a failed model over.
    func retry(_ id: ModelID) {
        guard case .failed = state(id) else { return }
        states[id] = .idle
        prefetch([id])
    }
}

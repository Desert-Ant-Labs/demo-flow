import AppKit
import Sparkle

/// Sparkle, started once at launch.
@MainActor
final class Updates {
    static let shared = Updates()

    private let controller = SPUStandardUpdaterController(
        startingUpdater: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil,
        updaterDelegate: nil, userDriverDelegate: nil)

    var checksAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func check() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}

import AppKit
import UserNotifications

/// Results and failures, as a bonus to the edge indicator, which shows every
/// state and works with notifications turned off. One notification per run,
/// so a run that is tried again replaces what it said before; the runs of one
/// trigger share a thread.
@MainActor
enum Notifications {
    private enum Action: String {
        case open, reveal, retry, undo
    }

    private enum Category: String, CaseIterable {
        case finished, finishedWithFiles, changedFiles, failed

        var actions: [UNNotificationAction] {
            switch self {
            case .finished: [action(.open, "Open")]
            case .finishedWithFiles: [action(.open, "Open"), action(.reveal, "Show in Finder")]
            case .changedFiles: [action(.open, "Open"), UNNotificationAction(identifier: Action.undo.rawValue, title: "Undo")]
            case .failed: [UNNotificationAction(identifier: Action.retry.rawValue, title: "Try again"), action(.open, "Open")]
            }
        }

        private func action(_ action: Action, _ title: String) -> UNNotificationAction {
            UNNotificationAction(identifier: action.rawValue, title: title, options: .foreground)
        }
    }

    private static let router = Router()
    private static var center: UNUserNotificationCenter { .current() }

    static func setUp() {
        center.delegate = router
        center.setNotificationCategories(Set(Category.allCases.map {
            UNNotificationCategory(identifier: $0.rawValue, actions: $0.actions, intentIdentifiers: [], options: [])
        }))
        askPermission()
    }

    static func askPermission() {
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
    }

    /// Posts a run's result or why it stopped, when notifications are allowed.
    static func show(_ run: FlowRun) {
        guard let content = content(for: run) else { return }
        let request = UNNotificationRequest(identifier: run.id.uuidString, content: content, trigger: nil)
        Task {
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else { return }
            try? await center.add(request)
        }
    }

    static func remove(_ run: FlowRun) {
        center.removeDeliveredNotifications(withIdentifiers: [run.id.uuidString])
    }

    private static func content(for run: FlowRun) -> UNMutableNotificationContent? {
        let content = UNMutableNotificationContent()
        content.threadIdentifier = run.trigger.id.uuidString
        content.userInfo = ["run": run.id.uuidString, "file": run.file?.path ?? ""]
        content.sound = .default
        switch run.phase {
        case .finished(let summary):
            content.title = run.title
            content.body = summary
            content.categoryIdentifier = (run.canUndo ? Category.changedFiles : run.files.isEmpty ? .finished : .finishedWithFiles).rawValue
            if let attachment = attachment(run.thumbnail) { content.attachments = [attachment] }
        case .failed(let reason):
            content.title = "\(run.title) stopped"
            content.body = reason
            content.categoryIdentifier = Category.failed.rawValue
        case .recording, .running:
            return nil
        }
        return content
    }

    /// The system moves an attachment's file into its own store, so it gets a copy.
    private static func attachment(_ url: URL?) -> UNNotificationAttachment? {
        guard let url else { return nil }
        let copy = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).jpg")
        guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "thumbnail", url: copy)
    }

    fileprivate static func respond(run id: String?, file: String?, action: String) {
        guard action != UNNotificationDismissActionIdentifier else { return }
        let center = TriggerCenter.shared
        let uuid = id.flatMap(UUID.init(uuidString:))
        let run = uuid.flatMap(center.run)
        let record = center.history.first { $0.id == uuid }
        switch Action(rawValue: action) {
        case .retry: if let run { center.retry(run) }
        case .reveal: if let run { center.reveal(run) }
        case .undo:
            if let run { center.undo(run) } else if let record { center.undo(record) }
        case .open, nil:
            if let run { center.openResult(run) } else if let record { center.openResult(record) } else if let file { center.open(file) }
        }
    }

    private final class Router: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
            [.banner, .list, .sound]
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
            let info = response.notification.request.content.userInfo
            let run = info["run"] as? String
            let file = (info["file"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let action = response.actionIdentifier
            await Notifications.respond(run: run, file: file, action: action)
        }
    }
}

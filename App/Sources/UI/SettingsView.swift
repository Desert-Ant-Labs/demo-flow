import AVFoundation
import EventKit
import DesertAntUI
import ServiceManagement
import SwiftUI
import UserNotifications

/// Settings: where flows save, what Flow may use on this Mac, and the app itself.
struct SettingsView: View {
    var body: some View {
        Form {
            Section {
                SaveToRow()
            } header: {
                VStack(alignment: .leading, spacing: 20) {
                    BrandCard()
                    Text("Files")
                }
            } footer: {
                Text("Notes, receipts, and other results go in a folder of their own here, like Meeting notes.")
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                Permissions()
            }

            Section {
                OpenAtLoginToggle()
                AutomaticUpdatesToggle()
                LabeledContent("Version") {
                    HStack(spacing: 10) {
                        Text(Bundle.main.version)
                        Button("Check for Updates…") { Updates.shared.check() }
                    }
                }
                LabeledContent("Source") {
                    Link("github.com/Desert-Ant-Labs/demo-flow", destination: URL(string: "https://github.com/Desert-Ant-Labs/demo-flow")!)
                }
            } footer: {
                Text("Every model runs on this Mac. Your recordings, text, and photos never leave it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 720)
    }
}

/// Where flows save what they make.
private struct SaveToRow: View {
    @State private var path = SaveTo.root.path

    var body: some View {
        LabeledContent("Save to") {
            HStack(spacing: 8) {
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…") {
                    if let url = chooseFolder(prompt: "Save Here") {
                        path = url.path
                        UserDefaults.standard.set(path, forKey: SaveTo.key)
                    }
                }
                Button("Show in Finder", systemImage: "folder") {
                    let url = SaveTo.root
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
        }
    }
}

/// The app's card, in the brand's ink: what is on this Mac.
private struct BrandCard: View {
    @State private var size: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Flow.")
                .font(.system(size: 40, weight: .semibold))
                .tracking(-2)
            Text("Powered by Desert Ant models")
                .font(.title3)
            HStack(spacing: 24) {
                Spec(value: "\(ModelID.allCases.filter { ModelHub.runner($0).isDownloaded() }.count) of \(ModelID.allCases.count)", label: "models downloaded")
                if let size { Spec(value: size, label: "on disk") }
            }
        }
        .foregroundStyle(Theme.cream)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ink)
        .clipShape(.rect(cornerRadius: 24))
        .task { size = await Self.sizeOnDisk() }
    }

    /// What the models take in the shared Desert Ant cache.
    private static func sizeOnDisk() async -> String? {
        await Task.detached {
            let folder = URL.cachesDirectory.appending(path: "desert-ant-models")
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
            let bytes = (files?.allObjects as? [URL] ?? []).reduce(0) { total, file in
                total + ((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
            }
            guard bytes > 0 else { return nil }
            return Int64(bytes).formatted(.byteCount(style: .file)).replacingOccurrences(of: " ", with: "")
        }.value
    }
}

private struct Spec: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.cream.opacity(0.65))
        }
    }
}

/// What macOS lets Flow use, read again whenever Flow comes back to the front,
/// since each can change in System Settings.
private struct Permissions: View {
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var systemAudio = MeetingRecorder.mayRecordSystemAudio
    @State private var notifications = UNAuthorizationStatus.notDetermined
    @State private var calendar = EKEventStore.authorizationStatus(for: .event)

    var body: some View {
        Group {
            PermissionRow(title: "Microphone", detail: "For recording, and for calls and notes a flow writes down.",
                          granted: microphone == .authorized) {
                if microphone == .notDetermined {
                    Task { _ = await AVCaptureDevice.requestAccess(for: .audio); await refresh() }
                } else {
                    NSWorkspace.shared.open(Self.privacy("Privacy_Microphone"))
                }
            }
            PermissionRow(title: "System audio", detail: "To hear the other people on a call, in any app.",
                          granted: systemAudio) {
                Task {
                    if !(await MeetingRecorder.askForSystemAudio()) { NSWorkspace.shared.open(MeetingRecorder.settingsURL) }
                    await refresh()
                }
            }
            PermissionRow(title: "Calendar", detail: "To title meeting notes with the event's name. Flow works without it.",
                          granted: calendar == .fullAccess) {
                if calendar == .notDetermined {
                    Task { _ = try? await EKEventStore().requestFullAccessToEvents(); await refresh() }
                } else {
                    NSWorkspace.shared.open(Self.privacy("Privacy_Calendars"))
                }
            }
            PermissionRow(title: "Notifications", detail: "To say when a flow that runs on its own is done. Flow works without them.",
                          granted: notifications == .authorized || notifications == .provisional) {
                if notifications == .notDetermined {
                    Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]); await refresh() }
                } else {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        calendar = EKEventStore.authorizationStatus(for: .event)
        systemAudio = MeetingRecorder.mayRecordSystemAudio
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private static func privacy(_ pane: String) -> URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
            } else {
                Button("Allow…", action: action)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

/// Reads the login item from macOS each time Settings opens, since it can
/// also be turned off in System Settings > General > Login Items. macOS may
/// hold it until it is approved there, which the toggle alone would hide.
private struct OpenAtLoginToggle: View {
    @State private var isOn = SMAppService.mainApp.status == .enabled
    @State private var needsApproval = SMAppService.mainApp.status == .requiresApproval

    var body: some View {
        Toggle(isOn: $isOn) {
            Text("Open at login")
            if needsApproval {
                HStack(spacing: 4) {
                    Text("Waiting for you to allow it in Login Items.")
                    Button("Open System Settings") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.link)
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onChange(of: isOn) {
            do {
                if isOn { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {}
            refresh()
        }
    }

    private func refresh() {
        let status = SMAppService.mainApp.status
        needsApproval = status == .requiresApproval
        isOn = status == .enabled || needsApproval
    }
}

private struct AutomaticUpdatesToggle: View {
    @State private var isOn = Updates.shared.checksAutomatically

    var body: some View {
        Toggle("Check for updates automatically", isOn: $isOn)
            .onChange(of: isOn) { Updates.shared.checksAutomatically = isOn }
    }
}

private extension Bundle {
    var version: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

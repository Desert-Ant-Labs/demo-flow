import AppKit
import DesertAntUI
import SwiftUI

/// The controls of the steps a flow starts with to run on its own: whether it
/// is on, then what sets it off.
struct TriggerBody: View {
    let node: Node
    let state: StepState
    @Environment(\.flowActions) private var actions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TriggerOnRow()
            switch node.type {
            case "call":
                CallAppPicker(apps: Binding(get: { node.params["apps"]?.strings ?? CallApps.allIDs }, set: { set("apps", .array($0.map { .string($0) })) }))
                DetailCard { RecordBody(node: node, state: state, showsSource: false) }
            case "watch":
                FolderDetails(path: Binding(get: { node.params["folder"]?.string ?? "" }, set: { set("folder", .string(Samples.path(for: URL(filePath: $0)))) }))
            case "schedule":
                ScheduleDetails(hour: node.params["hour"]?.int ?? 9, minute: node.params["minute"]?.int ?? 0,
                                weekdays: Set((node.params["days"]?.array ?? []).compactMap(\.int).filter((1...7).contains))) { h, m, days in
                    actions.set(node.id, ["hour": .number(Double(h)), "minute": .number(Double(m)),
                                          "days": .array(days.sorted().map { .number(Double($0)) })])
                }
            case "shortcut":
                ShortcutDetails(node: node)
                if (node.params["takes"]?.string ?? "voice") == "voice" {
                    DetailCard { RecordBody(node: node, state: state, showsSource: false) }
                }
            default:
                EmptyView()
            }
        }
    }

    private func set(_ key: String, _ value: JSON) { actions.set(node.id, [key: value]) }
}

/// On or off, for the flow this window shows. Turning it on saves it, since
/// it runs from its file.
struct TriggerOnRow: View {
    @Environment(\.flowSession) private var session
    @Environment(\.flowActions) private var actions
    @State private var center = TriggerCenter.shared

    var body: some View {
        let path = session?.fileURL?.path
        let on = path.map(center.isOn) ?? false
        HStack(spacing: 10) {
            StateDot(on: on)
            VStack(alignment: .leading, spacing: 1) {
                Text(on ? "On" : "Off").font(.callout.weight(.semibold))
                Text(on ? "Runs on its own on this Mac." : path == nil ? "Turn it on to save it in Flows and run it on its own." : "Turn it on to run on its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle("On", isOn: Binding(get: { on }, set: { new in
                Task { await session?.turnOn(new, graph: actions.graph) }
            }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.window))
    }
}

/// On or off at a glance: a green dot with a ring that reads on any card
/// color, or a hollow one.
struct StateDot: View {
    let on: Bool
    var failed = false

    var body: some View {
        Circle()
            .fill(on ? (failed ? Theme.danger : Theme.success) : .clear)
            .overlay(Circle().strokeBorder(on ? Theme.cream.opacity(0.9) : Color.primary.opacity(0.45), lineWidth: on ? 1.5 : 1.2))
            .frame(width: 9, height: 9)
            .shadow(color: .black.opacity(on ? 0.18 : 0), radius: 1, y: 0.5)
    }
}

/// The soft card the details of a trigger sit in.
private struct DetailCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.window))
    }
}

// MARK: Call

private struct CallAppPicker: View {
    @Binding var apps: [String]
    @State private var systemAudio = MeetingRecorder.mayRecordSystemAudio

    var body: some View {
        DetailCard {
            Text("In these apps").font(.callout.weight(.medium))
            FlowRow(spacing: 6) {
                let any = Set(apps) == Set(CallApps.allIDs)
                AppPill(name: "Any call app", icon: nil, symbol: "phone", on: any) {
                    apps = any ? [] : CallApps.allIDs
                }
                ForEach(CallApps.all) { app in
                    let on = !any && app.ids.allSatisfy(apps.contains)
                    AppPill(name: app.name, icon: AppIcon.of(app), symbol: app.name == "Browsers" ? "globe" : "video", on: on) {
                        if any {
                            apps = app.ids
                        } else if on {
                            apps.removeAll { app.ids.contains($0) }
                        } else {
                            apps += app.ids
                        }
                    }
                }
            }
            if !systemAudio {
                Divider()
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("System audio is off").font(.callout.weight(.medium))
                        Text("Flow needs it to hear the other people on the call.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Allow…") { Task { systemAudio = await MeetingRecorder.askForSystemAudio() } }
                }
            }
        }
        // Allowed in System Settings, or in the dialog Turn On brings up.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            systemAudio = MeetingRecorder.mayRecordSystemAudio
        }
    }
}

private struct AppPill: View {
    let name: String
    let icon: NSImage?
    let symbol: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                } else {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 16, height: 16)
                }
                Text(name).font(.callout.weight(on ? .semibold : .regular))
            }
            .padding(.leading, 7).padding(.trailing, 11).padding(.vertical, 4)
            .background(Capsule().fill(on ? AnyShapeStyle(.primary.opacity(0.12)) : AnyShapeStyle(.clear)))
            .overlay(Capsule().strokeBorder(hover && !on ? AnyShapeStyle(.primary.opacity(0.3)) : AnyShapeStyle(Theme.hairline)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .onHover { h in withAnimation(.snappy(duration: 0.15)) { hover = h } }
    }
}

/// An app's own icon, when it is installed.
private enum AppIcon {
    @MainActor static func of(_ app: CallApps.App) -> NSImage? {
        if app.name == "Browsers" { return nil }
        for id in app.ids {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return nil
    }
}

// MARK: Folder

private struct FolderDetails: View {
    @Binding var path: String
    @State private var targeted = false

    var body: some View {
        let full = (path as NSString).expandingTildeInPath
        Group {
            if path.isEmpty {
                Button(action: choose) {
                    VStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(targeted ? AnyShapeStyle(DA.Color.accent) : AnyShapeStyle(.secondary))
                        Text("Choose a folder to watch").font(.callout.weight(.semibold))
                        Text("or drop one here").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 92)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(targeted ? AnyShapeStyle(DA.Color.accent.opacity(0.08)) : AnyShapeStyle(Theme.window)))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(targeted ? AnyShapeStyle(DA.Color.accent) : AnyShapeStyle(.primary.opacity(0.22)),
                                          style: StrokeStyle(lineWidth: targeted ? 1.5 : 1, dash: [5, 4]))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                DetailCard {
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: full))
                            .resizable()
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(URL(filePath: full).lastPathComponent).font(.callout.weight(.semibold))
                            Text((full as NSString).abbreviatingWithTildeInPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("Change…", action: choose)
                    }
                    if TriggerCenter.shared.missingFolders.contains(URL(filePath: full).path) {
                        Text("This folder is missing. Flow watches it again once it's back.")
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                    } else {
                        Text("Only files added after it's turned on count. Run Again tries it on the samples.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .overlay {
                    if targeted { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DA.Color.accent, lineWidth: 2) }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first(where: { $0.hasDirectoryPath }) else { return false }
            path = folder.path
            return true
        } isTargeted: { targeted = $0 }
    }

    private func choose() {
        if let url = chooseFolder(prompt: "Watch This Folder") { path = url.path }
    }
}

// MARK: Schedule

private struct ScheduleDetails: View {
    let hour: Int
    let minute: Int
    let weekdays: Set<Int>
    let change: (Int, Int, Set<Int>) -> Void

    var body: some View {
        DetailCard {
            HStack(spacing: 8) {
                Text("At").font(.callout.weight(.medium))
                DatePicker("", selection: time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.stepperField)
                Spacer(minLength: 0)
                Text(Schedule.days(weekdays)).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                ForEach(weekOrder, id: \.self) { day in
                    DayDot(letter: Calendar.current.veryShortWeekdaySymbols[day - 1],
                           name: Calendar.current.weekdaySymbols[day - 1],
                           on: weekdays.contains(day)) {
                        var days = weekdays
                        if days.contains(day) { days.remove(day) } else { days.insert(day) }
                        change(hour, minute, days)
                    }
                }
            }
            Text("Flow has to be open, in the menu bar, at that time.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var time: Binding<Date> {
        Binding {
            Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? .now
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            change(parts.hour ?? hour, parts.minute ?? minute, weekdays)
        }
    }

    private var weekOrder: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }
}

private struct DayDot: View {
    let letter: String
    let name: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(letter)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(on ? AnyShapeStyle(DA.Color.accent) : AnyShapeStyle(Theme.stepFill)))
                .overlay(Circle().strokeBorder(on ? AnyShapeStyle(.clear) : hover ? AnyShapeStyle(.primary.opacity(0.3)) : AnyShapeStyle(Theme.hairline)))
                .foregroundStyle(on ? AnyShapeStyle(Theme.window) : AnyShapeStyle(.primary))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? .isSelected : [])
        .onHover { h in withAnimation(.snappy(duration: 0.15)) { hover = h } }
        .help(name)
    }
}

// MARK: Shortcut

/// The keys, and what pressing them hands the flow.
private struct ShortcutDetails: View {
    let node: Node
    @Environment(\.flowActions) private var actions
    @Environment(\.flowSession) private var session

    var body: some View {
        let shortcut = Shortcut(json: node.params["keys"])
        DetailCard {
            HStack(spacing: 10) {
                Text("Shortcut").font(.callout.weight(.medium))
                ShortcutRecorder(shortcut: Binding(get: { shortcut }, set: { new in
                    actions.set(node.id, ["keys": new?.json ?? .null])
                }))
                Spacer(minLength: 0)
            }
            if let shortcut, let other = TriggerCenter.shared.clashes(shortcut, besides: session?.fileURL?.path ?? "") {
                Text("\(other) already uses \(shortcut.display). Pick other keys, or turn that flow off.")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            } else if let shortcut, HotKeys.shared.taken.contains(shortcut) {
                Text("Another app already uses \(shortcut.display). Pick other keys.")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            }
            Picker("Takes", selection: Binding(get: { node.params["takes"]?.string ?? "voice" }, set: { takes in
                actions.set(node.id, ["takes": .string(takes),
                                      "fields": .array((takes == "voice" ? ["text", "title"] : takes == "clipboard" ? ["text", "files"] : []).map { .string($0) })])
            })) {
                Text("Your voice").tag("voice")
                Text("The clipboard").tag("clipboard")
                Text("Nothing").tag("nothing")
            }
            .pickerStyle(.segmented)
            Text(Self.explain(node.params["takes"]?.string ?? "voice"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static func explain(_ takes: String) -> String {
        switch takes {
        case "voice": "Press to start recording and again to stop. Voz writes it down as you talk."
        case "clipboard": "Runs on the text or files you copied last."
        default: "Just runs the flow, with what it has saved."
        }
    }
}

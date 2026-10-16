import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key with modifiers, as the shortcut that runs a flow: "⌥⌘N".
struct Shortcut: Codable, Hashable, Sendable {
    var keyCode: UInt32
    /// What the key types, for showing it.
    var key: String
    var command = false
    var option = false
    var control = false
    var shift = false

    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_N), key: "N", command: true, option: true)

    init(keyCode: UInt32, key: String, command: Bool = false, option: Bool = false, control: Bool = false, shift: Bool = false) {
        self.keyCode = keyCode
        self.key = key
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
    }

    /// From a key press. A shortcut needs ⌘, ⌥ or ⌃, so typing in another app
    /// never runs a flow.
    init?(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.isDisjoint(with: [.command, .option, .control]) else { return nil }
        self.init(keyCode: UInt32(event.keyCode), key: Self.name(event),
                  command: flags.contains(.command), option: flags.contains(.option),
                  control: flags.contains(.control), shift: flags.contains(.shift))
    }

    /// As a step keeps it in the flow file. A key code out of range, or not
    /// a number at all, means no shortcut, so a hand-edited file can't crash Flow.
    init?(json: JSON?) {
        guard let o = json?.object, let code = o["code"]?.int.flatMap(UInt32.init(exactly:)),
              let key = o["key"]?.string else { return nil }
        self.init(keyCode: code, key: key, command: o["command"]?.bool ?? false, option: o["option"]?.bool ?? false,
                  control: o["control"]?.bool ?? false, shift: o["shift"]?.bool ?? false)
    }

    var json: JSON {
        .object(["code": .number(Double(keyCode)), "key": .string(key), "command": .bool(command),
                 "option": .bool(option), "control": .bool(control), "shift": .bool(shift)])
    }

    /// In Apple's order: ⌃⌥⇧⌘, then the key.
    var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key
    }

    var carbonModifiers: UInt32 {
        (command ? UInt32(cmdKey) : 0) | (option ? UInt32(optionKey) : 0)
            | (control ? UInt32(controlKey) : 0) | (shift ? UInt32(shiftKey) : 0)
    }

    private static let named: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func name(_ event: NSEvent) -> String {
        if let name = named[Int(event.keyCode)] { return name }
        return (event.charactersIgnoringModifiers ?? "").uppercased()
    }
}

/// The system-wide shortcuts that run flows, through Carbon's hot keys: they
/// reach Flow from any app and need no accessibility permission.
@MainActor
@Observable
final class HotKeys {
    static let shared = HotKeys()

    /// Shortcuts macOS would not give Flow, as when another app has them.
    private(set) var taken: Set<Shortcut> = []
    @ObservationIgnored private var refs: [UInt32: EventHotKeyRef] = [:]
    @ObservationIgnored private var actions: [UInt32: () -> Void] = [:]
    @ObservationIgnored private var wanted: [Shortcut: () -> Void] = [:]
    @ObservationIgnored private var handler: EventHandlerRef?

    /// Off while a shortcut is being recorded, so pressing a taken one types it
    /// into the recorder instead of running its flow.
    var suspended = false {
        didSet { apply() }
    }

    private init() {}

    /// Registers these shortcuts and drops every other one.
    func set(_ shortcuts: [Shortcut: () -> Void]) {
        wanted = shortcuts
        apply()
    }

    private func apply() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs = [:]
        actions = [:]
        guard !suspended else { return }
        installHandler()
        var taken: Set<Shortcut> = []
        for (n, (shortcut, action)) in wanted.enumerated() {
            let id = UInt32(n + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, EventHotKeyID(signature: OSType(0x464C4F57), id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[id] = ref
                actions[id] = action
            } else {
                taken.insert(shortcut)
            }
        }
        if taken != self.taken { self.taken = taken }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let key = id.id
            MainActor.assumeIsolated { HotKeys.shared.actions[key]?() }
            return noErr
        }, 1, &type, nil, &handler)
    }
}

/// Shows a shortcut, and takes a new one: click, then press the keys. Esc
/// leaves it as it was; Delete clears it.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    @State private var listening = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if listening { stop() } else { listen() }
        } label: {
            Text(listening ? "Type a shortcut" : shortcut?.display ?? "None")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(listening ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .frame(minWidth: 96)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(listening ? 0.12 : 0.07), in: .capsule)
                .overlay(Capsule().strokeBorder(listening ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .onDisappear { stop() }
    }

    private func listen() {
        listening = true
        HotKeys.shared.suspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Escape: stop()
            case kVK_Delete where event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty:
                shortcut = nil
                stop()
            default:
                guard let new = Shortcut(event) else { NSSound.beep(); return nil }
                shortcut = new
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        listening = false
        HotKeys.shared.suspended = false
    }
}

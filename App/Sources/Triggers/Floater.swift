import AppKit
import Observation
import SwiftUI

/// The small circle that shows what triggers are doing, wherever it was
/// dragged: a live level while a call records, a ring while a flow runs, and
/// a check when it is done. Hovering or clicking opens a pill beside it,
/// toward the middle of the screen, with the words and the actions; clicking
/// while a call is transcribed opens its words in a window instead. While a
/// trigger is on it rests as the ant mark, where files can be dropped to run
/// a flow on them. Works with notifications turned off.
@MainActor
@Observable
final class Floater {
    static let shared = Floater()

    /// The run it shows: one recording, then one running, then the last one
    /// to end, until it has been seen.
    private(set) var run: FlowRun?
    /// Live runs besides `run`.
    private(set) var others = 0
    private(set) var expanded = false
    private(set) var shown = false
    /// The pill opens to the left when the circle is on the right half.
    private(set) var opensLeft = true
    /// And downward when it is on the top half, so a tall chooser stays on screen.
    private(set) var opensDown = true
    /// Files are being dragged over it.
    private(set) var targeted = false
    /// Files dropped on it, waiting for a flow to be chosen.
    private(set) var offer: DropOffer?
    let levels = Levels()

    @ObservationIgnored private var panel: NSPanel?
    /// Ended runs already shown and put away.
    @ObservationIgnored private var dismissed: Set<UUID> = []
    @ObservationIgnored private var seenPhase: (UUID, FlowRun.Phase)?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var hovering = false
    @ObservationIgnored private var pinned = false
    @ObservationIgnored private var drag: (anchor: CGPoint, mouse: CGPoint)?
    /// Where the circle's center is, in screen points.
    @ObservationIgnored private var anchor: CGPoint?

    static let circle: CGFloat = 38
    /// The height of one line of the pill, which the circle is centered on.
    static let row: CGFloat = 42
    /// Room around the drawing for its shadow.
    static let margin: CGFloat = 16

    private init() {}

    /// Follows the runs from now on.
    func start() {
        observe()
        // A display can go while the circle is on it; it comes back on one that is there.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Floater.shared.screensChanged() }
        }
    }

    private func observe() {
        withObservationTracking {
            _ = TriggerCenter.shared.runs.map(\.phase)
            _ = TriggerCenter.shared.triggers.map(\.on)
            _ = TriggerCenter.shared.paused
        } onChange: {
            Task { @MainActor in
                self.update()
                self.observe()
            }
        }
        update()
    }

    private func update() {
        let runs = TriggerCenter.shared.runs
        let live = runs.filter(\.live)
        let order: (FlowRun) -> Int = {
            switch $0.phase {
            case .recording: 0
            default: 1
            }
        }
        let ended = runs.first { !$0.live && !dismissed.contains($0.id) && Date().timeIntervalSince($0.since) < 60 }
        let focus = live.min { order($0) < order($1) } ?? ended
        run = focus
        others = max(0, live.count - (focus?.live == true ? 1 : 0))
        levels.follow(focus?.app != nil ? focus : nil)
        guard let focus else { return resting ? present() : hide() }
        if seenPhase?.0 != focus.id || seenPhase?.1 != focus.phase {
            seenPhase = (focus.id, focus.phase)
            entered(focus)
        }
        present()
    }

    /// What a run's new phase does to the circle and the pill.
    private func entered(_ run: FlowRun) {
        pinned = ProcessInfo.processInfo.environment["FLOW_DEMO_OPEN"] != nil
        switch run.phase {
        case .recording: open(for: .seconds(3))
        case .running: close()
        case .finished: open(for: .seconds(run.canUndo ? 10 : 6), thenHide: true)
        case .failed: open(for: .seconds(20), thenHide: true)
        }
    }

    // MARK: Opening and closing

    private func open(for time: Duration, thenHide: Bool = false) {
        setExpanded(true)
        schedule(time) { [weak self] in
            guard let self else { return }
            if thenHide { self.finish() } else { self.close() }
        }
    }

    private func close() {
        timer?.cancel()
        guard !pinned else { return }
        setExpanded(false)
    }

    private func schedule(_ time: Duration, _ then: @escaping @MainActor () -> Void) {
        timer?.cancel()
        timer = Task {
            try? await Task.sleep(for: time)
            guard !Task.isCancelled, !hovering, !pinned else { return }
            then()
        }
    }

    /// While a trigger is on, the circle stays, so there is somewhere to drop files.
    private var resting: Bool {
        let center = TriggerCenter.shared
        return offer != nil || (!center.paused && center.triggers.contains(where: \.on))
    }

    // MARK: Dropping files

    func target(_ over: Bool) {
        guard over != targeted else { return }
        withAnimation(.smooth(duration: 0.15)) { targeted = over }
    }

    /// Offers the flows that can take the dropped files.
    func drop(_ files: [URL]) {
        Task { [weak self] in
            let offer = DropOffer.make(files, mine: await SavedFlow.recent())
            guard let self else { return }
            withAnimation(Self.spring) { self.offer = offer }
            setExpanded(true)
            Task { await Task.yield(); self.layout() }
            offerTimeout()
        }
    }

    /// Dropped files not run in a while are let go.
    private func offerTimeout() {
        schedule(.seconds(30)) { [weak self] in self?.cancelOffer() }
    }

    func choose(_ choice: DropOffer.Choice) {
        guard let offer else { return }
        offer.chose(choice)
        TriggerCenter.shared.run(choice.ref, on: offer.files)
        cancelOffer()
    }

    func cancelOffer() {
        withAnimation(Self.spring) { offer = nil }
        setExpanded(false)
        update()
    }

    /// The run that ended has been seen; the circle goes until the next one.
    func finish() {
        if let run, !run.live { dismissed.insert(run.id) }
        setExpanded(false)
        update()
    }

    func hover(_ inside: Bool) {
        hovering = inside
        if inside {
            timer?.cancel()
            setExpanded(true)
        } else if offer != nil {
            offerTimeout()
        } else if !pinned {
            let ended = run.map { !$0.live } ?? false
            schedule(.seconds(ended ? 3 : 0.6)) { [weak self] in
                if ended { self?.finish() } else { self?.setExpanded(false) }
            }
        }
    }

    func tap() {
        if let run, case .recording = run.phase, run.transcript != nil {
            return TranscriptHUD.shared.toggle(run)
        }
        // A click opens the pill and keeps it open, or closes it, even with
        // the pointer still over it.
        pinned = !expanded
        setExpanded(pinned)
    }

    private func setExpanded(_ value: Bool) {
        guard value != expanded else { return }
        withAnimation(Self.spring) { expanded = value }
        Task { await Task.yield(); layout() }
    }

    static var spring: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0.18)
    }

    // MARK: The panel

    private func present() {
        let panel = panel ?? makePanel()
        self.panel = panel
        Task {
            await Task.yield()
            layout()
            panel.orderFrontRegardless()
            guard !shown else { return }
            withAnimation(Self.spring) { shown = true }
        }
    }

    private func hide() {
        timer?.cancel()
        expanded = false
        guard shown else { return }
        withAnimation(.easeIn(duration: 0.18)) { shown = false }
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !shown else { return }
            panel?.orderOut(nil)
        }
    }

    /// Sizes the panel to what it draws and puts the circle on its anchor,
    /// so the panel never takes a click meant for the window behind it.
    private func layout() {
        guard let panel, let content = panel.contentView else { return }
        let anchor = self.anchor ?? Self.remembered() ?? Self.home()
        self.anchor = anchor
        let visible = Self.screen(at: anchor)?.visibleFrame
        let left = anchor.x > (visible?.midX ?? 0)
        if left != opensLeft { opensLeft = left }
        let down = anchor.y > (visible?.midY ?? 0)
        if down != opensDown { opensDown = down }
        let size = content.fittingSize
        let half = Self.circle / 2 + Self.margin
        let row = Self.row / 2 + Self.margin
        var x = opensLeft ? anchor.x + half - size.width : anchor.x - half
        var y = opensDown ? anchor.y + row - size.height : anchor.y - row
        // Kept on the screen, but for the room left for the shadow, and not
        // while it is dragged, so it follows the pointer onto another display.
        if let visible, drag == nil {
            let room = visible.insetBy(dx: -Self.margin, dy: -Self.margin)
            x = min(max(x, room.minX), room.maxX - size.width)
            y = min(max(y, room.minY), room.maxY - size.height)
        }
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    /// A display came, went, or changed size: the circle stays where it is
    /// when its display is still there, and otherwise goes back to where it
    /// was last put on one that is.
    private func screensChanged() {
        if let anchor, let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) {
            self.anchor = Self.settle(anchor, in: screen.visibleFrame)
        } else {
            anchor = nil
        }
        layout()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // Glass follows the window's appearance; the floater is dark glass in both.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = FirstClickHostingView(rootView: FloaterView(floater: self))
        return panel
    }

    // MARK: Dragging

    func dragged() {
        let mouse = NSEvent.mouseLocation
        if drag == nil, let anchor { drag = (anchor, mouse) }
        guard let drag else { return }
        anchor = CGPoint(x: drag.anchor.x + mouse.x - drag.mouse.x, y: drag.anchor.y + mouse.y - drag.mouse.y)
        layout()
    }

    func dropped() {
        drag = nil
        guard let point = anchor, let screen = Self.screen(at: point) else { return }
        let settled = Self.settle(point, in: screen.visibleFrame)
        anchor = settled
        Self.remember(settled, on: screen)
        if let panel {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                let frame = panel.frame.offsetBy(dx: settled.x - point.x, dy: settled.y - point.y)
                panel.animator().setFrame(frame, display: true)
            }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(260))
            layout()
        }
    }

    /// Inside the screen, and against an edge when it was dropped close to one.
    static func settle(_ point: CGPoint, in visible: CGRect) -> CGPoint {
        let inset = circle / 2 + 12
        let snap: CGFloat = 40
        var p = CGPoint(x: min(max(point.x, visible.minX + inset), visible.maxX - inset),
                        y: min(max(point.y, visible.minY + inset), visible.maxY - inset))
        if p.x - visible.minX - inset < snap { p.x = visible.minX + inset }
        if visible.maxX - inset - p.x < snap { p.x = visible.maxX - inset }
        if p.y - visible.minY - inset < snap { p.y = visible.minY + inset }
        if visible.maxY - inset - p.y < snap { p.y = visible.maxY - inset }
        return p
    }

    private static func screen(at point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(point) } ?? NSScreen.main
    }

    /// Top right, under the menu bar.
    private static func home() -> CGPoint {
        let visible = (Snapshots.sharpScreen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return CGPoint(x: visible.maxX - circle / 2 - 12, y: visible.maxY - circle / 2 - 56)
    }

    private static func key(_ screen: NSScreen) -> String {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "main"
        return "floater.\(id)"
    }

    /// Kept as a fraction of the screen, per display, so it survives a
    /// resolution change, with the display it was last put on.
    private static func remember(_ point: CGPoint, on screen: NSScreen) {
        let v = screen.visibleFrame
        UserDefaults.standard.set([(point.x - v.minX) / v.width, (point.y - v.minY) / v.height], forKey: key(screen))
        UserDefaults.standard.set(key(screen), forKey: "floater.screen")
    }

    /// Where it was last put, on that display when it is there, and otherwise
    /// where it was put on the main one.
    private static func remembered() -> CGPoint? {
        let last = UserDefaults.standard.string(forKey: "floater.screen")
        guard let screen = NSScreen.screens.first(where: { key($0) == last }) ?? NSScreen.main ?? NSScreen.screens.first,
              let f = UserDefaults.standard.array(forKey: key(screen)) as? [Double], f.count == 2 else { return nil }
        let v = screen.visibleFrame
        return settle(CGPoint(x: v.minX + f[0] * v.width, y: v.minY + f[1] * v.height), in: v)
    }
}

/// How loud the call is, you and the others together, as a short history
/// for the bars in the circle. Sampled only while a call records.
@MainActor
@Observable
final class Levels {
    static let count = 5
    private(set) var history = [Double](repeating: 0, count: count)
    @ObservationIgnored private var sampling: Task<Void, Never>?
    @ObservationIgnored private weak var run: FlowRun?

    func follow(_ run: FlowRun?) {
        guard run !== self.run else { return }
        self.run = run
        sampling?.cancel()
        history = .init(repeating: 0, count: Self.count)
        guard let run else { return }
        sampling = Task { [weak self] in
            var t = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(90))
                t += 0.09
                let level: Double
                if let recorder = run.recorder {
                    level = recorder.level
                } else {
                    // A demo run has no recorder; a calm made-up voice stands in.
                    level = 0.35 + 0.3 * sin(t * 5) * sin(t * 1.3) + .random(in: 0...0.2)
                }
                self?.push(level)
            }
        }
    }

    private func push(_ level: Double) {
        history.removeFirst()
        history.append(min(1, max(0, level)))
    }
}


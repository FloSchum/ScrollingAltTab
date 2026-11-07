import AppKit
import SwiftUI

/// Windows-style ⌥Tab.
///
/// The event tap (its own thread) calls `handleKey` / `handleScroll` synchronously to decide
/// what to swallow. That decision only touches the small lock-protected "tap state"; all the
/// real work is queued with `DispatchQueue.main.async`, which keeps the tap fast and keeps
/// the order of key presses.
final class SwitcherController {
    private enum Key {
        static let tab: Int64 = 48, returnKey: Int64 = 36, enter: Int64 = 76, space: Int64 = 49, escape: Int64 = 53
        static let left: Int64 = 123, right: Int64 = 124, down: Int64 = 125, up: Int64 = 126
    }

    private enum Move {
        case items(Int)
        case rows(Int)
    }

    // MARK: Tap state (event-tap thread + main, guarded by `lock`)

    private let lock = NSLock()
    private var _isActive = false
    private var tapSession = 0
    private var scrollAccumulator = 0.0 // event-tap thread only

    /// True from the first ⌥Tab until ⌥ is released or Esc is pressed.
    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isActive
    }

    // MARK: Main-thread state

    private var current: Int? // session being displayed
    private var entries: [WindowEntry] = []
    private var loaded = false
    private var pendingMove = 0
    private var pendingFinish: Bool? // commit (true) / cancel (false) requested before the list was ready
    private var startBackwards = false
    private var showDue = false
    private var visible = false
    private var mouseAtShow = NSPoint.zero
    private var safetyTimer: Timer?

    private let model = SwitcherModel()
    private lazy var panel: SwitcherPanel = {
        let panel = SwitcherPanel()
        let host = FirstMouseHostingView(rootView: SwitcherView(model: model))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }()

    init() {
        model.onHover = { [weak self] index in self?.hover(index) }
        model.onClick = { [weak self] index in self?.click(index) }
    }

    // MARK: - Called from the event-tap thread

    /// Returns true when the key event must be swallowed.
    func handleKey(type: CGEventType, event: CGEvent) -> Bool {
        let active = isActive
        guard Settings.shared.altTabEnabled else {
            if active { tapFinish(commit: false) }
            return false
        }
        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        switch type {
        case .flagsChanged:
            if active && !flags.contains(.maskAlternate) { tapFinish(commit: true) }
            return false

        case .keyDown:
            let option = flags.contains(.maskAlternate)
            let others = !flags.intersection([.maskCommand, .maskControl]).isEmpty
            if keyCode == Key.tab && option && !others {
                let backwards = flags.contains(.maskShift)
                if active { tapMove(.items(backwards ? -1 : 1)) } else { tapStart(backwards: backwards) }
                return true
            }
            guard active else { return false }
            switch keyCode {
            case Key.escape: tapFinish(commit: false)
            case Key.returnKey, Key.enter, Key.space: tapFinish(commit: true)
            case Key.left: tapMove(.items(-1))
            case Key.right: tapMove(.items(1))
            case Key.up: tapMove(.rows(-1))
            case Key.down: tapMove(.rows(1))
            default:
                // Characters depend on the keyboard layout (main-thread only APIs): resolve on main.
                guard let copy = event.copy() else { break }
                let s = currentTapSession()
                DispatchQueue.main.async {
                    let chars = NSEvent(cgEvent: copy)?.charactersIgnoringModifiers?.lowercased() ?? ""
                    if let action = ["q": "quit", "w": "close", "m": "minimize", "h": "hide"][chars] {
                        self.perform(action, session: s)
                    }
                }
            }
            return true

        case .keyUp:
            return active

        default:
            return false
        }
    }

    /// Wheel / trackpad while the switcher is open moves the selection.
    func handleScroll(_ event: CGEvent) {
        if ScrollEngine.isMouseWheel(event) {
            let direction = ScrollEngine.physicalDirection(event)
            if direction != 0 { tapMove(.items(direction > 0 ? -1 : 1)) }
            return
        }
        // Trackpad: one step every ~40 px of finger travel.
        let inverted = NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice ?? false
        var dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        if inverted { dy = -dy }
        scrollAccumulator += dy
        while abs(scrollAccumulator) >= 40 {
            tapMove(.items(scrollAccumulator > 0 ? -1 : 1))
            scrollAccumulator -= scrollAccumulator > 0 ? 40 : -40
        }
    }

    private func currentTapSession() -> Int {
        lock.lock(); defer { lock.unlock() }
        return tapSession
    }

    private func tapStart(backwards: Bool) {
        lock.lock()
        _isActive = true
        tapSession += 1
        let s = tapSession
        lock.unlock()
        scrollAccumulator = 0
        DispatchQueue.main.async { self.begin(session: s, backwards: backwards) }
    }

    private func tapMove(_ move: Move) {
        let s = currentTapSession()
        DispatchQueue.main.async { self.move(session: s, move) }
    }

    /// Also called from the main thread (mouse click, safety timer).
    private func tapFinish(commit: Bool) {
        lock.lock()
        _isActive = false
        let s = tapSession
        lock.unlock()
        DispatchQueue.main.async { self.finish(session: s, commit: commit) }
    }

    // MARK: - Session (main thread)

    private func begin(session s: Int, backwards: Bool) {
        current = s
        entries = []
        loaded = false
        pendingMove = 0
        pendingFinish = nil
        startBackwards = backwards
        showDue = false

        WindowStore.shared.snapshot(onlyPid: nil) { [weak self] list in
            self?.loadedList(list, session: s)
        }
        // Like Windows: a quick ⌥Tab tap switches without flashing the UI.
        DispatchQueue.main.asyncAfter(deadline: .now() + Settings.shared.showDelay) { [weak self] in
            guard let self, s == self.current, self.isActive else { return }
            self.showDue = true
            if self.loaded { self.show() }
        }
        safetyTimer?.invalidate()
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            // If ⌥ was released while a secure text field ate the flagsChanged event.
            guard let self, self.isActive else { return }
            if !CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) {
                self.tapFinish(commit: true)
            }
        }
    }

    private func loadedList(_ list: [WindowEntry], session s: Int) {
        guard s == current else { return }
        entries = list
        loaded = true
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if entries.isEmpty {
            model.selected = 0
        } else if startBackwards {
            model.selected = entries.count - 1
        } else {
            model.selected = (entries.first?.pid == frontPid && entries.count > 1) ? 1 : 0
        }
        if pendingMove != 0 { applyMove(pendingMove) }
        pendingMove = 0
        if let commit = pendingFinish {
            finish(session: s, commit: commit)
            return
        }
        if showDue { show() }
    }

    private func move(session s: Int, _ move: Move) {
        guard s == current else { return }
        let delta: Int
        switch move {
        case .items(let n): delta = n
        case .rows(let n): delta = n * max(model.columns, 1)
        }
        if !loaded { pendingMove += delta; return }
        applyMove(delta)
    }

    private func applyMove(_ delta: Int) {
        guard !entries.isEmpty else { return }
        let n = entries.count
        model.selected = ((model.selected + delta) % n + n) % n
    }

    private func finish(session s: Int, commit: Bool) {
        guard s == current else { return }
        if !loaded { pendingFinish = commit; return }
        safetyTimer?.invalidate()
        safetyTimer = nil
        hide()
        if commit, entries.indices.contains(model.selected) {
            WindowStore.shared.activate(entries[model.selected])
        }
        entries = []
        loaded = false
        current = nil // invalidate late callbacks of this session
    }

    // MARK: - UI

    private func show() {
        guard !visible, isActive, !entries.isEmpty else { return }
        let wantsThumbs = layoutPanel()
        mouseAtShow = NSEvent.mouseLocation
        panel.orderFrontRegardless()
        visible = true
        if wantsThumbs, let current { loadThumbnails(for: entries, session: current) }
    }

    /// Debug: lays the switcher out for `list` without showing it and saves a PNG.
    func renderPreview(_ list: [WindowEntry], selected: Int, to url: URL) -> Bool {
        entries = list
        _ = layoutPanel()
        model.selected = selected
        guard let view = panel.contentView else { return false }
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        NSColor(white: 0.12, alpha: 1).setFill()
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// Sizes the grid and the panel for `entries`. Returns true when thumbnails will be used.
    private func layoutPanel() -> Bool {
        let settings = Settings.shared
        let wantsThumbs = settings.showThumbnails && CGPreflightScreenCaptureAccess() && Private.canCaptureWindows
        model.showThumbnails = wantsThumbs
        let tile = CGFloat(settings.thumbnailSize)
        model.itemSize = wantsThumbs ? CGSize(width: tile, height: (tile * 0.75).rounded()) : CGSize(width: 128, height: 118)
        model.thumbnails = [:]
        model.entries = entries

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        let item = model.itemSize
        let pad = SwitcherView.padding, gap = SwitcherView.spacing
        let maxColumns = max(1, Int((area.width * 0.9 - 2 * pad + gap) / (item.width + gap)))
        let columns = max(1, min(entries.count, maxColumns))
        let rows = Int(ceil(Double(max(entries.count, 1)) / Double(columns)))
        model.columns = columns
        let width = CGFloat(columns) * item.width + CGFloat(columns - 1) * gap + 2 * pad
        let fullHeight = CGFloat(rows) * item.height + CGFloat(rows - 1) * gap + 2 * pad
        let height = min(fullHeight, area.height * 0.85)
        let frame = NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
        panel.setFrame(frame.integral, display: false)
        return wantsThumbs
    }

    private func hide() {
        guard visible else { return }
        panel.orderOut(nil)
        visible = false
        model.entries = []
        model.thumbnails = [:]
    }

    private func loadThumbnails(for list: [WindowEntry], session s: Int) {
        let ids = list.compactMap(\.windowID)
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let lock = NSLock()
            var images: [CGWindowID: NSImage] = [:]
            DispatchQueue.concurrentPerform(iterations: ids.count) { i in
                guard let cg = Private.capture(windowID: ids[i]), cg.width > 1, cg.height > 1 else { return }
                let image = Self.downscale(cg, maxSide: 520)
                lock.lock()
                images[ids[i]] = image
                lock.unlock()
            }
            DispatchQueue.main.async {
                guard let self, s == self.current, self.visible else { return }
                self.model.thumbnails = images
            }
        }
    }

    private static func downscale(_ image: CGImage, maxSide: Int) -> NSImage {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)) }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let scaled = ctx.makeImage() ?? image
        return NSImage(cgImage: scaled, size: NSSize(width: w, height: h))
    }

    private func hover(_ index: Int) {
        guard visible, entries.indices.contains(index) else { return }
        let mouse = NSEvent.mouseLocation
        guard hypot(mouse.x - mouseAtShow.x, mouse.y - mouseAtShow.y) > 3 else { return }
        model.selected = index
    }

    private func click(_ index: Int) {
        guard visible, entries.indices.contains(index) else { return }
        model.selected = index
        tapFinish(commit: true)
    }

    private func perform(_ action: String, session s: Int) {
        guard s == current, loaded, entries.indices.contains(model.selected) else { return }
        let index = model.selected
        let entry = entries[index]
        let store = WindowStore.shared
        switch action {
        case "quit":
            store.quitApp(entry)
            entries.removeAll { $0.pid == entry.pid }
        case "close":
            store.close(entry)
            if entry.windowID != nil { entries.remove(at: index) }
        case "minimize":
            store.minimize(entry)
            entries[index].isMinimized = true
        case "hide":
            store.hideApp(entry)
            for i in entries.indices where entries[i].pid == entry.pid { entries[i].isAppHidden = true }
        default:
            return
        }
        model.entries = entries
        if entries.isEmpty {
            tapFinish(commit: false)
        } else {
            model.selected = min(index, entries.count - 1)
        }
    }
}

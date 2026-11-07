import AppKit
import CoreGraphics
import CoreVideo
import QuartzCore

/// One scroll axis. Each wheel notch moves `target`; `smooth` follows it through a short
/// first-order filter and the position follows `smooth` with a critically damped spring.
/// That is a third-order response: continuous velocity *and* acceleration, so successive
/// notches blend without a surge each time. Only whole pixels can be sent (AppKit truncates
/// fractions), so the remainder is carried.
struct ScrollAxis {
    var position: Double = 0
    var smooth: Double = 0
    var target: Double = 0
    var velocity: Double = 0
    var emitted: Double = 0
    var omega: Double = 38 // rad/s, spring stiffness; higher = snappier
    var tau: Double = 0.03 // s, first-stage time constant

    var isIdle: Bool { position == target && smooth == target && velocity == 0 }

    mutating func add(_ pixels: Double) {
        guard pixels != 0 else { return }
        let remaining = target - position
        if remaining != 0, (remaining > 0) != (pixels > 0) {
            target = position // real reversal: drop what was left, brake smoothly
            smooth = position
        }
        target += pixels
    }

    /// Advances by `dt` seconds (exact spring solution, stable for any frame length).
    mutating func step(dt: Double) -> Int32 {
        guard !isIdle else { return 0 }
        smooth += (target - smooth) * (tau > 0 ? 1 - exp(-dt / tau) : 1)
        let x0 = position - smooth
        let v0 = velocity
        let decay = exp(-omega * dt)
        let c2 = v0 + omega * x0
        let x1 = (x0 + c2 * dt) * decay
        let v1 = (c2 - omega * (x0 + c2 * dt)) * decay
        position = smooth + x1
        velocity = v1
        // Stop before the 1-pixel crawl at the very end.
        if abs(target - position) < 1.5, abs(target - smooth) < 1.5, abs(velocity) < 40 {
            position = target
            smooth = target
            velocity = 0
        }
        if isIdle {
            let rest = (target - emitted).rounded()
            position = 0; smooth = 0; target = 0; emitted = 0 // keep numbers small between gestures
            return Int32(rest)
        }
        let whole = (position - emitted).rounded(.towardZero)
        emitted += whole
        return Int32(whole)
    }
}

/// Decides which wheel notches are real. Cheap wheels report stray reverse ticks, both in the
/// middle of a spin and as the first tick of a new flick. Pure logic, no timers.
struct WheelFilter {
    /// A reverse tick less than this after the previous notch is a bounce.
    static let bounceWindow: Double = 0.12
    /// A flick starting against the previous direction within this delay must be confirmed…
    static let directionMemory: Double = 1.5
    /// …by a second tick within this delay, otherwise it is applied late.
    static let confirmDelay: Double = 0.06

    struct Notch {
        var sign: Int
        var time: Double
        var payload: (Double, Double) // (y, x) direction vector of this notch
    }

    private(set) var lastNotch: Double = -100
    private(set) var lastSign = 0
    private var streak = 0
    private(set) var held: Notch?

    /// Returns the accepted notches with their acceleration multiplier.
    /// When `canHold` is false (native passthrough) nothing is delayed.
    mutating func feed(_ notch: Notch, canHold: Bool) -> [(Notch, Double)] {
        if let h = held {
            held = nil
            if notch.sign == h.sign { return [(h, accept(h)), (notch, accept(notch))] } // confirmed
            return [(notch, accept(notch))] // the held tick was a bounce
        }
        if lastSign != 0, notch.sign != lastSign {
            let since = notch.time - lastNotch
            if since < Self.bounceWindow { return [] }
            if canHold, since < Self.directionMemory {
                held = notch
                return []
            }
        }
        return [(notch, accept(notch))]
    }

    /// Applies a held tick nobody confirmed or contradicted (a single deliberate notch).
    mutating func release(now: Double) -> [(Notch, Double)] {
        guard let h = held, now - h.time >= Self.confirmDelay * 0.9 else { return [] }
        held = nil
        return [(h, accept(h))]
    }

    private mutating func accept(_ n: Notch) -> Double {
        if n.time - lastNotch < 0.09, n.sign == lastSign { streak += 1 } else { streak = 0 }
        lastNotch = n.time
        lastSign = n.sign
        return min(1 + Double(streak) * 0.22, 4.5)
    }
}

/// Fixes a classic (notched) mouse wheel: own direction independent of the trackpad,
/// encoder-bounce filtering, spring-smoothed pixel scrolling paced on the display refresh,
/// acceleration, ⇧ + wheel = horizontal. Trackpads / Magic Mouse (continuous events) are untouched.
///
/// Threads: `handle` runs on the event-tap thread (bounce filter and acceleration state are
/// only touched there). Axes are shared with the display-link thread under `lock`.
final class ScrollEngine {
    static let marker: Int64 = 0x5343_524C // "SCRL": events we synthesised ourselves

    // Shared by the event-tap thread, the display-link thread and `linkQueue`, under `lock`.
    private let lock = NSLock()
    private var filter = WheelFilter()
    private var y = ScrollAxis()
    private var x = ScrollAxis()
    private var lastHostTime: UInt64 = 0

    private var link: CVDisplayLink?
    private let linkQueue = DispatchQueue(label: "ScrollingAltTab.displayLink", qos: .userInteractive)
    private let source = CGEventSource(stateID: .hidSystemState)
    private let ticksToSeconds: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom) / 1e9
    }()

    private var _frontmostBundleID: String?
    private var frontmostBundleID: String? {
        get { lock.lock(); defer { lock.unlock() }; return _frontmostBundleID }
        set { lock.lock(); _frontmostBundleID = newValue; lock.unlock() }
    }

    init() {
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontmostBundleID = app?.bundleIdentifier
        }
    }

    static func isMouseWheel(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) != marker
            && event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0
    }

    /// Returns the event to pass on (maybe modified), or nil when it was consumed.
    func handle(_ event: CGEvent) -> CGEvent? {
        let s = Settings.shared
        guard s.scrollEnabled, Self.isMouseWheel(event) else { return event }

        let flags = event.flags
        let modifierHeld = !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
        let excluded = frontmostBundleID.map { s.smoothExcludedApps.contains($0) } ?? false

        var ny = Self.notches(event, .scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1)
        var nx = Self.notches(event, .scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2)
        guard ny != 0 || nx != 0 else { return event }

        let now = CACurrentMediaTime()
        let passthrough = !s.smoothScrolling || modifierHeld || excluded
        // The filter always sees the physical direction (before reversal / ⇧ remapping).
        let sign = (ny != 0 ? ny : nx) > 0 ? 1 : -1

        // ⌘/⌃/⌥ + wheel is zoom & co. in many apps: keep the native event, only fix direction
        // (bounces are still dropped).
        if passthrough {
            lock.lock()
            let accepted = filter.feed(.init(sign: sign, time: now, payload: (0, 0)), canHold: false)
            lock.unlock()
            guard !accepted.isEmpty else { return nil }
            if s.reverseMouseWheel { Self.reverseInPlace(event) }
            return event
        }

        if s.reverseMouseWheel { ny = -ny; nx = -nx }
        if s.shiftScrollsHorizontally, flags.contains(.maskShift), nx == 0 {
            nx = ny
            ny = 0
        }
        let pixels = s.pixelsPerNotch
        let accelerate = s.acceleration
        let omega = s.springOmega
        let tau = s.smoothingTau

        lock.lock()
        y.omega = omega; x.omega = omega
        y.tau = tau; x.tau = tau
        let accepted = filter.feed(.init(sign: sign, time: now, payload: (ny, nx)), canHold: true)
        apply(accepted, pixels: pixels, accelerate: accelerate)
        let holding = filter.held != nil
        lock.unlock()

        if !accepted.isEmpty { startLinkIfNeeded(at: event.location) }
        if holding {
            let location = event.location
            linkQueue.asyncAfter(deadline: .now() + WheelFilter.confirmDelay) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let released = self.filter.release(now: CACurrentMediaTime())
                self.apply(released, pixels: pixels, accelerate: accelerate)
                self.lock.unlock()
                if !released.isEmpty { self.startLinkIfNeeded(at: location) }
            }
        }
        return nil
    }

    /// Caller holds `lock`.
    private func apply(_ notches: [(WheelFilter.Notch, Double)], pixels: Double, accelerate: Bool) {
        for (notch, accel) in notches {
            let amount = pixels * (accelerate ? accel : 1)
            y.add(notch.payload.0 * amount)
            x.add(notch.payload.1 * amount)
        }
    }

    /// Wheel direction as the user physically turned it: +1 = away from them (up), -1 = toward them.
    static func physicalDirection(_ event: CGEvent) -> Int {
        let n = notches(event, .scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1)
        guard n != 0 else { return 0 }
        let inverted = NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice ?? false
        return (n > 0) != inverted ? 1 : -1
    }

    // MARK: - Internals

    /// One event = one notch for a classic wheel. High-resolution wheels send fractions of a
    /// line; those are kept as fractions so they do not scroll ten times too fast.
    private static func notches(_ e: CGEvent, _ delta: CGEventField, _ fixed: CGEventField, _ point: CGEventField) -> Double {
        let d = Double(e.getIntegerValueField(delta))
        let f = e.getDoubleValueField(fixed)
        let p = Double(e.getIntegerValueField(point))
        let reference = d != 0 ? d : (f != 0 ? f : p)
        guard reference != 0 else { return 0 }
        let sign: Double = reference > 0 ? 1 : -1
        let magnitude = (d == 0 && f != 0 && abs(f) < 1) ? abs(f) : 1
        return sign * magnitude
    }

    private static func reverseInPlace(_ e: CGEvent) {
        let pairs: [(CGEventField, CGEventField, CGEventField)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1),
            (.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2),
        ]
        for (delta, fixed, point) in pairs {
            let d = e.getIntegerValueField(delta)
            let f = e.getDoubleValueField(fixed)
            let p = e.getIntegerValueField(point)
            e.setIntegerValueField(delta, value: -d)
            e.setDoubleValueField(fixed, value: -f)
            e.setIntegerValueField(point, value: -p)
        }
    }

    private var isIdle: Bool {
        lock.lock(); defer { lock.unlock() }
        return y.isIdle && x.isIdle
    }

    // MARK: - Display-synchronised frames

    /// Start/stop decisions are serialised on `linkQueue`, so a stop can never win over a
    /// newer impulse.
    private func startLinkIfNeeded(at location: CGPoint) {
        linkQueue.async {
            if self.link == nil { self.createLink() }
            guard let link = self.link, !self.isIdle else { return }
            if !CVDisplayLinkIsRunning(link) {
                var display: CGDirectDisplayID = 0
                var count: UInt32 = 0
                if CGGetDisplaysWithPoint(location, 1, &display, &count) == .success, count > 0 {
                    CVDisplayLinkSetCurrentCGDisplay(link, display)
                }
                self.lock.lock()
                self.lastHostTime = 0
                self.lock.unlock()
                CVDisplayLinkStart(link)
            }
        }
    }

    private func stopLinkIfIdle() {
        linkQueue.async {
            guard let link = self.link, self.isIdle, CVDisplayLinkIsRunning(link) else { return }
            CVDisplayLinkStop(link)
        }
    }

    private func createLink() {
        var newLink: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&newLink) == kCVReturnSuccess, let newLink else { return }
        CVDisplayLinkSetOutputHandler(newLink) { [weak self] _, _, outputTime, _, _ in
            self?.frame(hostTime: outputTime.pointee.hostTime)
            return kCVReturnSuccess
        }
        link = newLink
    }

    /// Display-link thread: one call per screen refresh, `hostTime` = when the frame is shown.
    private func frame(hostTime: UInt64) {
        lock.lock()
        let dt: Double
        if lastHostTime == 0 || hostTime <= lastHostTime {
            dt = 1.0 / 120
        } else {
            dt = min(max(Double(hostTime - lastHostTime) * ticksToSeconds, 1.0 / 240), 1.0 / 30)
        }
        lastHostTime = hostTime
        let dy = y.step(dt: dt)
        let dx = x.step(dt: dt)
        let idle = y.isIdle && x.isIdle
        lock.unlock()

        if dy != 0 || dx != 0 { post(dy: dy, dx: dx) }
        if idle { stopLinkIfIdle() }
    }

    private func post(dy: Int32, dx: Int32) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        e.flags = []
        if let location = CGEvent(source: nil)?.location { e.location = location }
        e.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        e.post(tap: .cgSessionEventTap)
    }
}

import CoreGraphics
import Foundation

/// One session-level event tap for the keyboard (⌥Tab) and the scroll wheel.
///
/// It runs on its own high-priority thread, never on the main thread: if the main thread
/// stalls (UI, Accessibility calls to a busy app…), input is not delayed and macOS does not
/// disable the tap — which would let raw wheel events through mixed with smoothed ones.
/// The handler returns the event to let it through (possibly modified) or nil to swallow it.
final class EventTap {
    typealias Handler = (CGEventType, CGEvent) -> CGEvent?

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var isRunning: Bool { port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    @discardableResult
    func start() -> Bool {
        if port != nil { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: refcon
        ) else { return false }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        self.source = source

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            self?.runLoop = loop
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "ScrollingAltTab.eventTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let runLoop, let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
        if let runLoop { CFRunLoopStop(runLoop) }
        if let port { CFMachPortInvalidate(port) }
        port = nil
        source = nil
        runLoop = nil
    }

    fileprivate func reenable(after type: CGEventType) {
        NSLog("ScrollingAltTab: event tap disabled (%@), re-enabling", type == .tapDisabledByTimeout ? "timeout" : "user input")
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }

    fileprivate func process(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        handler(type, event)
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        tap.reenable(after: type)
        return Unmanaged.passUnretained(event)
    }
    guard let out = tap.process(type, event) else { return nil }
    return Unmanaged.passUnretained(out)
}

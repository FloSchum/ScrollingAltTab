import AppKit
import ApplicationServices

struct WindowEntry: Identifiable {
    let id: String
    let windowID: CGWindowID? // nil = running app without any window
    let pid: pid_t
    let element: AXUIElement?
    let title: String
    let appName: String
    let appIcon: NSImage
    var isMinimized: Bool
    var isAppHidden: Bool
}

/// Lists windows in most-recently-used order, including windows on other Spaces,
/// minimised windows and windows of hidden apps.
final class WindowStore {
    static let shared = WindowStore()

    private let queue = DispatchQueue(label: "ScrollingAltTab.windows", qos: .userInteractive)
    private let observerQueue = DispatchQueue(label: "ScrollingAltTab.observers", qos: .utility)
    let actionQueue = DispatchQueue(label: "ScrollingAltTab.actions", qos: .userInteractive)

    // Guarded by `lock` (touched from concurrentPerform workers).
    private let lock = NSLock()
    private var elementCache: [CGWindowID: (pid: pid_t, element: AXUIElement)] = [:]
    private var searchedWithoutLuck: Set<CGWindowID> = []

    // Main thread only.
    private var mru: [CGWindowID] = []
    private var observers: [pid_t: AXObserver] = [:]

    private struct AppInfo {
        let pid: pid_t
        let name: String
        let icon: NSImage
        let isHidden: Bool
    }

    private struct CGInfo {
        let pid: pid_t
        let z: Int
        let bounds: CGRect
        var isBig: Bool { bounds.width >= 100 && bounds.height >= 60 }
    }

    // MARK: - MRU tracking

    func noteFocused(_ windowID: CGWindowID) {
        guard windowID != 0 else { return }
        mru.removeAll { $0 == windowID }
        mru.insert(windowID, at: 0)
        if mru.count > 300 { mru.removeLast(mru.count - 300) }
    }

    func startTracking() {
        let ws = NSWorkspace.shared
        ws.runningApplications.filter { $0.activationPolicy == .regular }.forEach(observe)
        let nc = ws.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.observe(app) }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.forget(app.processIdentifier) }
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            self.observerQueue.async {
                let axApp = AXUIElementCreateApplication(pid)
                guard let focused: AXUIElement = AX.attr(axApp, kAXFocusedWindowAttribute) else { return }
                let wid = Private.windowID(of: focused)
                DispatchQueue.main.async { self.noteFocused(wid) }
            }
        }
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.prewarm()
        }
        // Seed MRU with the current on-screen stacking order.
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in onScreen.reversed() where (info[kCGWindowLayer as String] as? Int) == 0 {
            if let wid = info[kCGWindowNumber as String] as? CGWindowID { noteFocused(wid) }
        }
        prewarm()
    }

    /// Fills the element cache (and finds other-Space windows) before the first ⌥Tab.
    func prewarm() {
        snapshot(onlyPid: nil) { _ in }
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != getpid(), observers[pid] == nil, app.activationPolicy == .regular else { return }
        observerQueue.async {
            var observer: AXObserver?
            guard AXObserverCreate(pid, axFocusCallback, &observer) == .success, let observer else { return }
            let axApp = AXUIElementCreateApplication(pid)
            AXObserverAddNotification(observer, axApp, kAXFocusedWindowChangedNotification as CFString, nil)
            AXObserverAddNotification(observer, axApp, kAXMainWindowChangedNotification as CFString, nil)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            DispatchQueue.main.async { self.observers[pid] = observer }
        }
    }

    private func forget(_ pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        lock.lock()
        elementCache = elementCache.filter { $0.value.pid != pid }
        lock.unlock()
    }

    // MARK: - Snapshot

    /// Builds the ordered window list on a background queue; `completion` runs on main.
    func snapshot(onlyPid: pid_t?, completion: @escaping ([WindowEntry]) -> Void) {
        let mru = self.mru
        let showWindowless = Settings.shared.showWindowlessApps && onlyPid == nil
        queue.async {
            // NSWorkspace.runningApplications and NSRunningApplication are documented thread-safe;
            // loading app icons here keeps that cost off the main thread.
            let me = getpid()
            let apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
                .filter { onlyPid == nil || $0.processIdentifier == onlyPid }
                .map { AppInfo(pid: $0.processIdentifier, name: $0.localizedName ?? "?", icon: $0.icon ?? NSImage(), isHidden: $0.isHidden) }
            let entries = self.enumerate(apps: apps, mru: mru, showWindowless: showWindowless)
            DispatchQueue.main.async { completion(entries) }
        }
    }

    /// AX observer callbacks arrive on the main run loop: resolve the window id elsewhere,
    /// because that call goes to the other app and can block if it is busy.
    fileprivate func noteFocused(element: AXUIElement) {
        observerQueue.async {
            let wid = Private.windowID(of: element)
            guard wid != 0 else { return }
            DispatchQueue.main.async { self.noteFocused(wid) }
        }
    }

    private func enumerate(apps: [AppInfo], mru: [CGWindowID], showWindowless: Bool) -> [WindowEntry] {
        var cg: [CGWindowID: CGInfo] = [:]
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for (z, info) in list.enumerated() {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let wid = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0 { continue }
            cg[wid] = CGInfo(pid: pid, z: z, bounds: bounds)
        }

        lock.lock()
        elementCache = elementCache.filter { cg[$0.key] != nil }
        searchedWithoutLuck = searchedWithoutLuck.filter { cg[$0] != nil }
        lock.unlock()

        var perApp = [[(WindowEntry, Int)]](repeating: [], count: apps.count)
        let resultLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let found = self.windows(of: apps[i], cg: cg)
            resultLock.lock()
            perApp[i] = found
            resultLock.unlock()
        }

        let mruRank = Dictionary(mru.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var windows: [(entry: WindowEntry, z: Int)] = perApp.flatMap { $0 }
        windows.sort { a, b in
            func group(_ e: WindowEntry) -> Int { e.isAppHidden ? 2 : (e.isMinimized ? 1 : 0) }
            let ga = group(a.entry), gb = group(b.entry)
            if ga != gb { return ga < gb }
            let ra = mruRank[a.entry.windowID ?? 0] ?? Int.max
            let rb = mruRank[b.entry.windowID ?? 0] ?? Int.max
            if ra != rb { return ra < rb }
            return a.z < b.z
        }
        var result = windows.map(\.entry)

        if showWindowless {
            let pidsWithWindows = Set(result.map(\.pid))
            for app in apps where !pidsWithWindows.contains(app.pid) {
                result.append(WindowEntry(id: "app-\(app.pid)", windowID: nil, pid: app.pid, element: nil,
                                          title: app.name, appName: app.name, appIcon: app.icon,
                                          isMinimized: false, isAppHidden: app.isHidden))
            }
        }
        return result
    }

    private func windows(of app: AppInfo, cg: [CGWindowID: CGInfo]) -> [(WindowEntry, Int)] {
        let axApp = AXUIElementCreateApplication(app.pid)
        var found: [CGWindowID: AXUIElement] = [:]
        if let list: [AXUIElement] = AX.attr(axApp, kAXWindowsAttribute) {
            for element in list {
                let wid = Private.windowID(of: element)
                if wid != 0 { found[wid] = element }
            }
        }

        lock.lock()
        for (wid, cached) in elementCache where cached.pid == app.pid && found[wid] == nil {
            found[wid] = cached.element
        }
        let missing = Set(cg.filter { $0.value.pid == app.pid && $0.value.isBig && found[$0.key] == nil && !searchedWithoutLuck.contains($0.key) }.keys)
        lock.unlock()

        if !missing.isEmpty {
            let extra = findOtherSpaceWindows(pid: app.pid, wanted: missing, budget: 0.15)
            found.merge(extra) { a, _ in a }
            lock.lock()
            searchedWithoutLuck.formUnion(missing.subtracting(extra.keys))
            lock.unlock()
        }

        lock.lock()
        for (wid, element) in found { elementCache[wid] = (app.pid, element) }
        lock.unlock()

        var out: [(WindowEntry, Int)] = []
        for (wid, element) in found {
            guard (AX.attr(element, kAXRoleAttribute) as String?) == kAXWindowRole else { continue }
            let subrole: String = AX.attr(element, kAXSubroleAttribute) ?? ""
            let minimized: Bool = AX.attr(element, kAXMinimizedAttribute) ?? false
            let info = cg[wid]
            let standard = subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
            let plausible = (info?.isBig ?? false) && !["AXUnknown", kAXFloatingWindowSubrole, kAXSystemDialogSubrole].contains(subrole)
            guard standard || plausible else { continue }
            guard info != nil || minimized else { continue }
            if let info, info.bounds.width < 20 || info.bounds.height < 20 { continue }
            var title: String = AX.attr(element, kAXTitleAttribute) ?? ""
            if title.isEmpty { title = app.name }
            let entry = WindowEntry(id: "win-\(wid)", windowID: wid, pid: app.pid, element: element,
                                    title: title, appName: app.name, appIcon: app.icon,
                                    isMinimized: minimized, isAppHidden: app.isHidden)
            out.append((entry, info?.z ?? Int.max))
        }
        return out
    }

    /// Enumerates remote AX tokens for the
    /// process until every wanted window id is matched or the time budget runs out.
    private func findOtherSpaceWindows(pid: pid_t, wanted: Set<CGWindowID>, budget: TimeInterval) -> [CGWindowID: AXUIElement] {
        guard Private.canFindOtherSpaceWindows else { return [:] }
        var result: [CGWindowID: AXUIElement] = [:]
        let start = Date()
        for elementID: UInt64 in 0..<1000 {
            if result.count == wanted.count || Date().timeIntervalSince(start) > budget { break }
            guard let element = Private.axElement(pid: pid, elementID: elementID) else { continue }
            let wid = Private.windowID(of: element)
            guard wid != 0, wanted.contains(wid) else { continue }
            result[wid] = element
        }
        return result
    }

    // MARK: - Actions

    func activate(_ entry: WindowEntry) {
        if let wid = entry.windowID { noteFocused(wid) }
        actionQueue.async {
            let app = NSRunningApplication(processIdentifier: entry.pid)
            if app?.isHidden == true { app?.unhide() }
            guard let wid = entry.windowID, let element = entry.element else {
                if !Private.focus(pid: entry.pid, windowID: 0) { app?.activate() }
                return
            }
            if entry.isMinimized { AX.set(element, kAXMinimizedAttribute, kCFBooleanFalse) }
            if !Private.focus(pid: entry.pid, windowID: wid) { app?.activate() }
            AX.perform(element, kAXRaiseAction)
        }
    }

    func close(_ entry: WindowEntry) {
        actionQueue.async {
            guard let element = entry.element,
                  let button: AXUIElement = AX.attr(element, kAXCloseButtonAttribute) else { return }
            AX.perform(button, kAXPressAction)
        }
    }

    func minimize(_ entry: WindowEntry) {
        actionQueue.async {
            guard let element = entry.element else { return }
            AX.set(element, kAXMinimizedAttribute, kCFBooleanTrue)
        }
    }

    func quitApp(_ entry: WindowEntry) {
        NSRunningApplication(processIdentifier: entry.pid)?.terminate()
    }

    func hideApp(_ entry: WindowEntry) {
        NSRunningApplication(processIdentifier: entry.pid)?.hide()
    }
}

private func axFocusCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    WindowStore.shared.noteFocused(element: element)
}

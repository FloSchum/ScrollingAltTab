import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let scroll = ScrollEngine()
    private let switcher = SwitcherController()
    /// `route` runs on the event-tap thread.
    private lazy var tap = EventTap { [unowned self] type, event in self.route(type, event) }
    private var permissionTimer: Timer?
    private var trackingStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        quitOtherInstances()
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)
        setupStatusItem()
        offerToQuitAltTab()
        if AXIsProcessTrusted() {
            startEverything()
        } else {
            askForAccessibility()
            SettingsWindowController.shared.show(section: .general)
        }
    }

    /// Opening the app again from the Finder / Launchpad shows the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    /// Two copies would both smooth the wheel (double scrolling) and fight over ⌥Tab:
    /// the copy launched last wins.
    private func quitOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = NSRunningApplication.current.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return }
        others.forEach { $0.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        }
    }

    // MARK: - Event routing (event-tap thread)

    private func route(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        switch type {
        case .scrollWheel:
            // Our own smooth-scroll output: never re-process it.
            if event.getIntegerValueField(.eventSourceUserData) == ScrollEngine.marker { return event }
            if switcher.isActive {
                switcher.handleScroll(event)
                return nil
            }
            return scroll.handle(event)
        case .keyDown, .keyUp, .flagsChanged:
            return switcher.handleKey(type: type, event: event) ? nil : event
        default:
            return event
        }
    }

    private func startEverything() {
        if !tap.start() {
            // Permission just granted but not effective yet: retry shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startEverything() }
            return
        }
        if !trackingStarted {
            trackingStarted = true
            WindowStore.shared.startTracking()
        }
    }

    private func askForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.permissionTimer = nil
            self?.startEverything()
        }
    }

    private func offerToQuitAltTab() {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.lwouis.alt-tab-macos")
        guard !others.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "AltTab est ouvert"
        alert.informativeText = "AltTab et Scrolling AltTab vont se disputer ⌥Tab. Quitter AltTab maintenant ? (Pense aussi à le retirer des éléments d'ouverture.)"
        alert.addButton(withTitle: "Quitter AltTab")
        alert.addButton(withTitle: "Garder les deux")
        if alert.runModal() == .alertFirstButtonReturn {
            others.forEach { $0.terminate() }
        }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MascotArt.menuBarIcon()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = Settings.shared

        menu.addItem(header("Scrolling AltTab"))
        if !AXIsProcessTrusted() {
            menu.addItem(action("⚠️ Autoriser l'Accessibilité…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            })
        }

        menu.addItem(.separator())
        menu.addItem(header("Molette"))
        menu.addItem(toggle("Corriger la molette", s.scrollEnabled) { s.scrollEnabled.toggle() })
        menu.addItem(toggle("Défilement fluide", s.smoothScrolling, enabled: s.scrollEnabled) { s.smoothScrolling.toggle() })
        menu.addItem(toggle("Inverser le sens", s.reverseMouseWheel, enabled: s.scrollEnabled) { s.reverseMouseWheel.toggle() })

        let speedItem = NSMenuItem(title: "Vitesse", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu()
        let preset = s.speedPreset
        for speed in Settings.Speed.allCases {
            speedMenu.addItem(toggle(speed.label, preset == speed) { s.pixelsPerNotch = speed.pixelsPerNotch })
        }
        if preset == nil {
            speedMenu.addItem(.separator())
            speedMenu.addItem(toggle("Personnalisée (\(Int(s.pixelsPerNotch)) px)", true, enabled: false) {})
        }
        speedItem.submenu = speedMenu
        speedItem.isEnabled = s.scrollEnabled && s.smoothScrolling
        menu.addItem(speedItem)

        if let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier, app.processIdentifier != getpid() {
            let name = app.localizedName ?? bundleID
            let excluded = s.smoothExcludedApps.contains(bundleID)
            menu.addItem(toggle("Pas de défilement fluide dans « \(name) »", excluded, enabled: s.scrollEnabled) {
                if excluded { s.smoothExcludedApps.remove(bundleID) } else { s.smoothExcludedApps.insert(bundleID) }
            })
        }

        menu.addItem(.separator())
        menu.addItem(header("Alt+Tab"))
        menu.addItem(toggle("Activer ⌥Tab", s.altTabEnabled) { s.altTabEnabled.toggle() })

        menu.addItem(.separator())
        menu.addItem(action("Réglages…", key: ",") { SettingsWindowController.shared.show() })
        menu.addItem(action("À propos de Scrolling AltTab") { SettingsWindowController.shared.show(section: .about) })
        menu.addItem(action("Quitter Scrolling AltTab", key: "q") { NSApp.terminate(nil) })
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func toggle(_ title: String, _ on: Bool, enabled: Bool = true, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, key: "", handler: handler)
        item.state = on ? .on : .off
        item.isEnabled = enabled
        return item
    }

    private func action(_ title: String, key: String = "", _ handler: @escaping () -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title, key: key, handler: handler)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, key: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

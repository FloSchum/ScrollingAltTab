import AppKit
import ApplicationServices
import SwiftUI

let arguments = CommandLine.arguments

if arguments.contains("--simulate-scroll") {
    // Checks the easing maths without touching real events.
    func run(_ label: String, impulses: [(frame: Int, pixels: Double)]) {
        var axis = ScrollAxis()
        var total: Int32 = 0
        var frames = 0
        var lastNonZero = 0
        var queue = impulses
        for frame in 0..<600 {
            while let first = queue.first, first.frame == frame {
                axis.add(first.pixels)
                queue.removeFirst()
            }
            let step = axis.step(dt: 1.0 / 120)
            total += step
            if step != 0 { lastNonZero = frame }
            frames = frame
            if axis.isIdle && queue.isEmpty { break }
        }
        print("\(label): total=\(total)px, last movement at frame \(lastNonZero) (\(String(format: "%.0f", Double(lastNonZero) / 120 * 1000)) ms), frames=\(frames)")
    }
    run("1 cran (85 px)", impulses: [(0, 85)])
    run("3 crans rapides", impulses: [(0, 85), (6, 85), (12, 85)])
    run("aller puis retour", impulses: [(0, 85), (10, -85)])
    run("cran fractionnaire (molette haute résolution)", impulses: [(0, 85 * 0.25)])
    exit(0)
}

if let i = arguments.firstIndex(of: "--replay-trace"), arguments.count > i + 1 {
    // Replays recorded raw notches ("RAW <ms> d=<lines> …" lines) through the real filter and
    // spring at 120 Hz, and prints smoothness metrics.
    let text = (try? String(contentsOfFile: arguments[i + 1], encoding: .utf8)) ?? ""
    let notches: [(Double, Int)] = text.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[0] == "RAW", let ms = Double(parts[1]), let d = Int(parts[2].dropFirst(2)) else { return nil }
        return (ms / 1000, d > 0 ? 1 : -1)
    }
    let smoothness = Settings.defaultSmoothness
    var filter = WheelFilter()
    var axis = ScrollAxis(omega: 48 - smoothness * 22, tau: 0.018 + smoothness * 0.027)
    var out: [Int32] = []
    var index = 0
    var t = 0.0
    let end = (notches.last?.0 ?? 0) + 0.8
    func apply(_ list: [(WheelFilter.Notch, Double)]) {
        for (n, accel) in list { axis.add(n.payload.0 * Settings.defaultPixelsPerNotch * accel) }
    }
    while t < end {
        while index < notches.count, notches[index].0 <= t {
            let (time, sign) = notches[index]
            index += 1
            apply(filter.feed(.init(sign: sign, time: time, payload: (Double(sign), 0)), canHold: true))
        }
        apply(filter.release(now: t))
        out.append(axis.step(dt: 1.0 / 120))
        t += 1.0 / 120
    }
    let moving = out.filter { $0 != 0 }
    let flips = zip(moving, moving.dropFirst()).filter { ($0 > 0) != ($1 > 0) }.count
    let surges = zip(out, out.dropFirst()).filter { abs($0) >= 6 && Double(abs($1 - $0)) >= 0.4 * Double(abs($0)) }.count
    print("\(notches.count) crans → inversions=\(flips) poussées≥40%=\(surges) total=\(out.reduce(0, +)) px")
    exit(0)
}

if arguments.contains("--list-windows") {
    print("Accessibilité autorisée : \(AXIsProcessTrusted())")
    print("Capture d'écran autorisée : \(CGPreflightScreenCaptureAccess()), API capture : \(Private.canCaptureWindows), autres Spaces : \(Private.canFindOtherSpaceWindows)")
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)
    let start = Date()
    WindowStore.shared.snapshot(onlyPid: nil) { first in
      print("1er appel (cache vide) : \(first.count) entrées en \(Int(Date().timeIntervalSince(start) * 1000)) ms")
      let again = Date()
      WindowStore.shared.snapshot(onlyPid: nil) { entries in
        print("2e appel (cache chaud, comme après le préchauffage) : \(entries.count) entrées en \(Int(Date().timeIntervalSince(again) * 1000)) ms")
        for (i, e) in entries.enumerated() {
            var flags: [String] = []
            if e.windowID == nil { flags.append("sans fenêtre") }
            if e.isMinimized { flags.append("réduite") }
            if e.isAppHidden { flags.append("app masquée") }
            print(String(format: "%2d. [%@] %@ %@", i, e.appName, e.title, flags.isEmpty ? "" : "(\(flags.joined(separator: ", ")))"))
        }
        exit(0)
      }
    }
    RunLoop.main.run()
}

if let i = arguments.firstIndex(of: "--render-icon"), arguments.count > i + 1 {
    do {
        try MainActor.assumeIsolated { try MascotArt.writeIconset(to: URL(fileURLWithPath: arguments[i + 1])) }
        print("Iconset écrit dans \(arguments[i + 1])/AppIcon.iconset")
        exit(0)
    } catch {
        print("Échec : \(error)")
        exit(1)
    }
}

if let i = arguments.firstIndex(of: "--render-preview"), arguments.count > i + 1 {
    let url = URL(fileURLWithPath: arguments[i + 1])
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)
    WindowStore.shared.snapshot(onlyPid: nil) { entries in
        let ok = SwitcherController().renderPreview(entries, selected: min(1, max(entries.count - 1, 0)), to: url)
        print(ok ? "Aperçu écrit : \(url.path)" : "Échec du rendu")
        exit(ok ? 0 : 1)
    }
    RunLoop.main.run()
}

if let i = arguments.firstIndex(of: "--render-settings"), arguments.count > i + 1 {
    // Renders every settings page offscreen to PNG files (layout check, no event tap).
    let dir = URL(fileURLWithPath: arguments[i + 1])
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    for section in SettingsSection.allCases {
        let host = NSHostingController(rootView: SettingsView(navigation: SettingsNavigation(section)))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 780, height: 560))
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("settings-\(section.rawValue).png"))
        }
        window.close()
    }
    print("Pages de réglages écrites dans \(dir.path)")
    exit(0)
}

// Never start the real app (event tap!) because of a typo or an unknown test flag.
if let unknown = arguments.dropFirst().first(where: { $0.hasPrefix("--") }) {
    print("Option inconnue : \(unknown)\nOptions : --simulate-scroll, --replay-trace <fichier>, --list-windows, --render-preview <png>, --render-settings <dossier>, --render-icon <dossier>")
    exit(2)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

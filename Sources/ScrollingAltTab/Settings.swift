import Foundation

/// UserDefaults keys, shared by `Settings` (read from any thread) and the SwiftUI
/// settings window (`@AppStorage`).
enum Keys {
    static let scrollEnabled = "scrollEnabled"
    static let smoothScrolling = "smoothScrolling"
    static let reverseMouseWheel = "reverseMouseWheel"
    static let acceleration = "acceleration"
    static let shiftScrollsHorizontally = "shiftScrollsHorizontally"
    static let pixelsPerNotch = "pixelsPerNotch"
    static let smoothness = "smoothness"
    static let smoothExcludedApps = "smoothExcludedApps"
    static let altTabEnabled = "altTabEnabled"
    static let showThumbnails = "showThumbnails"
    static let showWindowlessApps = "showWindowlessApps"
    static let showDelay = "showDelay"
    static let thumbnailSize = "thumbnailSize"
}

/// User preferences. UserDefaults is thread-safe, so these are read from the event-tap thread too.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    enum Speed: CaseIterable {
        case slow, normal, fast, veryFast

        var label: String {
            switch self {
            case .slow: return "Lente"
            case .normal: return "Normale"
            case .fast: return "Rapide"
            case .veryFast: return "Très rapide"
            }
        }

        var pixelsPerNotch: Double {
            switch self {
            case .slow: return 50
            case .normal: return 85
            case .fast: return 130
            case .veryFast: return 190
            }
        }
    }

    static let defaultPixelsPerNotch = 85.0
    static let defaultSmoothness = 0.45

    /// macOS "natural scrolling" switch. It applies to the mouse AND the trackpad at once.
    static var systemNaturalScrolling: Bool {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["com.apple.swipescrolldirection"] as? Bool ?? true
    }

    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        d.object(forKey: key) as? Bool ?? fallback
    }

    private func double(_ key: String, _ fallback: Double) -> Double {
        d.object(forKey: key) as? Double ?? fallback
    }

    // MARK: Scroll

    var scrollEnabled: Bool {
        get { bool(Keys.scrollEnabled, true) }
        set { d.set(newValue, forKey: Keys.scrollEnabled) }
    }

    var smoothScrolling: Bool {
        get { bool(Keys.smoothScrolling, true) }
        set { d.set(newValue, forKey: Keys.smoothScrolling) }
    }

    /// Reverse the mouse wheel only (trackpad untouched). Defaults to on when natural
    /// scrolling is on, which gives the classic Windows direction on the wheel.
    var reverseMouseWheel: Bool {
        get { bool(Keys.reverseMouseWheel, Settings.systemNaturalScrolling) }
        set { d.set(newValue, forKey: Keys.reverseMouseWheel) }
    }

    var acceleration: Bool {
        get { bool(Keys.acceleration, true) }
        set { d.set(newValue, forKey: Keys.acceleration) }
    }

    var shiftScrollsHorizontally: Bool {
        get { bool(Keys.shiftScrollsHorizontally, true) }
        set { d.set(newValue, forKey: Keys.shiftScrollsHorizontally) }
    }

    /// Pixels scrolled for one wheel notch, before acceleration.
    var pixelsPerNotch: Double {
        get { min(max(double(Keys.pixelsPerNotch, Settings.defaultPixelsPerNotch), 20), 300) }
        set { d.set(newValue, forKey: Keys.pixelsPerNotch) }
    }

    /// 0 = snappy, 1 = very gliding.
    var smoothness: Double {
        get { min(max(double(Keys.smoothness, Settings.defaultSmoothness), 0), 1) }
        set { d.set(newValue, forKey: Keys.smoothness) }
    }

    /// Spring stiffness derived from `smoothness`: 48 rad/s (snappy) … 26 rad/s (gliding).
    var springOmega: Double { 48 - smoothness * 22 }

    /// First-stage smoothing derived from `smoothness`: 18 ms … 45 ms.
    var smoothingTau: Double { 0.018 + smoothness * 0.027 }

    /// Closest named preset, for the menu.
    var speedPreset: Speed? {
        Speed.allCases.first { abs($0.pixelsPerNotch - pixelsPerNotch) < 0.5 }
    }

    /// Bundle identifiers where smooth scrolling is off (direction is still fixed there).
    var smoothExcludedApps: Set<String> {
        get { Set(d.stringArray(forKey: Keys.smoothExcludedApps) ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: Keys.smoothExcludedApps) }
    }

    // MARK: Alt+Tab

    var altTabEnabled: Bool {
        get { bool(Keys.altTabEnabled, true) }
        set { d.set(newValue, forKey: Keys.altTabEnabled) }
    }

    var showThumbnails: Bool {
        get { bool(Keys.showThumbnails, true) }
        set { d.set(newValue, forKey: Keys.showThumbnails) }
    }

    var showWindowlessApps: Bool {
        get { bool(Keys.showWindowlessApps, true) }
        set { d.set(newValue, forKey: Keys.showWindowlessApps) }
    }

    /// Seconds before the grid appears (a faster ⌥Tab switches without showing it).
    var showDelay: Double {
        get { min(max(double(Keys.showDelay, 0.11), 0), 0.5) }
        set { d.set(newValue, forKey: Keys.showDelay) }
    }

    /// Width of one thumbnail tile in points.
    var thumbnailSize: Double {
        get { min(max(double(Keys.thumbnailSize, 230), 160), 360) }
        set { d.set(newValue, forKey: Keys.thumbnailSize) }
    }

    private init() {
        // Migrate the speed preset of the first version.
        if d.object(forKey: Keys.pixelsPerNotch) == nil, d.object(forKey: "speed_v1") != nil {
            let presets = [50.0, 85, 130, 190]
            let i = min(max(d.integer(forKey: "speed_v1"), 0), presets.count - 1)
            d.set(presets[i], forKey: Keys.pixelsPerNotch)
        }
    }
}

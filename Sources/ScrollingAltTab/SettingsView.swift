import AppKit
import Combine
import ServiceManagement
import SwiftUI

// MARK: - Window

/// Settings window with a sidebar, in the spirit of AltTab's preferences.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private let navigation = SettingsNavigation(.general)

    func show(section: SettingsSection? = nil) {
        if let section { navigation.selection = section }
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(navigation: navigation))
            let w = NSWindow(contentViewController: host)
            w.title = "Réglages de Scrolling AltTab"
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.toolbarStyle = .unified
            w.setContentSize(NSSize(width: 780, height: 560))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        // Show in the Dock and ⌘Tab while the window is open, like AltTab does.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, scroll, altTab, appearance, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "Général"
        case .scroll: return "Molette"
        case .altTab: return "Alt+Tab"
        case .appearance: return "Apparence"
        case .about: return "À propos"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .scroll: return "computermouse.fill"
        case .altTab: return "rectangle.stack.fill"
        case .appearance: return "paintbrush.fill"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .scroll: return .indigo
        case .altTab: return .blue
        case .appearance: return .pink
        case .about: return .teal
        }
    }
}

// MARK: - Root

final class SettingsNavigation: ObservableObject {
    @Published var selection: SettingsSection?
    init(_ section: SettingsSection) { selection = section }
}

struct SettingsView: View {
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $navigation.selection) { section in
                Label {
                    Text(section.title)
                } icon: {
                    Image(systemName: section.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(section.tint.gradient))
                }
                .tag(section)
                .padding(.vertical, 2)
            }
            .navigationSplitViewColumnWidth(190)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 8) {
                    MascotCanvas().frame(width: 34, height: 34)
                    Text("Scrolling AltTab").font(.headline)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            Group {
                switch navigation.selection ?? .general {
                case .general: GeneralPane()
                case .scroll: ScrollPane()
                case .altTab: AltTabPane()
                case .appearance: AppearancePane()
                case .about: AboutPane()
                }
            }
            .navigationTitle((navigation.selection ?? .general).title)
        }
        .frame(minWidth: 740, minHeight: 520)
    }
}

// MARK: - Shared bits

private final class PermissionState: ObservableObject {
    @Published var accessibility = AXIsProcessTrusted()
    @Published var screenRecording = CGPreflightScreenCaptureAccess()
    @Published var loginItem = SMAppService.mainApp.status == .enabled
    private var timer: AnyCancellable?

    init() {
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        accessibility = AXIsProcessTrusted()
        screenRecording = CGPreflightScreenCaptureAccess()
        loginItem = SMAppService.mainApp.status == .enabled
    }
}

private struct StatusBadge: View {
    let ok: Bool
    var body: some View {
        Label(ok ? "Autorisé" : "Non autorisé", systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(ok ? .green : .orange)
            .font(.callout)
    }
}

private func openPrivacyPane(_ anchor: String) {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
}

// MARK: - Général

private struct GeneralPane: View {
    @StateObject private var permissions = PermissionState()
    @AppStorage(Keys.scrollEnabled) private var scrollEnabled = true
    @AppStorage(Keys.altTabEnabled) private var altTabEnabled = true

    var body: some View {
        Form {
            Section("Fonctions") {
                Toggle("Corriger la molette de la souris", isOn: $scrollEnabled)
                Toggle("Remplacer ⌥Tab par le sélecteur de fenêtres", isOn: $altTabEnabled)
            }
            Section("Démarrage") {
                Toggle("Ouvrir Scrolling AltTab à l'ouverture de session", isOn: Binding(
                    get: { permissions.loginItem },
                    set: { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSLog("ScrollingAltTab login item: \(error)")
                        }
                        permissions.refresh()
                    }))
            }
            Section {
                LabeledContent("Accessibilité") {
                    HStack {
                        StatusBadge(ok: permissions.accessibility)
                        if !permissions.accessibility {
                            Button("Ouvrir les Réglages") { openPrivacyPane("Privacy_Accessibility") }
                        }
                    }
                }
                LabeledContent("Enregistrement d'écran") {
                    HStack {
                        StatusBadge(ok: permissions.screenRecording)
                        if !permissions.screenRecording {
                            Button("Autoriser") {
                                if !CGRequestScreenCaptureAccess() { openPrivacyPane("Privacy_ScreenCapture") }
                            }
                        }
                    }
                }
            } header: {
                Text("Autorisations")
            } footer: {
                Text("L'Accessibilité est obligatoire (molette et ⌥Tab). L'enregistrement d'écran sert uniquement aux aperçus des fenêtres.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Molette

private struct ScrollPane: View {
    @AppStorage(Keys.scrollEnabled) private var scrollEnabled = true
    @AppStorage(Keys.smoothScrolling) private var smooth = true
    @AppStorage(Keys.reverseMouseWheel) private var reverse = Settings.systemNaturalScrolling
    @AppStorage(Keys.acceleration) private var acceleration = true
    @AppStorage(Keys.shiftScrollsHorizontally) private var shiftHorizontal = true
    @AppStorage(Keys.pixelsPerNotch) private var pixels = Settings.defaultPixelsPerNotch
    @AppStorage(Keys.smoothness) private var smoothness = Settings.defaultSmoothness

    var body: some View {
        Form {
            Section {
                Toggle("Corriger la molette de la souris", isOn: $scrollEnabled)
            } footer: {
                Text("S'applique seulement aux souris à molette crantée. Le trackpad et la Magic Mouse ne sont jamais modifiés.")
                    .foregroundStyle(.secondary)
            }

            Section("Sens") {
                Toggle("Inverser le sens de la molette", isOn: $reverse)
                Text(Settings.systemNaturalScrolling
                     ? "Le défilement naturel est activé sur ce Mac : l'inversion donne le sens « Windows » à la molette, le trackpad reste naturel."
                     : "Le défilement naturel est désactivé sur ce Mac : l'inversion donne le sens naturel à la molette.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .disabled(!scrollEnabled)

            Section("Défilement fluide") {
                Toggle("Défilement fluide", isOn: $smooth)
                Group {
                    LabeledContent("Vitesse") {
                        HStack {
                            Text("Lente").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $pixels, in: 30...250)
                            Text("Rapide").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Fluidité") {
                        HStack {
                            Text("Nette").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $smoothness, in: 0...1)
                            Text("Glissante").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        ForEach(Settings.Speed.allCases, id: \.self) { preset in
                            Button(preset.label) { pixels = preset.pixelsPerNotch }
                        }
                        Spacer()
                        Button("Réinitialiser") {
                            pixels = Settings.defaultPixelsPerNotch
                            smoothness = Settings.defaultSmoothness
                        }
                    }
                    .controlSize(.small)
                    Toggle("Accélération quand la molette tourne vite", isOn: $acceleration)
                    Toggle("⇧ + molette = défilement horizontal", isOn: $shiftHorizontal)
                }
                .disabled(!smooth)
            }
            .disabled(!scrollEnabled)

            Section("Essai") {
                ScrollTestArea()
                    .frame(height: 150)
            }

            Section {
                ExcludedAppsEditor()
            } header: {
                Text("Apps sans défilement fluide")
            } footer: {
                Text("Pour les jeux ou les apps qui gèrent déjà leur propre défilement. Le sens de la molette y reste corrigé.")
                    .foregroundStyle(.secondary)
            }
            .disabled(!scrollEnabled)
        }
        .formStyle(.grouped)
    }
}

private struct ScrollTestArea: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(1...40, id: \.self) { i in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(hue: Double(i % 12) / 12, saturation: 0.55, brightness: 0.95))
                            .frame(width: 18, height: 18)
                        Text("Ligne \(i) — fais tourner la molette ici pour tester les réglages")
                            .font(.callout)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
    }
}

private final class ExcludedAppsModel: ObservableObject {
    @Published var apps: [String] = Settings.shared.smoothExcludedApps.sorted()
    @Published var selected: String?
}

private struct ExcludedAppsEditor: View {
    @StateObject private var model = ExcludedAppsModel()
    private var apps: [String] { model.apps }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(apps, id: \.self, selection: $model.selected) { bundleID in
                HStack {
                    Image(nsImage: Self.icon(bundleID)).resizable().frame(width: 18, height: 18)
                    Text(Self.name(bundleID))
                    Spacer()
                    Text(bundleID).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 90)
            .overlay {
                if apps.isEmpty {
                    Text("Aucune app exclue").foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 0) {
                Menu {
                    ForEach(runningCandidates(), id: \.self) { bundleID in
                        Button(Self.name(bundleID)) { update(apps + [bundleID]) }
                    }
                    Divider()
                    Button("Choisir une app…") { pickApp() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 8)
                Button {
                    if let selected = model.selected { update(apps.filter { $0 != selected }) }
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(model.selected == nil)
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private func update(_ list: [String]) {
        let set = Set(list)
        Settings.shared.smoothExcludedApps = set
        model.apps = set.sorted()
        model.selected = nil
    }

    private func runningCandidates() -> [String] {
        let ids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { $0 != Bundle.main.bundleIdentifier && !apps.contains($0) }
        return Array(Set(ids)).sorted { Self.name($0).localizedCaseInsensitiveCompare(Self.name($1)) == .orderedAscending }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        update(apps + ids)
    }

    static func name(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(_ bundleID: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

// MARK: - Alt+Tab

private struct AltTabPane: View {
    @AppStorage(Keys.altTabEnabled) private var enabled = true
    @AppStorage(Keys.showWindowlessApps) private var windowless = true
    @AppStorage(Keys.showDelay) private var showDelay = 0.11

    private let shortcuts: [(String, String)] = [
        ("⌥ Tab", "Ouvrir, puis fenêtre suivante"),
        ("⌥ ⇧ Tab", "Fenêtre précédente"),
        ("Relâcher ⌥", "Aller à la fenêtre sélectionnée"),
        ("Molette (⌥ tenu)", "Changer de fenêtre"),
        ("← → ↑ ↓", "Se déplacer dans la grille"),
        ("Entrée / Espace", "Valider"),
        ("Échap", "Annuler"),
        ("Q", "Quitter l'app"),
        ("W", "Fermer la fenêtre"),
        ("M", "Réduire la fenêtre"),
        ("H", "Masquer l'app"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Activer ⌥Tab", isOn: $enabled)
            }
            Section("Comportement") {
                LabeledContent("Délai avant affichage") {
                    HStack {
                        Slider(value: $showDelay, in: 0...0.4)
                        Text("\(Int(showDelay * 1000)) ms").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                Text("Un ⌥Tab plus rapide que ce délai revient à la fenêtre précédente sans afficher la grille.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Afficher les apps ouvertes sans fenêtre", isOn: $windowless)
            }
            .disabled(!enabled)
            Section("Raccourcis") {
                ForEach(shortcuts, id: \.0) { key, action in
                    LabeledContent(action) {
                        Text(key)
                            .font(.system(.callout, design: .rounded).weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Apparence

private struct AppearancePane: View {
    @StateObject private var permissions = PermissionState()
    @AppStorage(Keys.showThumbnails) private var thumbnails = true
    @AppStorage(Keys.thumbnailSize) private var tileSize = 230.0

    var body: some View {
        Form {
            Section {
                Toggle("Aperçus des fenêtres", isOn: $thumbnails)
                if !permissions.screenRecording {
                    HStack {
                        Label("Les aperçus demandent l'autorisation « Enregistrement d'écran ».", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Autoriser") {
                            if !CGRequestScreenCaptureAccess() { openPrivacyPane("Privacy_ScreenCapture") }
                        }
                    }
                    .font(.callout)
                }
                LabeledContent("Taille des vignettes") {
                    HStack {
                        Text("Petites").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $tileSize, in: 160...360)
                        Text("Grandes").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!thumbnails)
            } footer: {
                Text("Sans aperçus, la grille affiche les icônes des apps.").foregroundStyle(.secondary)
            }
            Section("Aperçu") {
                TilePreview(size: thumbnails ? tileSize : 128, thumbnails: thumbnails)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TilePreview: View {
    let size: Double
    let thumbnails: Bool

    var body: some View {
        let scale = 0.6
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                VStack(spacing: 6) {
                    if thumbnails {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(LinearGradient(colors: [Color(hue: Double(i) / 3, saturation: 0.4, brightness: 0.95), .white],
                                                 startPoint: .top, endPoint: .bottom))
                    } else {
                        Image(systemName: ["safari.fill", "folder.fill", "terminal.fill"][i])
                            .font(.system(size: 34))
                            .frame(maxHeight: .infinity)
                    }
                    Text(["Safari", "Finder", "Terminal"][i]).font(.caption).lineLimit(1)
                }
                .padding(6)
                .frame(width: size * scale, height: (thumbnails ? size * 0.75 : 118) * scale)
                .background(RoundedRectangle(cornerRadius: 10).fill(i == 1 ? Color.accentColor.opacity(0.38) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(i == 1 ? Color.accentColor : .clear, lineWidth: 2))
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.75)))
    }
}

// MARK: - À propos

private struct AboutPane: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            MascotCanvas().frame(width: 190, height: 190)
            Text("Scrolling AltTab").font(.largeTitle.weight(.bold))
            Text("Version \(version)").foregroundStyle(.secondary)
            Text("Voici **Molette**, la petite souris qui remet ta molette dans le bon sens\net range tes fenêtres derrière ⌥Tab.")
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

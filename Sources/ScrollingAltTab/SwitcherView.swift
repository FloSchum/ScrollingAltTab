import AppKit
import SwiftUI

final class SwitcherModel: ObservableObject {
    @Published var entries: [WindowEntry] = []
    @Published var selected = 0
    @Published var thumbnails: [CGWindowID: NSImage] = [:]
    @Published var showThumbnails = true
    var columns = 1
    var itemSize = CGSize(width: 220, height: 170)

    var onHover: (Int) -> Void = { _ in }
    var onClick: (Int) -> Void = { _ in }
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    static let padding: CGFloat = 14
    static let spacing: CGFloat = 8

    var body: some View {
        let columns = Array(repeating: GridItem(.fixed(model.itemSize.width), spacing: Self.spacing), count: max(model.columns, 1))
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: Self.spacing) {
                    ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                        ItemView(
                            entry: entry,
                            thumbnail: entry.windowID.flatMap { model.thumbnails[$0] },
                            showThumbnail: model.showThumbnails,
                            isSelected: index == model.selected,
                            size: model.itemSize
                        )
                        .id(index)
                        .contentShape(Rectangle())
                        .onHover { inside in if inside { model.onHover(index) } }
                        .onTapGesture { model.onClick(index) }
                    }
                }
                .padding(Self.padding)
            }
            .onChange(of: model.selected) { _, newValue in
                proxy.scrollTo(newValue)
            }
        }
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }
}

private struct ItemView: View {
    let entry: WindowEntry
    let thumbnail: NSImage?
    let showThumbnail: Bool
    let isSelected: Bool
    let size: CGSize

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if showThumbnail, let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    } else {
                        Image(nsImage: entry.appIcon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: showThumbnail ? 72 : 64, height: showThumbnail ? 72 : 64)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showThumbnail, thumbnail != nil {
                    Image(nsImage: entry.appIcon)
                        .resizable()
                        .frame(width: 30, height: 30)
                        .shadow(radius: 2)
                        .offset(x: 4, y: 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 4) {
                if entry.isMinimized {
                    Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 9, weight: .bold))
                } else if entry.isAppHidden {
                    Image(systemName: "eye.slash").font(.system(size: 9, weight: .bold))
                }
                Text(entry.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.white.opacity(isSelected ? 1 : 0.85))
            .frame(height: 16)
        }
        .padding(8)
        .frame(width: size.width, height: size.height)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.38) : Color.white.opacity(0.0001))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .opacity(entry.isAppHidden || entry.isMinimized ? 0.7 : 1)
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class SwitcherPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
}

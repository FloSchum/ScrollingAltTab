import AppKit
import SwiftUI

/// "Molette", the mascot: a little mouse holding a scroll wheel in front of a fan of windows.
/// Drawn in a 1024×1024 design space so the same drawing gives the app icon,
/// the About page and the menu-bar silhouette.
struct MascotCanvas: View {
    /// Purple app-icon background and the windows behind the mouse.
    var withBackground = true

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 1024
            ctx.translateBy(x: (size.width - 1024 * s) / 2, y: (size.height - 1024 * s) / 2)
            ctx.scaleBy(x: s, y: s)
            if withBackground {
                Self.drawBackground(&ctx)
                Self.drawWindows(&ctx)
            }
            Self.drawMouse(&ctx)
        }
    }

    // MARK: Palette

    private static let fur = Gradient(colors: [Color(hex: 0xF1F2F8), Color(hex: 0xB7BACB)])
    private static let outline = Color(hex: 0x6E7190)
    private static let pink = Color(hex: 0xFF9EB8)
    private static let nose = Color(hex: 0xFF6F93)
    private static let ink = Color(hex: 0x1E1F2E)

    // MARK: Background

    private static func drawBackground(_ ctx: inout GraphicsContext) {
        let squircle = Path(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerRadius: 185, style: .continuous)
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 10))
            layer.fill(squircle, with: .linearGradient(
                Gradient(colors: [Color(hex: 0x8A7BFF), Color(hex: 0x4B33C9)]),
                startPoint: CGPoint(x: 512, y: 100), endPoint: CGPoint(x: 512, y: 924)))
        }
        // Soft light at the top, kept inside the squircle.
        var lit = ctx
        lit.clip(to: squircle)
        lit.fill(Path(ellipseIn: CGRect(x: 160, y: 60, width: 704, height: 420)),
                 with: .radialGradient(Gradient(colors: [.white.opacity(0.22), .clear]),
                                       center: CGPoint(x: 512, y: 200), startRadius: 0, endRadius: 360))
    }

    private static func drawWindows(_ ctx: inout GraphicsContext) {
        for (cx, angle, tint) in [(318.0, -13.0, 0x6FD3FF), (706.0, 13.0, 0xFFC86B)] {
            var c = ctx
            c.translateBy(x: cx, y: 500)
            c.rotate(by: .degrees(angle))
            let card = CGRect(x: -185, y: -140, width: 370, height: 280)
            c.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 8))
                layer.fill(Path(roundedRect: card, cornerRadius: 34, style: .continuous), with: .color(.white))
            }
            var bar = Path()
            bar.addRoundedRect(in: CGRect(x: -185, y: -140, width: 370, height: 56),
                               cornerRadii: RectangleCornerRadii(topLeading: 34, bottomLeading: 0, bottomTrailing: 0, topTrailing: 34), style: .continuous)
            c.fill(bar, with: .color(Color(hex: 0xE7E9F2)))
            for (i, dot) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
                c.fill(Path(ellipseIn: CGRect(x: -158 + Double(i) * 34, y: -122, width: 20, height: 20)), with: .color(Color(hex: dot)))
            }
            c.fill(Path(roundedRect: CGRect(x: -155, y: -56, width: 310, height: 86), cornerRadius: 16), with: .color(Color(hex: tint).opacity(0.85)))
            for (i, w) in [280.0, 210, 250].enumerated() {
                c.fill(Path(roundedRect: CGRect(x: -155, y: 48 + Double(i) * 28, width: w, height: 14), cornerRadius: 7),
                       with: .color(Color(hex: 0xD5D8E5)))
            }
        }
    }

    // MARK: Mouse

    private static func furFill(_ rect: CGRect) -> GraphicsContext.Shading {
        .radialGradient(fur, center: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.3),
                        startRadius: 0, endRadius: max(rect.width, rect.height) * 0.75)
    }

    private static func drawMouse(_ ctx: inout GraphicsContext) {
        // Ears.
        for cx in [318.0, 706.0] {
            let ear = CGRect(x: cx - 128, y: 190, width: 256, height: 256)
            ctx.fill(Path(ellipseIn: ear), with: furFill(ear))
            ctx.stroke(Path(ellipseIn: ear), with: .color(outline), lineWidth: 8)
            ctx.fill(Path(ellipseIn: ear.insetBy(dx: 44, dy: 44)), with: .color(pink))
        }

        // Head.
        let head = CGRect(x: 272, y: 270, width: 480, height: 460)
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 8))
            layer.fill(Path(ellipseIn: head), with: furFill(head))
        }
        ctx.stroke(Path(ellipseIn: head), with: .color(outline), lineWidth: 8)

        // Cheeks.
        for cx in [384.0, 640.0] {
            ctx.fill(Path(ellipseIn: CGRect(x: cx - 42, y: 548, width: 84, height: 46)), with: .color(pink.opacity(0.55)))
        }

        // Eyes.
        for cx in [430.0, 594.0] {
            ctx.fill(Path(ellipseIn: CGRect(x: cx - 27, y: 438, width: 54, height: 70)), with: .color(ink))
            ctx.fill(Path(ellipseIn: CGRect(x: cx - 16, y: 450, width: 22, height: 22)), with: .color(.white))
            ctx.fill(Path(ellipseIn: CGRect(x: cx + 6, y: 482, width: 10, height: 10)), with: .color(.white.opacity(0.8)))
        }

        // Whiskers.
        var whiskers = Path()
        for (from, to) in [((404.0, 560.0), (276.0, 532.0)), ((404.0, 578.0), (272.0, 590.0)),
                           ((620.0, 560.0), (748.0, 532.0)), ((620.0, 578.0), (752.0, 590.0))] {
            whiskers.move(to: CGPoint(x: from.0, y: from.1))
            whiskers.addLine(to: CGPoint(x: to.0, y: to.1))
        }
        ctx.stroke(whiskers, with: .color(outline.opacity(0.8)), style: StrokeStyle(lineWidth: 7, lineCap: .round))

        // Nose and smile.
        ctx.fill(Path(ellipseIn: CGRect(x: 487, y: 528, width: 50, height: 36)), with: .color(nose))
        ctx.fill(Path(ellipseIn: CGRect(x: 498, y: 533, width: 16, height: 10)), with: .color(.white.opacity(0.6)))
        var smile = Path()
        smile.move(to: CGPoint(x: 472, y: 584))
        smile.addQuadCurve(to: CGPoint(x: 512, y: 584), control: CGPoint(x: 492, y: 610))
        smile.addQuadCurve(to: CGPoint(x: 552, y: 584), control: CGPoint(x: 532, y: 610))
        ctx.stroke(smile, with: .color(ink), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))

        // The scroll wheel ("molette"), held in both paws.
        let center = CGPoint(x: 512, y: 762)
        let radius = 96.0
        let disc = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 6))
            layer.fill(Path(ellipseIn: disc),
                       with: .linearGradient(Gradient(colors: [Color(hex: 0x55597E), Color(hex: 0x23253A)]),
                                             startPoint: CGPoint(x: disc.minX, y: disc.minY), endPoint: CGPoint(x: disc.maxX, y: disc.maxY)))
        }
        var notches = Path()
        for i in 0..<16 {
            let a = Double(i) / 16 * 2 * .pi
            notches.move(to: CGPoint(x: center.x + cos(a) * (radius - 30), y: center.y + sin(a) * (radius - 30)))
            notches.addLine(to: CGPoint(x: center.x + cos(a) * (radius - 10), y: center.y + sin(a) * (radius - 10)))
        }
        ctx.stroke(notches, with: .color(Color(hex: 0x9EA2CC)), style: StrokeStyle(lineWidth: 8, lineCap: .round))
        ctx.fill(Path(ellipseIn: CGRect(x: center.x - 26, y: center.y - 26, width: 52, height: 52)), with: .color(Color(hex: 0x9EA2CC)))
        ctx.fill(Path(ellipseIn: CGRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24)), with: .color(Color(hex: 0x2E3150)))

        // Rotation swooshes.
        var swoosh = Path()
        swoosh.addArc(center: center, radius: radius + 34, startAngle: .degrees(-150), endAngle: .degrees(-100), clockwise: false)
        swoosh.move(to: CGPoint(x: center.x + cos(.pi * 30 / 180) * (radius + 34), y: center.y + sin(.pi * 30 / 180) * (radius + 34)))
        swoosh.addArc(center: center, radius: radius + 34, startAngle: .degrees(30), endAngle: .degrees(80), clockwise: false)
        ctx.stroke(swoosh, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 10, lineCap: .round))

        for cx in [418.0, 606.0] {
            let paw = CGRect(x: cx - 44, y: 712, width: 88, height: 70)
            ctx.fill(Path(ellipseIn: paw), with: furFill(paw))
            ctx.stroke(Path(ellipseIn: paw), with: .color(outline), lineWidth: 7)
        }
    }
}

extension Color {
    init(hex: Int) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: 1)
    }
}

enum MascotArt {
    /// Mouse-head silhouette for the menu bar (template image: macOS tints it).
    static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1.2, y: 1.6, width: 6.4, height: 6.4)).fill()
            NSBezierPath(ovalIn: NSRect(x: 10.4, y: 1.6, width: 6.4, height: 6.4)).fill()
            NSBezierPath(ovalIn: NSRect(x: 3.2, y: 4.2, width: 11.6, height: 11.2)).fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: 6.1, y: 8.0, width: 1.7, height: 2.2)).fill()
            NSBezierPath(ovalIn: NSRect(x: 10.2, y: 8.0, width: 1.7, height: 2.2)).fill()
            NSBezierPath(ovalIn: NSRect(x: 8.2, y: 11.2, width: 1.6, height: 1.2)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Scrolling AltTab"
        return image
    }

    /// Writes AppIcon.iconset (all macOS sizes) into `directory`.
    @MainActor
    static func writeIconset(to directory: URL) throws {
        let iconset = directory.appendingPathComponent("AppIcon.iconset")
        try? FileManager.default.removeItem(at: iconset)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                let renderer = ImageRenderer(content: MascotCanvas().frame(width: 1024, height: 1024))
                renderer.scale = CGFloat(px) / 1024
                guard let cg = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
                let rep = NSBitmapImageRep(cgImage: cg)
                guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: iconset.appendingPathComponent(name))
            }
        }
    }
}

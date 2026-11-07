// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ScrollingAltTab",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ScrollingAltTab",
            path: "Sources/ScrollingAltTab",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI"),
            ]
        )
    ]
)

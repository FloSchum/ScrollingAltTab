import ApplicationServices
import CoreGraphics
import Foundation

/// Private macOS functions, resolved at runtime with dlsym so the build does not
/// depend on private framework stubs. Every entry point is optional: if Apple removes
/// one, the feature that needs it degrades instead of crashing.
enum Private {
    struct PSN {
        var high: UInt32 = 0
        var low: UInt32 = 0
    }

    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias HWCaptureFn = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, UInt32, UInt32) -> Unmanaged<CFArray>?
    private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias AXRemoteTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private typealias GetPSNFn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> OSStatus
    private typealias SetFrontFn = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> CGError
    private typealias PostRecordFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>) -> CGError

    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func sym<T>(_ name: String, as _: T.Type) -> T? {
        let ptr = (skyLight.flatMap { dlsym($0, name) }) ?? dlsym(rtldDefault, name)
        guard let ptr else { return nil }
        return unsafeBitCast(ptr, to: T.self)
    }

    private static let mainConnection = sym("CGSMainConnectionID", as: MainConnectionFn.self)
    private static let hwCapture = sym("CGSHWCaptureWindowList", as: HWCaptureFn.self)
    private static let axGetWindow = sym("_AXUIElementGetWindow", as: AXGetWindowFn.self)
    private static let axRemoteToken = sym("_AXUIElementCreateWithRemoteToken", as: AXRemoteTokenFn.self)
    private static let getPSN = sym("GetProcessForPID", as: GetPSNFn.self)
    private static let setFront = sym("_SLPSSetFrontProcessWithOptions", as: SetFrontFn.self)
    private static let postRecord = sym("SLPSPostEventRecordTo", as: PostRecordFn.self)

    static var canCaptureWindows: Bool { mainConnection != nil && hwCapture != nil }
    static var canFindOtherSpaceWindows: Bool { axRemoteToken != nil }

    static func windowID(of element: AXUIElement) -> CGWindowID {
        var wid: CGWindowID = 0
        guard let axGetWindow, axGetWindow(element, &wid) == .success else { return 0 }
        return wid
    }

    /// Builds an AXUIElement for `pid` from a remote token. This finds windows that live
    /// on other Spaces, which `kAXWindowsAttribute` does not return.
    static func axElement(pid: pid_t, elementID: UInt64) -> AXUIElement? {
        guard let axRemoteToken else { return nil }
        var data = Data(capacity: 20)
        withUnsafeBytes(of: pid) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(0)) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(0x636f_636f)) { data.append(contentsOf: $0) } // "coco"
        withUnsafeBytes(of: elementID) { data.append(contentsOf: $0) }
        return axRemoteToken(data as CFData)?.takeRetainedValue()
    }

    /// Synchronous window capture through the WindowServer. Needs Screen Recording permission.
    static func capture(windowID: CGWindowID) -> CGImage? {
        guard let mainConnection, let hwCapture else { return nil }
        var wid = windowID
        let ignoreGlobalClipShape: UInt32 = 1 << 11
        let nominalResolution: UInt32 = 1 << 9
        guard let array = hwCapture(mainConnection(), &wid, 1, ignoreGlobalClipShape | nominalResolution)?
            .takeRetainedValue() as? [CGImage] else { return nil }
        return array.first
    }

    /// Brings one specific window to the front (switching Space if needed) and makes it key.
    @discardableResult
    static func focus(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let getPSN, let setFront else { return false }
        var psn = PSN()
        guard withUnsafeMutableBytes(of: &psn, { getPSN(pid, $0.baseAddress!) }) == noErr else { return false }
        let userGenerated: UInt32 = 0x200
        let noWindows: UInt32 = 0x400
        _ = withUnsafeMutableBytes(of: &psn) { setFront($0.baseAddress!, windowID, windowID == 0 ? noWindows : userGenerated) }
        if windowID != 0 { makeKey(&psn, windowID) }
        return true
    }

    private static func makeKey(_ psn: inout PSN, _ windowID: CGWindowID) {
        guard let postRecord else { return }
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowID) { raw in
            for (i, b) in raw.enumerated() { bytes[0x3c + i] = b }
        }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        for kind: UInt8 in [0x01, 0x02] {
            bytes[0x08] = kind
            _ = withUnsafeMutableBytes(of: &psn) { psnPtr in
                bytes.withUnsafeMutableBufferPointer { postRecord(psnPtr.baseAddress!, $0.baseAddress!) }
            }
        }
    }
}

// MARK: - Small Accessibility helpers

enum AX {
    static func attr<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        return value as? T
    }

    static func set(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) {
        AXUIElementSetAttributeValue(element, name as CFString, value)
    }

    static func perform(_ element: AXUIElement, _ action: String) {
        AXUIElementPerformAction(element, action as CFString)
    }
}

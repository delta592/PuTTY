import AppKit
import Foundation
import PuttyBridge
import PuttyMacUI
import XCTest

/// Shared helpers for PuttyMacUI XCTest cases (Phase 9.1).
@MainActor
enum PuttyMacUITestSupport {
    /// Ensure AppKit is ready for windowed tests without activating the Dock icon.
    static func ensureApplication() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        _ = app
    }

    /// Drain the main run loop briefly so deferred `DispatchQueue.main.async` work runs.
    static func pumpMain(seconds: TimeInterval = 0.05) {
        let until = Date(timeIntervalSinceNow: seconds)
        while Date() < until {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    static func uniqueSessionName(prefix: String) -> String {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        return "__PuttyMacUITest_\(prefix)_\(stamp)__"
    }
}

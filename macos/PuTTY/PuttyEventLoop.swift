import Foundation
import PuttyBridge

/// PuTTY timer / uxsel integration on the AppKit main run loop (Phase 5.4).
@MainActor
enum PuttyEventLoop {
    static func start() {
        putty_bridge_eventloop_start()
    }
}

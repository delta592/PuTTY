import Foundation
import PuttyBridge

/// PuTTY timer / uxsel integration on the AppKit main run loop (Phase 5.4).
@MainActor
public enum PuttyEventLoop {
    public static func start() {
        putty_bridge_eventloop_start()
    }
}

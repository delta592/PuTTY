import Foundation

/// Hop C→Swift UI work onto the main actor (bridge-and-ui.mdc / AUDIT P1.4).
///
/// Prefer this over bare `MainActor.assumeIsolated` for UI-mutating bridge
/// callbacks. Paint nested under `draw(_:)` may still use `assumeIsolated`
/// for synchronous latency.
public enum PuttyMainHop {
    /// Run `body` on the main actor. If already on the main thread, run
    /// synchronously; otherwise `DispatchQueue.main.async`.
    public nonisolated static func run(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }
}

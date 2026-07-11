import Foundation

/**
 * Standard hop for C→Swift (and other off-main) UI work onto the main actor
 * (bridge-and-ui.mdc / AUDIT P3.24).
 *
 * Policy:
 * - **UI-mutating bridge callbacks** (specials, event log, title, bell,
 *   open-session, remote exit, …): always `PuttyMainHop.run`.
 * - **Synchronous paint nested under `draw(_:)`** (setup/free draw ctx,
 *   draw_text/cursor, char_width): `MainActor.assumeIsolated` is OK for
 *   latency; do not async-hop mid-paint.
 * - **NSTextInputClient / AppKit input** already on the main thread: prefer
 *   `assumeIsolated` only when the trampoline is `nonisolated` and must
 *   return a value synchronously.
 * - Prefer this over bare `DispatchQueue.main.async` or `Task { @MainActor }`
 *   for the same hop (keeps one entry point and sync-on-main behavior).
 */
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

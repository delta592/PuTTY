import Foundation

/**
 * Standard hop for C→Swift (and other off-main) UI work onto the main actor
 * (bridge-and-ui.mdc / AUDIT P3.24).
 *
 * Policy:
 * - **UI-mutating bridge callbacks** that may already be on main and must
 *   run soon (specials, event log, title, bell, remote exit, …):
 *   `PuttyMainHop.run` (sync if already on main).
 * - **Work that must wait for the next main-queue turn** (session present
 *   after config `dlg_end`, settings apply that must not nest under SSH
 *   I/O): `PuttyMainHop.runAsync` — never synchronous, even on the main
 *   thread. Nested `backend_init` / `connect` during dialog teardown can
 *   fail with `EHOSTUNREACH` ("No route to host") before uxsel Dispatch
 *   sources run.
 * - **Synchronous paint nested under `draw(_:)`**: `MainActor.assumeIsolated`
 *   is OK for latency; do not async-hop mid-paint.
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

    /// Always schedule `body` on the next main-queue turn (never sync).
    public nonisolated static func runAsync(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async(execute: body)
    }
}

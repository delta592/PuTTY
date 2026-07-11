import Foundation

/**
 * Structured errors for C bridge failures at the first Swift touch point
 * (bridge-and-ui.mdc). Prefer mapping integer/bool C results here instead of
 * ad hoc `fputs` / beep-only paths.
 */
public enum PuttyBridgeError: Error, LocalizedError, Equatable {
    /// `putty_bridge_termwin_open` returned false.
    case termWinOpenFailed
    /// Heap message from a C `char **error_out` (already copied into Swift).
    case bridgeMessage(String)

    public var errorDescription: String? {
        switch self {
        case .termWinOpenFailed:
            return "Failed to open the terminal session."
        case .bridgeMessage(let message):
            return message
        }
    }

    /// Copy a C heap string into a `bridgeMessage`, then free with `freeFn`.
    public static func takeCString(
        _ ptr: inout UnsafeMutablePointer<CChar>?,
        free freeFn: (UnsafeMutablePointer<CChar>?) -> Void
    ) -> PuttyBridgeError? {
        guard let raw = ptr else { return nil }
        let message = String(cString: raw)
        freeFn(raw)
        ptr = nil
        return .bridgeMessage(message)
    }
}

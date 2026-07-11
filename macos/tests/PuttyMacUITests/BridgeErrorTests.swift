import Foundation
import PuttyMacUI
import XCTest

/// Bridge-boundary Error mapping (AUDIT P2.16 / P3 coverage).
final class BridgeErrorTests: XCTestCase {
    func testTermWinOpenFailedDescription() {
        let error = PuttyBridgeError.termWinOpenFailed
        XCTAssertEqual(
            error.localizedDescription,
            "Failed to open the terminal session."
        )
    }

    func testBridgeMessageDescription() {
        let error = PuttyBridgeError.bridgeMessage("probe failure")
        XCTAssertEqual(error.localizedDescription, "probe failure")
    }

    func testTakeCStringCopiesAndFrees() {
        var ptr: UnsafeMutablePointer<CChar>? = strdup("heap-error")
        XCTAssertNotNil(ptr)
        let error = PuttyBridgeError.takeCString(&ptr) { free($0) }
        XCTAssertNil(ptr)
        XCTAssertEqual(error, .bridgeMessage("heap-error"))
        XCTAssertEqual(error?.localizedDescription, "heap-error")
    }

    func testTakeCStringNilIsNil() {
        var ptr: UnsafeMutablePointer<CChar>?
        XCTAssertNil(PuttyBridgeError.takeCString(&ptr) { free($0) })
    }

    func testEquatable() {
        XCTAssertEqual(
            PuttyBridgeError.termWinOpenFailed,
            PuttyBridgeError.termWinOpenFailed
        )
        XCTAssertEqual(
            PuttyBridgeError.bridgeMessage("a"),
            PuttyBridgeError.bridgeMessage("a")
        )
        XCTAssertNotEqual(
            PuttyBridgeError.bridgeMessage("a"),
            PuttyBridgeError.bridgeMessage("b")
        )
        XCTAssertNotEqual(
            PuttyBridgeError.termWinOpenFailed,
            PuttyBridgeError.bridgeMessage("x")
        )
    }
}

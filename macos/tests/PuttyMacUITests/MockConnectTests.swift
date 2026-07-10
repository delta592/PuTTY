import AppKit
import PuttyBridge
import PuttyMacUI
import XCTest

/// Mock / local-echo connect path (null backend — no live SSH) (Phase 9.1).
@MainActor
final class MockConnectTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        PuttyMacUITestSupport.ensureApplication()
        putty_bridge_eventloop_init()
    }

    func testLocalEchoSessionProducesActiveTermWin() {
        let conf = putty_conf_new()
        XCTAssertNotNil(conf)
        // Empty / non-launchable host → putty_bridge_termwin_open uses local echo.
        putty_conf_set_host(conf, "")
        putty_conf_set_protocol(conf, Int32(PUTTY_CONF_PROT_RAW.rawValue))

        putty_bridge_session_window_opened()
        let controller = SessionWindowController(conf: conf, connect: false)
        controller.presentNow()
        PuttyMacUITestSupport.pumpMain(seconds: 0.2)

        guard let termWin = controller.activeTermWin else {
            XCTFail("expected TermWin after local-echo open")
            controller.window?.close()
            return
        }

        XCTAssertGreaterThan(putty_bridge_termwin_cols(termWin), 0)
        XCTAssertGreaterThan(putty_bridge_termwin_rows(termWin), 0)
        XCTAssertTrue(putty_bridge_termwin_session_is_active(termWin))

        let banner = Array("mock-connect-ok\r\n".utf8)
        banner.withUnsafeBufferPointer { buf in
            _ = putty_bridge_termwin_feed(termWin, buf.baseAddress, buf.count)
        }
        PuttyMacUITestSupport.pumpMain(seconds: 0.05)

        controller.window?.close()
        PuttyMacUITestSupport.pumpMain(seconds: 0.1)
    }

    func testTermWinExitSmoke() {
        XCTAssertEqual(putty_bridge_termwin_exit_smoke(), 0)
    }
}

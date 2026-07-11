import AppKit
import PuttyBridge
import PuttyMacUI
import XCTest

/// Launch / window presentation smoke (Phase 9.1).
@MainActor
final class LaunchTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        PuttyMacUITestSupport.ensureApplication()
        putty_bridge_eventloop_init()
    }

    func testBridgeApiVersion() {
        XCTAssertEqual(
            putty_bridge_api_version(),
            Int32(PUTTY_BRIDGE_API_VERSION)
        )
        let platform = String(cString: putty_bridge_buildinfo_platform())
        XCTAssertEqual(platform, "macOS (AppKit)")
    }

    func testSessionWindowOpensAndCloses() {
        PuttyMacUITestSupport.ensureApplication()

        let conf = putty_conf_new()
        XCTAssertNotNil(conf)
        putty_conf_set_host(conf, "ui-launch.example")
        putty_conf_set_port(conf, 22)
        putty_conf_set_protocol(conf, Int32(PUTTY_CONF_PROT_SSH.rawValue))

        let before = putty_bridge_open_session_window_count()
        putty_bridge_session_window_opened()
        XCTAssertEqual(
            putty_bridge_open_session_window_count(),
            before + 1
        )

        // connect=false → local-echo path (no network).
        let controller = SessionWindowController(conf: conf, connect: false)
        controller.presentNow()
        PuttyMacUITestSupport.pumpMain(seconds: 0.15)

        XCTAssertNotNil(controller.window)
        XCTAssertTrue(controller.window?.isVisible == true)
        XCTAssertNotNil(controller.activeTermWin)

        controller.window?.close()
        PuttyMacUITestSupport.pumpMain(seconds: 0.1)
        XCTAssertEqual(
            putty_bridge_open_session_window_count(),
            before
        )
    }

    func testNeedsInitialConfigForEmptyConf() {
        let conf = putty_conf_new()
        XCTAssertNotNil(conf)
        defer { putty_conf_free(conf) }
        XCTAssertTrue(putty_bridge_needs_initial_config(conf))
        XCTAssertFalse(putty_conf_launchable(conf))
    }

    func testConfHelpersTerminalSizeTryAgentAndHostkey() {
        let conf = putty_conf_new()
        XCTAssertNotNil(conf)
        defer { putty_conf_free(conf) }

        putty_conf_set_host(conf, "conf-helpers.example")
        putty_conf_set_protocol(conf, Int32(PUTTY_CONF_PROT_SSH.rawValue))
        putty_conf_set_terminal_size(conf, 132, 43)
        putty_conf_set_bool(conf, PUTTY_CONF_BOOL_TRY_AGENT, true)
        XCTAssertTrue(putty_conf_get_bool(conf, PUTTY_CONF_BOOL_TRY_AGENT))
        putty_conf_set_colour_rgb(conf, 0, 1, 2, 3)
        XCTAssertTrue(
            putty_conf_add_manual_hostkey(
                conf,
                "SHA256:QV1VZsAC792TF0SzLDcwbQ1feceWY481HUZDvbEBiaE"
            )
        )
        XCTAssertFalse(putty_conf_add_manual_hostkey(conf, "bad-key"))
        XCTAssertTrue(putty_conf_launchable(conf))
    }
}

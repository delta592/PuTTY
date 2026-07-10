import PuttyBridge
import XCTest

/// Config save / load round-trip through Application Support storage (Phase 9.1).
@MainActor
final class ConfigSaveLoadTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        PuttyMacUITestSupport.ensureApplication()
    }

    func testSaveAndLoadSession() {
        let name = PuttyMacUITestSupport.uniqueSessionName(prefix: "cfg")
        let conf = putty_conf_new()
        XCTAssertNotNil(conf)

        putty_conf_set_host(conf, "cfg-save.example")
        putty_conf_set_port(conf, 2222)
        putty_conf_set_protocol(conf, Int32(PUTTY_CONF_PROT_SSH.rawValue))
        putty_conf_set_username(conf, "uitest")
        putty_conf_set_bool(conf, PUTTY_CONF_BOOL_TCP_NODELAY, true)
        putty_conf_set_font(conf, "mac:Inconsolata-Regular:14")

        XCTAssertTrue(putty_conf_save_session(conf, name))

        let loaded = putty_conf_new()
        XCTAssertNotNil(loaded)
        XCTAssertTrue(putty_conf_load_session(loaded, name))

        XCTAssertEqual(String(cString: putty_conf_get_host(loaded)), "cfg-save.example")
        XCTAssertEqual(putty_conf_get_port(loaded), 2222)
        XCTAssertEqual(putty_conf_get_protocol(loaded), Int32(PUTTY_CONF_PROT_SSH.rawValue))
        XCTAssertEqual(String(cString: putty_conf_get_username(loaded)), "uitest")
        XCTAssertTrue(putty_conf_get_bool(loaded, PUTTY_CONF_BOOL_TCP_NODELAY))
        XCTAssertEqual(String(cString: putty_conf_get_font(loaded)), "mac:Inconsolata-Regular:14")

        putty_conf_free(conf)
        putty_conf_free(loaded)
        putty_conf_delete_session(name)
    }

    func testConfSmokeHarness() {
        XCTAssertEqual(putty_bridge_conf_smoke(), 0)
    }

    func testLaunchSmokeHarness() {
        XCTAssertEqual(putty_bridge_launch_smoke(), 0)
    }
}

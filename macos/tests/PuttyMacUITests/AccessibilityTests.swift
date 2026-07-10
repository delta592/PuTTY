import AppKit
import PuttyBridge
import PuttyMacUI
import XCTest

/// Accessibility surface checks (Phase 9.2).
@MainActor
final class AccessibilityTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        PuttyMacUITestSupport.ensureApplication()
        putty_bridge_eventloop_init()
    }

    func testTerminalViewVoiceOverIdentity() {
        PuttyMacUITestSupport.ensureApplication()

        let conf = putty_conf_new()
        XCTAssertNotNil(conf)
        putty_conf_set_host(conf, "a11y.example")
        putty_conf_set_port(conf, 22)
        putty_conf_set_protocol(conf, Int32(PUTTY_CONF_PROT_SSH.rawValue))

        putty_bridge_session_window_opened()
        let controller = SessionWindowController(conf: conf, connect: false)
        controller.presentNow()
        PuttyMacUITestSupport.pumpMain(seconds: 0.15)

        guard let content = controller.window?.contentView else {
            XCTFail("missing content view")
            return
        }

        let terminal = findTerminalView(in: content)
        XCTAssertNotNil(terminal, "TerminalView should be in the hierarchy")
        guard let terminal else { return }

        XCTAssertTrue(terminal.isAccessibilityElement())
        XCTAssertEqual(terminal.accessibilityRole(), .textArea)
        XCTAssertEqual(terminal.accessibilityLabel(), "Terminal")
        let help = terminal.accessibilityHelp() ?? ""
        XCTAssertTrue(
            help.localizedCaseInsensitiveContains("VoiceOver"),
            "help should document VoiceOver limits"
        )
        XCTAssertFalse(help.isEmpty)

        let scroller = findScroller(in: content)
        XCTAssertNotNil(scroller)
        XCTAssertEqual(scroller?.accessibilityLabel(), "Terminal scrollback")

        controller.window?.close()
        PuttyMacUITestSupport.pumpMain(seconds: 0.1)
    }

    func testAccessibilityPrefsHelpersAreReadable() {
        // Smoke: APIs must be callable without throwing (values are system-dependent).
        _ = PuttyAccessibility.reduceMotion
        _ = PuttyAccessibility.increaseContrast
        XCTAssertFalse(PuttyAccessibility.terminalVoiceOverHelp.isEmpty)
    }

    func testEventLogKeyboardFocus() {
        PuttyMacUITestSupport.ensureApplication()

        let conf = putty_conf_new()
        XCTAssertNotNil(conf)
        putty_conf_set_host(conf, "a11y-log.example")
        putty_bridge_session_window_opened()
        let controller = SessionWindowController(conf: conf, connect: false)
        controller.presentNow()
        PuttyMacUITestSupport.pumpMain(seconds: 0.15)

        SessionEventLog.shared.setKeyController(controller)
        SessionEventLog.shared.showEventLog(for: controller)
        PuttyMacUITestSupport.pumpMain(seconds: 0.1)

        let logWindow = SessionEventLog.shared.eventLogWindow(for: controller)
        XCTAssertNotNil(logWindow)
        XCTAssertEqual(logWindow?.accessibilityLabel(), "Event Log")
        XCTAssertTrue(logWindow?.initialFirstResponder is NSSearchField)

        logWindow?.close()
        controller.window?.close()
        PuttyMacUITestSupport.pumpMain(seconds: 0.1)
    }

    private func findTerminalView(in root: NSView) -> NSView? {
        if String(describing: type(of: root)).contains("TerminalView") {
            return root
        }
        for child in root.subviews {
            if let found = findTerminalView(in: child) {
                return found
            }
        }
        return nil
    }

    private func findScroller(in root: NSView) -> NSScroller? {
        if let scroller = root as? NSScroller {
            return scroller
        }
        for child in root.subviews {
            if let found = findScroller(in: child) {
                return found
            }
        }
        return nil
    }
}

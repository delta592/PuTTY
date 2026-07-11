import AppKit
import PuttyBridge
import PuttyMacUI
import XCTest

/// Session transcript printing checks (Phase 9.4).
@MainActor
final class PrintingTests: XCTestCase {
    func testFileMenuInstallsPrintAndPageSetup() {
        let main = NSMenu()
        main.addItem(NSMenuItem()) // app menu placeholder
        main.addItem(NSMenuItem(title: "Session", action: nil, keyEquivalent: ""))
        main.addItem(NSMenuItem(title: "Window", action: nil, keyEquivalent: ""))

        PuttyStandardMenus.installFileMenu(into: main)
        XCTAssertEqual(main.item(at: 1)?.title, "File")
        let file = main.item(at: 1)?.submenu
        let printItem = file?.item(withTitle: "Print…")
        XCTAssertNotNil(printItem)
        XCTAssertEqual(printItem?.keyEquivalent, "p")
        XCTAssertEqual(printItem?.action, PuttyStandardMenus.printSelector)

        let pageSetup = file?.item(withTitle: "Page Setup…")
        XCTAssertNotNil(pageSetup)
        XCTAssertEqual(pageSetup?.keyEquivalent, "p")
        XCTAssertEqual(pageSetup?.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(pageSetup?.action, #selector(NSApplication.runPageLayout(_:)))
    }

    func testTerminalViewRespondsToPrint() {
        PuttyMacUITestSupport.ensureApplication()
        putty_bridge_eventloop_init()

        let conf = putty_conf_new()
        XCTAssertNotNil(conf)
        putty_conf_set_host(conf, "print.example")
        putty_bridge_session_window_opened()
        let controller = SessionWindowController(conf: conf, connect: false)
        controller.presentNow()
        PuttyMacUITestSupport.pumpMain(seconds: 0.15)

        guard let content = controller.window?.contentView,
              let terminal = findTerminalView(in: content) else {
            XCTFail("missing TerminalView")
            return
        }

        XCTAssertTrue(terminal.responds(to: #selector(NSView.printView(_:))))
        XCTAssertTrue(terminal.responds(to: PuttyStandardMenus.printSelector))

        controller.window?.close()
        PuttyMacUITestSupport.pumpMain(seconds: 0.1)
    }

    func testGetAllTextContainsFedLine() {
        PuttyMacUITestSupport.ensureApplication()
        putty_bridge_eventloop_init()

        let conf = putty_conf_new()
        XCTAssertNotNil(conf)
        putty_conf_set_host(conf, "")
        putty_conf_set_protocol(conf, Int32(PUTTY_CONF_PROT_RAW.rawValue))
        putty_bridge_session_window_opened()
        let controller = SessionWindowController(conf: conf, connect: false)
        controller.presentNow()
        PuttyMacUITestSupport.pumpMain(seconds: 0.2)

        guard let termWin = controller.activeTermWin else {
            XCTFail("missing termWin")
            controller.window?.close()
            return
        }

        let marker = Array("phase94-print-marker\r\n".utf8)
        marker.withUnsafeBufferPointer { buf in
            _ = putty_bridge_termwin_feed(termWin, buf.baseAddress, buf.count)
        }
        PuttyMacUITestSupport.pumpMain(seconds: 0.05)

        guard let cText = putty_bridge_termwin_get_all_text(termWin) else {
            XCTFail("get_all_text returned nil")
            controller.window?.close()
            return
        }
        let text = String(cString: cText)
        putty_bridge_free_string(cText)
        XCTAssertTrue(text.contains("phase94-print-marker"), "transcript missing marker: \(text)")

        let view = TerminalPrint.makePrintableView(
            text: text,
            font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular))
        XCTAssertTrue(view.string.contains("phase94-print-marker"))
        XCTAssertGreaterThan(view.frame.height, 0)

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
}

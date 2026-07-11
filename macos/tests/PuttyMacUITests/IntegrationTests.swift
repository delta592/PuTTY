import AppKit
import PuttyBridge
import PuttyMacUI
import XCTest

/// macOS 15 integration checks (Phase 9.3).
@MainActor
final class IntegrationTests: XCTestCase {
    func testTrackpadScrollUsesCellHeight() {
        var acc: CGFloat = 0
        // Half a cell — no line yet.
        XCTAssertEqual(
            TerminalScrollInput.consumeLines(
                deltaY: 6, hasPreciseDeltas: true, cellHeight: 14,
                accumulator: &acc),
            0
        )
        XCTAssertEqual(acc, 6, accuracy: 0.001)
        // Cross one cell boundary.
        XCTAssertEqual(
            TerminalScrollInput.consumeLines(
                deltaY: 10, hasPreciseDeltas: true, cellHeight: 14,
                accumulator: &acc),
            1
        )
        XCTAssertEqual(acc, 2, accuracy: 0.001)
    }

    func testMouseWheelUsesFixedTickHeight() {
        var acc: CGFloat = 0
        XCTAssertEqual(
            TerminalScrollInput.consumeLines(
                deltaY: 3, hasPreciseDeltas: false, cellHeight: 14,
                accumulator: &acc),
            1
        )
        XCTAssertEqual(acc, 0, accuracy: 0.001)
    }

    func testMomentumStyleBurstScrollsMultipleLines() {
        var acc: CGFloat = 0
        // Simulate several precise momentum ticks totaling ~3 cells.
        var total: Int32 = 0
        for _ in 0..<6 {
            total += TerminalScrollInput.consumeLines(
                deltaY: 7, hasPreciseDeltas: true, cellHeight: 14,
                accumulator: &acc)
        }
        XCTAssertEqual(total, 3)
    }

    func testChromeAccentIsSystemAccent() {
        XCTAssertEqual(PuttyChrome.accentColor, NSColor.controlAccentColor)
        XCTAssertGreaterThan(PuttyChrome.chromeBorderWidth, 0)
    }

    func testEditMenuSelectorsReachTerminalView() {
        PuttyMacUITestSupport.ensureApplication()
        putty_bridge_eventloop_init()

        let conf = putty_conf_new()
        XCTAssertNotNil(conf)
        putty_conf_set_host(conf, "edit-menu.example")
        putty_bridge_session_window_opened()
        let controller = SessionWindowController(conf: conf, connect: false)
        controller.presentNow()
        PuttyMacUITestSupport.pumpMain(seconds: 0.15)

        guard let content = controller.window?.contentView,
              let terminal = findTerminalView(in: content) else {
            XCTFail("missing TerminalView")
            return
        }

        XCTAssertTrue(terminal.responds(to: #selector(NSText.copy(_:))))
        XCTAssertTrue(terminal.responds(to: #selector(NSText.paste(_:))))
        XCTAssertTrue(terminal.responds(to: #selector(NSText.selectAll(_:))))
        XCTAssertTrue(terminal.responds(to: PuttyStandardMenus.pasteSpecialSelector))
        XCTAssertTrue(terminal.responds(to: PuttyStandardMenus.copyAllSelector))

        controller.window?.close()
        PuttyMacUITestSupport.pumpMain(seconds: 0.1)
    }

    func testStandardMenusInstallEditAndSettings() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        main.addItem(appItem)
        appMenu.addItem(withTitle: "Quit", action: nil, keyEquivalent: "q")

        let target = NSObject()
        PuttyStandardMenus.installAppMenuChrome(
            into: appMenu,
            appName: "Test",
            target: target,
            aboutAction: #selector(NSObject.description),
            settingsAction: #selector(NSObject.description)
        )
        XCTAssertEqual(appMenu.item(at: 0)?.title, "About Test")
        XCTAssertEqual(appMenu.item(at: 2)?.title, "Settings…")
        XCTAssertEqual(appMenu.item(at: 2)?.keyEquivalent, ",")
        let hide = appMenu.item(withTitle: "Hide Test")
        XCTAssertNotNil(hide)
        XCTAssertEqual(hide?.keyEquivalent, "h")
        XCTAssertEqual(hide?.action, #selector(NSApplication.hide(_:)))
        XCTAssertNotNil(appMenu.item(withTitle: "Hide Others"))
        XCTAssertEqual(
            appMenu.item(withTitle: "Hide Others")?.keyEquivalentModifierMask,
            [.command, .option]
        )
        XCTAssertNotNil(appMenu.item(withTitle: "Show All"))
        XCTAssertEqual(appMenu.item(withTitle: "Quit")?.keyEquivalent, "q")

        main.addItem(NSMenuItem(title: "Window", action: nil, keyEquivalent: ""))
        PuttyStandardMenus.installFileMenu(into: main)
        PuttyStandardMenus.installEditMenu(into: main)
        XCTAssertEqual(main.item(at: 1)?.title, "File")
        XCTAssertEqual(main.item(at: 2)?.title, "Edit")
        let file = main.item(at: 1)?.submenu
        XCTAssertEqual(file?.item(withTitle: "Print…")?.keyEquivalent, "p")
        XCTAssertEqual(
            file?.item(withTitle: "Print…")?.action,
            PuttyStandardMenus.printSelector)
        let edit = main.item(at: 2)?.submenu
        XCTAssertEqual(edit?.item(withTitle: "Copy")?.keyEquivalent, "c")
        XCTAssertEqual(edit?.item(withTitle: "Paste")?.keyEquivalent, "v")
        XCTAssertEqual(edit?.item(withTitle: "Select All")?.keyEquivalent, "a")
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

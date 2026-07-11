import AppKit
import PuttyMacUI
import XCTest

/// Bundled Halibut HTML help (Phase 9.5).
@MainActor
final class HelpTests: XCTestCase {
    func testHelpMenuInstallsAppHelpItem() {
        let main = NSMenu()
        main.addItem(NSMenuItem()) // app menu placeholder

        PuttyStandardMenus.installHelpMenu(into: main, appName: "PuTTY")
        XCTAssertEqual(main.item(at: 1)?.title, "Help")
        let help = main.item(at: 1)?.submenu
        let item = help?.item(withTitle: "PuTTY Help")
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.keyEquivalent, "?")
        XCTAssertEqual(item?.action, PuttyStandardMenus.openHelpSelector)
        XCTAssertTrue(item?.target === PuttyHelpMenuTarget.shared)
    }

    func testOnlineManualURLIsHTTPS() {
        XCTAssertEqual(PuttyHelp.onlineManualURL.scheme, "https")
        XCTAssertFalse(PuttyHelp.onlineManualURL.absoluteString.isEmpty)
    }

    func testHelpWindowControllerConstructs() {
        PuttyMacUITestSupport.ensureApplication()
        let controller = HelpWindowController()
        XCTAssertNotNil(controller.window)
        XCTAssertEqual(controller.window?.title, "PuTTY Help")
        XCTAssertGreaterThanOrEqual(controller.window?.minSize.width ?? 0, 400)
        controller.close()
    }

    func testBundledHelpIndexWhenPresentInTestHost() {
        // XCTest host may not embed Help/; only assert API shape.
        let url = PuttyHelp.indexURL(in: .main)
        if let url {
            XCTAssertEqual(url.lastPathComponent, "index.html")
            XCTAssertTrue(PuttyHelp.isAvailable(in: .main))
            XCTAssertNotNil(PuttyHelp.helpDirectoryURL(in: .main))
        } else {
            XCTAssertFalse(PuttyHelp.isAvailable(in: .main))
        }
    }
}

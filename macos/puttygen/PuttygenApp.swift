import AppKit
import Foundation
import PuttygenBridge

@main
@MainActor
enum PuttygenMain {
    static func main() {
        puttygen_bridge_init()

        let delegate = PuttygenAppDelegate()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class PuttygenAppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: PuttygenWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        installMenus()
        let controller = PuttygenWindowController()
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func installMenus() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "Quit PuTTYgen",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")

        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(
            withTitle: "Load Private Key…",
            action: #selector(PuttygenWindowController.loadKey(_:)),
            keyEquivalent: "o")
        fileMenu.addItem(
            withTitle: "Save Private Key…",
            action: #selector(PuttygenWindowController.savePrivateKey(_:)),
            keyEquivalent: "s")
        fileMenu.addItem(
            withTitle: "Save Public Key…",
            action: #selector(PuttygenWindowController.savePublicKey(_:)),
            keyEquivalent: "")
        fileMenu.addItem(
            withTitle: "Export OpenSSH Key…",
            action: #selector(PuttygenWindowController.exportOpenSSH(_:)),
            keyEquivalent: "")
        mainMenu.addItem(fileItem)

        NSApp.mainMenu = mainMenu
    }
}

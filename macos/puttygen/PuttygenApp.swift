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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        _ = sender
        guard windowController?.isGenerating == true else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Key generation in progress"
        alert.informativeText =
            "Please wait for generation to finish before quitting PuTTYgen."
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return .terminateCancel
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

        let hide = NSMenuItem(
            title: "Hide PuTTYgen",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        hide.target = NSApp
        appMenu.insertItem(hide, at: 0)

        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        appMenu.insertItem(hideOthers, at: 1)

        let showAll = NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        showAll.target = NSApp
        appMenu.insertItem(showAll, at: 2)
        appMenu.insertItem(NSMenuItem.separator(), at: 3)

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

        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: "Help")
        let openHelp = helpMenu.addItem(
            withTitle: "PuTTYgen Help",
            action: #selector(PuttyHelpMenuTarget.openHelp(_:)),
            keyEquivalent: "?")
        openHelp.target = PuttyHelpMenuTarget.shared
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)
        NSApp.helpMenu = helpMenu
        PuttyHelp.registerNotificationObserver()

        NSApp.mainMenu = mainMenu
    }
}

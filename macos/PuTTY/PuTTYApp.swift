import AppKit
import Foundation
import PuttyBridge

@main
@MainActor
enum PuTTYMain {
    static func main() {
        var conf: PuttyConfHandle?
        var connect = false

        switch putty_bridge_process_command_line(
            CommandLine.argc, CommandLine.unsafeArgv, &conf, &connect) {
        case PUTTY_BRIDGE_CMDLINE_EXIT_HELP:
            putty_bridge_print_help(stdout)
            exit(EXIT_SUCCESS)
        case PUTTY_BRIDGE_CMDLINE_EXIT_VERSION:
            putty_bridge_print_version(stdout)
            exit(EXIT_SUCCESS)
        case PUTTY_BRIDGE_CMDLINE_EXIT_OK:
            exit(EXIT_SUCCESS)
        default:
            break
        }

        let delegate = AppDelegate(initialConf: conf, initialConnect: connect)
        let app = NSApplication.shared
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let initialConf: PuttyConfHandle?
    private let initialConnect: Bool

    init(initialConf: PuttyConfHandle?, initialConnect: Bool) {
        self.initialConf = initialConf
        self.initialConnect = initialConnect
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        PuttyEventLoop.start()
        installMenus()

        SessionWindowController.openNew(conf: initialConf, connect: initialConnect)
        if let initialConf {
            putty_conf_free(initialConf)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        _ = sender
        return true
    }

    private func installMenus() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit PuTTY",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        let sessionMenuItem = NSMenuItem(title: "Session", action: nil, keyEquivalent: "")
        let sessionMenu = NSMenu(title: "Session")
        sessionMenuItem.submenu = sessionMenu
        let newItem = sessionMenu.addItem(withTitle: "New Session",
                                          action: #selector(newSession(_:)),
                                          keyEquivalent: "n")
        newItem.target = self
        let closeItem = sessionMenu.addItem(withTitle: "Close",
                                            action: #selector(closeSession(_:)),
                                            keyEquivalent: "w")
        closeItem.target = self
        closeItem.keyEquivalentModifierMask = [.command]
        mainMenu.addItem(sessionMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func newSession(_ sender: Any?) {
        _ = sender
        SessionWindowController.openNew(conf: nil, connect: false)
    }

    @objc private func closeSession(_ sender: Any?) {
        _ = sender
        NSApp.keyWindow?.performClose(nil)
    }
}

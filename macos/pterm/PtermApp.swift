import AppKit
import Foundation
import PuttyBridge
import PuttyMacUI

@main
@MainActor
enum PtermMain {
    static func main() {
        var conf: PuttyConfHandle?
        var connect = false

        let cmdline = putty_bridge_process_command_line(
            CommandLine.argc, CommandLine.unsafeArgv, &conf, &connect)

        switch cmdline {
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

        let delegate = PtermAppDelegate(
            initialConf: conf,
            initialConnect: connect
        )
        let app = NSApplication.shared
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class PtermAppDelegate: NSObject, NSApplicationDelegate, SessionMenuUpdating {
    private var pendingConf: PuttyConfHandle?
    private let pendingConnect: Bool
    private var openSessionBox: OpenSessionBox?
    private weak var restartItem: NSMenuItem?

    init(initialConf: PuttyConfHandle?, initialConnect: Bool) {
        self.pendingConf = initialConf
        self.pendingConnect = initialConnect
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        PuttyEventLoop.start()
        installMenus()

        let box = OpenSessionBox(owner: self)
        openSessionBox = box
        putty_bridge_set_open_session_callback(
            { ctx, conf, connect in
                guard let ctx else { return }
                Unmanaged<OpenSessionBox>.fromOpaque(ctx)
                    .takeUnretainedValue()
                    .handleOpen(conf: conf, connect: connect)
            },
            Unmanaged.passUnretained(box).toOpaque()
        )

        let conf = pendingConf
        pendingConf = nil
        // pterm: initial_config_box is a no-op → immediate window + PTY.
        putty_bridge_start_app(conf, true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        _ = sender
        return putty_bridge_open_session_window_count() == 0
            && NSApp.windows.contains { $0.isVisible } == false
    }

    fileprivate func openSession(conf: PuttyConfHandle?, connect: Bool) {
        if conf == nil {
            NSApp.terminate(nil)
            return
        }
        // openNew takes ownership of conf.
        SessionWindowController.openNew(conf: conf, connect: true)
        putty_bridge_session_window_opened()
    }

    private func installMenus() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit pterm",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        PuttyStandardMenus.installAppMenuChrome(
            into: appMenu,
            appName: "pterm",
            target: self,
            aboutAction: #selector(showAbout(_:)),
            settingsAction: #selector(changeSettings(_:))
        )

        let sessionMenuItem = NSMenuItem(title: "Session", action: nil, keyEquivalent: "")
        let sessionMenu = NSMenu(title: "Session")
        sessionMenuItem.submenu = sessionMenu

        let restartItem = sessionMenu.addItem(
            withTitle: "Restart Session",
            action: #selector(restartSession(_:)),
            keyEquivalent: "r")
        restartItem.target = self
        restartItem.keyEquivalentModifierMask = [.command, .shift]
        restartItem.isEnabled = false
        self.restartItem = restartItem

        let changeItem = sessionMenu.addItem(
            withTitle: "Change Settings…",
            action: #selector(changeSettings(_:)),
            keyEquivalent: "")
        changeItem.target = self

        let closeItem = sessionMenu.addItem(withTitle: "Close",
                                            action: #selector(closeSession(_:)),
                                            keyEquivalent: "w")
        closeItem.target = self
        closeItem.keyEquivalentModifierMask = [.command]

        SessionSpecialsMenu.shared.install(into: sessionMenu)
        mainMenu.addItem(sessionMenuItem)

        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        PuttyStandardMenus.installFileMenu(into: mainMenu)
        PuttyStandardMenus.installEditMenu(into: mainMenu)

        NSApp.mainMenu = mainMenu
    }

    func updateSessionActionMenus() {
        let controller = NSApp.keyWindow?.windowController as? SessionWindowController
        if let termWin = controller?.activeTermWin {
            restartItem?.isEnabled = putty_bridge_termwin_can_restart(termWin)
        } else {
            restartItem?.isEnabled = false
        }
    }

    @objc private func restartSession(_ sender: Any?) {
        _ = sender
        guard let controller = NSApp.keyWindow?.windowController
                as? SessionWindowController,
              let termWin = controller.activeTermWin else {
            NSSound.beep()
            return
        }
        if !putty_bridge_termwin_restart_session(termWin) {
            NSSound.beep()
            return
        }
        controller.refreshSpecialsMenu()
        updateSessionActionMenus()
    }

    @objc private func changeSettings(_ sender: Any?) {
        _ = sender
        guard let controller = NSApp.keyWindow?.windowController
                as? SessionWindowController,
              let termWin = controller.activeTermWin else {
            NSSound.beep()
            return
        }
        if !putty_bridge_termwin_change_settings(termWin) {
            NSSound.beep()
        }
    }

    @objc private func showAbout(_ sender: Any?) {
        _ = sender
        let alert = NSAlert()
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "pterm"
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        alert.messageText = name
        var body = String(cString: putty_bridge_buildinfo_platform())
        if !short.isEmpty {
            body += "\nVersion \(short)"
        }
        if !build.isEmpty && build != short {
            body += " (\(build))"
        }
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func closeSession(_ sender: Any?) {
        _ = sender
        NSApp.keyWindow?.performClose(nil)
    }
}

@MainActor
private final class OpenSessionBox {
    private weak var owner: PtermAppDelegate?

    init(owner: PtermAppDelegate) {
        self.owner = owner
    }

    func handleOpen(conf: PuttyConfHandle?, connect: Bool) {
        owner?.openSession(conf: conf, connect: connect)
    }
}

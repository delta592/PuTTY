import AppKit
import Foundation
import PuttyBridge

@main
@MainActor
enum PuTTYMain {
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
        case PUTTY_BRIDGE_CMDLINE_CLEANUP:
            confirmAndCleanup()
            exit(EXIT_SUCCESS)
        case PUTTY_BRIDGE_CMDLINE_HOST_CA:
            break
        default:
            break
        }

        let delegate = AppDelegate(
            initialConf: conf,
            initialConnect: connect,
            hostCaOnly: cmdline == PUTTY_BRIDGE_CMDLINE_HOST_CA
        )
        let app = NSApplication.shared
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    /// Mirror Windows `putty -cleanup` confirmation, adapted for Application Support.
    private static func confirmAndCleanup() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "PuTTY Warning"
        alert.informativeText =
            "This procedure will remove ALL PuTTY data stored under\n"
            + "Library/Application Support/PuTTY for the current user,\n"
            + "including saved sessions, host keys, and the random seed file.\n"
            + "\n"
            + "THIS PROCESS WILL DESTROY YOUR SAVED SESSIONS.\n"
            + "Are you really sure you want to continue?"
        alert.addButton(withTitle: "Delete Data")
        alert.addButton(withTitle: "Cancel")
        // Need a running app for a proper modal; bootstrap briefly.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if alert.runModal() == .alertFirstButtonReturn {
            putty_bridge_cleanup_all()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingConf: PuttyConfHandle?
    private let pendingConnect: Bool
    private let hostCaOnly: Bool
    /// Retained for the C open-session callback lifetime.
    private var openSessionBox: OpenSessionBox?
    private weak var duplicateItem: NSMenuItem?
    private weak var restartItem: NSMenuItem?

    init(initialConf: PuttyConfHandle?, initialConnect: Bool, hostCaOnly: Bool = false) {
        self.pendingConf = initialConf
        self.pendingConnect = initialConnect
        self.hostCaOnly = hostCaOnly
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        PuttyEventLoop.start()
        installMenus()

        if hostCaOnly {
            if let conf = pendingConf {
                pendingConf = nil
                putty_conf_free(conf)
            }
            putty_bridge_show_host_ca_config()
            NSApp.terminate(nil)
            return
        }

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
        // Takes ownership of conf.
        putty_bridge_start_app(conf, pendingConnect)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        _ = sender
        // Keep running while the initial config dialog is the only window.
        return putty_bridge_open_session_window_count() == 0
            && NSApp.windows.contains { $0.isVisible } == false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        _ = application
        for url in urls {
            openURL(url)
        }
    }

    fileprivate func openSession(conf: PuttyConfHandle?, connect: Bool) {
        if conf == nil {
            NSApp.terminate(nil)
            return
        }
        SessionWindowController.openNew(conf: conf, connect: connect)
        putty_conf_free(conf)
        putty_bridge_session_window_opened()
    }

    private func openURL(_ url: URL) {
        let conf = putty_conf_new()
        let ok = url.absoluteString.withCString { cstr in
            putty_bridge_conf_from_url(conf, cstr)
        }
        guard ok else {
            putty_conf_free(conf)
            NSSound.beep()
            return
        }
        let connect = putty_conf_launchable(conf)
        if connect {
            SessionWindowController.openNew(conf: conf, connect: true)
            putty_conf_free(conf)
            putty_bridge_session_window_opened()
        } else {
            // Incomplete saved session: hand to start_app-style config box.
            putty_bridge_start_app(conf, false)
        }
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

        let dupItem = sessionMenu.addItem(
            withTitle: "Duplicate Session",
            action: #selector(duplicateSession(_:)),
            keyEquivalent: "d")
        dupItem.target = self
        dupItem.keyEquivalentModifierMask = [.command, .shift]
        duplicateItem = dupItem

        let restartItem = sessionMenu.addItem(
            withTitle: "Restart Session",
            action: #selector(restartSession(_:)),
            keyEquivalent: "r")
        restartItem.target = self
        restartItem.keyEquivalentModifierMask = [.command, .shift]
        restartItem.isEnabled = false
        self.restartItem = restartItem

        SessionSavedSessionsMenu.shared.install(into: sessionMenu)
        sessionMenu.addItem(NSMenuItem.separator())

        let changeItem = sessionMenu.addItem(
            withTitle: "Change Settings…",
            action: #selector(changeSettings(_:)),
            keyEquivalent: ",")
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
        SessionEventLog.shared.install(into: windowMenu)
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    func updateSessionActionMenus() {
        let controller = NSApp.keyWindow?.windowController as? SessionWindowController
        let termWin = controller?.activeTermWin
        duplicateItem?.isEnabled = termWin != nil
        if let termWin {
            restartItem?.isEnabled = putty_bridge_termwin_can_restart(termWin)
        } else {
            restartItem?.isEnabled = false
        }
    }

    @objc private func newSession(_ sender: Any?) {
        _ = sender
        putty_bridge_launch_new_session()
    }

    @objc private func duplicateSession(_ sender: Any?) {
        _ = sender
        guard let controller = NSApp.keyWindow?.windowController
                as? SessionWindowController,
              let termWin = controller.activeTermWin else {
            NSSound.beep()
            return
        }
        putty_bridge_launch_duplicate_session(termWin)
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

    @objc private func closeSession(_ sender: Any?) {
        _ = sender
        NSApp.keyWindow?.performClose(nil)
    }
}

/// Heap box so the C open-session callback can reach AppDelegate.
@MainActor
private final class OpenSessionBox {
    private weak var owner: AppDelegate?

    init(owner: AppDelegate) {
        self.owner = owner
    }

    func handleOpen(conf: PuttyConfHandle?, connect: Bool) {
        owner?.openSession(conf: conf, connect: connect)
    }
}

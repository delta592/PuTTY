import AppKit

/// Shared AppKit menu construction for PuTTY / pterm (Phase 9.3–9.5).
@MainActor
public enum PuttyStandardMenus {
    /// Edit → Paste Special (nil-target; handled by `TerminalView`).
    public static let pasteSpecialSelector = #selector(TerminalView.pasteSpecial(_:))
    /// Edit → Copy All (nil-target; handled by `TerminalView`).
    public static let copyAllSelector = #selector(TerminalView.copyAll(_:))
    /// File → Print… (nil-target; `TerminalView.printView` / ObjC `print:`).
    public static let printSelector = #selector(NSView.printView(_:))
    /// Help → «App» Help.
    public static let openHelpSelector = #selector(PuttyHelpMenuTarget.openHelp(_:))

    /// About + Settings… (⌘,) + Hide (⌘H) in the application menu.
    public static func installAppMenuChrome(
        into appMenu: NSMenu,
        appName: String,
        target: AnyObject,
        aboutAction: Selector,
        settingsAction: Selector
    ) {
        let about = NSMenuItem(
            title: "About \(appName)",
            action: aboutAction,
            keyEquivalent: "")
        about.target = target
        appMenu.insertItem(about, at: 0)
        appMenu.insertItem(NSMenuItem.separator(), at: 1)

        let settings = NSMenuItem(
            title: "Settings…",
            action: settingsAction,
            keyEquivalent: ",")
        settings.target = target
        appMenu.insertItem(settings, at: 2)
        appMenu.insertItem(NSMenuItem.separator(), at: 3)

        installHideItems(into: appMenu, appName: appName, beforeQuit: true)
    }

    /// Standard Hide / Hide Others / Show All (⌘H / ⌥⌘H).
    public static func installHideItems(
        into appMenu: NSMenu,
        appName: String,
        beforeQuit: Bool = true
    ) {
        let hide = NSMenuItem(
            title: "Hide \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        hide.target = NSApp

        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp

        let showAll = NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        showAll.target = NSApp

        var insertAt = appMenu.numberOfItems
        if beforeQuit {
            for i in 0..<appMenu.numberOfItems {
                let title = appMenu.item(at: i)?.title ?? ""
                if title.hasPrefix("Quit") {
                    insertAt = i
                    break
                }
            }
        }

        appMenu.insertItem(hide, at: insertAt)
        appMenu.insertItem(hideOthers, at: insertAt + 1)
        appMenu.insertItem(showAll, at: insertAt + 2)
        appMenu.insertItem(NSMenuItem.separator(), at: insertAt + 3)
    }

    /// File menu with Print… (⌘P) and Page Setup… (⇧⌘P).
    @discardableResult
    public static func installFileMenu(into mainMenu: NSMenu) -> NSMenu {
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")

        fileMenu.addItem(
            withTitle: "Print…",
            action: printSelector,
            keyEquivalent: "p")

        let pageSetup = fileMenu.addItem(
            withTitle: "Page Setup…",
            action: #selector(NSApplication.runPageLayout(_:)),
            keyEquivalent: "p")
        pageSetup.keyEquivalentModifierMask = [.command, .shift]
        pageSetup.target = NSApp

        fileItem.submenu = fileMenu

        /*
         * Insert after the application menu when present so the bar reads
         * App | File | Session | Edit | Window (HIG order).
         */
        var insertAt = 0
        if mainMenu.numberOfItems > 0 {
            insertAt = 1
        }
        for i in 0..<mainMenu.numberOfItems {
            let title = mainMenu.item(at: i)?.title ?? ""
            if title == "Session" || title == "Edit" || title == "Window" {
                insertAt = i
                break
            }
        }
        mainMenu.insertItem(fileItem, at: insertAt)
        return fileMenu
    }

    /// Edit menu with Copy / Paste / Paste Special / Select All (nil target → responder chain).
    @discardableResult
    public static func installEditMenu(into mainMenu: NSMenu) -> NSMenu {
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")

        editMenu.addItem(
            withTitle: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c")
        editMenu.addItem(
            withTitle: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v")

        let pasteSpecial = editMenu.addItem(
            withTitle: "Paste Special",
            action: pasteSpecialSelector,
            keyEquivalent: "v")
        pasteSpecial.keyEquivalentModifierMask = [.command, .option]

        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a")
        editMenu.addItem(
            withTitle: "Copy All",
            action: copyAllSelector,
            keyEquivalent: "")

        editItem.submenu = editMenu

        /*
         * Insert before Window when present so the bar reads
         * App | Session | Edit | Window (HIG order).
         */
        var insertAt = mainMenu.numberOfItems
        for i in 0..<mainMenu.numberOfItems where mainMenu.item(at: i)?.title == "Window" {
            insertAt = i
            break
        }
        mainMenu.insertItem(editItem, at: insertAt)
        return editMenu
    }

    /// Help menu with «App» Help (⇧⌘? / ?).
    @discardableResult
    public static func installHelpMenu(
        into mainMenu: NSMenu,
        appName: String
    ) -> NSMenu {
        PuttyHelp.registerNotificationObserver()

        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: "Help")

        let openHelp = helpMenu.addItem(
            withTitle: "\(appName) Help",
            action: openHelpSelector,
            keyEquivalent: "?")
        openHelp.target = PuttyHelpMenuTarget.shared

        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)
        NSApp.helpMenu = helpMenu
        return helpMenu
    }
}

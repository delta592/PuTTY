import AppKit
import PuttyBridge

/// Payload for a Special Commands menu item (NSObject for representedObject).
///
/// Holds a weak `SessionWindowController` instead of a raw TermWin pointer so a
/// deferred menu action cannot call into a freed bridge handle (AUDIT P1.5).
final class SpecialCommandPayload: NSObject {
    weak var controller: SessionWindowController?
    let code: Int32
    let arg: Int32

    init(controller: SessionWindowController, code: Int32, arg: Int32) {
        self.controller = controller
        self.code = code
        self.arg = arg
    }
}

@MainActor
final class SpecialCommandTarget: NSObject {
    @objc func sendSpecial(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? SpecialCommandPayload,
              let controller = payload.controller,
              SessionWindowController.isOpen(controller),
              let termWin = controller.activeTermWin
        else { return }
        putty_bridge_termwin_send_special(termWin, payload.code, payload.arg)
    }
}

/// Rebuilds Session → Special Commands from backend_get_specials() (Phase 5.6).
@MainActor
public final class SessionSpecialsMenu {
    public static let shared = SessionSpecialsMenu()

    private var separatorBefore: NSMenuItem!
    private var separatorAfter: NSMenuItem!
    private var specialCommandsItem: NSMenuItem!
    private var specialCommandsMenu: NSMenu!
    private weak var keyController: SessionWindowController?
    private let commandTarget = SpecialCommandTarget()

    private init() {}

    public func install(into sessionMenu: NSMenu) {
        separatorBefore = NSMenuItem.separator()
        sessionMenu.addItem(separatorBefore)

        specialCommandsMenu = NSMenu(title: "Special Commands")
        specialCommandsItem = NSMenuItem(
            title: "Special Commands", action: nil, keyEquivalent: "")
        specialCommandsItem.submenu = specialCommandsMenu
        sessionMenu.addItem(specialCommandsItem)

        separatorAfter = NSMenuItem.separator()
        sessionMenu.addItem(separatorAfter)

        hideSpecials()
    }

    func setKeyController(_ controller: SessionWindowController?) {
        keyController = controller
        if let controller {
            displaySpecials(for: controller, termWin: controller.activeTermWin)
        } else {
            hideSpecials()
        }
    }

    func refresh(for controller: SessionWindowController) {
        if controller === keyController {
            displaySpecials(for: controller, termWin: controller.activeTermWin)
        }
    }

    func resignKeyController(_ controller: SessionWindowController) {
        if controller === keyController {
            setKeyController(nil)
        }
    }

    /// Drop Special Commands UI before the session's TermWin is destroyed.
    func sessionWillClose(_ controller: SessionWindowController) {
        if controller === keyController {
            setKeyController(nil)
        }
    }

    func installCallback(for controller: SessionWindowController, termWin: OpaquePointer) {
        let ctx = Unmanaged.passUnretained(controller).toOpaque()
        putty_bridge_termwin_set_specials_menu_callback(
            termWin, SessionSpecialsBridge.updateMenu, ctx)
    }

    private func displaySpecials(for controller: SessionWindowController, termWin: OpaquePointer?) {
        guard let termWin else {
            hideSpecials()
            return
        }
        if !putty_bridge_termwin_has_specials(termWin) {
            hideSpecials()
            return
        }
        rebuildMenu(for: controller, termWin: termWin)
        separatorBefore.isHidden = false
        specialCommandsItem.isHidden = false
        separatorAfter.isHidden = false
    }

    private func hideSpecials() {
        separatorBefore?.isHidden = true
        specialCommandsItem?.isHidden = true
        separatorAfter?.isHidden = true
        clearMenuItems(specialCommandsMenu)
    }

    /// Remove items and drop representedObjects so no stale payloads linger.
    private func clearMenuItems(_ menu: NSMenu?) {
        guard let menu else { return }
        for item in menu.items {
            if let submenu = item.submenu {
                clearMenuItems(submenu)
            }
            item.representedObject = nil
            item.target = nil
        }
        menu.removeAllItems()
    }

    private func rebuildMenu(for controller: SessionWindowController, termWin: OpaquePointer) {
        clearMenuItems(specialCommandsMenu)

        let maxItems = 256
        var buffer = Array(
            repeating: PuttyBridgeSessionSpecial(name: nil, code: 0, arg: 0),
            count: maxItems)
        let count = putty_bridge_termwin_copy_specials(termWin, &buffer, maxItems)
        if count == 0 {
            hideSpecials()
            return
        }

        let codeSep = putty_bridge_special_code_sep()
        let codeSubmenu = putty_bridge_special_code_submenu()
        let codeExitmenu = putty_bridge_special_code_exitmenu()

        var menuStack: [NSMenu] = [specialCommandsMenu]
        var nesting = 1
        var index = 0

        while nesting > 0 && index < count {
            let spec = buffer[index]
            index += 1

            switch spec.code {
            case codeSep:
                menuStack.last?.addItem(.separator())

            case codeSubmenu:
                let submenu = NSMenu()
                let title = spec.name.map { String(cString: $0) } ?? ""
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = submenu
                menuStack.last?.addItem(item)
                menuStack.append(submenu)
                nesting += 1

            case codeExitmenu:
                nesting -= 1
                if nesting > 0 {
                    menuStack.removeLast()
                }

            default:
                let title = spec.name.map { String(cString: $0) } ?? ""
                let item = NSMenuItem(
                    title: title,
                    action: #selector(SpecialCommandTarget.sendSpecial(_:)),
                    keyEquivalent: "")
                item.target = commandTarget
                item.representedObject = SpecialCommandPayload(
                    controller: controller, code: spec.code, arg: spec.arg)
                menuStack.last?.addItem(item)
            }
        }
    }
}

private enum SessionSpecialsBridge {
    static let updateMenu: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
        guard let ctx else { return }
        let controller = Unmanaged<SessionWindowController>.fromOpaque(ctx)
            .takeUnretainedValue()
        PuttyMainHop.run { [weak controller] in
            guard let controller, SessionWindowController.isOpen(controller) else { return }
            controller.refreshSpecialsMenu()
        }
    }
}

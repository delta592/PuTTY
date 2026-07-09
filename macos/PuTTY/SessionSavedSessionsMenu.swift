import AppKit
import PuttyBridge

/// Rebuilds Session → Saved Sessions from get_sesslist() (Phase 7.1).
@MainActor
final class SessionSavedSessionsMenu: NSObject, NSMenuDelegate {
    static let shared = SessionSavedSessionsMenu()

    private var savedSessionsItem: NSMenuItem!
    private var savedSessionsMenu: NSMenu!

    private override init() {
        super.init()
    }

    func install(into sessionMenu: NSMenu) {
        savedSessionsMenu = NSMenu(title: "Saved Sessions")
        savedSessionsMenu.delegate = self
        savedSessionsItem = NSMenuItem(
            title: "Saved Sessions", action: nil, keyEquivalent: "")
        savedSessionsItem.submenu = savedSessionsMenu
        sessionMenu.addItem(savedSessionsItem)
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === savedSessionsMenu else { return }
        rebuild()
    }

    private func rebuild() {
        savedSessionsMenu.removeAllItems()

        var names = [UnsafeMutablePointer<CChar>?](repeating: nil, count: 64)
        let count = names.withUnsafeMutableBufferPointer { buf in
            putty_bridge_copy_saved_session_names(buf.baseAddress, buf.count)
        }

        if count == 0 {
            let empty = NSMenuItem(
                title: "(No sessions)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            savedSessionsMenu.addItem(empty)
            return
        }

        for i in 0..<count {
            guard let cName = names[i] else { continue }
            let name = String(cString: cName)
            putty_bridge_free_string(cName)
            let item = NSMenuItem(
                title: name,
                action: #selector(openSavedSession(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = name
            savedSessionsMenu.addItem(item)
        }
    }

    @objc private func openSavedSession(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        putty_bridge_launch_saved_session(name)
    }
}

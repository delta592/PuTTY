import AppKit
import Foundation
import PuttyBridge

/// NSPasteboard integration for MacTermWin clip_write / clip_request_paste (Phase 4.6).
@MainActor
final class TerminalClipboard {
  /// Borrowed TermWin; cleared by `detach()` before the owner frees it.
  private var termWin: OpaquePointer?
  private var ignorePasteboardChanges = 0
  private var lastGeneralChangeCount = -1
  private var trackingGeneralOwnership = false
  private var pasteboardObserver: NSObjectProtocol?

  private static let pasteboardChangedNotification = Notification.Name(
    "NSPasteboardChangedNotification"
  )

  init(termWin: OpaquePointer) {
    self.termWin = termWin
    pasteboardObserver = NotificationCenter.default.addObserver(
      forName: Self.pasteboardChangedNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      PuttyMainHop.run { [weak self] in
        self?.pasteboardDidChange()
      }
    }
  }

  /// Drop the TermWin handle and pasteboard observer (session teardown).
  func detach() {
    termWin = nil
    trackingGeneralOwnership = false
    if let pasteboardObserver {
      NotificationCenter.default.removeObserver(pasteboardObserver)
      self.pasteboardObserver = nil
    }
  }

  func write(text: String, clipboard: Int32, mustDeselect: Bool) {
    guard let pasteboard = pasteboard(for: clipboard) else { return }

    if !mustDeselect {
      ignorePasteboardChanges += 1
    }

    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)

    if clipboard == PUTTY_BRIDGE_CLIP_CLIPBOARD {
      lastGeneralChangeCount = pasteboard.changeCount
      trackingGeneralOwnership = true
    }

    if !mustDeselect {
      ignorePasteboardChanges -= 1
    }
  }

  func requestPaste(clipboard: Int32) {
    guard let termWin else { return }

    if clipboard == PUTTY_BRIDGE_CLIP_LOCAL {
      putty_bridge_termwin_request_paste(termWin, clipboard)
      return
    }

    guard let pasteboard = pasteboard(for: clipboard) else { return }
    let pasteboardName = pasteboard.name

    // Read off the main thread; inject on MainActor (ldisc path via term_do_paste).
    Task { [weak self] in
      let string = await Task.detached {
        NSPasteboard(name: pasteboardName).string(forType: .string)
      }.value
      guard let string, !string.isEmpty else { return }
      PuttyMainHop.run { [weak self] in
        guard let self, let termWin = self.termWin else { return }
        self.pasteString(string, termWin: termWin)
      }
    }
  }

  // MARK: - Private

  private func pasteboard(for clipboard: Int32) -> NSPasteboard? {
    switch clipboard {
    case PUTTY_BRIDGE_CLIP_CLIPBOARD:
      return .general
    case PUTTY_BRIDGE_CLIP_CUSTOM_1:
      return NSPasteboard(name: .find)
    default:
      return nil
    }
  }

  private func pasteboardDidChange() {
    guard ignorePasteboardChanges == 0 else { return }
    guard trackingGeneralOwnership, let termWin else { return }

    let count = NSPasteboard.general.changeCount
    if count != lastGeneralChangeCount {
      trackingGeneralOwnership = false
      putty_bridge_termwin_lost_clipboard_ownership(termWin, PUTTY_BRIDGE_CLIP_CLIPBOARD)
    }
  }

  private func pasteString(_ string: String, termWin: OpaquePointer) {
    var codepoints = [wchar_t]()
    codepoints.reserveCapacity(string.unicodeScalars.count)
    for scalar in string.unicodeScalars {
      codepoints.append(wchar_t(scalar.value))
    }
    guard !codepoints.isEmpty else { return }
    codepoints.withUnsafeBufferPointer { buf in
      putty_bridge_termwin_paste_text(termWin, buf.baseAddress, Int32(buf.count))
    }
  }
}

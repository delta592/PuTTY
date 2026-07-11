import AppKit
import Foundation
import PuttyBridge

/// Session transcript printing via `NSPrintOperation` (Phase 9.4).
@MainActor
public enum TerminalPrint {
    /// Build a monospaced text view sized to the printable area for `text`.
    public static func makePrintableView(text: String, font: NSFont) -> NSTextView {
        let printInfo = NSPrintInfo.shared
        let width = max(printInfo.imageablePageBounds.width, 100)
        let textStorage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize: NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1),
                                  textContainer: container)
        textView.isEditable = false
        textView.isSelectable = false
        textView.font = font
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: width, height: 1)
        textView.textContainerInset = .zero
        textView.sizeToFit()
        return textView
    }

    /// Run the system print panel for a session transcript (nil-target File → Print).
    public static func runPrintOperation(
        text: String,
        font: NSFont,
        jobTitle: String,
        from window: NSWindow?
    ) {
        let textView = makePrintableView(text: text, font: font)
        guard let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo else {
            return
        }
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false

        let op = NSPrintOperation(view: textView, printInfo: printInfo)
        op.jobTitle = jobTitle
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        if let window {
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            op.run()
        }
    }
}

import AppKit
import PuttyBridge

/// Event Log viewer for one session (Phase 6.4). Searchable NSTextView.
@MainActor
final class EventLogWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
    private let termWin: OpaquePointer
    private let textView: NSTextView
    private let searchField: NSSearchField
    private var filterText = ""
    var onWillClose: (() -> Void)?

    init(termWin: OpaquePointer, parent: NSWindow?) {
        self.termWin = termWin

        let contentRect = NSRect(x: 0, y: 0, width: 640, height: 360)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PuTTY Event Log"
        window.minSize = NSSize(width: 400, height: 200)

        let root = NSView(frame: contentRect)
        root.autoresizingMask = [.width, .height]

        searchField = NSSearchField(frame: .zero)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Filter"
        root.addSubview(searchField)

        let scroll = NSScrollView(frame: .zero)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView
        root.addSubview(scroll)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])

        window.contentView = root
        super.init(window: window)
        window.delegate = self
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))

        if let parent {
            let parentFrame = parent.frame
            var frame = window.frame
            frame.origin.x = parentFrame.midX - frame.width / 2
            frame.origin.y = parentFrame.midY - frame.height / 2
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }

        reloadText()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func reloadText() {
        let count = putty_bridge_termwin_eventlog_count(termWin)
        var lines: [String] = []
        lines.reserveCapacity(Int(count))
        var buf = [CChar](repeating: 0, count: 4096)
        let filter = filterText
        for i in 0..<count {
            guard putty_bridge_termwin_eventlog_line(
                termWin, i, &buf, buf.count) else { continue }
            let line = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if filter.isEmpty || line.localizedCaseInsensitiveContains(filter) {
                lines.append(line)
            }
        }
        let joined = lines.joined(separator: "\n")
        let wasAtBottom = isScrolledToBottom()
        textView.string = joined
        if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        onWillClose?()
        onWillClose = nil
    }

    @objc private func searchFieldChanged(_ sender: Any?) {
        _ = sender
        filterText = searchField.stringValue
        reloadText()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else { return }
        filterText = searchField.stringValue
        reloadText()
    }

    private func isScrolledToBottom() -> Bool {
        guard let scrollView = textView.enclosingScrollView else { return true }
        let visible = scrollView.contentView.bounds
        let doc = scrollView.documentView?.bounds ?? .zero
        return visible.maxY >= doc.maxY - 2
    }
}

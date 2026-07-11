import AppKit
import WebKit

/// Embedded WebKit window for the bundled Halibut HTML manual (Phase 9.5).
@MainActor
public final class HelpWindowController: NSWindowController, WKNavigationDelegate {
    private var webView: WKWebView!

    public convenience init() {
        let rect = NSRect(x: 0, y: 0, width: 780, height: 640)
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let window = NSWindow(
            contentRect: rect,
            styleMask: style,
            backing: .buffered,
            defer: false)
        window.title = "PuTTY Help"
        window.minSize = NSSize(width: 420, height: 320)
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        buildContent()
    }

    private func buildContent() {
        guard let window else { return }

        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.setAccessibilityElement(true)
        web.setAccessibilityRole(.textArea)
        web.setAccessibilityLabel("PuTTY User Manual")
        web.setAccessibilityHelp(
            "Browse the bundled PuTTY documentation. Use links to move between chapters.")
        web.translatesAutoresizingMaskIntoConstraints = false
        self.webView = web

        let content = NSView(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            web.topAnchor.constraint(equalTo: content.topAnchor),
            web.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
    }

    /// Load a local `file://` help page; `readAccessDirectory` must contain linked assets.
    public func showHelp(fileURL: URL, readAccessDirectory: URL) {
        guard let window else { return }
        webView.loadFileURL(fileURL, allowingReadAccessTo: readAccessDirectory)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        // Keep local file navigation in-app; open http(s) in the default browser.
        if url.isFileURL {
            decisionHandler(.allow)
            return
        }
        if let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

import AppKit
import Foundation

/// Bundled Halibut HTML help (Phase 9.5).
///
/// HTML lives at `Contents/Resources/Help/index.html` when the build has
/// Halibut. Opening uses an embedded `WKWebView` (`HelpWindowController`).
@MainActor
public enum PuttyHelp {
    /// Posted by AppKit alert Help buttons (`seat-dialogs.m`).
    public static let openNotification = Notification.Name("PuTTYOpenBundledHelp")

    public static let resourceDirectory = "Help"
    public static let indexResourceName = "index"
    public static let indexResourceExtension = "html"

    /// Online manual when the bundle has no Halibut HTML.
    public static let onlineManualURL = URL(
        string: "https://the.earth.li/~sgtatham/putty/latest/htmldoc/"
    )!

    private static var observerRegistered = false
    private static var helpWindow: HelpWindowController?

    /// `file://` URL of `Help/index.html`, or nil if not bundled.
    public static func indexURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(
            forResource: indexResourceName,
            withExtension: indexResourceExtension,
            subdirectory: resourceDirectory
        )
    }

    public static func helpDirectoryURL(in bundle: Bundle = .main) -> URL? {
        indexURL(in: bundle)?.deletingLastPathComponent()
    }

    public static func isAvailable(in bundle: Bundle = .main) -> Bool {
        indexURL(in: bundle) != nil
    }

    /// Observe alert Help buttons; safe to call more than once.
    public static func registerNotificationObserver() {
        guard !observerRegistered else { return }
        observerRegistered = true
        NotificationCenter.default.addObserver(
            forName: openNotification,
            object: nil,
            queue: .main
        ) { _ in
            PuttyMainHop.run {
                PuttyHelp.open()
            }
        }
    }

    /// Open the help window (or fall back to the online manual / alert).
    public static func open(anchor: String? = nil, in bundle: Bundle = .main) {
        registerNotificationObserver()

        guard let index = indexURL(in: bundle),
              let directory = helpDirectoryURL(in: bundle) else {
            NSWorkspace.shared.open(onlineManualURL)
            return
        }

        var url = index
        if let anchor, !anchor.isEmpty,
           var components = URLComponents(url: index, resolvingAgainstBaseURL: false) {
            components.fragment = anchor
            if let withFrag = components.url {
                url = withFrag
            }
        }

        if helpWindow == nil {
            helpWindow = HelpWindowController()
        }
        helpWindow?.showHelp(fileURL: url, readAccessDirectory: directory)
    }
}

/// Menu target for Help → «App» Help (nil-target menus need a concrete object).
@MainActor
public final class PuttyHelpMenuTarget: NSObject {
    public static let shared = PuttyHelpMenuTarget()

    @objc public func openHelp(_ sender: Any?) {
        _ = sender
        PuttyHelp.open()
    }
}

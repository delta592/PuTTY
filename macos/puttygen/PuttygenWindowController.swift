import AppKit
import Foundation
import PuttygenBridge

/// Progress callback context for background `puttygen_key_generate`.
/// Retained for the worker lifetime; holds a weak controller so UI updates
/// are skipped if the window is already torn down.
private final class PuttygenGenerateContext: @unchecked Sendable {
    let epoch: UInt64
    weak var controller: PuttygenWindowController?

    init(epoch: UInt64, controller: PuttygenWindowController) {
        self.epoch = epoch
        self.controller = controller
    }
}

/// Main PuTTYgen window — generate / load / save / export SSH-2 keys (Phase 7.3).
@MainActor
final class PuttygenWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    /// Owned C key handle. All `puttygen_key_*` access (including free) runs on
    /// `keyQueue` so generate cannot race with teardown or other key ops.
    nonisolated(unsafe) private var keyHandle: OpaquePointer?
    private let keyQueue = DispatchQueue(label: "uk.org.tartarus.putty.puttygen.key")
    /// Bumped on each generate start; completion/progress ignore stale epochs.
    private var generationEpoch: UInt64 = 0
    private var generating = false
    private var isTornDown = false

    /// True while a background `puttygen_key_generate` is in flight.
    var isGenerating: Bool { generating }

    private let typePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let bitsField = NSTextField(string: "2048")
    private let generateButton = NSButton(title: "Generate", target: nil, action: nil)
    private let loadButton = NSButton(title: "Load…", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let fingerprintField = NSTextField(labelWithString: "")
    private let publicKeyView = NSTextView()
    private let commentField = NSTextField(string: "")
    private let passphraseField = NSSecureTextField(string: "")
    private let confirmField = NSSecureTextField(string: "")
    private let savePrivateButton = NSButton(title: "Save private key…", target: nil, action: nil)
    private let savePublicButton = NSButton(title: "Save public key…", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export OpenSSH key…", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "No key.")

    init() {
        keyHandle = puttygen_key_new()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 520))
        let window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PuTTYgen"
        window.contentView = content
        window.minSize = NSSize(width: 560, height: 460)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            window.animationBehavior = .none
        }
        window.setAccessibilityLabel("PuTTYgen")
        super.init(window: window)
        window.delegate = self
        window.center()
        buildUI(in: content)
        refreshKeyDisplay()
        window.initialFirstResponder = typePopUp
        window.autorecalculatesKeyViewLoop = true
        window.recalculateKeyViewLoop()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        // Safety net if windowWillClose did not run (e.g. abrupt teardown).
        releaseKeyHandle()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        _ = sender
        guard generating else { return true }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Key generation in progress"
        alert.informativeText =
            "Please wait for generation to finish before closing PuTTYgen."
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        isTornDown = true
        generationEpoch &+= 1
        releaseKeyHandle()
    }

    /// Free the C key on `keyQueue` after any in-flight key work drains.
    nonisolated private func releaseKeyHandle() {
        keyQueue.sync {
            if let key = keyHandle {
                puttygen_key_free(key)
                keyHandle = nil
            }
        }
    }

    /// Run a PuttygenBridge key operation on `keyQueue` (serializes vs generate).
    private func withKeyHandle<T>(_ body: (OpaquePointer) -> T) -> T? {
        keyQueue.sync {
            guard let key = keyHandle else { return nil }
            return body(key)
        }
    }

    private func buildUI(in content: NSView) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])

        typePopUp.addItems(withTitles: ["Ed25519", "RSA", "ECDSA"])
        typePopUp.selectItem(at: 0)
        typePopUp.target = self
        typePopUp.action = #selector(typeChanged(_:))
        typePopUp.setAccessibilityLabel("Key type")

        bitsField.isEditable = true
        bitsField.isEnabled = false
        bitsField.frame.size.width = 80
        bitsField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        bitsField.setAccessibilityLabel("Bits")

        let params = NSStackView(views: [
            label("Key type:"), typePopUp,
            label("Bits:"), bitsField,
        ])
        params.orientation = .horizontal
        params.spacing = 8
        stack.addArrangedSubview(params)

        generateButton.target = self
        generateButton.action = #selector(generateKey(_:))
        generateButton.setAccessibilityLabel("Generate key")
        loadButton.target = self
        loadButton.action = #selector(loadKey(_:))
        loadButton.setAccessibilityLabel("Load key")
        let actions = NSStackView(views: [generateButton, loadButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        stack.addArrangedSubview(actions)

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = 0
        progress.isHidden = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.heightAnchor.constraint(equalToConstant: 16).isActive = true
        progress.widthAnchor.constraint(equalToConstant: 400).isActive = true
        progress.setAccessibilityLabel("Key generation progress")
        stack.addArrangedSubview(progress)

        stack.addArrangedSubview(label("Fingerprint (SHA-256):"))
        fingerprintField.isSelectable = true
        fingerprintField.lineBreakMode = .byTruncatingMiddle
        fingerprintField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fingerprintField.setAccessibilityLabel("Fingerprint")
        stack.addArrangedSubview(fingerprintField)

        stack.addArrangedSubview(label("Public key for pasting into OpenSSH authorized_keys:"))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 100).isActive = true
        publicKeyView.isEditable = false
        publicKeyView.isRichText = false
        publicKeyView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        publicKeyView.autoresizingMask = [.width, .height]
        publicKeyView.setAccessibilityLabel("Public key")
        scroll.documentView = publicKeyView
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addArrangedSubview(label("Key comment:"))
        commentField.delegate = self
        commentField.isEnabled = false
        commentField.setAccessibilityLabel("Key comment")
        stack.addArrangedSubview(commentField)
        commentField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let passRow = NSStackView(views: [
            label("Key passphrase:"), passphraseField,
            label("Confirm:"), confirmField,
        ])
        passRow.orientation = .horizontal
        passRow.spacing = 8
        passphraseField.widthAnchor.constraint(equalToConstant: 140).isActive = true
        confirmField.widthAnchor.constraint(equalToConstant: 140).isActive = true
        passphraseField.setAccessibilityLabel("Key passphrase")
        confirmField.setAccessibilityLabel("Confirm passphrase")
        stack.addArrangedSubview(passRow)

        savePrivateButton.target = self
        savePrivateButton.action = #selector(savePrivateKey(_:))
        savePrivateButton.setAccessibilityLabel("Save private key")
        savePublicButton.target = self
        savePublicButton.action = #selector(savePublicKey(_:))
        savePublicButton.setAccessibilityLabel("Save public key")
        exportButton.target = self
        exportButton.action = #selector(exportOpenSSH(_:))
        exportButton.setAccessibilityLabel("Export OpenSSH key")
        let saveRow = NSStackView(views: [savePrivateButton, savePublicButton, exportButton])
        saveRow.orientation = .horizontal
        saveRow.spacing = 8
        stack.addArrangedSubview(saveRow)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityLabel("Status")
        stack.addArrangedSubview(statusLabel)
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return field
    }

    @objc private func typeChanged(_ sender: Any?) {
        _ = sender
        let ed25519 = typePopUp.indexOfSelectedItem == 0
        bitsField.isEnabled = !ed25519
        if ed25519 {
            bitsField.stringValue = "255"
        } else if typePopUp.indexOfSelectedItem == 1 {
            bitsField.stringValue = "2048"
        } else {
            bitsField.stringValue = "384"
        }
    }

    private func selectedKeyType() -> PuttygenKeyType {
        switch typePopUp.indexOfSelectedItem {
        case 1: return PUTTYGEN_KEY_RSA
        case 2: return PUTTYGEN_KEY_ECDSA
        default: return PUTTYGEN_KEY_ED25519
        }
    }

    private func refreshKeyDisplay() {
        let snapshot: (hasKey: Bool, fingerprint: String?, publicKey: String?, comment: String?)? =
            withKeyHandle { key in
                let hasKey = puttygen_key_has_key(key)
                guard hasKey else {
                    return (false, nil, nil, nil)
                }
                var fingerprint: String?
                var publicKey: String?
                var comment: String?
                if let fp = puttygen_key_fingerprint(key) {
                    fingerprint = String(cString: fp)
                    puttygen_free_string(fp)
                }
                if let pub = puttygen_key_public_openssh(key) {
                    publicKey = String(cString: pub)
                    puttygen_free_string(pub)
                }
                if let c = puttygen_key_comment(key) {
                    comment = String(cString: c)
                    puttygen_free_string(c)
                }
                return (true, fingerprint, publicKey, comment)
            }

        let hasKey = snapshot?.hasKey ?? false
        savePrivateButton.isEnabled = hasKey && !generating
        savePublicButton.isEnabled = hasKey && !generating
        exportButton.isEnabled = hasKey && !generating
        commentField.isEnabled = hasKey && !generating
        generateButton.isEnabled = !generating && !isTornDown
        loadButton.isEnabled = !generating && !isTornDown

        guard let snapshot, snapshot.hasKey else {
            fingerprintField.stringValue = ""
            publicKeyView.string = ""
            commentField.stringValue = ""
            statusLabel.stringValue = "No key."
            return
        }

        fingerprintField.stringValue = snapshot.fingerprint ?? ""
        publicKeyView.string = snapshot.publicKey ?? ""
        commentField.stringValue = snapshot.comment ?? ""
        statusLabel.stringValue = "Key ready."
    }

    private func setGenerating(_ on: Bool) {
        generating = on
        progress.isHidden = !on
        if on {
            progress.doubleValue = 0
        }
        refreshKeyDisplay()
    }

    fileprivate func updateGenerationProgress(_ fraction: Double, epoch: UInt64) {
        guard !isTornDown, generationEpoch == epoch, generating else { return }
        progress.doubleValue = fraction
    }

    private func finishGeneration(ok: Bool, error: String?, epoch: UInt64) {
        guard !isTornDown, generationEpoch == epoch else { return }
        setGenerating(false)
        if !ok {
            showError(error ?? "Key generation failed")
            statusLabel.stringValue = "Generation failed."
        } else {
            refreshKeyDisplay()
            statusLabel.stringValue = "Key generated."
        }
    }

    @objc func generateKey(_ sender: Any?) {
        _ = sender
        guard !generating, !isTornDown, keyHandle != nil else { return }
        let type = selectedKeyType()
        let bits = Int32(bitsField.intValue)
        generationEpoch &+= 1
        let epoch = generationEpoch
        setGenerating(true)
        statusLabel.stringValue = "Generating key…"

        // Retain progress context for the worker; release after generate returns.
        // Key pointer is passed by bitPattern so the @Sendable closure does not
        // need to touch MainActor state. Free is blocked until generating ends
        // (windowShouldClose / terminate refuse while generating).
        let keyBits = Int(bitPattern: keyHandle!)
        let context = PuttygenGenerateContext(epoch: epoch, controller: self)
        let ctxBits = Int(bitPattern: Unmanaged.passRetained(context).toOpaque())

        keyQueue.async {
            defer {
                if let raw = UnsafeMutableRawPointer(bitPattern: ctxBits) {
                    Unmanaged<PuttygenGenerateContext>.fromOpaque(raw).release()
                }
            }
            guard let key = OpaquePointer(bitPattern: keyBits),
                  let ctx = UnsafeMutableRawPointer(bitPattern: ctxBits)
            else {
                DispatchQueue.main.async {
                    context.controller?.finishGeneration(
                        ok: false, error: "Invalid key handle", epoch: epoch)
                }
                return
            }
            var err: UnsafeMutablePointer<CChar>?
            let ok = puttygen_key_generate(
                key, type, bits,
                { rawCtx, fraction in
                    guard let rawCtx else { return }
                    let progressCtx = Unmanaged<PuttygenGenerateContext>
                        .fromOpaque(rawCtx).takeUnretainedValue()
                    DispatchQueue.main.async {
                        progressCtx.controller?.updateGenerationProgress(
                            fraction, epoch: progressCtx.epoch)
                    }
                },
                ctx,
                &err
            )
            let errorString: String? = err.map {
                let s = String(cString: $0)
                puttygen_free_string($0)
                return s
            }
            // Capture weak controller before defer releases the context.
            let controller = Unmanaged<PuttygenGenerateContext>
                .fromOpaque(ctx).takeUnretainedValue().controller
            DispatchQueue.main.async {
                controller?.finishGeneration(ok: ok, error: errorString, epoch: epoch)
            }
        }
    }

    @objc func loadKey(_ sender: Any?) {
        _ = sender
        let panel = NSOpenPanel()
        panel.title = "Load private key"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadKey(at: url.path)
    }

    private func loadKey(at path: String) {
        guard !generating, !isTornDown else { return }
        var needsPass = false
        var err: UnsafeMutablePointer<CChar>?
        guard puttygen_key_probe_file(path, &needsPass, &err) else {
            showError(takeError(&err) ?? "Cannot open key file")
            return
        }

        var passphrase: String?
        if needsPass {
            passphrase = askPassphrase(message: "Enter passphrase for key")
            if passphrase == nil {
                return
            }
        }

        let outcome: (PuttygenLoadResult, String?)? = withKeyHandle { key in
            var localErr: UnsafeMutablePointer<CChar>?
            let result = path.withCString { cPath in
                (passphrase ?? "").withCString { cPass in
                    puttygen_key_load(key, cPath, cPass, &localErr)
                }
            }
            let message: String? = localErr.map {
                let s = String(cString: $0)
                puttygen_free_string($0)
                return s
            }
            return (result, message)
        }
        guard let outcome else { return }

        switch outcome.0 {
        case PUTTYGEN_LOAD_OK:
            refreshKeyDisplay()
            statusLabel.stringValue = "Key loaded."
        case PUTTYGEN_LOAD_NEED_PASSPHRASE, PUTTYGEN_LOAD_WRONG_PASSPHRASE:
            showError("Wrong passphrase or passphrase required.")
        default:
            showError(outcome.1 ?? "Failed to load key")
        }
    }

    @objc func savePrivateKey(_ sender: Any?) {
        _ = sender
        guard !generating else { return }
        let hasKey = withKeyHandle { puttygen_key_has_key($0) } ?? false
        guard hasKey else { return }
        applyCommentFromField()
        guard let pass = matchedPassphraseForSave() else { return }

        let panel = NSSavePanel()
        panel.title = "Save private key"
        panel.nameFieldStringValue = "id_putty.ppk"
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let outcome = withKeyHandle { key -> (Bool, String?) in
            var localErr: UnsafeMutablePointer<CChar>?
            let ok = url.path.withCString { cPath in
                pass.withCString { cPass in
                    puttygen_key_save_ppk(key, cPath, cPass, &localErr)
                }
            }
            let message: String? = localErr.map {
                let s = String(cString: $0)
                puttygen_free_string($0)
                return s
            }
            return (ok, message)
        }
        if outcome?.0 == true {
            statusLabel.stringValue = "Private key saved."
        } else {
            showError(outcome?.1 ?? "Save failed")
        }
    }

    @objc func savePublicKey(_ sender: Any?) {
        _ = sender
        guard !generating else { return }
        let hasKey = withKeyHandle { puttygen_key_has_key($0) } ?? false
        guard hasKey else { return }
        applyCommentFromField()

        let panel = NSSavePanel()
        panel.title = "Save public key"
        panel.nameFieldStringValue = "id_putty.pub"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let outcome = withKeyHandle { key -> (Bool, String?) in
            var localErr: UnsafeMutablePointer<CChar>?
            let ok = url.path.withCString { cPath in
                puttygen_key_save_public(key, cPath, &localErr)
            }
            let message: String? = localErr.map {
                let s = String(cString: $0)
                puttygen_free_string($0)
                return s
            }
            return (ok, message)
        }
        if outcome?.0 == true {
            statusLabel.stringValue = "Public key saved."
        } else {
            showError(outcome?.1 ?? "Save failed")
        }
    }

    @objc func exportOpenSSH(_ sender: Any?) {
        _ = sender
        guard !generating else { return }
        let hasKey = withKeyHandle { puttygen_key_has_key($0) } ?? false
        guard hasKey else { return }
        applyCommentFromField()
        guard let pass = matchedPassphraseForSave() else { return }

        let panel = NSSavePanel()
        panel.title = "Export OpenSSH private key"
        panel.nameFieldStringValue = "id_ed25519"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let outcome = withKeyHandle { key -> (Bool, String?) in
            var localErr: UnsafeMutablePointer<CChar>?
            let ok = url.path.withCString { cPath in
                pass.withCString { cPass in
                    puttygen_key_export_openssh(key, cPath, cPass, &localErr)
                }
            }
            let message: String? = localErr.map {
                let s = String(cString: $0)
                puttygen_free_string($0)
                return s
            }
            return (ok, message)
        }
        if outcome?.0 == true {
            statusLabel.stringValue = "OpenSSH key exported."
        } else {
            showError(outcome?.1 ?? "Export failed")
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if obj.object as? NSTextField === commentField {
            applyCommentFromField()
            refreshKeyDisplay()
        }
    }

    private func applyCommentFromField() {
        let comment = commentField.stringValue
        _ = withKeyHandle { key -> Bool in
            guard puttygen_key_has_key(key) else { return false }
            comment.withCString { cstr in
                puttygen_key_set_comment(key, cstr)
            }
            return true
        }
    }

    private func matchedPassphraseForSave() -> String? {
        let a = passphraseField.stringValue
        let b = confirmField.stringValue
        if a != b {
            showError("Passphrases do not match.")
            return nil
        }
        if a.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Save without a passphrase?"
            alert.informativeText =
                "Are you sure you want to save this key without a passphrase to protect it?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Yes")
            alert.addButton(withTitle: "No")
            if alert.runModal() != .alertFirstButtonReturn {
                return nil
            }
        }
        return a
    }

    private func askPassphrase(message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "This key is encrypted."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "PuTTYgen"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func takeError(_ err: inout UnsafeMutablePointer<CChar>?) -> String? {
        guard let e = err else { return nil }
        let s = String(cString: e)
        puttygen_free_string(e)
        err = nil
        return s
    }
}

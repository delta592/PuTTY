import AppKit
import Foundation
import PuttygenBridge

/// Main PuTTYgen window — generate / load / save / export SSH-2 keys (Phase 7.3).
@MainActor
final class PuttygenWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    /// Owned C key handle; freed in deinit (nonisolated).
    nonisolated(unsafe) private let key: OpaquePointer
    private var generating = false

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
        key = puttygen_key_new()
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
        super.init(window: window)
        window.delegate = self
        window.center()
        buildUI(in: content)
        refreshKeyDisplay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        puttygen_key_free(key)
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

        bitsField.isEditable = true
        bitsField.isEnabled = false
        bitsField.frame.size.width = 80
        bitsField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let params = NSStackView(views: [
            label("Key type:"), typePopUp,
            label("Bits:"), bitsField,
        ])
        params.orientation = .horizontal
        params.spacing = 8
        stack.addArrangedSubview(params)

        generateButton.target = self
        generateButton.action = #selector(generateKey(_:))
        loadButton.target = self
        loadButton.action = #selector(loadKey(_:))
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
        stack.addArrangedSubview(progress)

        stack.addArrangedSubview(label("Fingerprint (SHA-256):"))
        fingerprintField.isSelectable = true
        fingerprintField.lineBreakMode = .byTruncatingMiddle
        fingerprintField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        scroll.documentView = publicKeyView
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addArrangedSubview(label("Key comment:"))
        commentField.delegate = self
        commentField.isEnabled = false
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
        stack.addArrangedSubview(passRow)

        savePrivateButton.target = self
        savePrivateButton.action = #selector(savePrivateKey(_:))
        savePublicButton.target = self
        savePublicButton.action = #selector(savePublicKey(_:))
        exportButton.target = self
        exportButton.action = #selector(exportOpenSSH(_:))
        let saveRow = NSStackView(views: [savePrivateButton, savePublicButton, exportButton])
        saveRow.orientation = .horizontal
        saveRow.spacing = 8
        stack.addArrangedSubview(saveRow)

        statusLabel.textColor = .secondaryLabelColor
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
        let hasKey = puttygen_key_has_key(key)
        savePrivateButton.isEnabled = hasKey && !generating
        savePublicButton.isEnabled = hasKey && !generating
        exportButton.isEnabled = hasKey && !generating
        commentField.isEnabled = hasKey && !generating
        generateButton.isEnabled = !generating
        loadButton.isEnabled = !generating

        if !hasKey {
            fingerprintField.stringValue = ""
            publicKeyView.string = ""
            commentField.stringValue = ""
            statusLabel.stringValue = "No key."
            return
        }

        if let fp = puttygen_key_fingerprint(key) {
            fingerprintField.stringValue = String(cString: fp)
            puttygen_free_string(fp)
        }
        if let pub = puttygen_key_public_openssh(key) {
            publicKeyView.string = String(cString: pub)
            puttygen_free_string(pub)
        }
        if let comment = puttygen_key_comment(key) {
            commentField.stringValue = String(cString: comment)
            puttygen_free_string(comment)
        }
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

    @objc func generateKey(_ sender: Any?) {
        _ = sender
        guard !generating else { return }
        let type = selectedKeyType()
        let bits = Int32(bitsField.intValue)
        setGenerating(true)
        statusLabel.stringValue = "Generating key…"

        let keyHandle = key
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        DispatchQueue.global(qos: .userInitiated).async {
            var err: UnsafeMutablePointer<CChar>?
            let ok = puttygen_key_generate(
                keyHandle, type, bits,
                { ctx, fraction in
                    guard let ctx else { return }
                    let controller = Unmanaged<PuttygenWindowController>
                        .fromOpaque(ctx).takeUnretainedValue()
                    DispatchQueue.main.async {
                        controller.progress.doubleValue = fraction
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
            DispatchQueue.main.async {
                self.setGenerating(false)
                if !ok {
                    self.showError(errorString ?? "Key generation failed")
                    self.statusLabel.stringValue = "Generation failed."
                } else {
                    self.refreshKeyDisplay()
                    self.statusLabel.stringValue = "Key generated."
                }
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
        var needsPass = false
        var err: UnsafeMutablePointer<CChar>?
        guard puttygen_key_probe_file(path, &needsPass, &err) else {
            showError(takeError(&err) ?? "Cannot open key file")
            return
        }

        var passphrase: String? = nil
        if needsPass {
            passphrase = askPassphrase(message: "Enter passphrase for key")
            if passphrase == nil {
                return
            }
        }

        let result = path.withCString { cPath in
            (passphrase ?? "").withCString { cPass in
                puttygen_key_load(key, cPath, cPass, &err)
            }
        }

        switch result {
        case PUTTYGEN_LOAD_OK:
            refreshKeyDisplay()
            statusLabel.stringValue = "Key loaded."
        case PUTTYGEN_LOAD_NEED_PASSPHRASE, PUTTYGEN_LOAD_WRONG_PASSPHRASE:
            showError("Wrong passphrase or passphrase required.")
        default:
            showError(takeError(&err) ?? "Failed to load key")
        }
    }

    @objc func savePrivateKey(_ sender: Any?) {
        _ = sender
        guard puttygen_key_has_key(key) else { return }
        applyCommentFromField()
        guard let pass = matchedPassphraseForSave() else { return }

        let panel = NSSavePanel()
        panel.title = "Save private key"
        panel.nameFieldStringValue = "id_putty.ppk"
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var err: UnsafeMutablePointer<CChar>?
        let ok = url.path.withCString { cPath in
            pass.withCString { cPass in
                puttygen_key_save_ppk(key, cPath, cPass, &err)
            }
        }
        if ok {
            statusLabel.stringValue = "Private key saved."
        } else {
            showError(takeError(&err) ?? "Save failed")
        }
    }

    @objc func savePublicKey(_ sender: Any?) {
        _ = sender
        guard puttygen_key_has_key(key) else { return }
        applyCommentFromField()

        let panel = NSSavePanel()
        panel.title = "Save public key"
        panel.nameFieldStringValue = "id_putty.pub"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var err: UnsafeMutablePointer<CChar>?
        let ok = url.path.withCString { cPath in
            puttygen_key_save_public(key, cPath, &err)
        }
        if ok {
            statusLabel.stringValue = "Public key saved."
        } else {
            showError(takeError(&err) ?? "Save failed")
        }
    }

    @objc func exportOpenSSH(_ sender: Any?) {
        _ = sender
        guard puttygen_key_has_key(key) else { return }
        applyCommentFromField()
        guard let pass = matchedPassphraseForSave() else { return }

        let panel = NSSavePanel()
        panel.title = "Export OpenSSH private key"
        panel.nameFieldStringValue = "id_ed25519"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var err: UnsafeMutablePointer<CChar>?
        let ok = url.path.withCString { cPath in
            pass.withCString { cPass in
                puttygen_key_export_openssh(key, cPath, cPass, &err)
            }
        }
        if ok {
            statusLabel.stringValue = "OpenSSH key exported."
        } else {
            showError(takeError(&err) ?? "Export failed")
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if obj.object as? NSTextField === commentField {
            applyCommentFromField()
            refreshKeyDisplay()
        }
    }

    private func applyCommentFromField() {
        guard puttygen_key_has_key(key) else { return }
        commentField.stringValue.withCString { cstr in
            puttygen_key_set_comment(key, cstr)
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

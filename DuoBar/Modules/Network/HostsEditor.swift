import AppKit
import SwiftUI

/// Reads `/etc/hosts` and stages new contents in a temporary file that is
/// then copied into place as root.
protocol HostsFileAccessing: Sendable {
    func read() throws -> String
    func writeTemporary(_ contents: String) throws -> URL
    func removeTemporary(_ url: URL)
}

struct HostsFileAccess: HostsFileAccessing {
    var path = NetworkTools.hostsPath

    func read() throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    func writeTemporary(_ contents: String) throws -> URL {
        // A plain name keeps the command simple; it is quoted anyway.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("duobarplus-hosts-\(UUID().uuidString).txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func removeTemporary(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The hosts editor's state. Saving asks for an administrator password once,
/// replaces the file and flushes the DNS cache so the change applies at once.
@MainActor
final class HostsEditorModel: ObservableObject {
    @Published var text = ""
    @Published private(set) var original = ""
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage: String?
    /// Called after a successful save; the window closes itself.
    var onSaved: (() -> Void)?

    private let runner: any PrivilegedCommandRunning
    private let file: any HostsFileAccessing

    init(runner: any PrivilegedCommandRunning, file: any HostsFileAccessing = HostsFileAccess()) {
        self.runner = runner
        self.file = file
    }

    var isDirty: Bool { text != original }
    var canSave: Bool { isDirty && !isSaving }

    func load() {
        do {
            let contents = try file.read()
            original = contents
            text = contents
            errorMessage = nil
        } catch {
            errorMessage = localized("Could not read the hosts file: %@", error.localizedDescription)
        }
    }

    func revert() {
        text = original
        errorMessage = nil
    }

    static func saveCommand(temporaryFile: URL) -> String {
        "cp \(ShellQuoting.shell(temporaryFile.path)) \(NetworkTools.hostsPath) && chmod 644 \(NetworkTools.hostsPath) && \(NetworkTools.flushDNSCommand)"
    }

    func save(completion: (() -> Void)? = nil) {
        guard canSave else { return }
        let temporary: URL
        do {
            temporary = try file.writeTemporary(text)
        } catch {
            errorMessage = localized("Could not save the hosts file: %@", error.localizedDescription)
            return
        }
        isSaving = true
        errorMessage = nil
        let file = file
        runner.run(Self.saveCommand(temporaryFile: temporary), prompt: localized("DuoBar+ wants to save the hosts file.")) { result in
            file.removeTemporary(temporary)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isSaving = false
                switch result {
                case .success:
                    self.load()
                    self.onSaved?()
                case .failure(.cancelled):
                    break
                case .failure(.failed(let message)):
                    self.errorMessage = localized("Could not save the hosts file: %@", message)
                }
                completion?()
            }
        }
    }
}

struct HostsEditorView: View {
    @ObservedObject var model: HostsEditorModel

    var body: some View {
        VStack(spacing: 10) {
            TextEditor(text: $model.text)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))

            HStack(spacing: 8) {
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text(localized("Saving asks for an administrator password and flushes the DNS cache."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isSaving { ProgressView().controlSize(.small) }
                Button(localized("Revert")) { model.revert() }
                    .disabled(!model.isDirty || model.isSaving)
                Button(localized("Save")) { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.canSave)
            }
        }
        .padding(12)
        .frame(minWidth: 480, minHeight: 320)
    }
}

/// One reusable window for the hosts editor.
@MainActor
final class HostsEditorWindowController: NSWindowController {
    private let model: HostsEditorModel

    init(model: HostsEditorModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = localized("Hosts File")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HostsEditorView(model: model))
        window.center()
        window.setFrameAutosaveName("DuoBarPlusHostsEditor")
        super.init(window: window)
        model.onSaved = { [weak self] in self?.close() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func present() {
        // Reload unless there are unsaved edits in an open window.
        if !(window?.isVisible == true && model.isDirty) { model.load() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

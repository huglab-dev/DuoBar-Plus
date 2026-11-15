import AppKit
import Foundation
@preconcurrency import UserNotifications

/// Quoting for commands passed to `do shell script`.
enum ShellQuoting {
    /// One shell word in single quotes.
    static func shell(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The contents of an AppleScript string literal.
    static func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// The AppleScript that runs `command` as root after macOS asks for an
    /// administrator password.
    static func privilegedScript(_ command: String, prompt: String) -> String {
        "do shell script \"\(appleScriptString(command))\" with prompt \"\(appleScriptString(prompt))\" with administrator privileges"
    }
}

enum PrivilegedCommandError: Error, Equatable {
    /// The user closed the password dialog.
    case cancelled
    case failed(String)
}

/// Runs a shell command as root. Asks for a password every time.
protocol PrivilegedCommandRunning: Sendable {
    func run(_ command: String, prompt: String, completion: @escaping @Sendable (Result<Void, PrivilegedCommandError>) -> Void)
}

/// Uses `osascript` and `do shell script … with administrator privileges`,
/// which shows the standard macOS password dialog. Public, no helper tool.
struct OsascriptPrivilegedRunner: PrivilegedCommandRunning {
    func run(_ command: String, prompt: String, completion: @escaping @Sendable (Result<Void, PrivilegedCommandError>) -> Void) {
        let script = ShellQuoting.privilegedScript(command, prompt: prompt)
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                completion(.failure(.failed(error.localizedDescription)))
                return
            }
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus != 0 else {
                completion(.success(()))
                return
            }
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            completion(.failure(Self.error(fromOutput: message)))
        }
    }

    /// osascript reports error -128 when the password dialog is cancelled.
    static func error(fromOutput message: String) -> PrivilegedCommandError {
        if message.contains("(-128)") { return .cancelled }
        return .failed(message.isEmpty ? localized("The command failed.") : message)
    }
}

/// Confirms a finished action with a system notification.
@MainActor
protocol NetworkToolsNotifying {
    func notify(title: String)
}

/// Asks for notification permission the first time it is used, never at launch.
@MainActor
struct UserNotificationNotifier: NetworkToolsNotifying {
    func notify(title: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
}

/// Flush DNS and the hosts file. Nothing runs until the user picks an action.
@MainActor
final class NetworkTools {
    nonisolated static let flushDNSCommand = "dscacheutil -flushcache; killall -HUP mDNSResponder"
    nonisolated static let hostsPath = "/etc/hosts"

    let runner: any PrivilegedCommandRunning
    private let ipReader: any IPConfigurationReading
    private var ipEditor: IPConfigurationWindowController?
    let profiles: IPProfileStore
    private let notifier: any NetworkToolsNotifying
    private let showError: (String) -> Void
    private var hostsEditor: HostsEditorWindowController?

    init(
        runner: any PrivilegedCommandRunning = OsascriptPrivilegedRunner(),
        ipReader: any IPConfigurationReading = SCPreferencesIPConfigurationReader(),
        profiles: IPProfileStore? = nil,
        notifier: (any NetworkToolsNotifying)? = nil,
        showError: ((String) -> Void)? = nil
    ) {
        self.runner = runner
        self.ipReader = ipReader
        self.profiles = profiles ?? IPProfileStore()
        self.notifier = notifier ?? UserNotificationNotifier()
        self.showError = showError ?? NetworkTools.presentAlert
    }

    func flushDNS() {
        runner.run(Self.flushDNSCommand, prompt: localized("DuoBar+ wants to flush the DNS cache.")) { result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success:
                    self.notifier.notify(title: localized("DNS cache flushed"))
                case .failure(.cancelled):
                    break
                case .failure(.failed(let message)):
                    self.showError(message)
                }
            }
        }
    }

    func configureIP(bsdName: String) {
        let editor = ipEditor?.model.bsdName == bsdName
            ? ipEditor!
            : IPConfigurationWindowController(model: IPConfigurationEditorModel(bsdName: bsdName, reader: ipReader, runner: runner, profiles: profiles))
        ipEditor = editor
        editor.present()
    }

    /// Renewing switches a manual service to DHCP, so it runs only for
    /// services that already use DHCP.
    func renewDHCPLease(bsdName: String) {
        guard ipReader.configuration(forBSDName: bsdName)?.configuration.method == .dhcp else {
            showError(localized("Renew DHCP Lease works only when IPv4 is configured using DHCP."))
            return
        }
        runner.run(IPConfigurationCommand.renew(bsdName: bsdName), prompt: localized("DuoBar+ wants to renew the DHCP lease.")) { result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success: self.notifier.notify(title: localized("DHCP lease renewed"))
                case .failure(.cancelled): break
                case .failure(.failed(let message)): self.showError(message)
                }
            }
        }
    }

    struct ProfileMenuState: Equatable {
        var serviceName: String
        var profiles: [IPProfile]
        var activeID: UUID?
        var isAutomatic: Bool
    }

    /// What the IP Profile submenu shows for the interface. Read when the
    /// right-click menu is built.
    func profileMenuState(bsdName: String) -> ProfileMenuState? {
        ipReader.configuration(forBSDName: bsdName).map { service in
            ProfileMenuState(
                serviceName: service.serviceName,
                profiles: profiles.profiles(for: service.serviceName),
                activeID: profiles.activeProfile(for: service)?.id,
                isAutomatic: service.configuration.matches(.automatic)
            )
        }
    }

    func applyProfile(_ profile: IPProfile) {
        apply(profile.configuration, service: profile.serviceName, name: profile.name)
    }

    /// DHCP with no own DNS servers or search domains.
    func applyAutomatic(service: String) {
        apply(.automatic, service: service, name: localized("Automatic (DHCP)"))
    }

    /// For `duobarplus://ip-profile?name=…`. "dhcp" means automatic, applied
    /// to the primary interface's service.
    func applyProfile(named name: String, primaryBSDName: String?) {
        if name.lowercased() == "dhcp" {
            guard let primaryBSDName, let service = ipReader.configuration(forBSDName: primaryBSDName) else {
                showError(localized("No network service uses %@.", primaryBSDName ?? "?"))
                return
            }
            applyAutomatic(service: service.serviceName)
        } else if let profile = profiles.profile(named: name) {
            applyProfile(profile)
        } else {
            showError(localized("No IP profile is named %@.", name))
        }
    }

    private func apply(_ configuration: IPConfiguration, service: String, name: String) {
        let command = IPConfigurationCommand.apply(configuration, service: service)
        runner.run(command, prompt: localized("DuoBar+ wants to change the IP configuration.")) { result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success: self.notifier.notify(title: localized("IP profile %@ applied", name))
                case .failure(.cancelled): break
                case .failure(.failed(let message)): self.showError(message)
                }
            }
        }
    }

    func editHostsFile() {
        let editor = hostsEditor ?? HostsEditorWindowController(model: HostsEditorModel(runner: runner))
        hostsEditor = editor
        editor.present()
    }

    private static func presentAlert(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = localized("The network action failed")
        alert.informativeText = message
        alert.runModal()
    }
}

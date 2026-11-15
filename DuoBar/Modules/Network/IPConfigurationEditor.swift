import AppKit
import SwiftUI

/// The IP configuration window's state. Applying asks for an administrator
/// password once and runs `networksetup`.
@MainActor
final class IPConfigurationEditorModel: ObservableObject {
    enum Field: Hashable {
        case address, subnetMask, router, dnsServers, searchDomains
    }

    @Published var method: IPConfiguration.Method = .dhcp
    @Published var address = ""
    @Published var subnetMask = ""
    @Published var router = ""
    /// One value per line.
    @Published var dnsText = ""
    @Published var searchText = ""
    @Published private(set) var serviceName: String?
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?
    /// The resolvers and search domains in use, shown when the lists are empty.
    @Published private(set) var currentDNSServers: [String] = []
    @Published private(set) var currentSearchDomains: [String] = []
    /// The profile whose values fill the form, if one was picked.
    @Published var selectedProfileID: UUID?
    /// The profile the service uses right now, marked in the profile row.
    @Published private(set) var activeProfileID: UUID?

    /// Called after a successful apply; the window closes itself.
    var onApplied: (() -> Void)?

    let bsdName: String
    private let reader: any IPConfigurationReading
    private let runner: any PrivilegedCommandRunning
    let profiles: IPProfileStore
    private var original: IPConfiguration?

    init(
        bsdName: String,
        reader: any IPConfigurationReading = SCPreferencesIPConfigurationReader(),
        runner: any PrivilegedCommandRunning,
        profiles: IPProfileStore? = nil
    ) {
        self.bsdName = bsdName
        self.reader = reader
        self.runner = runner
        self.profiles = profiles ?? IPProfileStore()
    }

    var serviceProfiles: [IPProfile] {
        serviceName.map(profiles.profiles(for:)) ?? []
    }

    /// Fills the form with a profile's values, or the current settings for
    /// nil. Nothing is applied until Apply.
    func selectProfile(_ id: UUID?) {
        selectedProfileID = id
        if let id, let profile = profiles.profiles.first(where: { $0.id == id }) {
            show(profile.configuration)
        } else if let original {
            show(original)
        }
        errorMessage = nil
    }

    /// Saves the form's values as a profile for this service.
    func saveProfile(named name: String) {
        guard let serviceName, !name.trimmingCharacters(in: .whitespaces).isEmpty, errors.isEmpty else { return }
        selectedProfileID = profiles.save(name: name, serviceName: serviceName, configuration: configuration).id
    }

    func deleteSelectedProfile() {
        guard let id = selectedProfileID else { return }
        deleteProfile(id)
    }

    func deleteProfile(_ id: UUID) {
        guard let profile = profiles.profiles.first(where: { $0.id == id }) else { return }
        profiles.delete(profile)
        if selectedProfileID == id { selectProfile(nil) }
        if activeProfileID == id { activeProfileID = nil }
    }

    func renameProfile(_ id: UUID, to name: String) {
        guard let profile = profiles.profiles.first(where: { $0.id == id }),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        profiles.rename(profile, to: name)
        objectWillChange.send()
    }

    /// Whether saving under `name` would replace a profile of this service.
    func profileNameExists(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return serviceProfiles.contains { $0.name == trimmed }
    }

    func load() {
        guard let service = reader.configuration(forBSDName: bsdName) else {
            serviceName = nil
            original = nil
            errorMessage = localized("No network service uses %@.", bsdName)
            return
        }
        serviceName = service.serviceName
        original = service.configuration
        currentDNSServers = service.currentDNSServers
        currentSearchDomains = service.currentSearchDomains
        show(service.configuration)
        activeProfileID = profiles.activeProfile(for: service)?.id
        selectedProfileID = activeProfileID
        errorMessage = nil
        statusMessage = nil
    }

    func revert() {
        if let original { show(original) }
        errorMessage = nil
    }

    var configuration: IPConfiguration {
        IPConfiguration(
            method: method,
            address: address.trimmingCharacters(in: .whitespaces),
            subnetMask: subnetMask.trimmingCharacters(in: .whitespaces),
            router: router.trimmingCharacters(in: .whitespaces),
            dnsServers: Self.lines(dnsText),
            searchDomains: Self.lines(searchText)
        )
    }

    var isDirty: Bool { original.map { !configuration.matches($0) } ?? false }

    /// Whether the address fields are used by the chosen method.
    var usesAddress: Bool { method != .dhcp }
    var usesSubnetAndRouter: Bool { method == .manual }
    /// Renewing switches a manual service to DHCP, so it is offered only for
    /// services that already use DHCP.
    var canRenewLease: Bool { original?.method == .dhcp && !isWorking }

    var errors: [Field: String] {
        let configuration = configuration
        var errors: [Field: String] = [:]
        if usesAddress, !IPv4Validation.isAddress(configuration.address) {
            errors[.address] = localized("Enter an IPv4 address.")
        }
        if usesSubnetAndRouter {
            if !IPv4Validation.isSubnetMask(configuration.subnetMask) {
                errors[.subnetMask] = localized("Enter a subnet mask, such as 255.255.255.0.")
            }
            if !IPv4Validation.isAddress(configuration.router) {
                errors[.router] = localized("Enter the router's IPv4 address.")
            } else if errors[.address] == nil, errors[.subnetMask] == nil,
                      !IPv4Validation.sameSubnet(configuration.address, configuration.router, mask: configuration.subnetMask) {
                errors[.router] = localized("The router is not in the same subnet.")
            }
        }
        if let bad = configuration.dnsServers.first(where: { !IPv4Validation.isDNSServer($0) }) {
            errors[.dnsServers] = localized("Not an IP address: %@", bad)
        }
        if let bad = configuration.searchDomains.first(where: { !IPv4Validation.isSearchDomain($0) }) {
            errors[.searchDomains] = localized("Not a domain: %@", bad)
        }
        return errors
    }

    var canApply: Bool { isDirty && errors.isEmpty && !isWorking && serviceName != nil }

    func apply(completion: (() -> Void)? = nil) {
        guard canApply, let serviceName else { return }
        let command = IPConfigurationCommand.apply(configuration, service: serviceName)
        run(command, prompt: localized("DuoBar+ wants to change the IP configuration.")) { [weak self] in
            self?.load()
            self?.onApplied?()
        } completion: { completion?() }
    }

    func renewLease(completion: (() -> Void)? = nil) {
        guard canRenewLease else { return }
        run(IPConfigurationCommand.renew(bsdName: bsdName), prompt: localized("DuoBar+ wants to renew the DHCP lease.")) { [weak self] in
            self?.load()
            self?.statusMessage = localized("DHCP lease renewed")
        } completion: { completion?() }
    }

    private func run(_ command: String, prompt: String, onSuccess: @escaping @MainActor () -> Void, completion: @escaping @MainActor () -> Void) {
        isWorking = true
        errorMessage = nil
        statusMessage = nil
        runner.run(command, prompt: prompt) { result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isWorking = false
                switch result {
                case .success: onSuccess()
                case .failure(.cancelled): break
                case .failure(.failed(let message)): self.errorMessage = message
                }
                completion()
            }
        }
    }

    private func show(_ configuration: IPConfiguration) {
        method = configuration.method
        address = configuration.address
        subnetMask = configuration.subnetMask
        router = configuration.router
        dnsText = configuration.dnsServers.joined(separator: "\n")
        searchText = configuration.searchDomains.joined(separator: "\n")
    }

    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isNewline || $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

struct IPConfigurationEditorView: View {
    @ObservedObject var model: IPConfigurationEditorModel

    var body: some View {
        let errors = model.errors
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section(localized("Profiles")) {
                    IPProfileChips(model: model)
                }
                Section {
                Picker(localized("Configure IPv4"), selection: $model.method) {
                    ForEach(IPConfiguration.Method.allCases) { Text($0.title).tag($0) }
                }
                field(localized("IP Address"), text: $model.address, error: errors[.address], enabled: model.usesAddress)
                field(localized("Subnet Mask"), text: $model.subnetMask, error: errors[.subnetMask], enabled: model.usesSubnetAndRouter)
                field(localized("Router"), text: $model.router, error: errors[.router], enabled: model.usesSubnetAndRouter)
                list(localized("DNS Servers"), text: $model.dnsText, error: errors[.dnsServers], current: model.currentDNSServers)
                list(localized("Search Domains"), text: $model.searchText, error: errors[.searchDomains], current: model.currentSearchDomains)
                }
            }
            .formStyle(.grouped)

            Text(localized("Applies to the %@ service on all networks. Applying asks for an administrator password.", model.serviceName ?? model.bsdName))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)

            HStack(spacing: 8) {
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if let status = model.statusMessage {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
                if model.isWorking { ProgressView().controlSize(.small) }
                Button(localized("Renew DHCP Lease")) { model.renewLease() }
                    .disabled(!model.canRenewLease)
                Button(localized("Revert")) { model.revert() }
                    .disabled(!model.isDirty || model.isWorking)
                Button(localized("Apply")) { model.apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canApply)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 460)
    }

    private func field(_ title: String, text: Binding<String>, error: String?, enabled: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            TextField(title, text: text)
                .font(.system(.body, design: .monospaced))
                .disabled(!enabled)
            if enabled, let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func list(_ title: String, text: Binding<String>, error: String?, current: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .frame(height: 48)
                .scrollContentBackground(.hidden)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(IPConfigurationEditorView.inUseText(current))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(localized("One per line. Leave empty to use the values from DHCP."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(localized("One per line. Leave empty to use the values from DHCP."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func inUseText(_ values: [String]) -> String {
        localized("From DHCP: %@", values.isEmpty ? localized("None") : values.joined(separator: ", "))
    }
}

/// One reusable window per network interface.
@MainActor
final class IPConfigurationWindowController: NSWindowController {
    let model: IPConfigurationEditorModel

    init(model: IPConfigurationEditorModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: IPConfigurationEditorView(model: model))
        window.center()
        super.init(window: window)
        model.onApplied = { [weak self] in self?.close() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func present() {
        if !(window?.isVisible == true && model.isDirty) { model.load() }
        window?.title = localized("IP Configuration — %@", model.serviceName ?? model.bsdName)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The profile row: one chip per saved profile, plus a chip that turns into
/// a name field for saving. Right-click a profile to rename or delete it.
private struct IPProfileChips: View {
    @ObservedObject var model: IPConfigurationEditorModel

    private enum Editing: Equatable {
        case none
        case new
        case rename(UUID)
    }

    @State private var editing: Editing = .none
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChipFlowLayout(spacing: 6) {
                chip(title: localized("Current"), symbol: "arrow.uturn.backward", isSelected: model.selectedProfileID == nil, isActive: false) {
                    model.selectProfile(nil)
                }
                ForEach(model.serviceProfiles) { profile in
                    if editing == .rename(profile.id) {
                        nameField
                    } else {
                        chip(title: profile.name, symbol: nil, isSelected: model.selectedProfileID == profile.id,
                             isActive: model.activeProfileID == profile.id) {
                            model.selectProfile(profile.id)
                        }
                        .contextMenu {
                            Button(localized("Rename…")) { begin(.rename(profile.id), name: profile.name) }
                            Button(localized("Delete"), role: .destructive) { model.deleteProfile(profile.id) }
                        }
                    }
                }
                if editing == .new {
                    nameField
                } else {
                    saveChip
                }
            }
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private var hint: String? {
        if editing == .none, !model.errors.isEmpty { return localized("Fix the highlighted fields to save a profile.") }
        if model.serviceProfiles.isEmpty, editing == .none {
            return localized("Save these settings to switch to them later from the network card's right-click menu.")
        }
        return nil
    }

    private var saveChip: some View {
        Button { begin(.new, name: "") } label: {
            Label(localized("Save Profile"), systemImage: "plus")
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2])).foregroundStyle(.secondary))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!model.errors.isEmpty)
    }

    private var nameField: some View {
        HStack(spacing: 4) {
            TextField(localized("Profile name"), text: $name)
                .textFieldStyle(.plain)
                .font(.callout)
                .frame(width: 130)
                .focused($nameFocused)
                .onSubmit(commit)
                .onExitCommand { editing = .none }
            Button(action: commit) {
                if case .new = editing, model.profileNameExists(name) {
                    Text(localized("Replace")).font(.caption.weight(.semibold))
                } else {
                    Image(systemName: "checkmark")
                }
            }
            .buttonStyle(.borderless)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button { editing = .none } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(nsColor: .textBackgroundColor)))
        .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: 1))
    }

    private func chip(title: String, symbol: String?, isSelected: Bool, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isActive {
                    Circle().fill(.green).frame(width: 6, height: 6)
                        .accessibilityLabel(localized("In use"))
                }
                if let symbol { Image(systemName: symbol).imageScale(.small) }
                Text(title).lineLimit(1)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(Capsule().fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
            .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Color.primary.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func begin(_ mode: Editing, name: String) {
        self.name = name
        editing = mode
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch editing {
        case .new: model.saveProfile(named: trimmed)
        case .rename(let id): model.renameProfile(id, to: trimmed)
        case .none: break
        }
        editing = .none
    }
}

/// Lays chips out left to right and wraps them onto new lines.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let isFirst = rows[rows.count - 1].indices.isEmpty
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += isFirst ? size.width : size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

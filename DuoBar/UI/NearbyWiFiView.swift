import SwiftUI

struct NearbyWiFiButton: View {
    @ObservedObject var statusStore: SystemStatusStore
    let onOpenSettings: () -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            label
        }
        .buttonStyle(.plain)
        .popoverCardBackground(cornerRadius: PopoverDesign.cardCornerRadius, fillOpacity: 0.065)
        .accessibilityHint(localized("Browse nearby Wi-Fi networks"))
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            NearbyWiFiPopoverView(
                statusStore: statusStore,
                onOpenSettings: {
                    isPresented = false
                    onOpenSettings()
                }
            )
        }
    }

    /// DuoBar+: one larger row showing the current network; a click opens
    /// the network picker.
    private var label: some View {
        let network = statusStore.status.network
        let isConnectedWiFi = network.transport == .wifi && network.isConnected
        return HStack(spacing: 11) {
            IconTile(symbol: network.isWiFiPoweredOn == false ? "wifi.slash" : "wifi")
            VStack(alignment: .leading, spacing: 1) {
                Text(isConnectedWiFi ? NetworkStatusText.detail(for: network, hasPowerControlError: false) : localized("Wi-Fi"))
                    .font(PopoverDesign.titleFont)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isConnectedWiFi ? localized("Choose another network") : localized("Choose a network"))
                    .font(PopoverDesign.subtitleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            RowChevron()
        }
        .padding(.horizontal, PopoverDesign.horizontalPadding)
        .frame(height: PopoverDesign.rowHeight)
        .contentShape(Rectangle())
    }
}

struct NearbyWiFiPopoverView: View {
    let statusStore: SystemStatusStore
    let onOpenSettings: () -> Void

    @ObservedObject private var controller: NearbyWiFiController
    @State private var passwordNetwork: NearbyWiFiNetwork?
    @State private var password = ""

    init(statusStore: SystemStatusStore, onOpenSettings: @escaping () -> Void) {
        self.statusStore = statusStore
        self.onOpenSettings = onOpenSettings
        controller = statusStore.nearbyWiFiController
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
            settingsRow
        }
        .padding(12)
        .frame(width: 300)
        .task {
            await statusStore.scanNearbyWiFiIfNeeded()
        }
        .sheet(item: $passwordNetwork, onDismiss: clearPassword) { network in
            WiFiPasswordView(
                network: network,
                isJoining: controller.isBusy,
                errorMessage: joinError,
                password: $password,
                onCancel: {
                    passwordNetwork = nil
                },
                onJoin: {
                    let submittedPassword = password
                    password = ""
                    Task {
                        let joined = await statusStore.joinNearbyWiFi(network, password: submittedPassword)
                        if joined {
                            passwordNetwork = nil
                        }
                    }
                }
            )
        }
    }

    // DuoBar+: title with an icon refresh button instead of a footer button.
    private var header: some View {
        HStack(spacing: 8) {
            Text(localized("Nearby Networks"))
                .font(PopoverDesign.titleFont)
            Spacer()
            if controller.state == .scanning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(localized("Scanning…"))
            } else {
                Button {
                    Task { await statusStore.refreshNearbyWiFi() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.08), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .disabled(controller.isBusy || controller.isWiFiPoweredOn == false)
                .help(localized("Refresh"))
                .accessibilityLabel(localized("Refresh"))
            }
        }
        .padding(.horizontal, 4)
    }

    // DuoBar+: an action row in the popover style instead of a bordered button.
    private var settingsRow: some View {
        DetailActionRow(title: localized("Wi-Fi Settings…"), symbol: "gearshape", action: onOpenSettings)
            .focusable(false)
    }

    /// Current and known networks first, as in the macOS Wi-Fi menu.
    private var knownNetworks: [NearbyWiFiNetwork] {
        controller.networks.filter { $0.isCurrent || $0.isKnown }
    }

    private var otherNetworks: [NearbyWiFiNetwork] {
        controller.networks.filter { !$0.isCurrent && !$0.isKnown }
    }

    @ViewBuilder
    private var content: some View {
        if controller.isWiFiPoweredOn == false {
            message(localized("Wi-Fi is Off"), symbol: "wifi.slash")
        } else if controller.state == .scanning && controller.networks.isEmpty {
            message(localized("Scanning…"), symbol: "wifi")
        } else if case let .failure(error) = controller.state, controller.networks.isEmpty {
            message(error, symbol: "exclamationmark.triangle")
        } else if controller.networks.isEmpty {
            VStack(spacing: 8) {
                if locationAccessIsRestricted {
                    message(
                        localized("Location access is needed to show Wi-Fi network names."),
                        symbol: "location.slash"
                    )
                    Button(localized("Open System Settings…")) {
                        _ = SystemSettingsOpener.open(.privacy)
                    }
                    .controlSize(.small)
                } else {
                    message(localized("No Networks Found"), symbol: "wifi.slash")
                }
            }
        } else {
            FittingScrollView(maxHeight: 340) {
                VStack(alignment: .leading, spacing: 2) {
                    if !knownNetworks.isEmpty {
                        sectionTitle(localized("Known Networks"))
                        ForEach(knownNetworks) { networkButton($0) }
                    }
                    if !otherNetworks.isEmpty {
                        sectionTitle(localized("Other Networks"))
                            .padding(.top, knownNetworks.isEmpty ? 0 : 6)
                        ForEach(otherNetworks) { networkButton($0) }
                    }
                }
            }

            if case let .failure(error) = controller.state {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .padding(.horizontal, 4)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func message(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 76)
    }

    private func networkButton(_ network: NearbyWiFiNetwork) -> some View {
        Button {
            select(network)
        } label: {
            NearbyNetworkRowLabel(network: network, isJoining: isJoining(network))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(controller.isBusy && !network.isCurrent)
        .accessibilityLabel(network.ssid)
        .accessibilityValue(accessibilityValue(for: network))
        .accessibilityHint(network.isCurrent ? localized("Current Network") : localized("Join network"))
    }

    private func select(_ network: NearbyWiFiNetwork) {
        guard !network.isCurrent else { return }
        controller.clearTransientState()

        switch network.security {
        case .open:
            Task { _ = await statusStore.joinNearbyWiFi(network, password: nil) }
        case .personal:
            password = ""
            passwordNetwork = network
        case .enterprise, .unsupported:
            onOpenSettings()
        }
    }

    private func isJoining(_ network: NearbyWiFiNetwork) -> Bool {
        controller.state == .joining(networkID: network.id)
    }

    private var joinError: String? {
        guard case let .failure(message) = controller.state else { return nil }
        return message
    }

    private var locationAccessIsRestricted: Bool {
        let authorization = statusStore.wifiSSIDAuthorization
        return authorization == .denied || authorization == .restricted
    }

    private func accessibilityValue(for network: NearbyWiFiNetwork) -> String {
        let strength: String
        switch network.signalLevel {
        case .strong: strength = localized("Strong signal")
        case .medium: strength = localized("Medium signal")
        case .weak: strength = localized("Weak signal")
        case .disconnected, .disabled, .unavailable: strength = localized("Signal unavailable")
        }
        return network.isCurrent
            ? "\(localized("Current Network")), \(strength)"
            : strength
    }

    private func clearPassword() {
        password = ""
        controller.clearTransientState()
    }
}

private struct WiFiPasswordView: View {
    let network: NearbyWiFiNetwork
    let isJoining: Bool
    let errorMessage: String?
    @Binding var password: String
    let onCancel: () -> Void
    let onJoin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(network.ssid)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .lineLimit(1)

            SecureField(localized("Password"), text: $password)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(localized("Password"))
                .onSubmit {
                    if canJoin { onJoin() }
                }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
            }

            HStack {
                Button(localized("Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isJoining)
                Spacer()
                Button(localized("Join"), action: onJoin)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canJoin)
                if isJoining {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(localized("Joining…"))
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private var canJoin: Bool {
        !isJoining && !password.isEmpty
    }
}

/// One network in the Nearby Networks list, highlighted on hover. The
/// current network is emphasized rather than dimmed.
private struct NearbyNetworkRowLabel: View {
    let network: NearbyWiFiNetwork
    let isJoining: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: network.signalSymbolName, variableValue: network.signalSymbolVariableValue)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(network.isCurrent ? Color.accentColor : Color.primary)
                .frame(width: 20)
                .accessibilityHidden(true)

            Text(network.ssid)
                .font(.system(size: 12.5, weight: network.isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if let band = network.band {
                Text(band.text)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            if network.security != .open {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(localized("Secured network"))
            }

            Group {
                if network.isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel(localized("Current Network"))
                } else if isJoining {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel(localized("Joining…"))
                } else {
                    Color.clear
                }
            }
            .frame(width: 14)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovered && !network.isCurrent ? 0.08 : (network.isCurrent ? 0.05 : 0)))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

import CoreLocation
import Foundation

#if DEBUG
import Combine
#endif

enum SSIDAuthorizationState: String, Equatable, Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined

    init(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        @unknown default: self = .restricted
        }
    }

    #if DEBUG
    var diagnosticLabel: String {
        switch self {
        case .authorized: "Authorized"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not Determined"
        }
    }
    #endif
}

enum LocationRequestTrigger: String, Equatable, Sendable {
    case startup
    case appBecameActive
    case popoverOpened
    case settingsOpened
    case none

    #if DEBUG
    var diagnosticLabel: String {
        switch self {
        case .startup: "startup"
        case .appBecameActive: "app became active"
        case .popoverOpened: "popover opened"
        case .settingsOpened: "settings opened"
        case .none: "none"
        }
    }
    #endif
}

enum SSIDAccessAction: Equatable {
    case requestAuthorization(trigger: LocationRequestTrigger)
    case refresh
}

struct SSIDAccessCoordinator {
    private(set) var isWaitingForApplicationActivation = false
    private(set) var hasAttemptedAuthorizationRequest = false
    private(set) var hasIssuedAuthorizationRequest = false
    private(set) var wasAuthorizationRequestIssuedWhileActive = false
    private(set) var lastRequestTrigger: LocationRequestTrigger = .none

    mutating func requestAccess(
        authorization: SSIDAuthorizationState,
        applicationIsActive: Bool,
        trigger: LocationRequestTrigger
    ) -> [SSIDAccessAction] {
        switch authorization {
        case .authorized, .denied, .restricted:
            isWaitingForApplicationActivation = false
            return [.refresh]
        case .notDetermined:
            guard !hasIssuedAuthorizationRequest else { return [] }
            hasAttemptedAuthorizationRequest = true
            lastRequestTrigger = trigger
            guard applicationIsActive else {
                isWaitingForApplicationActivation = true
                return []
            }
            isWaitingForApplicationActivation = false
            hasIssuedAuthorizationRequest = true
            wasAuthorizationRequestIssuedWhileActive = true
            return [.requestAuthorization(trigger: trigger)]
        }
    }

    mutating func applicationDidBecomeActive(
        authorization: SSIDAuthorizationState
    ) -> [SSIDAccessAction] {
        guard isWaitingForApplicationActivation else { return [] }
        return requestAccess(
            authorization: authorization,
            applicationIsActive: true,
            trigger: .appBecameActive
        )
    }

    mutating func authorizationDidChange(
        to authorization: SSIDAuthorizationState
    ) -> [SSIDAccessAction] {
        if authorization != .notDetermined {
            isWaitingForApplicationActivation = false
            hasIssuedAuthorizationRequest = false
        }
        return [.refresh]
    }
}

enum SSIDValue {
    static func normalized(_ rawValue: String?) -> String? {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

enum NetworkRefreshReason: String, Sendable {
    case startup
    case pathChange
    case authorizationChange
    case wifiPowerChange
    case periodic
    case manual

    #if DEBUG
    var diagnosticLabel: String {
        switch self {
        case .startup: "startup"
        case .pathChange: "path change"
        case .authorizationChange: "authorization change"
        case .wifiPowerChange: "Wi-Fi power change"
        case .periodic: "periodic"
        case .manual: "manual"
        }
    }
    #endif
}

#if DEBUG
struct SSIDHardwareDiagnostic: Equatable, Sendable {
    var authorization: SSIDAuthorizationState
    var applicationIsActive: Bool
    var interfaceName: String?
    var isWiFiPoweredOn: Bool?
    var rawSSID: String?
    var networkStatusSSID: String?
    var pathDescription: String
    var rssi: Int?
    var refreshReason: NetworkRefreshReason
    var locationRequestAttempted: Bool
    var locationRequestIssuedWhileActive: Bool
    var lastLocationRequestTrigger: LocationRequestTrigger

    var copyableReport: String {
        [
            "Location authorization: \(authorization.diagnosticLabel)",
            "Application active: \(applicationIsActive ? "Yes" : "No")",
            "Wi-Fi interface: \(interfaceName ?? "unavailable")",
            "Wi-Fi power: \(isWiFiPoweredOn.map { $0 ? "On" : "Off" } ?? "Unavailable")",
            "CoreWLAN SSID raw result: \(rawSSID ?? "nil")",
            "NetworkStatus SSID: \(networkStatusSSID ?? "nil")",
            "NWPath: \(pathDescription)",
            "RSSI: \(rssi.map(String.init) ?? "unavailable")",
            "Last SSID refresh reason: \(refreshReason.diagnosticLabel)",
            "Location request attempted: \(locationRequestAttempted ? "Yes" : "No")",
            "Location request issued while active: \(locationRequestIssuedWhileActive ? "Yes" : "No")",
            "Last location request trigger: \(lastLocationRequestTrigger.diagnosticLabel)"
        ].joined(separator: "\n")
    }
}

extension Notification.Name {
    static let debugSSIDManualRefresh = Notification.Name("com.mikeli.duobar.debug-ssid-manual-refresh")
}

@MainActor
final class SSIDDiagnosticCenter: ObservableObject {
    static let shared = SSIDDiagnosticCenter()

    @Published private(set) var diagnostic: SSIDHardwareDiagnostic?

    private init() {}

    func update(_ diagnostic: SSIDHardwareDiagnostic) {
        self.diagnostic = diagnostic
    }

    func requestRefresh() {
        NotificationCenter.default.post(name: .debugSSIDManualRefresh, object: nil)
    }
}
#endif

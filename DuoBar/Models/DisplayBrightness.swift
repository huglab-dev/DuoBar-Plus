import CoreGraphics
import Foundation

enum DisplayBrightnessAvailability: Equatable, Sendable {
    case available(Double)
    case unavailable
}

struct MainDisplayDescriptor: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let vendorID: UInt32
    let productID: UInt32
    let serialNumber: UInt32

    var diagnosticLabel: String {
        "Display \(displayID) · \(vendorID):\(productID)"
    }
}

struct DisplayBrightnessSnapshot: Equatable, Sendable {
    let mainDisplay: MainDisplayDescriptor
    let availability: DisplayBrightnessAvailability
    let sampledAt: TimeInterval

    #if DEBUG
    /// DEBUG-only evidence for the public IOKit brightness-read pipeline.
    /// It never changes `availability`.
    let diagnostic: DisplayBrightnessDiagnostic?
    #endif

    #if DEBUG
    init(
        mainDisplay: MainDisplayDescriptor,
        availability: DisplayBrightnessAvailability,
        sampledAt: TimeInterval,
        diagnostic: DisplayBrightnessDiagnostic? = nil
    ) {
        self.mainDisplay = mainDisplay
        self.availability = availability
        self.sampledAt = sampledAt
        self.diagnostic = diagnostic
    }
    #else
    init(
        mainDisplay: MainDisplayDescriptor,
        availability: DisplayBrightnessAvailability,
        sampledAt: TimeInterval
    ) {
        self.mainDisplay = mainDisplay
        self.availability = availability
        self.sampledAt = sampledAt
    }
    #endif

    func isFresh(at timestamp: TimeInterval, maximumAge: TimeInterval) -> Bool {
        timestamp >= sampledAt && timestamp - sampledAt <= maximumAge
    }
}

#if DEBUG
enum DisplayBrightnessSource: String, Equatable, Sendable {
    case standard
    case linear
    case unavailable
}

enum DisplayBrightnessFailureStage: String, Equatable, Sendable {
    case mainDisplayMetadata
    case framebufferEnumeration
    case displayIdentityMatch
    case ambiguousDisplayMatch
    case displayServiceResolution
    case standardBrightnessRead
    case linearBrightnessRead
    case invalidBrightnessValue
    case none
}

enum DisplayBrightnessIdentitySelection: String, Equatable, Sendable {
    case uniqueMatch
    case ambiguousMatch
    case noMatch
}

struct DisplayBrightnessParameterDiagnostic: Equatable, Sendable {
    let attempted: Bool
    let ioReturn: Int32?
    let value: Double?
    let isValid: Bool

    static let notAttempted = DisplayBrightnessParameterDiagnostic(
        attempted: false,
        ioReturn: nil,
        value: nil,
        isValid: false
    )

    var reportValue: String {
        guard attempted else { return "not attempted" }
        let result = ioReturn.map { String(format: "0x%08X", UInt32(bitPattern: $0)) } ?? "none"
        let valueText = value.map { String(format: "%.4f", $0) } ?? "none"
        return "IOReturn \(result) · value \(valueText) · valid \(isValid ? "yes" : "no")"
    }
}

struct DisplayBrightnessFramebufferDiagnostic: Equatable, Sendable {
    let index: Int
    let vendorID: UInt32?
    let productID: UInt32?
    let serialNumber: UInt32?
    let metadataReadable: Bool
    let displayServiceResolved: Bool?
    let standardBrightness: DisplayBrightnessParameterDiagnostic
    let linearBrightness: DisplayBrightnessParameterDiagnostic
}

struct DisplayBrightnessDiagnostic: Equatable, Sendable {
    let mainDisplay: MainDisplayDescriptor
    let isBuiltIn: Bool
    let bounds: CGRect
    let framebufferCount: Int
    let framebufferCandidates: [DisplayBrightnessFramebufferDiagnostic]
    let vendorMatchCount: Int
    let vendorProductMatchCount: Int
    let vendorProductSerialMatchCount: Int?
    let selection: DisplayBrightnessIdentitySelection
    let identityFieldsUsed: String
    let selectedFramebufferIndex: Int?
    let displayServiceResolved: Bool?
    let standardBrightness: DisplayBrightnessParameterDiagnostic
    let linearBrightness: DisplayBrightnessParameterDiagnostic
    let source: DisplayBrightnessSource
    let value: Double?
    let failureStage: DisplayBrightnessFailureStage

    static func classifyFailure(
        framebufferCount: Int,
        mainDisplayMetadataIsUsable: Bool,
        selection: DisplayBrightnessIdentitySelection,
        displayServiceResolved: Bool?,
        standardBrightness: DisplayBrightnessParameterDiagnostic,
        linearBrightness: DisplayBrightnessParameterDiagnostic
    ) -> DisplayBrightnessFailureStage {
        guard framebufferCount > 0 else { return .framebufferEnumeration }
        guard mainDisplayMetadataIsUsable else { return .mainDisplayMetadata }
        switch selection {
        case .noMatch: return .displayIdentityMatch
        case .ambiguousMatch: return .ambiguousDisplayMatch
        case .uniqueMatch: break
        }
        guard displayServiceResolved == true else { return .displayServiceResolution }
        if (standardBrightness.attempted && standardBrightness.ioReturn == 0 && !standardBrightness.isValid)
            || (linearBrightness.attempted && linearBrightness.ioReturn == 0 && !linearBrightness.isValid) {
            return .invalidBrightnessValue
        }
        if standardBrightness.attempted && standardBrightness.ioReturn != 0 {
            return .standardBrightnessRead
        }
        return .linearBrightnessRead
    }

    static func resolvedSource(
        availability: DisplayBrightnessAvailability,
        standardBrightness: DisplayBrightnessParameterDiagnostic,
        linearBrightness: DisplayBrightnessParameterDiagnostic
    ) -> DisplayBrightnessSource {
        guard case .available = availability else { return .unavailable }
        return standardBrightness.isValid ? .standard : linearBrightness.isValid ? .linear : .unavailable
    }

    var copyableReport: String {
        let serialUsable = mainDisplay.serialNumber != 0
        let boundsText = String(
            format: "%.0f×%.0f at %.0f,%.0f",
            bounds.width,
            bounds.height,
            bounds.origin.x,
            bounds.origin.y
        )
        let serialMatches = vendorProductSerialMatchCount.map(String.init) ?? "not usable"
        let candidateLines = framebufferCandidates.map { candidate in
            let vendor = candidate.vendorID.map(String.init) ?? "unavailable"
            let product = candidate.productID.map(String.init) ?? "unavailable"
            let serial = candidate.serialNumber.map(String.init) ?? "unavailable"
            return "  [\(candidate.index)] metadata \(candidate.metadataReadable ? "yes" : "no") · vendor \(vendor) · product \(product) · serial \(serial)"
        }.joined(separator: "\n")

        return """
        Main display
        Built-in: \(isBuiltIn ? "Yes" : "No") · ID: \(mainDisplay.displayID)
        Vendor: \(mainDisplay.vendorID) · Product: \(mainDisplay.productID) · Serial: \(mainDisplay.serialNumber) · Serial usable: \(serialUsable ? "Yes" : "No")
        Bounds: \(boundsText)

        IOFramebuffer candidates: \(framebufferCount)
        \(candidateLines.isEmpty ? "  none" : candidateLines)

        Identity match
        Vendor: \(vendorMatchCount) · Vendor + Product: \(vendorProductMatchCount) · Vendor + Product + Serial: \(serialMatches)
        Result: \(selection.rawValue) · Fields used: \(identityFieldsUsed) · Selected framebuffer: \(selectedFramebufferIndex.map(String.init) ?? "none")

        IODisplayForFramebuffer: \(displayServiceResolved == true ? "Success" : displayServiceResolved == false ? "Failure" : "not attempted")
        brightness: \(standardBrightness.reportValue)
        linear-brightness: \(linearBrightness.reportValue)

        Final: \(source.rawValue)\(value.map { String(format: " · %.4f", $0) } ?? "")
        Failure stage: \(failureStage.rawValue)
        """
    }
}
#endif

struct DisplayHardwareIdentity: Equatable, Sendable {
    let vendorID: UInt32
    let productID: UInt32
    let serialNumber: UInt32

    func matches(_ display: MainDisplayDescriptor) -> Bool {
        guard vendorID == display.vendorID, productID == display.productID else { return false }
        return display.serialNumber == 0 || serialNumber == 0 || serialNumber == display.serialNumber
    }

    static func uniqueMatchIndex(
        for display: MainDisplayDescriptor,
        candidates: [DisplayHardwareIdentity]
    ) -> Int? {
        let matches = candidates.indices.filter { candidates[$0].matches(display) }
        return matches.count == 1 ? matches[0] : nil
    }
}

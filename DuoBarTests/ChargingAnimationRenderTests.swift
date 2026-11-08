import AppKit
import SwiftUI
import XCTest
@testable import DuoBar

final class ChargingAnimationRenderTests: XCTestCase {
    @MainActor
    func testRenderMeasuredChargingStages() throws {
        let stages = [
            Stage(label: "0%", frameIndex: 112, elapsed: 1.0 / 60.0),
            Stage(label: "25%", frameIndex: 119, elapsed: 0.125),
            Stage(label: "50%", frameIndex: 125, elapsed: 0.225),
            Stage(label: "75%", frameIndex: 132, elapsed: 0.342),
            Stage(label: "100%", frameIndex: 172, elapsed: 1.015)
        ]

        let production = HStack(spacing: 14) {
            ForEach(stages) { stage in
                VStack(spacing: 8) {
                    self.productionGlyph(stage)
                    Text(stage.label)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(16)
        .background(Color.black)
        .environment(\.colorScheme, .dark)

        try write(production, to: "/tmp/DuoBar-1.2-Charging-Production-Stages.png")

        if let referenceDirectory = ProcessInfo.processInfo.environment["DUOBAR_CHARGING_REFERENCE_DIR"] {
            let comparisons = HStack(spacing: 14) {
                ForEach(stages) { stage in
                    VStack(spacing: 8) {
                        self.referenceFrame(directory: referenceDirectory, index: stage.frameIndex)
                        self.productionGlyph(stage)
                        Text(stage.label)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(16)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
            try write(comparisons, to: "/tmp/DuoBar-1.2-Charging-Reference-Comparison.png")
        }

        try write(
            productionGlyph(stages[3])
                .padding(30)
                .background(Color.black)
                .environment(\.colorScheme, .dark),
            to: "/tmp/DuoBar-1.2-Charging-1.00.png"
        )
    }

    @MainActor
    func testRenderFinalChargingSemanticMatrix() throws {
        let cases = [
            RenderCase(label: "50% Unplugged", percentage: 50, plugged: false, full: false, lowPower: false, colorCoding: true),
            RenderCase(label: "50% Plugged / On", percentage: 50, plugged: true, full: false, lowPower: false, colorCoding: true),
            RenderCase(label: "50% Plugged / Off", percentage: 50, plugged: true, full: false, lowPower: false, colorCoding: false),
            RenderCase(label: "15% Plugged + LPM", percentage: 15, plugged: true, full: false, lowPower: true, colorCoding: true),
            RenderCase(label: "100% Plugged / On", percentage: 100, plugged: true, full: true, lowPower: false, colorCoding: true),
            RenderCase(label: "100% Plugged / Off", percentage: 100, plugged: true, full: true, lowPower: false, colorCoding: false)
        ]
        let matrix = HStack(spacing: 14) {
            ForEach(cases) { item in
                VStack(spacing: 8) {
                    self.semanticGlyph(item)
                    Text(item.label)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(16)
        .background(Color.black)
        .environment(\.colorScheme, .dark)

        try write(matrix, to: "/tmp/DuoBar-1.2-Charging-Final-QA.png")
    }

    @MainActor
    private func productionGlyph(_ stage: Stage) -> some View {
        let snapshot = BatteryChargingAnimationProfile.entranceSnapshot(elapsed: stage.elapsed)
        let battery = BatteryStatus(
            percentage: 50,
            isCharging: true,
            isPluggedIn: true,
            isFullyCharged: false,
            isAvailable: true
        )
        let presentation = DuoPersistentRingPresentation(
            mode: .battery,
            progress: 0.5,
            opacity: 1,
            batteryPresentation: BatteryRingPresentation(
                boltPlacement: .topGap,
                colorRole: .charging
            )
        )
        return DuoGlyphView(
            status: status(battery: battery),
            metrics: DuoGlyphMetrics.standard.sized(200),
            animationsEnabled: false,
            ringPresentation: presentation,
            batteryColorCodingEnabled: true,
            chargingBoltProgressOverride: snapshot.boltProgress,
            chargingTrackProgressOverride: snapshot.trackProgress,
            chargingColorMixOverride: snapshot.colorMix
        )
        .frame(width: 240, height: 240)
    }

    @MainActor
    private func semanticGlyph(_ item: RenderCase) -> some View {
        let battery = BatteryStatus(
            percentage: item.percentage,
            isCharging: item.plugged && !item.full,
            isPluggedIn: item.plugged,
            isFullyCharged: item.full,
            isAvailable: true,
            isLowPowerModeEnabled: item.lowPower
        )
        return DuoGlyphView(
            status: status(battery: battery),
            metrics: DuoGlyphMetrics.standard.sized(160),
            animationsEnabled: false,
            batteryColorCodingEnabled: item.colorCoding
        )
        .frame(width: 190, height: 190)
    }

    @ViewBuilder
    private func referenceFrame(directory: String, index: Int) -> some View {
        let prefix = String(format: "frame-%04d-", index)
        let directoryURL = URL(fileURLWithPath: directory)
        let url = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix(prefix) }
        if let url, let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 240, height: 240)
        } else {
            Color.red.frame(width: 240, height: 240)
        }
    }

    @MainActor
    private func write<V: View>(_ view: V, to path: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let representation = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        XCTAssertGreaterThan(png.count, 1_000)
    }

    private func status(battery: BatteryStatus) -> SystemStatus {
        SystemStatus(
            battery: battery,
            network: NetworkStatus(
                isAvailable: true,
                isConnected: true,
                transport: .wifi,
                interfaceName: "en0",
                isWiFiPoweredOn: true,
                ssid: "Test",
                rssi: -42
            ),
            audio: AudioStatus(
                isAvailable: true,
                defaultOutput: nil,
                volume: OutputVolumeStatus(level: 1, isMuted: false, isSettable: true),
                connectedBluetoothOutputs: []
            ),
            bluetooth: .unavailable
        )
    }
}

private struct RenderCase: Identifiable {
    let label: String
    let percentage: Int
    let plugged: Bool
    let full: Bool
    let lowPower: Bool
    let colorCoding: Bool
    var id: String { label }
}

private struct Stage: Identifiable {
    let label: String
    let frameIndex: Int
    let elapsed: TimeInterval
    var id: Int { frameIndex }
}

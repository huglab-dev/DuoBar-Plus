import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import DuoBar

final class AudioConnectionTransitionRenderTests: XCTestCase {
    @MainActor
    func testRenderAudioConnectionTransitionStoryboard() throws {
        let stages = [
            Stage(name: "Network", outgoing: nil, incoming: .wifi(.strong), progress: 1, pulse: 1),
            Stage(name: "Fade in", outgoing: .wifi(.strong), incoming: .airPodsPro, progress: 0.5, pulse: 1),
            Stage(name: "AirPods Pro", outgoing: nil, incoming: .airPodsPro, progress: 1, pulse: 1),
            Stage(name: "Pulse", outgoing: nil, incoming: .airPodsPro, progress: 1, pulse: 1.055),
            Stage(name: "Hold", outgoing: nil, incoming: .airPodsPro, progress: 1, pulse: 1),
            Stage(name: "Fade back", outgoing: .airPodsPro, incoming: .wifi(.strong), progress: 0.5, pulse: 1),
            Stage(name: "Network", outgoing: nil, incoming: .wifi(.strong), progress: 1, pulse: 1)
        ]

        let storyboard = HStack(alignment: .top, spacing: 16) {
            ForEach(stages) { stage in
                VStack(spacing: 8) {
                    self.transitionFrame(
                        stage,
                        batteryProgress: 0.75,
                        batteryArcOpacity: 1,
                        volumeDots: 3
                    )
                    Text(stage.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: 104)
            }
        }
        .padding(18)
        .background(Color.black)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: storyboard)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let representation = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuoBar-Audio-Transition-Storyboard.png")
        try png.write(to: outputURL, options: .atomic)
        XCTAssertGreaterThan(png.count, 1_000)
    }

    @MainActor
    func testRecordWiFiAirPodsWiFiTransition() throws {
        try recordTransition(
            networkState: .wifi(.strong),
            audioState: .airPodsPro,
            batteryProgress: 0.75,
            batteryArcOpacity: 1,
            volumeDots: 3,
            named: "DuoBar-WiFi-AirPodsPro-WiFi.mp4"
        )
    }

    @MainActor
    func testRecordCurrentAirPodsProTransition() throws {
        guard ProcessInfo.processInfo.environment["DUOBAR_HARDWARE_VALIDATION"] == "1" else {
            throw XCTSkip("Enable explicit real-hardware validation with DUOBAR_HARDWARE_VALIDATION=1")
        }

        let service = AudioOutputService()
        let batteryService = BatteryService()
        let networkService = NetworkService()
        var latest: AudioStatus?
        var battery: BatteryStatus?
        var network: NetworkStatus?
        service.onStatusChange = { latest = $0 }
        batteryService.onStatusChange = { battery = $0 }
        networkService.onStatusChange = { network = $0 }
        service.start()
        batteryService.start()
        networkService.start()
        let audio = try XCTUnwrap(latest)
        let output = try XCTUnwrap(latest?.defaultOutput)
        guard output.transport.isBluetooth else {
            throw XCTSkip("The current default output is not a Bluetooth audio endpoint")
        }
        XCTAssertEqual(output.temporaryConnectionGlyph, .airPodsPro)

        let actualStatus = SystemStatus(
            battery: try XCTUnwrap(battery),
            network: try XCTUnwrap(network),
            audio: audio,
            bluetooth: .unavailable
        )
        let actualGlyph = DuoGlyphState(status: actualStatus)

        try recordTransition(
            networkState: actualGlyph.centerState,
            audioState: centerState(for: output.temporaryConnectionGlyph),
            batteryProgress: actualGlyph.batteryProgress,
            batteryArcOpacity: actualGlyph.batteryArcOpacity,
            volumeDots: actualGlyph.volumeActiveDotCount,
            named: "DuoBar-Actual-WiFi-AirPodsPro-WiFi.mp4"
        )
    }

    @MainActor
    private func recordTransition(
        networkState: DuoCenterState,
        audioState: DuoCenterState,
        batteryProgress: Double,
        batteryArcOpacity: Double,
        volumeDots: Int?,
        named fileName: String
    ) throws {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: outputURL)

        let width = 640
        let height = 360
        let framesPerSecond: Int32 = 60
        let frameCount = 102
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frameIndex in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.002))
            }

            let seconds = Double(frameIndex) / Double(framesPerSecond)
            let frame = try renderVideoFrame(
                at: seconds,
                networkState: networkState,
                audioState: audioState,
                batteryProgress: batteryProgress,
                batteryArcOpacity: batteryArcOpacity,
                volumeDots: volumeDots,
                width: width,
                height: height
            )
            let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: framesPerSecond)
            XCTAssertTrue(adaptor.append(frame, withPresentationTime: presentationTime))
        }

        input.markAsFinished()
        let completion = expectation(description: "video writer")
        writer.finishWriting { completion.fulfill() }
        wait(for: [completion], timeout: 10)
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "Unknown video writer error")
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        XCTAssertGreaterThan(attributes[.size] as? Int ?? 0, 10_000)
    }

    private func transitionFrame(
        _ stage: Stage,
        batteryProgress: Double,
        batteryArcOpacity: Double,
        volumeDots: Int?
    ) -> some View {
        let metrics = DuoGlyphMetrics.standard.sized(76)
        return ZStack {
            DuoArcShape(
                startDegrees: metrics.arcStartDegrees,
                endDegrees: metrics.arcEndDegrees,
                progress: batteryProgress
            )
            .stroke(
                Color.primary,
                style: StrokeStyle(
                    lineWidth: metrics.ringLineWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: metrics.ringDiameter, height: metrics.ringDiameter)
            .offset(y: metrics.ringYOffset)
            .opacity(batteryArcOpacity)

            DuoCenterTransitionLayer(
                outgoingState: stage.outgoing,
                incomingState: stage.incoming,
                progress: stage.progress,
                pulseScale: stage.pulse,
                size: metrics.wifiSymbolSize,
                usesSpatialMotion: true
            )
            .offset(y: metrics.wifiYOffset)

            DuoDotRow(
                activeCount: volumeDots,
                diameter: metrics.dotDiameter,
                ringDiameter: metrics.ringDiameter,
                rowCenterYOffset: metrics.dotYOffset,
                animationsEnabled: false
            )
        }
        .frame(width: DuoGlyphMetrics.canvasSize, height: DuoGlyphMetrics.canvasSize)
        .scaleEffect(metrics.overallSize / DuoGlyphMetrics.canvasSize)
        .frame(width: metrics.overallSize, height: metrics.overallSize)
    }

    @MainActor
    private func renderVideoFrame(
        at seconds: Double,
        networkState: DuoCenterState,
        audioState: DuoCenterState,
        batteryProgress: Double,
        batteryArcOpacity: Double,
        volumeDots: Int?,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        let transitionDuration = 0.25
        let eventReturnTime = 1.45
        let stage: Stage

        if seconds < transitionDuration {
            let progress = eased(seconds / transitionDuration)
            stage = Stage(name: "", outgoing: networkState, incoming: audioState, progress: progress, pulse: pulse(at: seconds))
        } else if seconds < eventReturnTime {
            stage = Stage(name: "", outgoing: nil, incoming: audioState, progress: 1, pulse: pulse(at: seconds))
        } else {
            let progress = eased(min((seconds - eventReturnTime) / transitionDuration, 1))
            stage = Stage(name: "", outgoing: audioState, incoming: networkState, progress: progress, pulse: 1)
        }

        let content = transitionFrame(
            stage,
            batteryProgress: batteryProgress,
            batteryArcOpacity: batteryArcOpacity,
            volumeDots: volumeDots
        )
            .frame(width: CGFloat(width), height: CGFloat(height))
            .background(Color.black)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let context = try XCTUnwrap(
            CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private func eased(_ value: Double) -> CGFloat {
        let clamped = min(max(value, 0), 1)
        return CGFloat(clamped * clamped * (3 - 2 * clamped))
    }

    private func pulse(at seconds: Double) -> CGFloat {
        switch seconds {
        case 0.26..<0.36:
            1 + CGFloat((seconds - 0.26) / 0.1) * 0.055
        case 0.36..<0.56:
            1.055 - CGFloat((seconds - 0.36) / 0.2) * 0.055
        default:
            1
        }
    }

    private func centerState(for glyph: AudioConnectionGlyph) -> DuoCenterState {
        switch glyph {
        case .airPodsPro: .airPodsPro
        case .airPodsMax: .airPodsMax
        case .airPods: .airPods
        case .headphones: .headphones
        case .audioDevice: .audioDevice
        }
    }
}

private struct Stage: Identifiable {
    let name: String
    let outgoing: DuoCenterState?
    let incoming: DuoCenterState
    let progress: CGFloat
    let pulse: CGFloat
    let id = UUID()
}

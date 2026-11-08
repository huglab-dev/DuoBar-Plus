import AppKit
import SwiftUI
import XCTest
@testable import DuoBar

@MainActor
final class AudioRowRenderTests: XCTestCase {
    func testRenderAudioRowsWithSelectedDevice() throws {
        let view = VStack(spacing: 8) {
            AudioOutputRow(
                symbol: "speaker.wave.2", title: localized("Audio Output"), detail: "MacBook Pro Speakers",
                stateText: localized("Built-in"), outputs: [], selectedUID: nil,
                onSelect: { _ in true }, onOpenSoundSettings: {}, onOpenBluetoothSettings: {}
            )
            AudioOutputRow(
                symbol: "mic", title: localized("Audio Input"), detail: "MacBook Pro Microphone",
                stateText: localized("Built-in"), outputs: [], selectedUID: nil,
                onSelect: { _ in true }, onOpenSoundSettings: {}, onOpenBluetoothSettings: {}
            )
        }
        .padding(12)
        .frame(width: 304)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)
        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("DuoBarPlus-AudioRows.png"), options: .atomic)
    }
}

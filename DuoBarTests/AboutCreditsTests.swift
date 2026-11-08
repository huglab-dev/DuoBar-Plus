import AppKit
import SwiftUI
import XCTest
@testable import DuoBar

@MainActor
final class AboutCreditsTests: XCTestCase {
    func testLicenseShipsInTheAppWithTheRequiredNotices() throws {
        let text = try XCTUnwrap(AppLicense.text())
        XCTAssertTrue(text.contains("Copyright (c) 2026 Mike Li"))
        XCTAssertTrue(text.contains("Permission is hereby granted, free of charge"))
        XCTAssertTrue(text.contains("shall be included in all"))
        XCTAssertTrue(text.contains("THE SOFTWARE IS PROVIDED \"AS IS\""))
    }

    func testReflowKeepsEveryWordAndParagraph() throws {
        let text = try XCTUnwrap(AppLicense.text())
        let reflowed = AppLicense.reflowed(text)
        XCTAssertEqual(reflowed.split(whereSeparator: \.isWhitespace), text.split(whereSeparator: \.isWhitespace))
        XCTAssertEqual(AppLicense.reflowed("a\nb\n\nc\n"), "a b\n\nc")
    }

    func testLogoIsInTheAssetCatalog() {
        XCTAssertNotNil(NSImage(named: "HuglabWordmark"))
    }

    func testRenderCredits() throws {
        try render(.aqua, scheme: .light, background: .white, name: "DuoBarPlus-Credits-light.png")
        try render(.darkAqua, scheme: .dark, background: Color(white: 0.16), name: "DuoBarPlus-Credits-dark.png")
    }

    private func render(_ appearance: NSAppearance.Name, scheme: ColorScheme, background: Color, name: String) throws {
        let view = Form {
            Section(localized("Developer")) {
                AboutCreditsView(showsLicense: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 560)
        .background(background)
        .environment(\.colorScheme, scheme)
        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = NSAppearance(named: appearance)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 560)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(name), options: .atomic)
    }
}

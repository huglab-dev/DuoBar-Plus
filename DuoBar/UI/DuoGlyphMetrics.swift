import CoreGraphics

struct DuoGlyphMetrics: Equatable {
    static let standard = DuoGlyphMetrics(
        // DuoBar+: the user's tuned values (Duo Glyph Tuning, 8 nov 2026).
        overallSize: 24,
        ringDiameter: 28,
        ringLineWidth: 3,
        arcGap: 140,
        wifiSymbolSize: 12.4,
        wifiYOffset: -1.25,
        dotDiameter: 2.4,
        dotSpacing: 5,
        dotYOffset: 7.495652174
    )

    static let canvasSize: CGFloat = 32
    static let menuBarVerticalOffset: CGFloat = 1
    // Ring stroke / outer ring diameter. DuoBar+: measured from the reference
    // mark the user supplied (upstream used 0.076378 from product photography).
    static let referenceArcStrokeRatio: CGFloat = 0.106
    private static let priorArcStrokeRatio: CGFloat = 2.8 / 26.5

    var overallSize: CGFloat
    var ringDiameter: CGFloat
    var ringLineWidth: CGFloat
    var arcGap: Double
    var wifiSymbolSize: CGFloat
    var wifiYOffset: CGFloat
    var dotDiameter: CGFloat
    var dotSpacing: CGFloat
    /// Legacy tuning value: the dots are now placed from the ring centre (see `DuoVolumeIndicatorGeometry`).
    var dotYOffset: CGFloat

    var ringYOffset: CGFloat = -0.8
    var statusItemHorizontalPadding: CGFloat = 3
    /// DuoBar+: user setting "Ring Thickness" (1 = the reference proportion).
    var ringThicknessScale: CGFloat = 1
    /// DuoBar+: user setting "Center Size" (1 = the reference size).
    var centerScale: CGFloat = 1

    var arcLineWidth: CGFloat {
        ringLineWidth * Self.referenceArcStrokeRatio / Self.priorArcStrokeRatio * ringThicknessScale
    }

    func withRingThickness(_ scale: Double) -> DuoGlyphMetrics {
        var copy = self
        copy.ringThicknessScale = CGFloat(RingThickness.resolve(scale))
        return copy
    }
    func withCenterScale(_ scale: Double) -> DuoGlyphMetrics {
        var copy = self
        copy.centerScale = CGFloat(CenterIconSize.resolve(scale))
        return copy
    }

    var ringPathDiameter: CGFloat { max(0, ringDiameter - arcLineWidth) }
    var arcStartDegrees: Double { 90 + arcGap / 2 }
    var arcEndDegrees: Double { 450 - arcGap / 2 }
    var statusItemWidth: CGFloat {
        max(MenuBarIconSize.minimumStatusItemWidth, overallSize + statusItemHorizontalPadding)
    }

    func sized(_ size: CGFloat) -> DuoGlyphMetrics {
        var copy = self
        copy.overallSize = size
        return copy
    }

    func scaled(by rawScale: Double) -> DuoGlyphMetrics {
        let scale = CGFloat(MenuBarIconSize.resolve(rawScale))
        var copy = self
        copy.overallSize *= scale
        copy.ringDiameter *= scale
        copy.ringLineWidth *= scale
        copy.wifiSymbolSize *= scale
        copy.wifiYOffset *= scale
        copy.dotDiameter *= scale
        copy.dotSpacing *= scale
        copy.dotYOffset *= scale
        copy.ringYOffset *= scale
        copy.statusItemHorizontalPadding *= scale
        return copy
    }
}

#if DEBUG
enum DuoGlyphTuningKeys {
    static let overallSize = "debug.duoGlyph.overallSize"
    static let ringDiameter = "debug.duoGlyph.ringDiameter"
    static let ringLineWidth = "debug.duoGlyph.ringLineWidth"
    static let arcGap = "debug.duoGlyph.arcGap"
    static let wifiSymbolSize = "debug.duoGlyph.wifiSymbolSize"
    static let wifiYOffset = "debug.duoGlyph.wifiYOffset"
    static let dotDiameter = "debug.duoGlyph.dotDiameter"
    static let dotSpacing = "debug.duoGlyph.dotSpacing"
    static let dotYOffset = "debug.duoGlyph.dotYOffset"
}
#endif

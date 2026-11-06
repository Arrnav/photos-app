import CoreGraphics
import Foundation

/// Everything an edit changes, kept as parameters (non-destructive): it is stored with
/// the edit, so reopening the editor continues from the original.
struct EditState: Codable, Equatable, Sendable {
    /// Adjust tool values, each -1…1 (0 = unchanged). Auto is on/off.
    var adjustments: [Adjustment: Double] = [:]
    var auto = false
    var filter: Filter = .original
    /// Crop rectangle in unit coordinates of the straightened image (0…1, origin top-left).
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Straighten in degrees (-45…45); perspective -1…1.
    var straighten: Double = 0
    var vertical: Double = 0
    var horizontal: Double = 0
    /// Quarter turns counter-clockwise, and a horizontal flip.
    var quarterTurns = 0
    var flipped = false
    /// Video only.
    var trimStart: Double = 0
    var trimEnd: Double?
    var muted = false
    var audioMix: AudioMix = .standard

    enum Adjustment: String, Codable, CaseIterable, Sendable {
        case exposure, brilliance, highlights, shadows, contrast, brightness, blackPoint
        case saturation, vibrance, warmth, tint, sharpness, definition, noiseReduction, vignette

        var title: String {
            switch self {
            case .exposure: String(localized: "Exposure")
            case .brilliance: String(localized: "Brilliance")
            case .highlights: String(localized: "Highlights")
            case .shadows: String(localized: "Shadows")
            case .contrast: String(localized: "Contrast")
            case .brightness: String(localized: "Brightness")
            case .blackPoint: String(localized: "Black Point")
            case .saturation: String(localized: "Saturation")
            case .vibrance: String(localized: "Vibrance")
            case .warmth: String(localized: "Warmth")
            case .tint: String(localized: "Tint")
            case .sharpness: String(localized: "Sharpness")
            case .definition: String(localized: "Definition")
            case .noiseReduction: String(localized: "Noise Reduction")
            case .vignette: String(localized: "Vignette")
            }
        }

        var symbol: String {
            switch self {
            case .exposure: "plusminus.circle"
            case .brilliance: "circle.lefthalf.filled"
            case .highlights: "circle.lefthalf.striped.horizontal"
            case .shadows: "circle.righthalf.filled"
            case .contrast: "circle.lefthalf.filled.righthalf.striped.horizontal"
            case .brightness: "sun.max"
            case .blackPoint: "circle.fill"
            case .saturation: "drop.halffull"
            case .vibrance: "triangle.lefthalf.filled"
            case .warmth: "thermometer.medium"
            case .tint: "eyedropper.halffull"
            case .sharpness: "triangle"
            case .definition: "rhombus"
            case .noiseReduction: "circle.dotted"
            case .vignette: "circle.dashed"
            }
        }

        /// Sharpness, definition and noise reduction only go up.
        var allowsNegative: Bool { ![.sharpness, .definition, .noiseReduction].contains(self) }
    }

    enum Filter: String, Codable, CaseIterable, Sendable {
        case original, vivid, vividWarm, vividCool, dramatic, dramaticWarm, dramaticCool, mono, silvertone, noir

        var title: String {
            switch self {
            case .original: String(localized: "ORIGINAL")
            case .vivid: String(localized: "VIVID")
            case .vividWarm: String(localized: "VIVID WARM")
            case .vividCool: String(localized: "VIVID COOL")
            case .dramatic: String(localized: "DRAMATIC")
            case .dramaticWarm: String(localized: "DRAMATIC WARM")
            case .dramaticCool: String(localized: "DRAMATIC COOL")
            case .mono: String(localized: "MONO")
            case .silvertone: String(localized: "SILVERTONE")
            case .noir: String(localized: "NOIR")
            }
        }
    }

    enum AudioMix: String, Codable, CaseIterable, Sendable {
        case standard, inFrame, studio, cinematic

        var title: String {
            switch self {
            case .standard: String(localized: "STANDARD")
            case .inFrame: String(localized: "IN-FRAME")
            case .studio: String(localized: "STUDIO")
            case .cinematic: String(localized: "CINEMATIC")
            }
        }
    }

    var isIdentity: Bool { self == EditState() }

    /// Changes only crop / rotate / flip (the kinds a Cloud server can apply itself).
    var isGeometryOnly: Bool {
        var geometry = EditState()
        geometry.crop = crop
        geometry.quarterTurns = quarterTurns
        geometry.flipped = flipped
        return self == geometry && straighten == 0 && vertical == 0 && horizontal == 0
    }

    var hasVisualChanges: Bool {
        var visual = self
        visual.trimStart = 0
        visual.trimEnd = nil
        visual.muted = false
        visual.audioMix = .standard
        return !visual.isIdentity
    }

    func value(_ adjustment: Adjustment) -> Double { adjustments[adjustment] ?? 0 }

    // Codable for [Adjustment: Double] with string keys.
    enum CodingKeys: String, CodingKey {
        case adjustments, auto, filter, crop, straighten, vertical, horizontal, quarterTurns, flipped, trimStart, trimEnd, muted, audioMix
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([String: Double].self, forKey: .adjustments) ?? [:]
        adjustments = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in Adjustment(rawValue: key).map { ($0, value) } })
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? false
        filter = try c.decodeIfPresent(Filter.self, forKey: .filter) ?? .original
        crop = try c.decodeIfPresent(CGRect.self, forKey: .crop) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        straighten = try c.decodeIfPresent(Double.self, forKey: .straighten) ?? 0
        vertical = try c.decodeIfPresent(Double.self, forKey: .vertical) ?? 0
        horizontal = try c.decodeIfPresent(Double.self, forKey: .horizontal) ?? 0
        quarterTurns = try c.decodeIfPresent(Int.self, forKey: .quarterTurns) ?? 0
        flipped = try c.decodeIfPresent(Bool.self, forKey: .flipped) ?? false
        trimStart = try c.decodeIfPresent(Double.self, forKey: .trimStart) ?? 0
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        audioMix = try c.decodeIfPresent(AudioMix.self, forKey: .audioMix) ?? .standard
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Dictionary(uniqueKeysWithValues: adjustments.map { ($0.key.rawValue, $0.value) }), forKey: .adjustments)
        try c.encode(auto, forKey: .auto)
        try c.encode(filter, forKey: .filter)
        try c.encode(crop, forKey: .crop)
        try c.encode(straighten, forKey: .straighten)
        try c.encode(vertical, forKey: .vertical)
        try c.encode(horizontal, forKey: .horizontal)
        try c.encode(quarterTurns, forKey: .quarterTurns)
        try c.encode(flipped, forKey: .flipped)
        try c.encode(trimStart, forKey: .trimStart)
        try c.encodeIfPresent(trimEnd, forKey: .trimEnd)
        try c.encode(muted, forKey: .muted)
        try c.encode(audioMix, forKey: .audioMix)
    }
}

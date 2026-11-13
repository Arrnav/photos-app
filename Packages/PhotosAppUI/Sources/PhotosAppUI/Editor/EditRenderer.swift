import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Applies an `EditState` to an image with Core Image, in extended range, so HDR highlights
/// survive (the result is written back with its gain map). The same pipeline renders the
/// live preview, video frames (via a video composition) and the saved file.
enum EditRenderer {
    static func apply(_ state: EditState, to input: CIImage, autoFilters: [CIFilter] = []) -> CIImage {
        var image = input
        // Auto first (Core Image's analysis of the photo), then the tools, then the filter.
        if state.auto {
            for filter in autoFilters {
                filter.setValue(image, forKey: kCIInputImageKey)
                if let output = filter.outputImage { image = output }
            }
        }
        image = adjust(image, state)
        image = filter(image, state.filter)
        image = geometry(image, state)
        return image
    }

    private static func adjust(_ input: CIImage, _ state: EditState) -> CIImage {
        var image = input
        let v = state.value
        if v(.exposure) != 0 {
            let f = CIFilter.exposureAdjust(); f.inputImage = image; f.ev = Float(v(.exposure) * 1.5); image = f.outputImage ?? image
        }
        // Brilliance lifts shadows and holds highlights back (negative: the reverse), with a
        // little extra contrast and colour so the result doesn't look flat.
        let brilliance = v(.brilliance)
        let shadows = min(max(v(.shadows) + brilliance * 0.8, -1), 1)
        let highlightsDown = min(v(.highlights), 0) - max(brilliance, 0) * 0.6
        let highlightsUp = max(v(.highlights), 0) + max(-brilliance, 0) * 0.5
        if highlightsDown != 0 || shadows != 0 {
            let f = CIFilter.highlightShadowAdjust(); f.inputImage = image
            f.highlightAmount = Float(max(1 + highlightsDown * 0.9, 0.05))
            f.shadowAmount = Float(shadows * 0.8)
            image = f.outputImage ?? image
        }

        // Tone and colour controls work on perceived brightness (sRGB curve), so contrast
        // pivots on the midtones and brightness keeps black and white where they are.
        let contrast = v(.contrast) + brilliance * 0.15, brightness = v(.brightness), saturation = v(.saturation) + brilliance * 0.1
        let blackPoint = v(.blackPoint)
        if highlightsUp > 0 || contrast != 0 || brightness != 0 || saturation != 0 || blackPoint != 0 {
            image = image.applyingFilter("CILinearToSRGBToneCurve")
            if highlightsUp > 0 {
                image = curve(image, [(0, 0), (0.25, 0.25), (0.5, 0.5 + 0.04 * highlightsUp), (0.75, 0.75 + 0.12 * highlightsUp), (1, 1)])
            }
            if contrast != 0 || saturation != 0 {
                let f = CIFilter.colorControls(); f.inputImage = image
                f.contrast = Float(1 + contrast * 0.35)
                f.saturation = Float(1 + saturation)
                image = f.outputImage ?? image
            }
            if brightness != 0 {
                let f = CIFilter.gammaAdjust(); f.inputImage = image; f.power = Float(1 - brightness * 0.4); image = f.outputImage ?? image
            }
            if blackPoint != 0 {
                // Positive: deeper blacks; negative: lifted blacks.
                let b = blackPoint * 0.22
                image = curve(image, [(max(b, 0), max(-b, 0)), (0.25, 0.25 - b * 0.55), (0.5, 0.5 - b * 0.2), (0.75, 0.75 - b * 0.05), (1, 1)])
            }
            image = image.applyingFilter("CISRGBToneCurveToLinear")
        }
        if v(.vibrance) != 0 {
            let f = CIFilter.vibrance(); f.inputImage = image; f.amount = Float(v(.vibrance)); image = f.outputImage ?? image
        }
        if v(.warmth) != 0 || v(.tint) != 0 {
            image = whiteBalance(image, warmth: v(.warmth), tint: v(.tint))
        }
        if v(.definition) > 0 {
            let f = CIFilter.unsharpMask(); f.inputImage = image; f.radius = 30; f.intensity = Float(v(.definition) * 0.6); image = f.outputImage ?? image
        }
        if v(.sharpness) > 0 {
            let f = CIFilter.sharpenLuminance(); f.inputImage = image; f.sharpness = Float(v(.sharpness) * 0.9); f.radius = 1.5; image = f.outputImage ?? image
        }
        if v(.noiseReduction) > 0 {
            let f = CIFilter.noiseReduction(); f.inputImage = image; f.noiseLevel = Float(v(.noiseReduction) * 0.08); f.sharpness = 0.3; image = f.outputImage ?? image
        }
        if v(.vignette) != 0 {
            let f = CIFilter.vignette(); f.inputImage = image; f.intensity = Float(v(.vignette) * 1.2); f.radius = 1.6; image = f.outputImage ?? image
        }
        return image.cropped(to: input.extent)
    }

    /// A tone curve through five points; values beyond 0…1 (HDR) continue the curve's ends.
    private static func curve(_ image: CIImage, _ points: [(CGFloat, CGFloat)]) -> CIImage {
        let f = CIFilter.toneCurve(); f.inputImage = image
        f.point0 = CGPoint(x: points[0].0, y: points[0].1)
        f.point1 = CGPoint(x: points[1].0, y: points[1].1)
        f.point2 = CGPoint(x: points[2].0, y: points[2].1)
        f.point3 = CGPoint(x: points[3].0, y: points[3].1)
        f.point4 = CGPoint(x: points[4].0, y: points[4].1)
        if #available(iOS 26.0, macOS 26.0, *) { f.extrapolate = true }
        return f.outputImage ?? image
    }

    /// Warmth (+ warmer, − cooler) and tint (+ magenta, − green), even steps in mireds.
    private static func whiteBalance(_ image: CIImage, warmth: Double, tint: Double) -> CIImage {
        let neutralMired = 1_000_000 / 6500.0
        let f = CIFilter.temperatureAndTint(); f.inputImage = image
        f.neutral = CIVector(x: 6500, y: 0)
        // Warmer means a lower target white (Core Image then shifts the colours towards orange).
        f.targetNeutral = CIVector(x: 1_000_000 / (neutralMired + warmth * 45), y: -tint * 60)
        return f.outputImage ?? image
    }

    private static func filter(_ image: CIImage, _ filter: EditState.Filter) -> CIImage {
        func controls(_ image: CIImage, saturation: Float, contrast: Float) -> CIImage {
            let f = CIFilter.colorControls(); f.inputImage = image.applyingFilter("CILinearToSRGBToneCurve"); f.saturation = saturation; f.contrast = contrast
            return (f.outputImage ?? image).applyingFilter("CISRGBToneCurveToLinear")
        }
        func temperature(_ image: CIImage, _ warmth: Double) -> CIImage { whiteBalance(image, warmth: warmth, tint: 0) }
        func blackAndWhite(_ image: CIImage, contrast: Float, points: [(CGFloat, CGFloat)]?) -> CIImage {
            let f = CIFilter.colorControls(); f.inputImage = image.applyingFilter("CILinearToSRGBToneCurve"); f.saturation = 0; f.contrast = contrast
            var shaped = f.outputImage ?? image
            if let points { shaped = curve(shaped, points) }
            return shaped.applyingFilter("CISRGBToneCurveToLinear")
        }
        switch filter {
        case .original: return image
        case .vivid: return controls(image, saturation: 1.25, contrast: 1.08)
        case .vividWarm: return temperature(controls(image, saturation: 1.22, contrast: 1.08), 0.4)
        case .vividCool: return temperature(controls(image, saturation: 1.22, contrast: 1.08), -0.4)
        case .dramatic: return controls(image, saturation: 0.85, contrast: 1.22)
        case .dramaticWarm: return temperature(controls(image, saturation: 0.9, contrast: 1.22), 0.4)
        case .dramaticCool: return temperature(controls(image, saturation: 0.9, contrast: 1.22), -0.4)
        // Black and white from the same perceptual controls as the other looks: Core Image's
        // photo effects darken HDR pictures (video, and photos as they're saved).
        case .mono: return blackAndWhite(image, contrast: 1.06, points: nil)
        case .silvertone: return blackAndWhite(image, contrast: 1.12, points: [(0, 0.03), (0.25, 0.24), (0.5, 0.52), (0.75, 0.78), (1, 0.98)])
        case .noir: return blackAndWhite(image, contrast: 1.38, points: [(0, 0), (0.25, 0.18), (0.5, 0.47), (0.75, 0.8), (1, 1)])
        }
    }

    /// The size a picture of `size` has after the geometry edits (quarter turns swap the sides,
    /// cropping shrinks it).
    static func outputSize(of size: CGSize, state: EditState) -> CGSize {
        geometry(CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)), state).extent.size
    }

    /// The same for a video frame, in whole, even pixels as video encoders need.
    static func videoRenderSize(upright: CGSize, state: EditState) -> CGSize {
        let size = outputSize(of: upright, state: state)
        return CGSize(width: max(2, (size.width / 2).rounded() * 2), height: max(2, (size.height / 2).rounded() * 2))
    }

    /// One edited video frame that fills `renderSize` exactly, over black.
    static func videoFrame(_ state: EditState, source: CIImage, renderSize: CGSize, autoFilters: [CIFilter]) -> CIImage {
        let origin = CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY)
        let image = apply(state, to: source.transformed(by: origin), autoFilters: autoFilters)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: renderSize)) }
        let fitted = image.transformed(by: CGAffineTransform(scaleX: renderSize.width / extent.width, y: renderSize.height / extent.height))
        return fitted.composited(over: CIImage(color: .black)).cropped(to: CGRect(origin: .zero, size: renderSize))
    }

    /// Straighten (rotate and fill), perspective, crop, quarter turns and flip.
    static func geometry(_ input: CIImage, _ state: EditState) -> CIImage {
        var image = input
        let extent = input.extent
        if state.vertical != 0 || state.horizontal != 0 {
            let f = CIFilter.perspectiveTransform(); f.inputImage = image
            let dx = extent.width * 0.15 * state.horizontal, dy = extent.height * 0.15 * state.vertical
            f.topLeft = CGPoint(x: extent.minX - dy, y: extent.maxY + dx)
            f.topRight = CGPoint(x: extent.maxX + dy, y: extent.maxY - dx)
            f.bottomLeft = CGPoint(x: extent.minX + dy, y: extent.minY - dx)
            f.bottomRight = CGPoint(x: extent.maxX - dy, y: extent.minY + dx)
            // The corners move by up to dy across and dx up/down: zoom in until the frame is full.
            let inner = extent.insetBy(dx: abs(dy), dy: abs(dx))
            let fill = max(extent.width / max(inner.width, 1), extent.height / max(inner.height, 1))
            let center = CGPoint(x: extent.midX, y: extent.midY)
            let zoom = CGAffineTransform(translationX: center.x, y: center.y).scaledBy(x: fill, y: fill).translatedBy(x: -center.x, y: -center.y)
            image = (f.outputImage ?? image).transformed(by: zoom).cropped(to: extent)
        }
        if state.straighten != 0 {
            let radians = state.straighten * .pi / 180
            // Scale up just enough that the rotated photo still fills the frame.
            let w = extent.width, h = extent.height
            let scale = (abs(cos(radians)) * w + abs(sin(radians)) * h) / w
            let scaleH = (abs(sin(radians)) * w + abs(cos(radians)) * h) / h
            let fill = max(scale, scaleH)
            let center = CGPoint(x: extent.midX, y: extent.midY)
            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: radians).scaledBy(x: fill, y: fill).translatedBy(x: -center.x, y: -center.y)
            image = image.transformed(by: transform).cropped(to: extent)
        }
        if state.flipped {
            image = image.oriented(.upMirrored)
        }
        let turns = ((state.quarterTurns % 4) + 4) % 4
        if turns > 0 {
            image = image.oriented([.up, .left, .down, .right][turns])
        }
        // Crop last, in the coordinates of the rotated/flipped photo (as shown while cropping).
        // Crop (unit rect, origin top-left) → Core Image coordinates (origin bottom-left).
        let c = state.crop
        if c != CGRect(x: 0, y: 0, width: 1, height: 1) {
            let extent = image.extent
            let rect = CGRect(x: extent.minX + c.minX * image.extent.width, y: extent.minY + (1 - c.maxY) * extent.height,
                              width: c.width * extent.width, height: c.height * extent.height)
            image = image.cropped(to: rect)
        }
        // Back to an origin at zero, so writers and players see a normal image.
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
}

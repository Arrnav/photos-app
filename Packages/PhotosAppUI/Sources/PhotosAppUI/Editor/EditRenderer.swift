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
        let brilliance = v(.brilliance)
        let highlights = v(.highlights) - brilliance * 0.4
        let shadows = v(.shadows) + brilliance * 0.5
        if highlights != 0 || shadows != 0 {
            let f = CIFilter.highlightShadowAdjust(); f.inputImage = image
            f.highlightAmount = Float(1 - max(-highlights, 0) * 0.8 + max(highlights, 0) * 0.3)
            f.shadowAmount = Float(shadows * 0.8)
            image = f.outputImage ?? image
        }
        let contrast = v(.contrast) + brilliance * 0.1, brightness = v(.brightness), saturation = v(.saturation)
        if contrast != 0 || brightness != 0 || saturation != 0 {
            let f = CIFilter.colorControls(); f.inputImage = image
            f.contrast = Float(1 + contrast * 0.35)
            f.brightness = Float(brightness * 0.2)
            f.saturation = Float(1 + saturation)
            image = f.outputImage ?? image
        }
        if v(.blackPoint) != 0 {
            let f = CIFilter.toneCurve(); f.inputImage = image
            let lift = Float(v(.blackPoint) * 0.12)
            f.point0 = CGPoint(x: CGFloat(max(lift, 0)), y: CGFloat(max(-lift, 0)))
            f.point1 = CGPoint(x: 0.25, y: 0.25); f.point2 = CGPoint(x: 0.5, y: 0.5); f.point3 = CGPoint(x: 0.75, y: 0.75); f.point4 = CGPoint(x: 1, y: 1)
            image = f.outputImage ?? image
        }
        if v(.vibrance) != 0 {
            let f = CIFilter.vibrance(); f.inputImage = image; f.amount = Float(v(.vibrance)); image = f.outputImage ?? image
        }
        if v(.warmth) != 0 || v(.tint) != 0 {
            let f = CIFilter.temperatureAndTint(); f.inputImage = image
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 + v(.warmth) * 2500, y: v(.tint) * 60)
            image = f.outputImage ?? image
        }
        if v(.definition) > 0 {
            let f = CIFilter.unsharpMask(); f.inputImage = image; f.radius = 30; f.intensity = Float(v(.definition) * 0.6); image = f.outputImage ?? image
        }
        if v(.sharpness) > 0 {
            let f = CIFilter.sharpenLuminance(); f.inputImage = image; f.sharpness = Float(v(.sharpness) * 0.9); f.radius = 1.5; image = f.outputImage ?? image
        }
        if v(.noiseReduction) > 0 {
            let f = CIFilter.noiseReduction(); f.inputImage = image; f.noiseLevel = Float(v(.noiseReduction) * 0.05); f.sharpness = 0.4; image = f.outputImage ?? image
        }
        if v(.vignette) != 0 {
            let f = CIFilter.vignette(); f.inputImage = image; f.intensity = Float(v(.vignette) * 1.2); f.radius = 1.6; image = f.outputImage ?? image
        }
        return image.cropped(to: input.extent)
    }

    private static func filter(_ image: CIImage, _ filter: EditState.Filter) -> CIImage {
        func controls(_ image: CIImage, saturation: Float, contrast: Float) -> CIImage {
            let f = CIFilter.colorControls(); f.inputImage = image; f.saturation = saturation; f.contrast = contrast; return f.outputImage ?? image
        }
        func temperature(_ image: CIImage, _ kelvin: CGFloat) -> CIImage {
            let f = CIFilter.temperatureAndTint(); f.inputImage = image; f.neutral = CIVector(x: 6500, y: 0); f.targetNeutral = CIVector(x: 6500 + kelvin, y: 0); return f.outputImage ?? image
        }
        switch filter {
        case .original: return image
        case .vivid: return controls(image, saturation: 1.25, contrast: 1.08)
        case .vividWarm: return temperature(controls(image, saturation: 1.22, contrast: 1.08), 900)
        case .vividCool: return temperature(controls(image, saturation: 1.22, contrast: 1.08), -900)
        case .dramatic: return controls(image, saturation: 0.85, contrast: 1.25)
        case .dramaticWarm: return temperature(controls(image, saturation: 0.9, contrast: 1.25), 900)
        case .dramaticCool: return temperature(controls(image, saturation: 0.9, contrast: 1.25), -900)
        case .mono: let f = CIFilter.photoEffectMono(); f.inputImage = image; return f.outputImage ?? image
        case .silvertone: let f = CIFilter.photoEffectTonal(); f.inputImage = image; return controls(f.outputImage ?? image, saturation: 0, contrast: 1.1)
        case .noir: let f = CIFilter.photoEffectNoir(); f.inputImage = image; return f.outputImage ?? image
        }
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
            image = (f.outputImage ?? image).cropped(to: extent)
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

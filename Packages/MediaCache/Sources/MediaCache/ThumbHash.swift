import CoreGraphics
import Foundation

/// Decodes ThumbHash placeholders (https://evanw.github.io/thumbhash/), which
/// Immich sends base64-encoded with every asset. Produces an image of at most 32×32.
public enum ThumbHash {
    public struct RGBA: Sendable {
        public let width: Int
        public let height: Int
        public let pixels: [UInt8]
    }

    public static func image(base64: String) -> CGImage? {
        guard let data = Data(base64Encoded: base64), let rgba = decode(Array(data)) else { return nil }
        return makeImage(rgba)
    }

    /// Width / height encoded in the hash.
    public static func approximateAspectRatio(_ hash: [UInt8]) -> Double? {
        guard hash.count >= 5 else { return nil }
        let header = hash[3]
        let hasAlpha = hash[2] & 0x80 != 0
        let isLandscape = hash[4] & 0x80 != 0
        let lx = isLandscape ? (hasAlpha ? 5 : 7) : Int(header & 7)
        let ly = isLandscape ? Int(header & 7) : (hasAlpha ? 5 : 7)
        guard lx > 0, ly > 0 else { return nil }
        return Double(lx) / Double(ly)
    }

    public static func decode(_ hash: [UInt8]) -> RGBA? {
        guard hash.count >= 5, let ratio = approximateAspectRatio(hash) else { return nil }

        let header24 = Int(hash[0]) | Int(hash[1]) << 8 | Int(hash[2]) << 16
        let header16 = Int(hash[3]) | Int(hash[4]) << 8
        let lDC = Double(header24 & 63) / 63
        let pDC = Double((header24 >> 6) & 63) / 31.5 - 1
        let qDC = Double((header24 >> 12) & 63) / 31.5 - 1
        let lScale = Double((header24 >> 18) & 31) / 31
        let hasAlpha = (header24 >> 23) != 0
        let pScale = Double((header16 >> 3) & 63) / 63
        let qScale = Double((header16 >> 9) & 63) / 63
        let isLandscape = (header16 >> 15) != 0
        let lx = max(3, isLandscape ? (hasAlpha ? 5 : 7) : header16 & 7)
        let ly = max(3, isLandscape ? header16 & 7 : (hasAlpha ? 5 : 7))

        if hasAlpha && hash.count < 6 { return nil }
        let aDC = hasAlpha ? Double(hash[5] & 15) / 15 : 1
        let aScale = hasAlpha ? Double(hash[5] >> 4) / 15 : 0

        // AC coefficients are packed as 4-bit values after the header.
        let acStart = hasAlpha ? 6 : 5
        var acIndex = 0
        func decodeChannel(_ nx: Int, _ ny: Int, _ scale: Double) -> [Double]? {
            var ac: [Double] = []
            for cy in 0..<ny {
                var cx = cy == 0 ? 1 : 0
                while cx * ny < nx * (ny - cy) {
                    let byteIndex = acStart + (acIndex >> 1)
                    guard byteIndex < hash.count else { return nil }
                    let nibble = (Int(hash[byteIndex]) >> ((acIndex & 1) << 2)) & 15
                    ac.append((Double(nibble) / 7.5 - 1) * scale)
                    acIndex += 1
                    cx += 1
                }
            }
            return ac
        }
        // Saturation is boosted 1.25× to compensate for quantisation.
        guard let lAC = decodeChannel(lx, ly, lScale),
              let pAC = decodeChannel(3, 3, pScale * 1.25),
              let qAC = decodeChannel(3, 3, qScale * 1.25)
        else { return nil }
        let aAC: [Double]
        if hasAlpha {
            guard let decoded = decodeChannel(5, 5, aScale) else { return nil }
            aAC = decoded
        } else {
            aAC = []
        }

        let width = Int((ratio > 1 ? 32 : 32 * ratio).rounded())
        let height = Int((ratio > 1 ? 32 / ratio : 32).rounded())
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let fxCount = max(lx, hasAlpha ? 5 : 3)
        let fyCount = max(ly, hasAlpha ? 5 : 3)
        // The cosine basis depends only on the column (x) or row (y), so it is
        // computed once per column and row rather than per pixel.
        var fxTable = [Double](repeating: 0, count: width * fxCount)
        for x in 0..<width {
            for cx in 0..<fxCount {
                fxTable[x * fxCount + cx] = cos(Double.pi / Double(width) * (Double(x) + 0.5) * Double(cx))
            }
        }
        var fyTable = [Double](repeating: 0, count: height * fyCount)
        for y in 0..<height {
            for cy in 0..<fyCount {
                fyTable[y * fyCount + cy] = cos(Double.pi / Double(height) * (Double(y) + 0.5) * Double(cy))
            }
        }

        var i = 0
        for y in 0..<height {
            let fy = fyTable[(y * fyCount)..<((y + 1) * fyCount)]
            let fyBase = fy.startIndex
            for x in 0..<width {
                var l = lDC, p = pDC, q = qDC, a = aDC
                let fx = fxTable[(x * fxCount)..<((x + 1) * fxCount)]
                let fxBase = fx.startIndex

                var j = 0
                for cy in 0..<ly {
                    let fy2 = fy[fyBase + cy] * 2
                    var cx = cy == 0 ? 1 : 0
                    while cx * ly < lx * (ly - cy) {
                        l += lAC[j] * fx[fxBase + cx] * fy2
                        j += 1
                        cx += 1
                    }
                }

                j = 0
                for cy in 0..<3 {
                    let fy2 = fy[fyBase + cy] * 2
                    var cx = cy == 0 ? 1 : 0
                    while cx < 3 - cy {
                        let f = fx[fxBase + cx] * fy2
                        p += pAC[j] * f
                        q += qAC[j] * f
                        j += 1
                        cx += 1
                    }
                }

                if hasAlpha {
                    j = 0
                    for cy in 0..<5 {
                        let fy2 = fy[fyBase + cy] * 2
                        var cx = cy == 0 ? 1 : 0
                        while cx < 5 - cy {
                            a += aAC[j] * fx[fxBase + cx] * fy2
                            j += 1
                            cx += 1
                        }
                    }
                }

                // LPQ → RGB
                let b = l - 2.0 / 3.0 * p
                let r = (3 * l - b + q) / 2
                let g = r - q
                pixels[i] = channel(r)
                pixels[i + 1] = channel(g)
                pixels[i + 2] = channel(b)
                pixels[i + 3] = channel(a)
                i += 4
            }
        }
        return RGBA(width: width, height: height, pixels: pixels)
    }

    private static func channel(_ value: Double) -> UInt8 {
        UInt8(max(0, min(255, (255 * value).rounded(.down))))
    }

    static func makeImage(_ rgba: RGBA) -> CGImage? {
        // Premultiply so CoreGraphics composites transparent placeholders correctly.
        var premultiplied = rgba.pixels
        for index in stride(from: 0, to: premultiplied.count, by: 4) {
            let alpha = UInt16(premultiplied[index + 3])
            for c in 0..<3 {
                premultiplied[index + c] = UInt8(UInt16(premultiplied[index + c]) * alpha / 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(premultiplied) as CFData) else { return nil }
        return CGImage(
            width: rgba.width,
            height: rgba.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: rgba.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

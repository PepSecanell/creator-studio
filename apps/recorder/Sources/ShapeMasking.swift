import CoreGraphics
import CoreImage
import CoreVideo

/// Builds alpha-carrying masks for `BubbleShapePath` shapes.
///
/// Shared by the screen compositor (bubble overlay) and camera-only export
/// (the whole frame cut to a shape) so both cut identical curves.
///
/// Must carry real **alpha**, not just luminance: `CIBlendWithAlphaMask`
/// reads the mask's alpha channel. A grayscale mask built with
/// `CGImageAlphaInfo.none` is opaque everywhere and silently masks
/// nothing, that shipped once in the bubble path, and a centre-pixel test
/// could not catch it, only an edge-pixel one could.
enum ShapeMasking {

    static func shapeMask(size: CGSize, shape: BubbleShape, tilt: CGFloat) -> CIImage {
        let path = BubbleShapePath.path(
            for: shape,
            in: CGRect(x: 0, y: 0, width: size.width.rounded(), height: size.height.rounded()),
            tiltDegrees: tilt
        )
        return alphaMask(size: size, path: path)
    }

    /// Transparent outside the path, opaque white inside.
    static func alphaMask(size: CGSize, path: CGPath) -> CIImage {
        let width = max(Int(size.width.rounded()), 1)
        let height = max(Int(size.height.rounded()), 1)

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .empty() }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.addPath(path)
        context.fillPath()

        guard let cgImage = context.makeImage() else { return .empty() }
        return GPUResident.image(cgImage)
    }
}

/// Static layers (backdrop, baked shadows, masks, rims, sprites) as images that live on the GPU.
///
/// Why: a `CIImage(cgImage:)` gets uploaded into a fresh Metal texture on EVERY
/// render. CoreImage's CGImage texture cache is small and these layers are full-frame (a 4K
/// half-float shadow is 66 MB). A sample of the app finishing a 4K Studio take showed ~88% of the
/// compositor's time inside `texture_for_CGImage` -> `replaceRegion` (CPU-side texture
/// compression), so a 3-minute take took well over 20 minutes and pushed the Mac into swap.
/// Copying the same bytes once into an IOSurface-backed pixel buffer lets CoreImage sample them
/// in place, with no upload. The bytes are copied exactly (8-bit RGBA is swizzled to BGRA,
/// half-float is copied as is) and the CGImage's own colour space is kept, so every frame
/// renders the same pixels as before. Any other layout falls back to the plain CGImage.
enum GPUResident {

    static func image(_ cg: CGImage) -> CIImage {
        guard let space = cg.colorSpace,
              let data = cg.dataProvider?.data,
              let src = CFDataGetBytePtr(data) else { return CIImage(cgImage: cg) }
        let width = cg.width, height = cg.height
        let alpha = cg.alphaInfo
        let order = CGImageByteOrderInfo(rawValue: cg.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue)
        let isFloat = cg.bitmapInfo.contains(.floatComponents)

        let format: OSType
        if cg.bitsPerComponent == 8, cg.bitsPerPixel == 32, !isFloat,
           alpha == .premultipliedLast || alpha == .noneSkipLast,
           order == .orderDefault || order == .order32Big {
            format = kCVPixelFormatType_32BGRA
        } else if cg.bitsPerComponent == 16, cg.bitsPerPixel == 64, isFloat,
                  alpha == .premultipliedLast,
                  order == .order16Little {
            format = kCVPixelFormatType_64RGBAHalf
        } else {
            return CIImage(cgImage: cg)
        }

        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        guard CVPixelBufferCreate(nil, width, height, format, attributes as CFDictionary, &buffer)
                == kCVReturnSuccess, let buffer else { return CIImage(cgImage: cg) }

        CVPixelBufferLockBaseAddress(buffer, [])
        let dstBase = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let dstStride = CVPixelBufferGetBytesPerRow(buffer)
        let srcStride = cg.bytesPerRow
        if format == kCVPixelFormatType_64RGBAHalf {
            for y in 0..<height {
                memcpy(dstBase + y * dstStride, src + y * srcStride, width * 8)
            }
        } else {
            let opaque = alpha == .noneSkipLast
            for y in 0..<height {
                let s = src + y * srcStride
                let d = dstBase + y * dstStride
                for x in 0..<width {
                    let p = x * 4
                    d[p] = s[p + 2]
                    d[p + 1] = s[p + 1]
                    d[p + 2] = s[p]
                    d[p + 3] = opaque ? 255 : s[p + 3]
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: space])
    }
}

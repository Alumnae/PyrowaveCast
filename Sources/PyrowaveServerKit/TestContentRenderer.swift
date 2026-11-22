import Foundation
import CoreGraphics
import CoreVideo
import CoreText
import ImageIO

/// Renders the visual test content that the server streams in test mode.
///
/// The content is a broadcast style test card: colour bars, a moving progress
/// indicator and a text overlay with the frame number, timestamp and stream
/// geometry. It makes it obvious on the receiving client that frames arrive
/// and decode correctly, and that the stream is live rather than stalled.
public enum TestContentMode: Sendable {
    /// Animated test card.
    case card
    /// A still image, scaled to fit the frame, with the overlay on top.
    case image(URL)
    /// A video file, played back in a loop.
    case video(URL)
}

/// Shared statistics so the overlay can show the live throughput.
final class StreamStats: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var bytes = 0
    private let startedAt = Date()

    func record(frameBytes: Int) {
        lock.lock()
        frames += 1
        bytes += frameBytes
        lock.unlock()
    }

    var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    var byteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    var megabitsPerSecond: Double {
        lock.lock()
        let totalBytes = bytes
        lock.unlock()
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0 else { return 0 }
        return Double(totalBytes * 8) / elapsed / 1_000_000
    }
}

enum TestContentRenderer {
    /// SMPTE style colour bars, in the classic 7 bar order.
    private static let barColors: [(CGFloat, CGFloat, CGFloat)] = [
        (0.75, 0.75, 0.75),  // white
        (0.75, 0.75, 0.00),  // yellow
        (0.00, 0.75, 0.75),  // cyan
        (0.00, 0.75, 0.00),  // green
        (0.75, 0.00, 0.75),  // magenta
        (0.75, 0.00, 0.00),  // red
        (0.00, 0.00, 0.75)   // blue
    ]

    /// The colour space of the rendered frames.
    ///
    /// CoreGraphics converts colours into the space of the drawing context.
    /// `CGColor(red:green:blue:alpha:)` is created in the *generic* RGB space,
    /// which would silently shift every colour (and wash out saturated
    /// primaries), so all colours are created explicitly in sRGB instead.
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bufferLock = NSLock()
    nonisolated(unsafe) private static var cachedBGRA: CVPixelBuffer?
    nonisolated(unsafe) private static var cachedOverlayBGRA: CVPixelBuffer?
    nonisolated(unsafe) private static var cachedStaticNV12: CVPixelBuffer?
    nonisolated(unsafe) private static var cachedStaticWidth = 0
    nonisolated(unsafe) private static var cachedStaticHeight = 0
    nonisolated(unsafe) private static var cachedStaticImageURL: URL?
    nonisolated(unsafe) private static var cachedStaticIsCard = false
    nonisolated(unsafe) private static var cachedNV12Pool: [CVPixelBuffer] = []
    nonisolated(unsafe) private static var cachedNV12Index = 0
    nonisolated(unsafe) private static var cachedWidth = 0
    nonisolated(unsafe) private static var cachedHeight = 0
    nonisolated(unsafe) private static var cachedImageURL: URL?
    nonisolated(unsafe) private static var cachedImage: CGImage?
    nonisolated(unsafe) private static var fontCache: [Int: CTFont] = [:]

    /// Precomputed full-range YCbCr (Y, Cb, Cr) for the 7 SMPTE bars (0.75 intensity).
    private static let barYUVTop: [(y: UInt8, cb: UInt8, cr: UInt8)] = [
        (191, 128, 128), // white
        (177,  28, 138), // yellow
        (153, 151,  21), // cyan
        (139,  51,  31), // green
        ( 66, 205, 225), // magenta
        ( 52, 105, 235), // red
        ( 14, 228, 118)  // blue
    ]

    /// Precomputed full-range YCbCr for the middle 0.45x reverse bars.
    private static let barYUVMid: [(y: UInt8, cb: UInt8, cr: UInt8)] = [
        (  6, 173, 124), // blue * 0.45
        ( 23, 118, 176), // red * 0.45
        ( 30, 163, 172), // magenta * 0.45
        ( 62,  93,  84), // green * 0.45
        ( 69, 138,  80), // cyan * 0.45
        ( 80,  83, 132), // yellow * 0.45
        ( 86, 128, 128)  // white * 0.45
    ]

    /// Creates an opaque or translucent colour in the rendering colour space.
    private static func color(
        _ red: CGFloat,
        _ green: CGFloat,
        _ blue: CGFloat,
        _ alpha: CGFloat = 1
    ) -> CGColor {
        CGColor(colorSpace: colorSpace, components: [red, green, blue, alpha])!
    }

    /// Draws one frame of test content and returns it as an NV12 pixel buffer.
    static func makePixelBuffer(
        width: Int,
        height: Int,
        frameIndex: Int,
        mode: TestContentMode,
        overlayLines: [String]
    ) -> CVPixelBuffer? {
        guard width > 0, height > 0, width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            return nil
        }

        guard let buffers = ensureBuffers(width: width, height: height) else { return nil }
        let nv12Buffer = buffers.nv12

        switch mode {
        case .card, .video:
            renderCardFastNV12(
                into: nv12Buffer,
                overlayBGRA: buffers.overlayBGRA,
                staticNV12: buffers.staticNV12,
                width: width,
                height: height,
                frameIndex: frameIndex,
                overlayLines: overlayLines
            )
            return nv12Buffer

        case .image(let url):
            let bgraBuffer = buffers.bgra
            CVPixelBufferLockBaseAddress(bgraBuffer, [])
            defer { CVPixelBufferUnlockBaseAddress(bgraBuffer, []) }
            guard let baseAddress = CVPixelBufferGetBaseAddress(bgraBuffer) else { return nil }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(bgraBuffer)
            guard let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
            ) else { return nil }

            drawContent(
                in: context,
                width: width,
                height: height,
                frameIndex: frameIndex,
                mode: .image(url),
                overlayLines: overlayLines
            )
            return convertBGRAtoNV12(bgraBuffer, into: nv12Buffer, width: width, height: height)
        }
    }

    /// Ultra-fast direct NV12 renderer for `.card` mode:
    /// 1. Populates `staticNV12` once per resolution with the static colour bars.
    /// 2. Copies `staticNV12` into the target `nv12Buffer` via `memcpy`.
    /// 3. Draws the small top text banner into `overlayBGRA` (only ~18% of frame height)
    ///    and converts only those top rows into `nv12Buffer`.
    /// 4. Fills the moving progress bar and sweep indicator directly in NV12 planes.
    private static func renderCardFastNV12(
        into nv12Buffer: CVPixelBuffer,
        overlayBGRA: CVPixelBuffer,
        staticNV12: CVPixelBuffer,
        width: Int,
        height: Int,
        frameIndex: Int,
        overlayLines: [String]
    ) {
        let overlayHeight = min(height, max(32, ((Int(Double(max(overlayLines.count, 1)) * Double(height) * 0.052 + Double(height) * 0.04) + 1) & ~1)))

        bufferLock.lock()
        let needsStaticInit = !cachedStaticIsCard || cachedStaticWidth != width || cachedStaticHeight != height
        if needsStaticInit {
            populateStaticCardNV12(staticNV12, width: width, height: height)
            cachedStaticIsCard = true
            cachedStaticWidth = width
            cachedStaticHeight = height
        }
        bufferLock.unlock()

        CVPixelBufferLockBaseAddress(staticNV12, .readOnly)
        CVPixelBufferLockBaseAddress(nv12Buffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(nv12Buffer, [])
            CVPixelBufferUnlockBaseAddress(staticNV12, .readOnly)
        }

        guard let srcY = CVPixelBufferGetBaseAddressOfPlane(staticNV12, 0),
              let srcUV = CVPixelBufferGetBaseAddressOfPlane(staticNV12, 1),
              let dstYBase = CVPixelBufferGetBaseAddressOfPlane(nv12Buffer, 0),
              let dstUVBase = CVPixelBufferGetBaseAddressOfPlane(nv12Buffer, 1) else { return }

        let yStride = CVPixelBufferGetBytesPerRowOfPlane(nv12Buffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(nv12Buffer, 1)
        let srcYStride = CVPixelBufferGetBytesPerRowOfPlane(staticNV12, 0)
        let srcUVStride = CVPixelBufferGetBytesPerRowOfPlane(staticNV12, 1)

        if yStride == srcYStride {
            memcpy(dstYBase, srcY, yStride * height)
        } else {
            for r in 0..<height {
                memcpy(dstYBase.advanced(by: r * yStride), srcY.advanced(by: r * srcYStride), width)
            }
        }
        let chromaHeight = height / 2
        if uvStride == srcUVStride {
            memcpy(dstUVBase, srcUV, uvStride * chromaHeight)
        } else {
            for r in 0..<chromaHeight {
                memcpy(dstUVBase.advanced(by: r * uvStride), srcUV.advanced(by: r * srcUVStride), width)
            }
        }

        let dstY = dstYBase.assumingMemoryBound(to: UInt8.self)
        let dstUV = dstUVBase.assumingMemoryBound(to: UInt8.self)

        // Draw animated progress bar & sweep bar directly in NV12 (top-down coordinates).
        let phase = Double(frameIndex % 240) / 240.0
        let barsHeight = Int(Double(height) * 0.62) & ~1
        let stripTop = (height - Int(Double(height) * 0.18)) & ~1
        let stripBottom = (height - Int(Double(height) * 0.08)) & ~1
        let progressWidth = min(width, max(0, Int(Double(width) * phase) & ~1))

        if progressWidth > 0 && stripBottom > stripTop {
            fillNV12Rect(
                dstY: dstY, yStride: yStride,
                dstUV: dstUV, uvStride: uvStride,
                x: 0, y: stripTop,
                rectWidth: progressWidth, rectHeight: stripBottom - stripTop,
                luma: 147, cb: 158, cr: 37 // teal progress bar
            )
        }

        let sweepX = min(width - 2, max(0, Int(Double(width) * phase) & ~1))
        let sweepWidth = max(2, min(width - sweepX, Int(Double(width) * 0.012) & ~1))
        if sweepWidth > 0 && barsHeight > overlayHeight {
            fillNV12Rect(
                dstY: dstY, yStride: yStride,
                dstUV: dstUV, uvStride: uvStride,
                x: sweepX, y: overlayHeight,
                rectWidth: sweepWidth, rectHeight: barsHeight - overlayHeight,
                luma: 225, cb: 128, cr: 128 // bright sweep indicator
            )
        }

        // Render text overlay into the small top strip of `overlayBGRA` and convert only `overlayHeight` rows.
        CVPixelBufferLockBaseAddress(overlayBGRA, [])
        defer { CVPixelBufferUnlockBaseAddress(overlayBGRA, []) }
        guard let overlayBase = CVPixelBufferGetBaseAddress(overlayBGRA) else { return }
        let overlayStride = CVPixelBufferGetBytesPerRow(overlayBGRA)

        if let context = CGContext(
            data: overlayBase,
            width: width,
            height: overlayHeight,
            bitsPerComponent: 8,
            bytesPerRow: overlayStride,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        ) {
            let w = CGFloat(width)
            let h = CGFloat(overlayHeight)
            let barWidth = w / CGFloat(barColors.count)
            for (index, bar) in barColors.enumerated() {
                context.setFillColor(color(bar.0 * 0.45, bar.1 * 0.45, bar.2 * 0.45, 1))
                context.fill(CGRect(x: CGFloat(index) * barWidth, y: 0, width: barWidth + 1, height: h))
            }

            var y = h - CGFloat(height) * 0.022
            for (index, line) in overlayLines.enumerated() {
                let fontSize = CGFloat(height) * (index == 0 ? 0.058 : 0.034)
                drawText(
                    line,
                    in: context,
                    at: CGPoint(x: w * 0.022, y: y),
                    fontSize: fontSize,
                    color: index == 0 ? color(0.20, 0.95, 0.85, 1) : color(1, 1, 1, 1)
                )
                y -= fontSize * 1.35
            }
        }

        let bgra = overlayBase.assumingMemoryBound(to: UInt8.self)
        let chromaWidth = width / 2
        let overlayChromaRows = overlayHeight / 2
        for chromaRow in 0..<overlayChromaRows {
            let row0 = chromaRow * 2
            let row1 = row0 + 1
            let src0 = bgra + row0 * overlayStride
            let src1 = bgra + row1 * overlayStride
            let dY0 = dstY + row0 * yStride
            let dY1 = dstY + row1 * yStride
            let dUV = dstUV + chromaRow * uvStride

            for chromaCol in 0..<chromaWidth {
                let col0 = chromaCol * 2
                let col1 = col0 + 1

                let b00 = Int(src0[col0 * 4 + 0])
                let g00 = Int(src0[col0 * 4 + 1])
                let r00 = Int(src0[col0 * 4 + 2])
                dY0[col0] = UInt8(truncatingIfNeeded: (54 * r00 + 183 * g00 + 19 * b00 + 128) >> 8)

                let b01 = Int(src0[col1 * 4 + 0])
                let g01 = Int(src0[col1 * 4 + 1])
                let r01 = Int(src0[col1 * 4 + 2])
                dY0[col1] = UInt8(truncatingIfNeeded: (54 * r01 + 183 * g01 + 19 * b01 + 128) >> 8)

                let b10 = Int(src1[col0 * 4 + 0])
                let g10 = Int(src1[col0 * 4 + 1])
                let r10 = Int(src1[col0 * 4 + 2])
                dY1[col0] = UInt8(truncatingIfNeeded: (54 * r10 + 183 * g10 + 19 * b10 + 128) >> 8)

                let b11 = Int(src1[col1 * 4 + 0])
                let g11 = Int(src1[col1 * 4 + 1])
                let r11 = Int(src1[col1 * 4 + 2])
                dY1[col1] = UInt8(truncatingIfNeeded: (54 * r11 + 183 * g11 + 19 * b11 + 128) >> 8)

                let cb = ((-31 * r00 - 103 * g00 + 134 * b00 + 128) >> 8) + 128
                let cr = ((144 * r00 - 131 * g00 - 13 * b00 + 128) >> 8) + 128
                dUV[col0] = UInt8(clamping: cb)
                dUV[col1] = UInt8(clamping: cr)
            }
        }
    }

    private static func populateStaticCardNV12(_ nv12Buffer: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(nv12Buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(nv12Buffer, []) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(nv12Buffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(nv12Buffer, 1) else { return }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(nv12Buffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(nv12Buffer, 1)
        let dstY = yBase.assumingMemoryBound(to: UInt8.self)
        let dstUV = uvBase.assumingMemoryBound(to: UInt8.self)

        // Base dark background
        fillNV12Rect(
            dstY: dstY, yStride: yStride,
            dstUV: dstUV, uvStride: uvStride,
            x: 0, y: 0, rectWidth: width, rectHeight: height,
            luma: 28, cb: 132, cr: 126
        )

        let topBarsHeight = Int(Double(height) * 0.62) & ~1
        let midBarsHeight = Int(Double(height) * 0.20) & ~1
        let barCount = barYUVTop.count

        for index in 0..<barCount {
            let x0 = (index * width / barCount) & ~1
            let x1 = index == barCount - 1 ? width : ((index + 1) * width / barCount) & ~1
            let w = max(0, x1 - x0)
            guard w > 0 else { continue }
            let topColor = barYUVTop[index]
            fillNV12Rect(
                dstY: dstY, yStride: yStride,
                dstUV: dstUV, uvStride: uvStride,
                x: x0, y: 0, rectWidth: w, rectHeight: topBarsHeight,
                luma: topColor.y, cb: topColor.cb, cr: topColor.cr
            )
            let midColor = barYUVMid[index]
            fillNV12Rect(
                dstY: dstY, yStride: yStride,
                dstUV: dstUV, uvStride: uvStride,
                x: x0, y: topBarsHeight, rectWidth: w, rectHeight: midBarsHeight,
                luma: midColor.y, cb: midColor.cb, cr: midColor.cr
            )
        }
    }

    private static func fillNV12Rect(
        dstY: UnsafeMutablePointer<UInt8>,
        yStride: Int,
        dstUV: UnsafeMutablePointer<UInt8>,
        uvStride: Int,
        x: Int,
        y: Int,
        rectWidth: Int,
        rectHeight: Int,
        luma: UInt8,
        cb: UInt8,
        cr: UInt8
    ) {
        let xEven = x & ~1
        let yEven = y & ~1
        let wEven = rectWidth & ~1
        let hEven = rectHeight & ~1
        guard wEven > 0, hEven > 0 else { return }

        for row in yEven..<(yEven + hEven) {
            memset(dstY.advanced(by: row * yStride + xEven), Int32(luma), wEven)
        }
        let uvPattern = UInt16(cb) | (UInt16(cr) << 8)
        let chromaStartRow = yEven / 2
        let chromaRows = hEven / 2
        let chromaCols = wEven / 2
        for cRow in chromaStartRow..<(chromaStartRow + chromaRows) {
            let rowPtr = UnsafeMutableRawPointer(dstUV.advanced(by: cRow * uvStride + xEven))
                .assumingMemoryBound(to: UInt16.self)
            for cCol in 0..<chromaCols {
                rowPtr[cCol] = uvPattern
            }
        }
    }

    // MARK: - Drawing

    private static func drawContent(
        in context: CGContext,
        width: Int,
        height: Int,
        frameIndex: Int,
        mode: TestContentMode,
        overlayLines: [String]
    ) {
        let w = CGFloat(width)
        let h = CGFloat(height)

        // Background.
        context.setFillColor(color(0.04, 0.05, 0.07, 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        switch mode {
        case .card:
            drawBars(in: context, width: w, height: h, frameIndex: frameIndex)
        case .image(let url):
            drawImage(at: url, in: context, width: w, height: h)
        case .video:
            drawBars(in: context, width: w, height: h, frameIndex: frameIndex)
        }

        drawOverlay(in: context, width: w, height: h, frameIndex: frameIndex, lines: overlayLines)
    }

    private static func drawBars(in context: CGContext, width: CGFloat, height: CGFloat, frameIndex: Int) {
        let barsHeight = height * 0.62

        // Top row: the seven colour bars.
        let barWidth = width / CGFloat(barColors.count)
        for (index, bar) in barColors.enumerated() {
            context.setFillColor(color(bar.0, bar.1, bar.2, 1))
            context.fill(CGRect(
                x: CGFloat(index) * barWidth,
                y: height - barsHeight,
                width: barWidth + 1,
                height: barsHeight
            ))
        }

        // Middle row: darker reverse bars.
        let midHeight = height * 0.20
        let midBarWidth = width / CGFloat(barColors.count)
        for (index, bar) in barColors.enumerated().reversed() {
            context.setFillColor(color(
                bar.0 * 0.45,
                bar.1 * 0.45,
                bar.2 * 0.45,
                1
            ))
            context.fill(CGRect(
                x: CGFloat(index) * midBarWidth,
                y: height - barsHeight - midHeight,
                width: midBarWidth + 1,
                height: midHeight
            ))
        }

        // Bottom strip: a progress bar that advances with every frame, so a
        // frozen picture is obvious on the receiver.
        let stripY = height * 0.08
        let stripHeight = height * 0.10
        context.setFillColor(color(0.10, 0.11, 0.14, 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: stripY + stripHeight))

        let phase = Double(frameIndex % 240) / 240.0
        context.setFillColor(color(0.16, 0.85, 0.75, 1))
        context.fill(CGRect(
            x: 0,
            y: stripY,
            width: width * CGFloat(phase),
            height: stripHeight
        ))

        // A block that sweeps across the colour bars.
        let sweepX = width * CGFloat(phase)
        context.setFillColor(color(1, 1, 1, 0.55))
        context.fill(CGRect(x: sweepX, y: height - barsHeight, width: width * 0.012, height: barsHeight))
    }

    private static func drawImage(at url: URL, in context: CGContext, width: CGFloat, height: CGFloat) {
        bufferLock.lock()
        if cachedImageURL != url || cachedImage == nil {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                cachedImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
                cachedImageURL = url
            }
        }
        let image = cachedImage
        bufferLock.unlock()

        guard let image else {
            // Fall back to the bars if the image cannot be read.
            drawBars(in: context, width: width, height: height, frameIndex: 0)
            return
        }

        // Scale to fit while preserving the aspect ratio.
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let scale = min(width / imageWidth, height / imageHeight)
        let drawWidth = imageWidth * scale
        let drawHeight = imageHeight * scale
        let originX = (width - drawWidth) / 2
        let originY = (height - drawHeight) / 2

        context.setFillColor(color(0.04, 0.05, 0.07, 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(
            image,
            in: CGRect(x: originX, y: originY, width: drawWidth, height: drawHeight)
        )
    }

    private static func drawOverlay(
        in context: CGContext,
        width: CGFloat,
        height: CGFloat,
        frameIndex: Int,
        lines: [String]
    ) {
        // A translucent panel behind the text keeps it readable over any
        // background.
        let panelHeight = CGFloat(lines.count) * height * 0.052 + height * 0.03
        context.setFillColor(color(0, 0, 0, 0.55))
        context.fill(CGRect(
            x: 0,
            y: height - panelHeight,
            width: width,
            height: panelHeight
        ))

        var y = height - height * 0.022
        for (index, line) in lines.enumerated() {
            let fontSize = height * (index == 0 ? 0.058 : 0.034)
            drawText(
                line,
                in: context,
                at: CGPoint(x: width * 0.022, y: y),
                fontSize: fontSize,
                color: index == 0
                    ? color(0.20, 0.95, 0.85, 1)
                    : color(1, 1, 1, 1)
            )
            y -= fontSize * 1.35
        }
    }

    private static func drawText(
        _ text: String,
        in context: CGContext,
        at point: CGPoint,
        fontSize: CGFloat,
        color: CGColor
    ) {
        let sizeKey = Int(fontSize * 10)
        bufferLock.lock()
        let font: CTFont
        if let existing = fontCache[sizeKey] {
            font = existing
        } else {
            let created = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
            fontCache[sizeKey] = created
            font = created
        }
        bufferLock.unlock()
        let attributes = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color
        ] as CFDictionary

        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes) else {
            return
        }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)

        let bounds = CGRect(
            x: point.x,
            y: point.y - fontSize * 1.1,
            width: 20000,
            height: fontSize * 1.6
        )
        let path = CGPath(rect: bounds, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: CFAttributedStringGetLength(attributed)),
            path,
            nil
        )
        CTFrameDraw(frame, context)
    }

    // MARK: - Pixel buffers

    private static func ensureBuffers(width: Int, height: Int) -> (bgra: CVPixelBuffer, overlayBGRA: CVPixelBuffer, staticNV12: CVPixelBuffer, nv12: CVPixelBuffer)? {
        bufferLock.lock()
        defer { bufferLock.unlock() }

        let attributes = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ] as CFDictionary

        let overlayAllocHeight = min(height, max(32, (Int(Double(height) * 0.28) + 1) & ~1))

        if cachedWidth != width || cachedHeight != height || cachedBGRA == nil || cachedOverlayBGRA == nil || cachedStaticNV12 == nil || cachedNV12Pool.count < 3 {
            var bgra: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &bgra) == kCVReturnSuccess,
                  let bgra else { return nil }
            var overlayBGRA: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, width, overlayAllocHeight, kCVPixelFormatType_32BGRA, attributes, &overlayBGRA) == kCVReturnSuccess,
                  let overlayBGRA else { return nil }
            var staticNV12: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes, &staticNV12) == kCVReturnSuccess,
                  let staticNV12 else { return nil }
            var pool: [CVPixelBuffer] = []
            for _ in 0..<3 {
                var nv12: CVPixelBuffer?
                guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes, &nv12) == kCVReturnSuccess,
                      let nv12 else { return nil }
                pool.append(nv12)
            }
            cachedBGRA = bgra
            cachedOverlayBGRA = overlayBGRA
            cachedStaticNV12 = staticNV12
            cachedStaticIsCard = false
            cachedNV12Pool = pool
            cachedNV12Index = 0
            cachedWidth = width
            cachedHeight = height
        }
        guard let bgra = cachedBGRA,
              let overlayBGRA = cachedOverlayBGRA,
              let staticNV12 = cachedStaticNV12 else { return nil }
        let nv12 = cachedNV12Pool[cachedNV12Index % cachedNV12Pool.count]
        cachedNV12Index = (cachedNV12Index + 1) % cachedNV12Pool.count
        return (bgra, overlayBGRA, staticNV12, nv12)
    }

    /// Converts a BGRA buffer into the biplanar NV12 layout the encoder takes.
    private static func convertBGRAtoNV12(
        _ bgraBuffer: CVPixelBuffer,
        into nv12Buffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        // The caller already holds the BGRA lock, so it must not be locked
        // again here: a nested lock on the same pixel buffer is rejected by
        // CoreVideo and would release the mapping early.
        CVPixelBufferLockBaseAddress(nv12Buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(nv12Buffer, []) }

        guard let bgraBase = CVPixelBufferGetBaseAddress(bgraBuffer) else { return nil }
        let bgraStride = CVPixelBufferGetBytesPerRow(bgraBuffer)
        let bgra = bgraBase.assumingMemoryBound(to: UInt8.self)

        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(nv12Buffer, 0),
              let cbCrBase = CVPixelBufferGetBaseAddressOfPlane(nv12Buffer, 1) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(nv12Buffer, 0)
        let cbCrStride = CVPixelBufferGetBytesPerRowOfPlane(nv12Buffer, 1)

        let y = yBase.assumingMemoryBound(to: UInt8.self)
        let cbCr = cbCrBase.assumingMemoryBound(to: UInt8.self)

        let chromaWidth = width / 2
        let chromaHeight = height / 2

        // Combined single-pass 2x2 block conversion (luma + chroma together).
        for chromaRow in 0..<chromaHeight {
            let row0 = chromaRow * 2
            let row1 = row0 + 1
            let src0 = bgra + row0 * bgraStride
            let src1 = bgra + row1 * bgraStride
            let dstY0 = y + row0 * yStride
            let dstY1 = y + row1 * yStride
            let dstUV = cbCr + chromaRow * cbCrStride

            for chromaCol in 0..<chromaWidth {
                let col0 = chromaCol * 2
                let col1 = col0 + 1

                let b00 = Int(src0[col0 * 4 + 0])
                let g00 = Int(src0[col0 * 4 + 1])
                let r00 = Int(src0[col0 * 4 + 2])
                dstY0[col0] = UInt8(truncatingIfNeeded: (54 * r00 + 183 * g00 + 19 * b00 + 128) >> 8)

                let b01 = Int(src0[col1 * 4 + 0])
                let g01 = Int(src0[col1 * 4 + 1])
                let r01 = Int(src0[col1 * 4 + 2])
                dstY0[col1] = UInt8(truncatingIfNeeded: (54 * r01 + 183 * g01 + 19 * b01 + 128) >> 8)

                let b10 = Int(src1[col0 * 4 + 0])
                let g10 = Int(src1[col0 * 4 + 1])
                let r10 = Int(src1[col0 * 4 + 2])
                dstY1[col0] = UInt8(truncatingIfNeeded: (54 * r10 + 183 * g10 + 19 * b10 + 128) >> 8)

                let b11 = Int(src1[col1 * 4 + 0])
                let g11 = Int(src1[col1 * 4 + 1])
                let r11 = Int(src1[col1 * 4 + 2])
                dstY1[col1] = UInt8(truncatingIfNeeded: (54 * r11 + 183 * g11 + 19 * b11 + 128) >> 8)

                let cb = ((-31 * r00 - 103 * g00 + 134 * b00 + 128) >> 8) + 128
                let cr = ((144 * r00 - 131 * g00 - 13 * b00 + 128) >> 8) + 128
                dstUV[col0] = UInt8(clamping: cb)
                dstUV[col1] = UInt8(clamping: cr)
            }
        }

        return nv12Buffer
    }
}

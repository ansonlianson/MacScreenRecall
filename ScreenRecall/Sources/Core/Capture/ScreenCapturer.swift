import Foundation
import ScreenCaptureKit
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import AppKit

struct CapturedFrame {
    let displayId: String
    let displayLabel: String
    let pixelWidth: Int
    let pixelHeight: Int
    let jpegData: Data
    let phash: String?
}

actor ScreenCapturer {
    static let shared = ScreenCapturer()
    private init() {}

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func captureAllDisplays(maxLongEdge: Int, jpegQuality: Int) async throws -> [CapturedFrame] {
        var content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            DebugFile.write("SCShareableContent failed: \(error.localizedDescription) — re-requesting permission")
            _ = CGRequestScreenCaptureAccess()
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        if content.displays.isEmpty {
            DebugFile.write("displays=0 from SCShareableContent — re-requesting permission and retrying")
            _ = CGRequestScreenCaptureAccess()
            try? await Task.sleep(nanoseconds: 500_000_000)
            content = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)) ?? content
        }
        DebugFile.write("displays found=\(content.displays.count)")
        var out: [CapturedFrame] = []
        for display in content.displays {
            do {
                let frame = try await capture(display: display,
                                              maxLongEdge: maxLongEdge,
                                              jpegQuality: jpegQuality)
                out.append(frame)
            } catch {
                DebugFile.write("display \(display.displayID) capture failed: \(error.localizedDescription)")
            }
        }
        return out
    }

    private func capture(display: SCDisplay,
                         maxLongEdge: Int,
                         jpegQuality: Int) async throws -> CapturedFrame {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let width = Int(CGFloat(display.width) * scale)
        let height = Int(CGFloat(display.height) * scale)
        cfg.width = width
        cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.queueDepth = 1
        cfg.showsCursor = true
        cfg.pixelFormat = kCVPixelFormatType_32BGRA

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        let label = displayLabel(for: display)
        let displayId = String(display.displayID)
        let resized = resize(cgImage: cgImage, maxLongEdge: maxLongEdge)
        let jpeg = encodeJPEG(image: resized, quality: jpegQuality)
        let phash = phash64(of: resized)
        return CapturedFrame(
            displayId: displayId,
            displayLabel: label,
            pixelWidth: resized.width,
            pixelHeight: resized.height,
            jpegData: jpeg,
            phash: phash
        )
    }

    private func displayLabel(for display: SCDisplay) -> String {
        let id = CGDirectDisplayID(display.displayID)
        for screen in NSScreen.screens {
            let num = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            if num == id { return screen.localizedName }
        }
        return "Display \(display.displayID)"
    }

    private func resize(cgImage: CGImage, maxLongEdge: Int) -> CGImage {
        let w = cgImage.width, h = cgImage.height
        let longEdge = max(w, h)
        guard longEdge > maxLongEdge else { return cgImage }
        let scale = CGFloat(maxLongEdge) / CGFloat(longEdge)
        let newW = Int(CGFloat(w) * scale)
        let newH = Int(CGFloat(h) * scale)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: newW, height: newH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return cgImage
        }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? cgImage
    }

    private func encodeJPEG(image: CGImage, quality: Int) -> Data {
        let q = max(1, min(100, quality))
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return Data()
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: Double(q) / 100.0]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    private func phash64(of cgImage: CGImage) -> String? {
        let size = 8
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: size,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = ctx.data else { return nil }
        let buf = data.bindMemory(to: UInt8.self, capacity: size * size)
        var pixels = [UInt8](repeating: 0, count: size * size)
        for i in 0..<(size * size) { pixels[i] = buf[i] }
        let avg = pixels.reduce(0) { $0 + Int($1) } / pixels.count
        var bits: UInt64 = 0
        for (i, p) in pixels.enumerated() {
            if Int(p) >= avg { bits |= (1 << (63 - i)) }
        }
        return String(bits, radix: 16)
    }
}

enum PHashUtil {
    static func hammingHex(_ a: String?, _ b: String?) -> Int? {
        guard let a, let b, let ai = UInt64(a, radix: 16), let bi = UInt64(b, radix: 16) else {
            return nil
        }
        return (ai ^ bi).nonzeroBitCount
    }
}

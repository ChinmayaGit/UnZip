import AppKit
import CoreGraphics
import Foundation
import ImageIO

enum IconFile {
    static func nsImage(at url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return NSImage(contentsOf: url)
        }
        return nsImage(from: data)
    }

    static func nsImage(from data: Data) -> NSImage? {
        if let cg = cgImage(from: data) {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        if let image = NSImage(data: data), image.isValid, image.size.width > 0 {
            return image
        }
        return nil
    }

    static func cgImage(from data: Data) -> CGImage? {
        if let image = decodeICO(data) { return image }
        if let image = imageIO(data) { return image }
        return nil
    }

    private static func imageIO(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        if CGImageSourceGetCount(source) == 0 { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
    }

    private static func decodeICO(_ data: Data) -> CGImage? {
        guard data.count >= 22 else { return nil }
        let type = u16(data, 2)
        let count = Int(u16(data, 4))
        guard type == 1 || type == 2, count > 0, count <= 64 else { return nil }

        var best: CGImage?
        var bestScore = -1
        for index in 0..<count {
            let entry = 6 + index * 16
            guard entry + 16 <= data.count else { break }
            let width = data[entry] == 0 ? 256 : Int(data[entry])
            let height = data[entry + 1] == 0 ? 256 : Int(data[entry + 1])
            let size = Int(u32(data, entry + 8))
            let offset = Int(u32(data, entry + 12))
            guard size > 0, offset >= 0, offset + size <= data.count else { continue }
            let payload = data.subdata(in: offset..<(offset + size))
            guard let image = decodeFrame(payload, width: width, height: height) else { continue }
            let score = image.width * image.height
            if score > bestScore {
                bestScore = score
                best = image
            }
        }
        return best
    }

    private static func decodeFrame(_ data: Data, width: Int, height: Int) -> CGImage? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return imageIO(data)
        }
        return decodeDIB(data, declaredWidth: width, declaredHeight: height)
    }

    private static func decodeDIB(_ data: Data, declaredWidth: Int, declaredHeight: Int) -> CGImage? {
        guard data.count >= 40 else { return nil }
        let headerSize = Int(u32(data, 0))
        guard headerSize >= 40, headerSize <= data.count else { return nil }
        let width = max(1, Int(i32(data, 4)))
        let rawHeight = Int(i32(data, 8))
        var height = abs(rawHeight)
        if declaredHeight > 0, height == declaredHeight * 2 {
            height = declaredHeight
        } else if declaredHeight > 0, height > declaredHeight {
            height = declaredHeight
        }
        let bitCount = Int(u16(data, 14))
        let compression = u32(data, 16)
        guard [1, 4, 8, 16, 24, 32].contains(bitCount) else { return nil }
        guard compression == 0 || compression == 3 else { return nil }

        var palette: [UInt8] = []
        var pixelsAt = headerSize
        if compression == 3, headerSize == 40 {
            pixelsAt += 12
        }
        if bitCount <= 8 {
            var colors = Int(u32(data, 32))
            if colors == 0 { colors = 1 << bitCount }
            colors = min(colors, 256)
            let paletteBytes = colors * 4
            guard pixelsAt + paletteBytes <= data.count else { return nil }
            palette = Array(data[pixelsAt..<(pixelsAt + paletteBytes)])
            pixelsAt += paletteBytes
        }
        let rowBytes = ((bitCount * width + 31) / 32) * 4
        guard pixelsAt + rowBytes * height <= data.count else { return nil }
        let bottomUp = rawHeight >= 0

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let srcY = bottomUp ? (height - 1 - y) : y
            let row = pixelsAt + srcY * rowBytes
            for x in 0..<width {
                var r: UInt8 = 0
                var g: UInt8 = 0
                var b: UInt8 = 0
                var a: UInt8 = 255
                switch bitCount {
                case 32:
                    b = data[row + x * 4]
                    g = data[row + x * 4 + 1]
                    r = data[row + x * 4 + 2]
                    a = data[row + x * 4 + 3]
                    if a == 0, r != 0 || g != 0 || b != 0 { a = 255 }
                case 24:
                    b = data[row + x * 3]
                    g = data[row + x * 3 + 1]
                    r = data[row + x * 3 + 2]
                case 16:
                    let value = UInt16(data[row + x * 2]) | UInt16(data[row + x * 2 + 1]) << 8
                    r = UInt8(((value >> 11) & 0x1F) * 255 / 31)
                    g = UInt8(((value >> 5) & 0x3F) * 255 / 63)
                    b = UInt8((value & 0x1F) * 255 / 31)
                case 8:
                    let index = Int(data[row + x]) * 4
                    if index + 2 < palette.count {
                        b = palette[index]
                        g = palette[index + 1]
                        r = palette[index + 2]
                    }
                case 4:
                    let packed = data[row + x / 2]
                    let index = Int((x % 2 == 0) ? (packed >> 4) : (packed & 0x0F)) * 4
                    if index + 2 < palette.count {
                        b = palette[index]
                        g = palette[index + 1]
                        r = palette[index + 2]
                    }
                default:
                    let packed = data[row + x / 8]
                    let bit = (packed >> (7 - (x % 8))) & 1
                    let index = Int(bit) * 4
                    if index + 2 < palette.count {
                        b = palette[index]
                        g = palette[index + 1]
                        r = palette[index + 2]
                    } else {
                        let v: UInt8 = bit == 0 ? 0 : 255
                        r = v
                        g = v
                        b = v
                    }
                }
                let dest = (y * width + x) * 4
                rgba[dest] = r
                rgba[dest + 1] = g
                rgba[dest + 2] = b
                rgba[dest + 3] = a
            }
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func i32(_ data: Data, _ offset: Int) -> Int32 {
        Int32(bitPattern: u32(data, offset))
    }
}

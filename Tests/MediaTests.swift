import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct MediaTestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct MediaTests {
    static var passed = 0

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw MediaTestFailure(description: message) }
    }

    static func test(_ name: String, _ body: () throws -> Void) throws {
        try body()
        passed += 1
        print("PASS \(name)")
    }

    static func rejects(_ operation: () throws -> Void) throws {
        var rejected = false
        do { try operation() } catch { rejected = true }
        try require(rejected, "Expected the invalid image to be rejected")
    }

    static func image(width: Int = 96, height: Int = 64, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func write(_ frames: [CGImage], type: UTType, to url: URL, animated: Bool = false) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames.count, nil) else {
            throw MediaTestFailure(description: "Could not create the original test fixture")
        }
        if animated {
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        }
        for frame in frames {
            let properties: CFDictionary? = animated
                ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.24,
                                                   kCGImagePropertyGIFUnclampedDelayTime: 0.24]] as CFDictionary
                : type == .tiff ? [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1]] as CFDictionary : nil
            CGImageDestinationAddImage(destination, frame, properties)
        }
        try require(CGImageDestinationFinalize(destination), "Could not finish the test fixture")
    }

    static func bytes(from dataURL: String) -> Data? {
        guard let value = dataURL.split(separator: ",", maxSplits: 1).last else { return nil }
        return Data(base64Encoded: String(value))
    }

    static func centerColor(_ image: CGImage) -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                                    bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel
    }

    @MainActor static func main() throws {
        let root = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/media-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let gifURL = root.appendingPathComponent("animated-red-green-blue.gif")
        let pngURL = root.appendingPathComponent("static-large.png")
        let jpegURL = root.appendingPathComponent("static.jpeg")
        let tiffURL = root.appendingPathComponent("static.tiff")
        let singleURL = root.appendingPathComponent("single-frame.gif")
        let largeTIFFURL = root.appendingPathComponent("large-uncompressed.tiff")
        let frames = [image(red: 1, green: 0, blue: 0), image(red: 0, green: 1, blue: 0), image(red: 0, green: 0, blue: 1)]
        try write(frames, type: .gif, to: gifURL, animated: true)
        try write([frames[0]], type: .gif, to: singleURL)
        try write([image(width: 3200, height: 1600, red: 0.2, green: 0.5, blue: 0.8)], type: .png, to: pngURL)
        try write([frames[1]], type: .jpeg, to: jpegURL)
        try write([frames[2]], type: .tiff, to: tiffURL)
        try write([image(width: 2400, height: 2100, red: 0.3, green: 0.6, blue: 0.2)], type: .tiff, to: largeTIFFURL)
        let originalGIF = try Data(contentsOf: gifURL)
        let gifDataURL = "data:image/gif;base64," + originalGIF.base64EncodedString()

        try test("GIF loading preserves bytes and all three frames") {
            let media = try BackdropMedia.load(url: gifURL)
            try require(media.isAnimated && media.frameCount == 3, "GIF was flattened or lost its animation metadata")
            try require(media.pixelWidth == 96 && media.pixelHeight == 64, "GIF canvas dimensions changed")
            try require(bytes(from: media.dataURL) == originalGIF, "GIF bytes were rewritten")
            let rep = media.image.representations.compactMap { $0 as? NSBitmapImageRep }.first
            try require((rep?.value(forProperty: .frameCount) as? NSNumber)?.intValue == 3, "Native preview lost GIF frames")
        }
        try test("Theme JSON round-trip retains the exact GIF payload") {
            let theme = try JSONSerialization.data(withJSONObject: ["imageData": gifDataURL])
            let decodedTheme = try JSONSerialization.jsonObject(with: theme) as! [String: String]
            let loaded = try BackdropMedia.decode(dataURL: decodedTheme["imageData"]!)
            try require(loaded.dataURL == gifDataURL, "GIF import changed the data URL")
            try require(bytes(from: loaded.dataURL) == originalGIF, "GIF import changed its bytes")
        }
        try test("GIF frames contain distinct red, green, and blue images with timing") {
            let source = CGImageSourceCreateWithData(originalGIF as CFData, nil)!
            for index in 0..<3 {
                let frame = CGImageSourceCreateImageAtIndex(source, index, nil)!
                let pixel = centerColor(frame)
                try require(pixel[index] > 240, "The fixture frames are not visually distinct")
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as! [CFString: Any]
                let gif = properties[kCGImagePropertyGIFDictionary] as! [CFString: Any]
                let duration = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                    ?? (gif[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0
                try require(abs(duration - 0.24) < 0.001, "GIF frame timing changed")
            }
        }
        try test("A single-frame GIF remains a GIF and reports static metadata") {
            let original = try Data(contentsOf: singleURL)
            let media = try BackdropMedia.load(url: singleURL)
            try require(!media.isAnimated && media.frameCount == 1, "Single-frame GIF metadata is incorrect")
            try require(bytes(from: media.dataURL) == original, "Single-frame GIF bytes changed")
        }
        try test("GIF87a headers are supported") {
            var original = try Data(contentsOf: singleURL)
            original.replaceSubrange(0..<6, with: Data("GIF87a".utf8))
            let media = try BackdropMedia.decode(dataURL: "data:image/gif;base64," + original.base64EncodedString())
            try require(media.frameCount == 1 && bytes(from: media.dataURL) == original, "GIF87a was not retained")
        }
        try test("Large static PNGs still normalize to a 2400px thumbnail") {
            let media = try BackdropMedia.load(url: pngURL)
            try require(!media.isAnimated && media.frameCount == 1, "PNG was marked as animated")
            try require(media.pixelWidth == 2400 && media.pixelHeight == 1200, "Static thumbnail dimensions are incorrect")
            try require(media.dataURL.hasPrefix("data:image/png;base64,"), "Static image was not normalized to PNG")
            let imported = try BackdropMedia.decode(dataURL: media.dataURL)
            try require(imported.pixelWidth == 2400 && imported.pixelHeight == 1200, "PNG theme import changed its dimensions")
        }
        try test("JPEG and TIFF files remain supported and normalize to PNG") {
            for url in [jpegURL, tiffURL] {
                let media = try BackdropMedia.load(url: url)
                try require(media.dataURL.hasPrefix("data:image/png;base64,"), "Static image did not normalize to PNG")
                try require(media.pixelWidth == 96 && media.pixelHeight == 64 && media.frameCount == 1, "Static image metadata changed")
            }
        }
        try test("Static source files larger than 14 MB still normalize successfully") {
            let sourceSize = try largeTIFFURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            try require(sourceSize > BackdropMedia.maximumRawBytes, "The uncompressed TIFF fixture must genuinely exceed 14 MB")
            let media = try BackdropMedia.load(url: largeTIFFURL)
            try require(!media.isAnimated && media.dataURL.hasPrefix("data:image/png;base64,"), "Large static input was not normalized")
            try require(media.pixelWidth == 2400 && media.pixelHeight == 2100, "Large TIFF dimensions were lost")
            try require((bytes(from: media.dataURL)?.count ?? Int.max) <= BackdropMedia.maximumRawBytes, "Normalized image exceeds the theme limit")
        }
        try test("MIME and signature mismatches are rejected") {
            try rejects { _ = try BackdropMedia.decode(dataURL: "data:image/png;base64," + originalGIF.base64EncodedString()) }
            try rejects { _ = try BackdropMedia.decode(dataURL: "data:image/gif;base64," + Data("GIF90ainvalid".utf8).base64EncodedString()) }
        }
        try test("Malformed GIF and Base64 payloads are rejected") {
            try rejects { _ = try BackdropMedia.decode(dataURL: "data:image/gif;base64," + Data("GIF89a".utf8).base64EncodedString()) }
            try rejects { _ = try BackdropMedia.decode(dataURL: "data:image/gif;base64,not base64") }
            try rejects { _ = try BackdropMedia.decode(dataURL: "data:image/gif;base64,AAAA===A") }
        }
        try test("Remote URLs and unsupported image data are rejected") {
            try rejects { _ = try BackdropMedia.load(url: URL(string: "https://example.com/background.gif")!) }
            try rejects { _ = try BackdropMedia.decode(dataURL: "https://example.com/background.gif") }
            try rejects { _ = try BackdropMedia.decode(dataURL: "data:image/svg+xml;base64,PHN2Zz4=") }
        }
        try test("Oversized payloads and GIF canvases are rejected") {
            try rejects { _ = try BackdropMedia.decode(dataURL: "data:image/gif;base64," + String(repeating: "A", count: BackdropMedia.maximumDataURLCharacters)) }
            var tooWide = originalGIF
            tooWide[6] = 1; tooWide[7] = 32 // 8193 logical pixels wide.
            try rejects { _ = try BackdropMedia.decode(dataURL: "data:image/gif;base64," + tooWide.base64EncodedString()) }
            let hugeURL = root.appendingPathComponent("oversized.gif")
            try (originalGIF + Data(repeating: 0, count: BackdropMedia.maximumRawBytes)).write(to: hugeURL)
            defer { try? FileManager.default.removeItem(at: hugeURL) }
            try rejects { _ = try BackdropMedia.load(url: hugeURL) }
        }
        print("\(passed) media tests passed")
        print("Original animation fixture: \(gifURL.path) (red → green → blue, 0.24s each, loop forever)")
    }
}

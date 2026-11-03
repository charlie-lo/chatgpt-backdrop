import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The data URL is the payload saved in a theme and passed to the renderer.
/// GIF payloads retain their original frames, timing, and looping metadata.
struct LoadedBackdropMedia {
    let image: NSImage
    let dataURL: String
    let isAnimated: Bool
    let frameCount: Int
    let pixelWidth: Int
    let pixelHeight: Int
}

enum BackdropMediaError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

/// Decodes local files only. Static images are resized; GIFs are not flattened.
enum BackdropMedia {
    static let maximumRawBytes = 14 * 1024 * 1024
    static let maximumStaticSourceBytes = 64 * 1024 * 1024
    static let maximumDataURLCharacters = 20 * 1024 * 1024
    static let maximumThumbnailDimension = 2400
    static let maximumGIFDimension = 8192
    static let maximumGIFPixelsPerFrame = 16_777_216
    static let maximumGIFFrameCount = 600
    static let maximumGIFDecodedPixels = 240_000_000

    static func load(url: URL) throws -> LoadedBackdropMedia {
        guard url.isFileURL else {
            throw BackdropMediaError.invalid("Choose an image stored on this Mac.")
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw BackdropMediaError.invalid("Choose an image file.")
        }
        guard let size = values.fileSize, size > 0, size <= maximumStaticSourceBytes else {
            throw BackdropMediaError.invalid("Choose a static image no larger than 64 MB or a GIF no larger than 14 MB.")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try decodeBytes(data, declaredMIME: nil, maximumInputBytes: maximumStaticSourceBytes)
    }

    static func decode(dataURL: String) throws -> LoadedBackdropMedia {
        guard dataURL.utf8.count < maximumDataURLCharacters,
              let comma = dataURL.firstIndex(of: ",") else {
            throw BackdropMediaError.invalid("The theme image exceeds the size limit or has an invalid data URL.")
        }
        let header = String(dataURL[..<comma])
        let mime: String
        switch header {
        case "data:image/png;base64": mime = "image/png"
        case "data:image/jpeg;base64": mime = "image/jpeg"
        case "data:image/webp;base64": mime = "image/webp"
        case "data:image/gif;base64": mime = "image/gif"
        default:
            throw BackdropMediaError.invalid("Themes support local PNG, JPEG, WebP, or GIF image data.")
        }
        let encoded = String(dataURL[dataURL.index(after: comma)...])
        guard !encoded.isEmpty, encoded.utf8.count.isMultiple(of: 4),
              encoded.range(of: "^[A-Za-z0-9+/]+={0,2}$", options: .regularExpression) != nil,
              let bytes = Data(base64Encoded: encoded) else {
            throw BackdropMediaError.invalid("The theme image contains invalid Base64 data.")
        }
        return try decodeBytes(bytes, declaredMIME: mime)
    }

    private static func decodeBytes(_ data: Data, declaredMIME: String?, maximumInputBytes: Int = maximumRawBytes) throws -> LoadedBackdropMedia {
        guard !data.isEmpty, data.count <= maximumInputBytes else {
            throw BackdropMediaError.invalid("The source image exceeds the size limit.")
        }
        let detectedMIME = signatureMIME(data)
        if detectedMIME == "image/gif" && data.count > maximumRawBytes {
            throw BackdropMediaError.invalid("Choose a GIF no larger than 14 MB.")
        }
        if let declaredMIME = declaredMIME, detectedMIME != declaredMIME {
            throw BackdropMediaError.invalid("The image contents do not match the declared format.")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let sourceType = CGImageSourceGetType(source) as String?,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0 else {
            throw BackdropMediaError.invalid("Could not decode this image. Choose a valid PNG, JPEG, WebP, HEIC, TIFF, or GIF file.")
        }
        if sourceType == UTType.gif.identifier {
            guard detectedMIME == "image/gif" else {
                throw BackdropMediaError.invalid("The GIF must have a valid GIF87a or GIF89a header.")
            }
            return try animatedGIF(data, source: source)
        }
        let staticTypes = [UTType.png.identifier, UTType.jpeg.identifier, UTType.webP.identifier,
                           UTType.heic.identifier, UTType.heif.identifier, UTType.tiff.identifier]
        guard staticTypes.contains(sourceType) else {
            throw BackdropMediaError.invalid("Choose a PNG, JPEG, WebP, HEIC, TIFF, or GIF file.")
        }
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumThumbnailDimension
        ] as CFDictionary),
              let normalized = NSBitmapImageRep(cgImage: thumbnail).representation(using: .png, properties: [:]),
              normalized.count <= maximumRawBytes else {
            throw BackdropMediaError.invalid("Could not prepare this image. Choose a smaller image.")
        }
        let url = try makeDataURL(normalized, mime: "image/png")
        let image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        return LoadedBackdropMedia(image: image, dataURL: url, isAnimated: false, frameCount: 1,
                                   pixelWidth: thumbnail.width, pixelHeight: thumbnail.height)
    }

    private static func animatedGIF(_ data: Data, source: CGImageSource) throws -> LoadedBackdropMedia {
        let count = CGImageSourceGetCount(source)
        guard count > 0, count <= maximumGIFFrameCount, data.count >= 13 else {
            throw BackdropMediaError.invalid("This GIF has no usable frames or exceeds the 600-frame limit.")
        }
        // The logical screen dimensions protect against oversized GIF canvases,
        // including files whose individual frame rectangles are much smaller.
        let header = [UInt8](data.prefix(10))
        let width = Int(header[6]) | (Int(header[7]) << 8)
        let height = Int(header[8]) | (Int(header[9]) << 8)
        guard width > 0, height > 0, width <= maximumGIFDimension, height <= maximumGIFDimension,
              width * height <= maximumGIFPixelsPerFrame,
              width * height * count <= maximumGIFDecodedPixels else {
            throw BackdropMediaError.invalid("This GIF is too large to animate. Choose a smaller image or fewer frames.")
        }
        for index in 0..<count {
            guard CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let frameWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let frameHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  frameWidth > 0, frameHeight > 0,
                  frameWidth <= maximumGIFDimension, frameHeight <= maximumGIFDimension,
                  frameWidth * frameHeight <= maximumGIFPixelsPerFrame else {
                throw BackdropMediaError.invalid("This GIF contains an incomplete or oversized frame.")
            }
        }
        guard let image = NSImage(data: data), image.isValid,
              image.representations.contains(where: { ($0 as? NSBitmapImageRep) != nil }) else {
            throw BackdropMediaError.invalid("Could not open this GIF for animated preview.")
        }
        image.size = NSSize(width: width, height: height)
        return LoadedBackdropMedia(image: image, dataURL: try makeDataURL(data, mime: "image/gif"),
                                   isAnimated: count > 1, frameCount: count,
                                   pixelWidth: width, pixelHeight: height)
    }

    private static func makeDataURL(_ data: Data, mime: String) throws -> String {
        let url = "data:\(mime);base64," + data.base64EncodedString()
        guard url.utf8.count < maximumDataURLCharacters else {
            throw BackdropMediaError.invalid("The prepared image exceeds the theme size limit.")
        }
        return url
    }

    private static func signatureMIME(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.count >= 12, Array(bytes[0..<4]) == [0x52, 0x49, 0x46, 0x46],
           Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) { return "image/gif" }
        return nil
    }
}

/// NSImageView preserves native GIF timing. SwiftUI owns the outer crop/offset.
/// Reusing the same NSImage avoids resetting playback when a slider changes.
struct AnimatedBackdropImage: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageFrameStyle = .none
        view.imageScaling = .scaleAxesIndependently
        view.isEditable = false
        view.animates = true
        view.image = image
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setAccessibilityLabel("Background preview")
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image !== image { view.image = image }
        view.animates = true
    }
}

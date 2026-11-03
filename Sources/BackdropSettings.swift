import Foundation

enum ReadingMode: String, Codable, CaseIterable, Identifiable {
    case none, sheet, cards, focus

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var summary: String {
        switch self {
        case .none: return "Keep the current appearance."
        case .sheet: return "One calm surface behind the conversation."
        case .cards: return "Separate surfaces behind each response."
        case .focus: return "Softly shade the center without a border."
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .none
    }
}

struct BackdropPosition: Codable {
    var x = 50.0
    var y = 50.0

    init(x: Double = 50, y: Double = 50) { self.x = x; self.y = y }

    private enum CodingKeys: String, CodingKey { case x, y }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 50
        y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 50
    }
}

struct BackdropSettings: Codable {
    var imageData: String
    var opacity = 0.40
    var blur = 0.0
    var panelOpacity = 0.72
    var position = BackdropPosition()
    var readingMode = ReadingMode.none
    var readingOpacity = 0.60
    var readingBlur = 8.0

    init(imageData: String, opacity: Double = 0.40, blur: Double = 0,
         panelOpacity: Double = 0.72, position: BackdropPosition = BackdropPosition(),
         readingMode: ReadingMode = .none, readingOpacity: Double = 0.60,
         readingBlur: Double = 8) {
        self.imageData = imageData
        self.opacity = opacity
        self.blur = blur
        self.panelOpacity = panelOpacity
        self.position = position
        self.readingMode = readingMode
        self.readingOpacity = Self.clamp(readingOpacity, fallback: 0.60, range: 0...1)
        self.readingBlur = Self.clamp(readingBlur, fallback: 8, range: 0...24)
    }

    private enum CodingKeys: String, CodingKey {
        case imageData, opacity, blur, panelOpacity, position
        case readingMode, readingOpacity, readingBlur
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        imageData = try container.decode(String.self, forKey: .imageData)
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.40
        blur = try container.decodeIfPresent(Double.self, forKey: .blur) ?? 0
        panelOpacity = try container.decodeIfPresent(Double.self, forKey: .panelOpacity) ?? 0.72
        position = try container.decodeIfPresent(BackdropPosition.self, forKey: .position) ?? BackdropPosition()
        readingMode = try container.decodeIfPresent(ReadingMode.self, forKey: .readingMode) ?? .none
        readingOpacity = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .readingOpacity) ?? 0.60,
                                    fallback: 0.60, range: 0...1)
        readingBlur = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .readingBlur) ?? 8,
                                 fallback: 8, range: 0...24)
    }

    private static func clamp(_ value: Double, fallback: Double, range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

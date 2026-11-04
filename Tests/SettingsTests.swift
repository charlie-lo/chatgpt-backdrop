import Foundation

@main
struct SettingsTests {
    static func main() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            count += 1
            print("PASS: \(name)")
        }
        func decode(_ text: String) throws -> BackdropSettings {
            try decoder.decode(BackdropSettings.self, from: Data(text.utf8))
        }

        let legacy = try decode(#"{"imageData":"data:image/png;base64,old","opacity":0.2,"blur":4,"panelOpacity":0.18,"position":{"x":25,"y":75}}"#)
        check(legacy.readingMode == .none, "legacy themes keep Reading Mode off")
        check(legacy.readingOpacity == 0.60 && legacy.readingBlur == 8, "legacy themes receive independent reading defaults")
        check(legacy.opacity == 0.2 && legacy.blur == 4 && legacy.panelOpacity == 0.18, "legacy appearance values are preserved")
        check(legacy.position.x == 25 && legacy.position.y == 75, "legacy image position is preserved")

        let minimal = try decode(#"{"imageData":"local-image"}"#)
        check(minimal.readingMode == .none && minimal.panelOpacity == 0.72, "minimal themes use safe defaults")
        check(minimal.position.x == 50 && minimal.position.y == 50, "missing image position remains centered")
        let partialPosition = try decode(#"{"imageData":"image","position":{"x":20}}"#)
        check(partialPosition.position.x == 20 && partialPosition.position.y == 50, "partially specified position retains the missing coordinate default")

        let unknown = try decode(#"{"imageData":"image","readingMode":"future-mode","readingOpacity":0.35,"readingBlur":3}"#)
        check(unknown.readingMode == .none, "unknown reading modes fall back to None")
        check(unknown.readingOpacity == 0.35 && unknown.readingBlur == 3, "future modes do not discard independent control values")
        let nullFields = try decode(#"{"imageData":"image","readingMode":null,"readingOpacity":null,"readingBlur":null}"#)
        check(nullFields.readingMode == .none && nullFields.readingOpacity == 0.60 && nullFields.readingBlur == 8, "null optional reading fields use defaults")

        for mode in ReadingMode.allCases {
            let original = BackdropSettings(imageData: "data:image/gif;base64,R0lGODlh", panelOpacity: 0.19,
                readingMode: mode, readingOpacity: 0.61, readingBlur: 11)
            let data = try encoder.encode(original)
            let roundtrip = try decoder.decode(BackdropSettings.self, from: data)
            check(roundtrip.readingMode == mode, "\(mode.title) survives theme export/import")
            check(roundtrip.readingOpacity == 0.61 && roundtrip.readingBlur == 11, "\(mode.title) reading controls survive export/import")
            check(roundtrip.imageData == original.imageData && roundtrip.panelOpacity == 0.19, "\(mode.title) preserves media and sidebar opacity")
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            check(object["readingMode"] as? String == mode.rawValue, "\(mode.title) exports its stable engine value")
        }
        check(ReadingMode.allCases.map(\.title) == ["None", "Sheet", "Cards", "Focus"], "all four one-word labels are stable and ordered")

        let clamped = try decode(#"{"imageData":"image","readingOpacity":-3,"readingBlur":500}"#)
        check(clamped.readingOpacity == 0 && clamped.readingBlur == 24, "imported reading values are bounded")
        let opposite = try decode(#"{"imageData":"image","readingOpacity":3,"readingBlur":-4}"#)
        check(opposite.readingOpacity == 1 && opposite.readingBlur == 0, "both numeric limits are bounded")
        let nonfinite = BackdropSettings(imageData: "image", readingOpacity: .infinity, readingBlur: .nan)
        check(nonfinite.readingOpacity == 0.60 && nonfinite.readingBlur == 8, "non-finite initializer values use defaults")

        var rejectedMissingImage = false
        do { _ = try decode(#"{"readingMode":"sheet"}"#) } catch { rejectedMissingImage = true }
        check(rejectedMissingImage, "required image data is not silently fabricated")
        print("All \(count) settings checks passed.")
    }
}

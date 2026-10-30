import Foundation
import SwiftUI

/// Things that write new kinds of data into the dash, switched on one at a time after a
/// bike test. On 2026-10-17 colour slots above 18 (and/or our first drawn screen) left the
/// Bluetooth unit unable to show the phone screen until the pairing was deleted and redone.
enum Features {
    /// Send our own LIVE screen (MYSTERY_BOX) to the dash. Off by default; the rider turns it
    /// on from the home screen. Uses RoadSync's own colour slots only (no custom colours).
    static let drawOnDashKey = "feature.drawOnDash"
    static var drawOnDash: Bool { UserDefaults.standard.bool(forKey: drawOnDashKey) }
    /// Put the user's colour into the orange slots instead of RoadSync's orange.
    static let customColours = false
}

/// Dash colour slots. 0/1 are fixed white/black; 2-18 are RoadSync's palette, registered by us
/// at connect. Slots above 18 are accepted but stop the dash from showing the phone screen.
enum DashColor {
    static let white: UInt8 = 0
    static let black: UInt8 = 1
    static let orange: UInt8 = 14, orangeDark: UInt8 = 15, orangeLight: UInt8 = 13
}

/// Built-in dash icons (Assignments.IconId). Values overlap between groups:
/// arrows are the action frame, action icons go inside it, content icons are separate.
enum DashIcon {
    static let none: UInt8 = 0
    // Live-screen action frame
    static let arrowLeft: UInt8 = 1, arrowRight: UInt8 = 2
    // Live-screen action contents
    static let play: UInt8 = 3, pause: UInt8 = 4, next: UInt8 = 5
}

/// User theme: one accent colour, with darker and lighter variants derived from it.
struct Theme: Equatable {
    var red: Double, green: Double, blue: Double

    static let honda = Theme(red: 0.80, green: 0.08, blue: 0.12)

    var color: Color { Color(red: red, green: green, blue: blue) }

    init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }

    #if canImport(UIKit)
    init(_ color: Color) {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(red: Double(r), green: Double(g), blue: Double(b))
    }
    #endif

    private func rgb(_ transform: (Double) -> Double) -> [UInt8] {
        [red, green, blue].map { UInt8(max(0, min(255, (transform($0) * 255).rounded()))) }
    }

    var palette: (main: [UInt8], dark: [UInt8], light: [UInt8]) { (main, dark, light) }
    var main: [UInt8] { rgb { $0 } }
    var dark: [UInt8] { rgb { $0 * 0.35 } }
    var light: [UInt8] { rgb { $0 + (1 - $0) * 0.35 } }

    // Persistence
    private static let key = "dashTheme"
    static func load() -> Theme {
        guard let values = UserDefaults.standard.array(forKey: key) as? [Double], values.count == 3 else { return .honda }
        return Theme(red: values[0], green: values[1], blue: values[2])
    }
    func save() { UserDefaults.standard.set([red, green, blue], forKey: Theme.key) }
}

/// The three colour slots a screen is drawn with.
struct ScreenColors: Equatable {
    var main: UInt8, dark: UInt8, light: UInt8
    /// The orange family, which carries the user's theme RGB.
    static let theme = ScreenColors(main: DashColor.orange, dark: DashColor.orangeDark, light: DashColor.orangeLight)
}

/// RoadSync's LIVE screen (CommandBuilder.f / projections.LiveScreen.a):
/// header bar, two text lines, optional left/right action icons.
struct LiveScreen: Equatable {
    var header: String
    var line1: String?
    var line2: String?
    var leftAction: UInt8?
    var rightAction: UInt8?
    var colors: ScreenColors

    static let maxText = 30

    /// The dash font is basic; keep to printable ASCII-ish text and the 30-character limit.
    static func clean(_ text: String) -> [UInt8] {
        // Letters that have no ASCII base form: map them before folding drops them.
        let mapped = text.map { (c: Character) -> String in
            switch c {
            case "ı": return "i"
            case "İ": return "I"
            case "ß": return "ss"
            case "æ": return "ae"
            case "Æ": return "AE"
            case "ø": return "o"
            case "Ø": return "O"
            case "ł": return "l"
            case "Ł": return "L"
            case "đ": return "d"
            case "Đ": return "D"
            case "\u{2018}", "\u{2019}": return "'"
            case "\u{201C}", "\u{201D}": return "\""
            case "\u{2013}", "\u{2014}": return "-"
            case "\u{2026}": return "..."
            default: return String(c)
            }
        }.joined()
        let folded = mapped.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7F }
        return Array(String(String.UnicodeScalarView(scalars)).prefix(maxText).utf8)
    }

    private static func text(_ string: String?, color: UInt8) -> [UInt8] {
        let bytes = string.map(clean) ?? []
        return bytes.isEmpty ? [0] : [UInt8(bytes.count)] + bytes + [color]
    }

    private func action(frame: UInt8, content: UInt8?) -> [UInt8] {
        guard let content else { return [DashIcon.none] }
        // frame icon, frame tint, content icon, content tint, background
        return [frame, DashColor.black, content, DashColor.white, colors.light]
    }

    func encode(requestId: UInt8) -> Data {
        var bytes: [UInt8] = [0x01, requestId, colors.main]           // MYSTERY_BOX, request, header background
        bytes += Self.text(header, color: DashColor.white)
        bytes += [0x02, colors.main]                                   // LIVE_SCREEN body, body background
        bytes += action(frame: DashIcon.arrowLeft, content: leftAction)
        bytes += action(frame: DashIcon.arrowRight, content: rightAction)
        bytes += [colors.dark, DashIcon.none]                          // content background, no content icon
        bytes += Self.text(line1, color: DashColor.white)
        bytes += Self.text(line2, color: DashColor.white)
        return Data(bytes)
    }
}

/// Receipt on Data.ControlPoint: [command, requestId, status, errorPosition?]
struct Receipt {
    let command: UInt8, requestId: UInt8, status: UInt8, errorPosition: UInt8?

    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 3, b.count <= 4 else { return nil }
        command = b[0]; requestId = b[1]; status = b[2]
        errorPosition = b.count == 4 ? b[3] : nil
    }

    var isOK: Bool { status == 1 }
}

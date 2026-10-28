import AppKit
import SwiftUI

/// The Garment Designer's look: dark greys, an orange accent for what is selected, a hue per seam.
enum GarmentTheme {
    static let window = NSColor(white: 0.13, alpha: 1)
    static let panel = NSColor(white: 0.17, alpha: 1)
    static let canvas = NSColor(white: 0.21, alpha: 1)
    static let grid = NSColor(white: 0.25, alpha: 1)
    static let gridMajor = NSColor(white: 0.32, alpha: 1)
    static let outline = NSColor(white: 0.92, alpha: 1)
    static let point = NSColor(white: 0.95, alpha: 1)
    static let handle = NSColor(red: 0.45, green: 0.75, blue: 1, alpha: 1)
    static let accent = NSColor(red: 1, green: 0.6, blue: 0.12, alpha: 1)
    static let internalLine = NSColor(red: 0.3, green: 0.55, blue: 0.95, alpha: 1)
    static let grain = NSColor(white: 0.35, alpha: 1)
    static let allowance = NSColor(white: 0.75, alpha: 0.8)
    static let frozen = NSColor(red: 0.4, green: 0.75, blue: 1, alpha: 0.5)
    static let warning = NSColor(red: 1, green: 0.25, blue: 0.25, alpha: 1)
    static let text = NSColor(white: 0.12, alpha: 1)
    static let dim = NSColor(white: 0.75, alpha: 1)

    static let swAccent = Color(accent)
    static let swPanel = Color(panel)
    static let swWindow = Color(window)
    static let swText = Color(white: 0.88)
    static let swDim = Color(white: 0.58)

    /// The `n`th seam's colour: hues round the wheel, apart.
    static func seamColour(_ n: Int) -> NSColor {
        NSColor(hue: CGFloat((Double(n) * 0.618_034).truncatingRemainder(dividingBy: 1)), saturation: 0.75, brightness: 0.95, alpha: 1)
    }
}

import AppKit
import DesertAntUI
import SwiftUI

/// The brand colors the cards use, beyond what the kit names.
enum Theme {
    /// A color from its sRGB hex value.
    static func rgb(_ hex: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }

    static let cream = rgb(0xFBFAF4)
    static let ink = rgb(0x0E1113)

    /// A step's card colors: its model's, or the plain step card's.
    static func card(_ def: StepDef) -> (fill: Color, ink: Color, tag: Color) {
        def.model.map(model) ?? (fill: stepFill, ink: Color.primary, tag: stepTag)
    }

    /// A model's card, as the brand's feature card has it: the model's color,
    /// the ink on it, and the tint behind its tag (`.feature-card--<color>`).
    static func model(_ id: ModelID) -> (fill: Color, ink: Color, tag: Color) {
        let inkTag = rgb(0x0E1113, 0.05)
        return switch id.info.color {
        case "dark-teal": (rgb(0x1C525D), cream, rgb(0xFBFAF4, 0.08))
        case "teal": (rgb(0xC3D3CE), ink, inkTag)
        case "light-peach": (rgb(0xF8DBCA), ink, inkTag)
        case "forest": (rgb(0x181E1D), cream, rgb(0xFBFAF4, 0.05))
        case "stone": (rgb(0xB4AEA6), ink, inkTag)
        case "terracotta": (rgb(0xDB704C), ink, rgb(0x0E1113, 0.08))
        case "ink": (ink, cream, rgb(0xFBFAF4, 0.08))
        case "sand": (rgb(0xD6D0C3), ink, inkTag)
        case "warm-grey": (rgb(0xB7B6B4), ink, inkTag)
        case "slate": (rgb(0x344B5A), cream, rgb(0xFBFAF4, 0.05))
        case "sage": (rgb(0xADB49C), ink, inkTag)
        case "rosewood": (rgb(0xCC9087), ink, inkTag)
        case "dusty-pink": (rgb(0xB6969D), ink, inkTag)
        default: (rgb(0xF2F1EB), ink, inkTag)
        }
    }

    /// Every other step's card: the brand's gray placeholder card.
    static let stepFill = Color(light: rgb(0xF2F1EB), dark: rgb(0x262E2C))
    static let stepTag = Color(light: rgb(0x0E1113, 0.05), dark: rgb(0xFBFAF4, 0.08))
    static let canvas = DA.Color.bgCanvas
    static let dot = Color(light: rgb(0x0E1113, 0.14), dark: rgb(0xFBFAF4, 0.12))
    static let window = Color(light: rgb(0xFBFAF4), dark: rgb(0x181E1D))
    static let hairline = Color(light: rgb(0x0E1113, 0.1), dark: rgb(0xFBFAF4, 0.12))

    /// Wires take the color of what they carry. The dark brand colors are
    /// lifted in dark mode, where they would sink into the window.
    static func wire(_ type: PortType) -> Color {
        switch type {
        // Each kind of value its own clear color, legible on the light canvas
        // and the dark one, and on the model cards wires pass behind.
        case .text: Color(light: rgb(0x3E8A6F), dark: rgb(0x6FC3A3))
        case .audio: Color(light: rgb(0x1F7A8C), dark: rgb(0x5CC0D4))
        case .image: Color(light: rgb(0x3D6FB0), dark: rgb(0x86AEE6))
        case .stroke: Color(light: rgb(0xD0643E), dark: rgb(0xF0936E))
        case .any: Color(light: rgb(0x6A6F78), dark: rgb(0xB4BAC2))
        }
    }

    static let danger = rgb(0xBE3A2E)
    static let success = rgb(0x3C8A52)
}

extension Color {
    /// One color for light mode and another for dark.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }
}

/// A small symbol for each kind of step, for its card's top row and the palette.
func symbol(for type: String) -> String {
    switch type {
    case "call": "phone"
    case "watch": "folder"
    case "schedule": "clock"
    case "shortcut": "command"
    case "if": "arrow.triangle.branch"
    case "ask": "questionmark.bubble"
    case "merge": "arrow.triangle.merge"
    case "list": "list.number"
    case "best": "star"
    case "template": "curlybraces"
    case "join": "text.append"
    case "convert": "arrow.left.arrow.right.square"
    case "readtext": "text.viewfinder"
    case "captions": "captions.bubble"
    case "gallery": "square.grid.2x2"
    case "table": "tablecells"
    case "view": "checkmark.seal"
    case "folder": "folder"
    case "files": "doc.on.doc"
    case "rename": "character.cursor.ibeam"
    case "copy": "folder.badge.plus"
    case "speak": "speaker.wave.2"
    case "text": "text.alignleft"
    case "textlist": "list.bullet.rectangle"
    case "audio": "waveform"
    case "record": "mic"
    case "image": "photo"
    case "photos": "photo.on.rectangle"
    case "sketch": "scribble"
    case "whiteboard": "pencil.and.scribble"
    case "cleanboard": "square.on.circle"
    case "note": "note.text"
    default: "circle"
    }
}

/// Times as the cards show them.
func formatMs(_ ms: Double) -> String {
    ms < 1 ? "<1ms" : ms < 1000 ? "\(Int(ms.rounded()))ms" : String(format: "%.1fs", ms / 1000)
}

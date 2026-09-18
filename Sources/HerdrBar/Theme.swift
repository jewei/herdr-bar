// Hallmark · component: agent palette · theme: user screenshot · genre: modern-minimal
// Pre-emit critique: Philosophy 5, Hierarchy 4, Execution 4, Specificity 5, Restraint 5, Variety 4.
// Native controls provide hover, focus, press, and disabled states. The palette handles loading,
// connection errors, and successful updates. A fixed-width font follows the supplied terminal UI.
import AppKit
import SwiftUI
import HerdrBarCore

enum Theme {
    static let background = Color(hex: 0x131f2b)
    static let foreground = Color(hex: 0xd8deeb)
    static let muted = Color(hex: 0x9baad1)
    static let selected = Color(hex: 0x383c54)
    static let hover = Color(hex: 0x253144)
    static let divider = Color(hex: 0x314155)
    static let focus = Color(hex: 0xc7a1f5)
    static let idle = Color(hex: 0x66d994)
    static let running = Color(hex: 0xf1f58c)
    static let blocked = Color(hex: 0xffb873)
    static let done = Color(hex: 0x87c7ff)
    static let unknown = Color(hex: 0xa2acbb)

    static let width: CGFloat = 300
    static let rowHeight: CGFloat = 48
    static let maximumListHeight: CGFloat = 480
    static let body = Font.system(size: 13, weight: .medium, design: .monospaced)
    static let caption = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let header = Font.system(size: 12, weight: .semibold, design: .monospaced)

    static func color(for status: AgentStatus) -> Color {
        switch status {
        case .idle: idle
        case .working: running
        case .blocked: blocked
        case .done: done
        case .unknown: unknown
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255, opacity: 1)
    }
}

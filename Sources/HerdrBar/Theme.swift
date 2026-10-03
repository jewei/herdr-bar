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

    static let width: CGFloat = 360
    static let rowHeight: CGFloat = 56
    static let rowSpacing: CGFloat = 2
    static let listInset: CGFloat = 8
    static let headerHeight: CGFloat = 52
    static let footerHeight: CGFloat = 74
    static let emptyHeight: CGFloat = 180
    static let offlineHeight: CGFloat = 78
    static let maximumListHeight: CGFloat = 360
    static let maximumPaletteHeight: CGFloat = 640
    static let cornerRadius: CGFloat = 6
    static let body = Font.system(size: 13, weight: .medium, design: .monospaced)
    static let caption = Font.system(size: 12)
    static let header = Font.system(size: 14, weight: .semibold, design: .monospaced)

    static func listHeight(count: Int) -> CGFloat {
        min(CGFloat(count) * (rowHeight + rowSpacing) - rowSpacing + listInset * 2, maximumListHeight)
    }

    static func errorHeight(_ message: String) -> CGFloat {
        min(150, max(64, errorTextHeight(message) + 28))
    }

    static func errorNeedsScrolling(_ message: String) -> Bool {
        errorTextHeight(message) + 28 > 150
    }

    private static func errorTextHeight(_ message: String) -> CGFloat {
        let bounds = (message as NSString).boundingRect(
            with: NSSize(width: width - 90, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 12)])
        return ceil(bounds.height)
    }

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

import AppKit
import SwiftUI
import HerdrBarCore

enum Theme {
    static let background = Color(hex: 0x141820)
    static let foreground = Color(hex: 0xe8ecf4)
    static let muted = Color(hex: 0x9ea9bd)
    static let selected = Color(hex: 0x28283d)
    static let hover = Color(hex: 0x202631)
    static let divider = Color(hex: 0x343c4b)
    static let focus = Color(hex: 0xc6b2ff)
    static let idle = Color(hex: 0x8fcab0)
    static let running = Color(hex: 0xe6d590)
    static let blocked = Color(hex: 0xf4ba87)
    static let done = Color(hex: 0x91baff)
    static let unknown = Color(hex: 0xafb8c7)

    static let width: CGFloat = 384
    static let rowHeight: CGFloat = 60
    static let rowSpacing: CGFloat = 4
    static let listInset: CGFloat = 10
    static let headerHeight: CGFloat = 68
    static let footerHeight: CGFloat = 72
    static let emptyHeight: CGFloat = 232
    static let offlineHeight: CGFloat = 80
    static let maximumListHeight: CGFloat = 400
    static let maximumPaletteHeight: CGFloat = 640
    static let cornerRadius: CGFloat = 10
    static let body = Font.system(size: 13, weight: .medium, design: .monospaced)
    static let caption = Font.system(size: 12)
    static let header = Font.system(size: 20, weight: .semibold)

    static func listHeight(count: Int) -> CGFloat {
        min(CGFloat(max(0, count)) * (rowHeight + rowSpacing) - (count > 0 ? rowSpacing : 0) + listInset * 2, maximumListHeight)
    }

    static func errorHeight(_ message: String) -> CGFloat {
        min(112, max(88, errorTextHeight(message) + 64))
    }

    static func errorNeedsScrolling(_ message: String) -> Bool {
        errorTextHeight(message) + 64 > 112
    }

    private static func errorTextHeight(_ message: String) -> CGFloat {
        let bounds = (message as NSString).boundingRect(
            with: NSSize(width: width - 64, height: .greatestFiniteMagnitude),
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

import AppKit
import HerdrBarCore

/// The menu bar item's content, shared by all status groups in one button.
struct StatusPresentation: Equatable {
    struct Group: Equatable {
        let symbol: String
        let tint: NSColor
        let count: Int?
    }

    let groups: [Group]
    let text: String

    init(summary: AgentSummary, connected: Bool, loading: Bool) {
        text = connected ? (summary.description.isEmpty ? "No agents" : summary.description)
            : loading ? "Connecting to Herdr" : "Herdr is offline"
        if !connected {
            groups = [Group(symbol: loading ? "ellipsis.circle" : "bolt.slash.circle",
                            tint: .secondaryLabelColor, count: nil)]
            return
        }
        let active = [
            Group(symbol: "exclamationmark.circle", tint: .systemOrange, count: summary.blocked),
            Group(symbol: "circle.inset.filled", tint: .systemYellow, count: summary.running),
            Group(symbol: "checkmark.circle", tint: .systemBlue, count: summary.done),
        ].filter { ($0.count ?? 0) > 0 }
        if !active.isEmpty {
            groups = active
        } else if summary.unknown > 0 {
            groups = [Group(symbol: "questionmark.circle", tint: .secondaryLabelColor, count: summary.unknown)]
        } else {
            groups = [Group(symbol: "circle", tint: .labelColor, count: nil)]
        }
    }

    @MainActor
    var attributedTitle: NSAttributedString {
        let title = NSMutableAttributedString(string: "")
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        for (index, group) in groups.enumerated() {
            if index > 0 { title.append(NSAttributedString(string: "  ", attributes: attributes)) }
            if let image = NSImage(systemSymbolName: group.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))?
                .withSymbolConfiguration(.init(paletteColors: [group.tint])) {
                image.isTemplate = false
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = NSRect(x: 0, y: (font.capHeight - image.size.height) / 2,
                                           width: image.size.width, height: image.size.height)
                title.append(NSAttributedString(attachment: attachment))
            }
            if let count = group.count {
                title.append(NSAttributedString(string: " \(count)", attributes: attributes))
            }
        }
        return title
    }
}

import SwiftUI
import HerdrBarCore

struct AgentRowView: View {
    let row: AgentRow
    let selected: Bool
    let opening: Bool
    let available: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    private var statusColor: Color {
        available ? Theme.color(for: row.status) : Theme.unknown
    }

    private var active: Bool { available && isEnabled && (selected || hovered) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                statusWell

                VStack(alignment: .leading, spacing: 6) {
                    Text(row.workspace)
                        .font(Theme.body)
                        .foregroundStyle(available ? Theme.foreground : Theme.foreground.opacity(0.7))
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 7) {
                        Text(row.kind)
                            .font(.system(size: 11, weight: .medium))
                            .truncationMode(.tail)
                            .frame(maxWidth: 74, alignment: .leading)
                            .fixedSize()
                        Circle()
                            .fill(Theme.muted.opacity(0.45))
                            .frame(width: 2, height: 2)
                        Image(systemName: "macwindow")
                            .font(.system(size: 9, weight: .medium))
                            .accessibilityHidden(true)
                        Text(row.tab)
                            .font(.system(size: 11, design: .monospaced))
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(Theme.muted)
                }
                .lineLimit(1)
                .layoutPriority(1)

                HStack(spacing: 8) {
                    Text(opening ? "Opening…" : row.status.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(statusColor.opacity(available ? 0.09 : 0.05), in: Capsule())
                        .fixedSize()
                        .frame(width: 65, alignment: .trailing)

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.focus)
                        .opacity(active && !opening ? 0.85 : 0)
                        .frame(width: 10)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: Theme.rowHeight)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(selected && available ? Theme.focus.opacity(contrast == .increased ? 0.8 : 0.25) : Color.white.opacity(hovered && available && isEnabled ? 0.05 : 0), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: selected)
        }
        .buttonStyle(RowButtonStyle())
        .disabled(!available)
        .onHover { hovered = $0 }
        .help("\(row.title)\n\(row.kind) · \(row.status.label) · \(row.detail)\n\(available ? "Open in Herdr" : "Last known status. Reconnect to open.")")
        .accessibilityLabel("\(row.workspace), tab \(row.tab), \(row.kind), \(available ? "" : "Offline. Last known status: ")\(row.status.label)")
        .accessibilityValue(opening ? "Opening" : selected ? "Selected" : "")
        .accessibilityHint(available ? "Open this agent in Herdr" : "Herdr is offline")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var rowBackground: Color {
        guard available else { return .clear }
        return selected ? Theme.selected : hovered && isEnabled ? Theme.hover : .clear
    }

    private var statusWell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(statusColor.opacity(available ? 0.09 : 0.04))
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(statusColor.opacity(contrast == .increased ? 0.65 : available ? 0.12 : 0.08), lineWidth: 1)
            if opening {
                PaletteProgressIndicator(size: 14, color: statusColor)
            } else if available {
                StatusMark(status: row.status)
            } else {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.unknown)
            }
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }
}

struct StatusMark: View {
    let status: AgentStatus

    var body: some View {
        Group {
            switch status {
            case .idle:
                Circle().strokeBorder(Theme.idle, lineWidth: 1.5).frame(width: 8, height: 8)
            case .working:
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.running)
            case .blocked:
                Image(systemName: "exclamationmark").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.blocked)
            case .done:
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.done)
            case .unknown:
                Image(systemName: "questionmark").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.unknown)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct RowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .fill(configuration.isPressed ? Theme.focus.opacity(0.08) : .clear)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

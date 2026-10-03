import SwiftUI

struct PaletteEmptyState: View {
    var loading: Bool
    var connected: Bool
    var retrying: Bool
    var connectionError: String?
    var retry: () -> Void
    var editConnection: () -> Void

    private var accent: Color { connected || loading ? Theme.focus : Theme.blocked }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(accent.opacity(0.08))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(accent.opacity(0.17), lineWidth: 1)
                if loading {
                    PaletteProgressIndicator(size: 16)
                        .accessibilityLabel("Connecting to Herdr")
                } else {
                    Image(systemName: connected ? "terminal" : "bolt.slash")
                        .font(.system(size: 21, weight: .regular))
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 46, height: 46)

            Text(loading ? "Connecting to Herdr" : connected ? "Ready when you are" : "Herdr is offline")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.foreground)
                .padding(.top, 14)

            Text(loading ? "Reading your agent status…" : connected
                 ? "Start an agent in Herdr.\nIts status will appear here."
                 : "Start Herdr in your terminal,\nor check your connection.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)

            if !loading, !connected {
                PaletteRecoveryActions(retrying: retrying, connectionError: connectionError,
                                       retry: retry, editConnection: editConnection)
                    .padding(.top, 18)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .frame(height: Theme.emptyHeight)
        .accessibilityElement(children: .contain)
    }
}

struct PaletteOfflineNotice: View {
    var retrying: Bool
    var connectionError: String?
    var retry: () -> Void
    var editConnection: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "bolt.slash")
                    .foregroundStyle(Theme.blocked)
                    .accessibilityHidden(true)
                Text("Offline")
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.blocked)
                Text("·")
                    .foregroundStyle(Theme.muted)
                Text("Showing last known status")
                    .foregroundStyle(Theme.muted)
            }
            .font(.system(size: 12))
            .lineLimit(1)
            PaletteRecoveryActions(retrying: retrying, connectionError: connectionError,
                                   retry: retry, editConnection: editConnection)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .frame(height: Theme.offlineHeight)
        .background(Theme.blocked.opacity(0.035))
        .overlay(alignment: .bottom) {
            Theme.blocked.opacity(0.12).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

struct PaletteErrorNotice: View {
    var message: String
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.blocked)
                .frame(width: 12, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Action failed")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.foreground)
                    Spacer(minLength: 0)
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(PaletteDismissButtonStyle())
                    .help("Dismiss message (Esc)")
                    .accessibilityLabel("Dismiss message")
                }
                .frame(height: 24)

                ScrollView {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.automatic)
                .help(message)

                if Theme.errorNeedsScrolling(message) {
                    Label("Scroll for details", systemImage: "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.muted)
                        .frame(height: 12)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(height: Theme.errorHeight(message))
        .background(Theme.blocked.opacity(0.035))
        .overlay(alignment: .top) {
            Theme.blocked.opacity(0.14).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct PaletteRecoveryActions: View {
    var retrying: Bool
    var connectionError: String?
    var retry: () -> Void
    var editConnection: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: retry) {
                HStack(spacing: 6) {
                    if retrying {
                        PaletteProgressIndicator(size: 12)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(retrying ? "Connecting…" : "Retry connection")
                }
                .frame(minWidth: 118)
            }
            .buttonStyle(PaletteRecoveryButtonStyle(prominent: true))
            .disabled(retrying)
            .help(connectionError ?? "Connect to Herdr")

            Button("Connection…", action: editConnection)
                .buttonStyle(PaletteRecoveryButtonStyle(prominent: false))
                .help("Choose how to connect to Herdr")
        }
        .font(.system(size: 12, weight: .medium))
    }
}

private struct PaletteRecoveryButtonStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? (prominent ? Theme.focus : Theme.foreground) : Theme.muted)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(fill(pressed: configuration.isPressed),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private var border: Color {
        if contrast == .increased { return Theme.muted }
        return prominent ? Theme.focus.opacity(0.28) : Theme.divider.opacity(0.7)
    }

    private func fill(pressed: Bool) -> Color {
        if !isEnabled { return Theme.hover.opacity(0.4) }
        if prominent { return Theme.focus.opacity(pressed ? 0.26 : hovering ? 0.19 : 0.11) }
        return pressed ? Theme.selected : hovering ? Theme.hover : Theme.hover.opacity(0.5)
    }
}

private struct PaletteDismissButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? Theme.foreground : Theme.muted)
            .background(configuration.isPressed ? Theme.selected : hovering ? Theme.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

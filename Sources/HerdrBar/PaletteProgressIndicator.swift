import SwiftUI

/// A visible progress indicator for pending actions on the dark palette.
struct PaletteProgressIndicator: View {
    var size: CGFloat = 14
    var color: Color = Theme.focus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotating = false

    var body: some View {
        Group {
            if reduceMotion {
                Image(systemName: "hourglass")
                    .font(.system(size: size - 1, weight: .medium))
                    .foregroundStyle(color)
            } else {
                ZStack {
                    Circle().strokeBorder(color.opacity(0.2), lineWidth: 1.5)
                    Circle().trim(from: 0, to: 0.28)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .padding(0.75)
                        .rotationEffect(.degrees(rotating ? 360 : 0))
                        .animation(rotating ? .linear(duration: 0.85).repeatForever(autoreverses: false) : nil,
                                   value: rotating)
                }
                .onAppear { rotating = true }
                .onDisappear { rotating = false }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

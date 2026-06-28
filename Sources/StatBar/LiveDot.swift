import SwiftUI

/// A small green "live" indicator that gently pulses — a halo ring expands and
/// fades around a solid core on a slow repeating loop. Used everywhere a game is
/// live (popup hero status, game-list rows, the notch tile) so the cue reads the
/// same in every surface. Static when reduced-motion is on (just the core).
struct LiveDot: View {
    var size: CGFloat = 7
    var color: Color = .green

    @State private var animating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !reduceMotion {
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .scaleEffect(animating ? 2.4 : 1)
                    .opacity(animating ? 0 : 0.5)
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                animating = true
            }
        }
        .accessibilityHidden(true)
    }
}

import SwiftUI

/// A ring showing how far along something is.
///
/// The centre always carries a number or label, so the ring is decoration on
/// top of a readable value rather than the only way to read it. Growth is
/// animated because the movement explains progress — and is skipped entirely
/// when the student has asked for reduced motion.
struct ProgressRing<Center: View>: View {
    let fraction: Double
    var lineWidth: CGFloat = 10
    var tint: Color = .accentColor
    @ViewBuilder var center: () -> Center

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.15), lineWidth: lineWidth)

            // Nothing drawn at zero. A round line cap on a zero-length trim
            // still paints a dot, which reads as "a little progress".
            if shown > 0 {
                Circle()
                    .trim(from: 0, to: shown)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }

            center()
        }
        .onAppear {
            guard !reduceMotion else { shown = fraction; return }
            withAnimation(.easeOut(duration: 0.7)) { shown = fraction }
        }
        .onChange(of: fraction) { _, new in
            guard !reduceMotion else { shown = new; return }
            withAnimation(.easeOut(duration: 0.4)) { shown = new }
        }
        .accessibilityHidden(true)  // The surrounding card carries the label.
    }
}

/// Today's route as a path of nodes — the visual the product is named after.
///
/// Reads left to right: filled nodes are done, the open ring is where the
/// student is now. Shape carries the state as well as colour.
struct RoutePathView: View {
    let total: Int
    let completed: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<max(total, 1), id: \.self) { index in
                node(at: index)

                if index < total - 1 {
                    Rectangle()
                        .fill(index < completed - 1 ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 3)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("今日のルート、\(total)ステップ中\(completed)ステップ完了")
    }

    @ViewBuilder
    private func node(at index: Int) -> some View {
        if index < completed {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
        } else if index == completed {
            Image(systemName: "circle.circle")
                .font(.title3)
                .foregroundStyle(.tint)
        } else {
            Image(systemName: "circle")
                .font(.title3)
                .foregroundStyle(.secondary.opacity(0.5))
        }
    }
}

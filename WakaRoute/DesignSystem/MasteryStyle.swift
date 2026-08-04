import SwiftUI
import WakaRouteKit

/// Presentation for the five understanding levels.
///
/// Every level carries a name and a distinct shape as well as a colour. §8 of
/// the 開発ガイド forbids using colour alone to convey state, and a student
/// with a colour vision deficiency has to be able to read this map.
extension MasteryLevel {

    var label: String {
        switch self {
        case .notStarted: "未着手"
        case .understandsMeaning: "意味がわかる"
        case .solvesBasics: "基本を解ける"
        case .connectsReasoning: "根拠をつなげる"
        case .appliesToNovel: "初見で使える"
        case .stableUnderTime: "時間内に安定する"
        }
    }

    /// Shown next to the label so the level is legible without colour.
    var symbolName: String {
        switch self {
        case .notStarted: "circle.dotted"
        case .understandsMeaning: "circle.bottomhalf.filled"
        case .solvesBasics: "circle.lefthalf.filled"
        case .connectsReasoning: "circle.tophalf.filled"
        case .appliesToNovel: "circle.fill"
        case .stableUnderTime: "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .notStarted: .secondary
        case .understandsMeaning: .orange
        case .solvesBasics: .yellow
        case .connectsReasoning: .mint
        case .appliesToNovel: .green
        case .stableUnderTime: .accentColor
        }
    }

    /// Spoken description. VoiceOver should say what the level means, not read
    /// out a bare number.
    var accessibilityDescription: String {
        self == .notStarted ? "未着手" : "レベル\(rawValue)、\(label)"
    }
}

/// A level shown as symbol plus words.
struct MasteryBadge: View {
    let level: MasteryLevel

    var body: some View {
        Label {
            Text(level.label)
        } icon: {
            Image(systemName: level.symbolName)
        }
        .font(.caption)
        .foregroundStyle(level.tint)
        .accessibilityLabel(level.accessibilityDescription)
    }
}

/// Five segments, one per level, filled to the level reached.
///
/// Not a percentage bar: the segments are discrete because the underlying
/// scale is.
///
/// The upper levels need 確認テスト that do not exist yet, so they are drawn
/// fainter than an unreached level and named 準備中 rather than left looking
/// like something the student failed to reach. Nobody has failed a level nobody
/// can measure.
struct MasteryScaleView: View {
    let level: MasteryLevel

    private var highestMeasurable: Int { MasteryDerivation.highestMeasurable.rawValue }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { step in
                Capsule()
                    .fill(fill(for: step))
                    .frame(height: 5)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(spoken)
    }

    private func fill(for step: Int) -> Color {
        if step <= level.rawValue { return level.tint }
        return Color.secondary.opacity(step > highestMeasurable ? 0.08 : 0.2)
    }

    private var spoken: String {
        "\(level.accessibilityDescription)。レベル\(highestMeasurable + 1)以上は確認テストの準備中です。"
    }
}

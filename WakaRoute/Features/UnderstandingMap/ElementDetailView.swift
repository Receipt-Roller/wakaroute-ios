import SwiftUI
import WakaRouteKit

/// One 要素: where the student stands, what it needs, and what it opens up.
///
/// The two relationship lists are the reason this screen exists — they make
/// the prerequisite graph legible to a student instead of leaving it as an
/// invisible ranking rule.
struct ElementDetailView: View {
    let subject: Subject
    let element: LearningElement
    let mastery: MasteryRecord

    private var focus: StudyFocus { StudyFocus(subject: subject, mastery: mastery) }
    private var level: MasteryLevel { focus.level(of: element.id) }
    private var readiness: ElementReadiness { focus.readiness(of: element) }

    private var prerequisites: [LearningElement] {
        element.prerequisiteIds.compactMap { id in
            subject.elements.first { $0.id == id }
        }
    }

    /// Elements that list this one as a prerequisite.
    private var unlocks: [LearningElement] {
        subject.elements.filter { $0.prerequisiteIds.contains(element.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                currentStanding

                if !prerequisites.isEmpty {
                    RelatedElementsSection(
                        title: "この項目の前提",
                        subtitle: "ここが不安なら、先に戻ります",
                        subject: subject,
                        elements: prerequisites,
                        focus: focus
                    )
                }

                if !unlocks.isEmpty {
                    RelatedElementsSection(
                        title: "理解すると進めるもの",
                        subtitle: "\(unlocks.count) 項目がここから先にあります",
                        subject: subject,
                        elements: unlocks,
                        focus: focus
                    )
                }
            }
            .padding()
        }
        .navigationTitle(element.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var currentStanding: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("いまの理解").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                MasteryBadge(level: level)
            }

            MasteryScaleView(level: level)

            switch readiness {
            case .mastered:
                Label("この項目は入試で使える状態です", systemImage: "checkmark.seal.fill")
                    .font(.subheadline).foregroundStyle(.green)

            case .ready:
                NavigationLink(value: AppRoute.study(title: element.name)) {
                    Label("この項目を学ぶ", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

            case let .blocked(missing):
                // Never offer to study a blocked element. Sending a student
                // into content they cannot follow is the exact failure the
                // 理解マップ exists to prevent.
                Label(
                    "先に \(missing.compactMap(name(of:)).joined(separator: "・")) を理解しておく必要があります",
                    systemImage: "arrow.turn.left.up"
                )
                .font(.subheadline)
                .foregroundStyle(.orange)
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    private func name(of id: ElementId) -> String? {
        subject.elements.first { $0.id == id }?.name
    }
}

private struct RelatedElementsSection: View {
    let title: String
    let subtitle: String
    let subject: Subject
    let elements: [LearningElement]
    let focus: StudyFocus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title, subtitle: subtitle)

            VStack(spacing: 0) {
                ForEach(Array(elements.enumerated()), id: \.element.id) { index, element in
                    NavigationLink(value: AppRoute.element(subject.id, element.id)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(element.name).font(.subheadline)
                                MasteryBadge(level: focus.level(of: element.id))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)

                    if index < elements.count - 1 { Divider() }
                }
            }
            .padding(.horizontal)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

import SwiftUI
import WakaRouteKit

/// 数学 → its four 領域, so strengths and weaknesses inside one subject are
/// visible before drilling into individual 要素.
struct SubjectDomainsView: View {
    let subject: Subject
    let mastery: MasteryRecord

    private var domains: [DomainProgress] {
        subject.domainProgress(mastery: mastery)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader(
                        title: "領域ごとの理解",
                        subtitle: "得意な領域と、手前でつまずいている領域がわかります"
                    )

                    // This screen exists to be *compared* across. On a narrow
                    // phone that means one 領域 at a time and a tap to see its
                    // 要素; given the room, showing all four with their 要素 at
                    // once is the thing the screen was always for.
                    if geometry.size.width >= StudyLayout.sideBySide {
                        DomainGrid(subject: subject, mastery: mastery, domains: domains)
                    } else {
                        ForEach(domains) { progress in
                            NavigationLink(value: AppRoute.domain(subject.id, domainId: progress.domain.id)) {
                                DomainCard(progress: progress)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
            }
        }
        .navigationTitle(subject.name)
        .navigationBarTitleDisplayMode(.large)
    }
}

/// Every 領域 and every 要素 on one screen.
private struct DomainGrid: View {
    let subject: Subject
    let mastery: MasteryRecord
    let domains: [DomainProgress]

    private var focus: StudyFocus { StudyFocus(subject: subject, mastery: mastery) }
    private let columns = [GridItem(.adaptive(minimum: 380), spacing: 16, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(domains) { progress in
                DomainPanel(
                    subject: subject,
                    progress: progress,
                    focus: focus
                )
            }
        }
    }
}

private struct DomainPanel: View {
    let subject: Subject
    let progress: DomainProgress
    let focus: StudyFocus

    private var elements: [LearningElement] {
        subject.elements(inDomain: progress.domain.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(progress.domain.code)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(progress.standing.tint)
                Text(progress.domain.name).font(.headline)
                Spacer(minLength: 4)
                StandingBadge(standing: progress.standing)
            }

            LevelDistributionBar(levelCounts: progress.levelCounts, total: progress.totalElements)

            Text("\(progress.totalElements) 項目中 \(progress.solidCount) 項目は基本を解けます")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Divider()

            ForEach(elements) { element in
                NavigationLink(value: AppRoute.element(subject.id, element.id)) {
                    CompactElementRow(
                        element: element,
                        level: focus.level(of: element.id),
                        isStumbling: focus.isStumbling(element)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Deliberately shorter than `ElementSummaryRow`.
///
/// The full row names the prerequisites that are in the way, which is what a
/// student needs when they have chosen one 要素 to look at. Repeated 26 times
/// across four panels it becomes a wall of text and defeats the comparison this
/// screen is for — so the overview shows the level, and the detail explains it.
private struct CompactElementRow: View {
    let element: LearningElement
    let level: MasteryLevel
    let isStumbling: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(element.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                if isStumbling {
                    Image(systemName: "arrow.turn.left.up")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 4)
                if let grade = element.grade {
                    Text("中\(grade)").font(.caption2).foregroundStyle(.secondary)
                }
            }

            MasteryScaleView(level: level)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(element.name)、\(level.accessibilityDescription)"
            + (isStumbling ? "、手前でつまずいています" : "")
        )
    }
}

private struct DomainCard: View {
    let progress: DomainProgress

    var body: some View {
        AdaptiveRow(spacing: 16, alignment: .top) {
            ProgressRing(
                fraction: progress.solidFraction,
                lineWidth: 7,
                tint: progress.standing.tint
            ) {
                Text(progress.domain.code)
                    .font(.headline)
                    .foregroundStyle(progress.standing.tint)
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 6) {
                // The 領域 name and its badge also stop fitting side by side —
                // at the largest sizes the capsule was squeezed to one
                // character per line.
                AdaptiveRow(spacing: 8, alignment: .firstTextBaseline) {
                    Text(progress.domain.name).font(.headline)
                    StandingBadge(standing: progress.standing)
                }

                LevelDistributionBar(levelCounts: progress.levelCounts, total: progress.totalElements)

                Text("\(progress.totalElements) 項目中 \(progress.solidCount) 項目は基本を解けます")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            RowChevron()
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(progress.domain.code)、\(progress.domain.name)、\(progress.standing.label)。"
            + "\(progress.totalElements)項目中\(progress.solidCount)項目は基本を解けます。"
        )
    }
}

/// The shape of a 領域: how many elements sit at each level.
///
/// Segments are proportional but every non-zero level keeps a minimum width,
/// so a single struggling element is still visible rather than rounded away.
struct LevelDistributionBar: View {
    let levelCounts: [(level: MasteryLevel, count: Int)]
    let total: Int

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(levelCounts.filter { $0.count > 0 }, id: \.level) { entry in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(fill(for: entry.level))
                        .frame(width: width(for: entry.count, in: geometry.size.width))
                }
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel(spokenSummary)
    }

    /// 未着手 is drawn as an empty track, not a filled segment.
    ///
    /// At full strength a 領域 nobody has opened became one solid bar across the
    /// whole width, which reads as *finished* — the opposite of the truth, and
    /// exactly what a student sees on their first launch.
    private func fill(for level: MasteryLevel) -> Color {
        level == .notStarted ? Color.secondary.opacity(0.18) : level.tint
    }

    private func width(for count: Int, in available: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        let proportional = available * CGFloat(count) / CGFloat(total)
        return max(6, proportional - 2)
    }

    private var spokenSummary: String {
        levelCounts
            .filter { $0.count > 0 }
            .map { "\($0.level.label) \($0.count)項目" }
            .joined(separator: "、")
    }
}

struct StandingBadge: View {
    let standing: DomainProgress.Standing

    var body: some View {
        Label(standing.label, systemImage: standing.symbolName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(standing.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(standing.tint)
    }
}

extension DomainProgress.Standing {
    var label: String {
        switch self {
        case .notStarted: "これから"
        case .blocked: "手前でつまずき"
        case .inProgress: "学習中"
        case .strong: "得意"
        }
    }

    var symbolName: String {
        switch self {
        case .notStarted: "circle.dotted"
        case .blocked: "exclamationmark.triangle.fill"
        case .inProgress: "arrow.triangle.turn.up.right.circle"
        case .strong: "star.fill"
        }
    }

    var tint: Color {
        switch self {
        case .notStarted: .secondary
        case .blocked: .orange
        case .inProgress: .accentColor
        case .strong: .green
        }
    }
}

#if DEBUG
/// Design review only, behind `-openMap`. Compiled out of release builds.
///
/// The 理解マップ is three pushes from the home screen, and it is the screen
/// most worth looking at against live data rather than fixtures.
struct MapPreviewView: View {
    let repository: any UnderstandingMapRepository

    @State private var subject: Subject?
    @State private var mastery = MasteryRecord()
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if let subject {
                    SubjectDomainsView(subject: subject, mastery: mastery)
                } else {
                    ContentUnavailableView("理解マップなし", systemImage: "map", description: Text(message ?? "読み込み中"))
                }
            }
            .appDestinations(context: MapContext(
                readiness: ExamReadiness(subjects: []),
                subjects: subject.map { [$0] } ?? [],
                mastery: subject.map { [$0.id: mastery] } ?? [:]
            ))
        }
        .task {
            guard case let .available(subjects) = try? await repository.subjects(),
                  let first = subjects.first else {
                message = "repository reported unavailable"
                return
            }
            if case let .available(record) = try? await repository.mastery(for: first.id) {
                mastery = record
            }
            subject = first
        }
    }
}
#endif

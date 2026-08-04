import SwiftUI
import WakaRouteKit

/// The path to the goal, and the other schools on the list.
struct GoalDetailView: View {
    let schools: TargetSchoolList
    let readiness: ExamReadiness

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let primary = schools.primary {
                    PrimaryGoalCard(goal: primary, daysRemaining: schools.daysRemaining, readiness: readiness)
                }

                readinessBreakdown

                if !schools.alternatives.isEmpty {
                    alternativesSection
                }

                deadlineNote
            }
            .padding()
        }
        .navigationTitle("めざす高校")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: AppRoute.editTargetSchools) { Text("編集") }
            }
        }
    }

    private var readinessBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "合格までの道のり", subtitle: "5教科の理解できた項目で見ています")

            VStack(spacing: 14) {
                StatRow(
                    label: "理解できた項目",
                    value: "\(readiness.masteredElements) / \(readiness.totalElements)",
                    symbol: "checkmark.circle.fill",
                    tint: .green
                )
                Divider()
                StatRow(
                    label: "手前でつまずいている項目",
                    value: "\(readiness.blockedElements)",
                    symbol: "exclamationmark.triangle.fill",
                    tint: readiness.blockedElements > 0 ? .orange : .secondary
                )
            }
            .padding()
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var alternativesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "ほかの志望校",
                subtitle: "登録した順に第二志望、第三志望として扱います"
            )

            VStack(spacing: 0) {
                ForEach(Array(schools.alternatives.enumerated()), id: \.element.id) { index, goal in
                    AlternativeGoalRow(
                        goal: goal,
                        // +1 because alternatives start after the 第一志望.
                        preference: TargetSchoolList.preferenceLabel(at: index + 1)
                    )
                    if index < schools.alternatives.count - 1 { Divider() }
                }
            }
            .padding(.horizontal)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    /// The soonest exam is the real deadline, and it is often not the 第一志望's.
    /// The server decides which that is; this only explains it.
    @ViewBuilder
    private var deadlineNote: some View {
        if schools.deadlineIsNotPrimary, let soonest = schools.schoolWithEarliestExam {
            Label {
                Text("いちばん早い入試は \(soonest.name)（あと \(soonest.daysRemaining(from: Date()) ?? 0) 日）です。準備はこの日に間に合わせます。")
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding()
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct PrimaryGoalCard: View {
    let goal: TargetSchool
    let daysRemaining: Int?
    let readiness: ExamReadiness

    var body: some View {
        VStack(spacing: 16) {
            ProgressRing(fraction: readiness.fraction, lineWidth: 13) {
                VStack(spacing: 0) {
                    Text("\(Int(readiness.fraction * 100))")
                        .font(.largeTitle.bold())
                        .monospacedDigit()
                    Text("%").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 132, height: 132)

            VStack(spacing: 4) {
                Text(TargetSchoolList.preferenceLabel(at: 0))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(goal.name)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let daysRemaining {
                    Text("いちばん早い入試まで あと \(daysRemaining) 日")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
}

private struct AlternativeGoalRow: View {
    let goal: TargetSchool
    let preference: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(preference).font(.caption2).foregroundStyle(.secondary)
                Text(goal.name).font(.subheadline)
            }
            Spacer()
            if let days = goal.daysRemaining(from: Date()) {
                Text("あと \(days) 日")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

struct StatRow: View {
    let label: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack {
            Label(label, systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .labelStyle(TintedIconLabelStyle(tint: tint))
            Spacer()
            Text(value).font(.subheadline.weight(.medium)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TintedIconLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

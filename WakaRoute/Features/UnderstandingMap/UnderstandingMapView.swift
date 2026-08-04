import SwiftUI
import WakaRouteKit

/// Subject list → 領域 summary → 要素 list → 要素 detail.
///
/// The 領域 tier exists so a student can see where they are strong and weak
/// inside one subject before facing a flat list of every 要素.
struct UnderstandingMapView: View {
    let repository: any UnderstandingMapRepository

    @State private var context = MapContext(readiness: ExamReadiness(subjects: []), subjects: [], mastery: [:])
    @State private var plannedReason: String?

    var body: some View {
        NavigationStack {
            Group {
                if let plannedReason {
                    PlannedFeatureView(reason: plannedReason)
                } else {
                    List(context.subjects) { subject in
                        if subject.elements.isEmpty {
                            SubjectListRow(subject: subject, progress: nil)
                        } else {
                            NavigationLink(value: AppRoute.subject(subject.id)) {
                                SubjectListRow(
                                    subject: subject,
                                    progress: SubjectProgress(
                                        subject: subject,
                                        mastery: context.mastery(for: subject.id)
                                    )
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle("理解マップ")
            .appDestinations(context: context)
            .task { await load() }
        }
    }

    private func load() async {
        let subjects: [Subject]
        switch try? await repository.subjects() {
        case let .available(loaded):
            subjects = loaded
            plannedReason = nil
        case let .unavailable(reason):
            plannedReason = reason
            return
        case nil:
            plannedReason = "読み込みに失敗しました。"
            return
        }

        var mastery: [SubjectId: MasteryRecord] = [:]
        var progress: [SubjectProgress] = []
        for subject in subjects {
            if case let .available(record) = try? await repository.mastery(for: subject.id) {
                mastery[subject.id] = record
                progress.append(SubjectProgress(subject: subject, mastery: record))
            }
        }

        context = MapContext(
            readiness: ExamReadiness(subjects: progress),
            subjects: subjects,
            mastery: mastery
        )
    }
}

private struct SubjectListRow: View {
    let subject: Subject
    let progress: SubjectProgress?

    var body: some View {
        HStack(spacing: 14) {
            if let progress {
                ProgressRing(fraction: progress.solidFraction, lineWidth: 5) {
                    Text("\(Int(progress.solidFraction * 100))")
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                }
                .frame(width: 40, height: 40)
            } else {
                Image(systemName: "hammer")
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(subject.name).font(.headline)

                if let progress {
                    Text("\(progress.totalElements) 項目・\(subject.domains.count) 領域")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if progress.blockedCount > 0 {
                        Label("\(progress.blockedCount) 項目が手前でつまずいています", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("準備中").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

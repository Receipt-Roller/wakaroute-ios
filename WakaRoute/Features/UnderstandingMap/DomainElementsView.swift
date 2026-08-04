import SwiftUI
import WakaRouteKit

/// The 要素 inside one 領域, in map order.
struct DomainElementsView: View {
    let subject: Subject
    let domain: LearningDomain
    let mastery: MasteryRecord

    private var focus: StudyFocus { StudyFocus(subject: subject, mastery: mastery) }
    private var elements: [LearningElement] { subject.elements(inDomain: domain.id) }

    var body: some View {
        List {
            Section {
                ForEach(elements) { element in
                    NavigationLink(value: AppRoute.element(subject.id, element.id)) {
                        ElementSummaryRow(
                            element: element,
                            level: focus.level(of: element.id),
                            readiness: focus.readiness(of: element),
                            nameOfElement: nameOfElement
                        )
                    }
                }
            } header: {
                Text("\(domain.code)　\(domain.name)")
            } footer: {
                Text("項目をタップすると、前提と次に進める内容がわかります。")
            }
        }
        .navigationTitle(domain.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func nameOfElement(_ id: ElementId) -> String {
        subject.elements.first { $0.id == id }?.name ?? "前提項目"
    }
}

/// Shared row for an element in a list.
struct ElementSummaryRow: View {
    let element: LearningElement
    let level: MasteryLevel
    let readiness: ElementReadiness
    let nameOfElement: (ElementId) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(element.name).font(.body)
                Spacer(minLength: 8)
                if let grade = element.grade {
                    Text("中\(grade)").font(.caption2).foregroundStyle(.secondary)
                }
            }

            MasteryScaleView(level: level)

            switch readiness {
            case .mastered:
                Label("習得済み", systemImage: "checkmark.seal")
                    .font(.caption).foregroundStyle(.green)
            case .ready:
                Label(level == .notStarted ? "いま学べます" : "学習中", systemImage: "play.circle")
                    .font(.caption).foregroundStyle(.secondary)
            case let .blocked(missing):
                Label(
                    "先に \(missing.map(nameOfElement).joined(separator: "・")) が必要です",
                    systemImage: "arrow.turn.left.up"
                )
                .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

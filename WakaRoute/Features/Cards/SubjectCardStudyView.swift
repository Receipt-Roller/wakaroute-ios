import SwiftUI
import WakaRouteKit

/// 数学・理科・社会 の一問一答.
struct SubjectCardStudyView: View {
    let title: String
    let subject: String
    let viewModel: CardsViewModel

    @State private var deck: [SubjectCard] = []

    var body: some View {
        CardStudyView(title: title, cards: deck, viewModel: viewModel) { card in
            VStack(spacing: 8) {
                if let domain = CardSubjects.domainName(subject: card.subject, domain: card.domain) {
                    Text(domain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(card.prompt)
                    .font(.title2.weight(.medium))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } back: { card in
            VStack(alignment: .leading, spacing: 12) {
                Text(card.answer)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                if let explanation = card.explanation, !explanation.isEmpty {
                    Text(explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { if deck.isEmpty { deck = viewModel.session(from: viewModel.cards(forSubject: subject)) } }
    }
}

/// The 教科 and 領域 names the card API uses.
///
/// The ids are stable and the names are not, so the names live here rather
/// than being read back out of the data — the same rule the understanding map
/// follows for courses.
enum CardSubjects {
    static let math = "math"
    static let science = "science"
    static let socialStudies = "social-studies"

    private static let domains: [String: [String: String]] = [
        math: [
            "numbers": "数と式", "geometry": "図形",
            "functions": "関数", "data": "データの活用"
        ],
        science: [
            "energy": "エネルギー", "particles": "粒子",
            "life": "生命", "earth": "地球"
        ],
        socialStudies: [
            "geography": "地理", "history": "歴史",
            "civics": "公民", "inquiry": "資料と考察"
        ]
    ]

    static func domainName(subject: String, domain: String) -> String? {
        domains[subject]?[domain]
    }
}

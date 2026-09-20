import SwiftUI
import WakaRouteKit

/// カードの入口 — 単語と漢字のデッキ、範囲、これまでの進み。
struct CardsView: View {
    @State var viewModel: CardsViewModel

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                ProgressView("カードを準備しています")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case let .failed(message):
                ContentUnavailableView {
                    Label("読み込めませんでした", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("再試行") { Task { await viewModel.load() } }
                        .buttonStyle(.borderedProminent)
                }

            case .ready:
                decks
            }
        }
        .navigationTitle("カード")
        .task { await viewModel.load() }
    }

    private var decks: some View {
        List {
            Section("範囲") {
                Picker("学年", selection: $viewModel.scope.grade) {
                    Text("すべて").tag(Int?.none)
                    ForEach(1...3, id: \.self) { grade in
                        Text("中\(grade)").tag(Int?.some(grade))
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                DeckRow(
                    title: "単語カード",
                    symbol: "textformat.alt",
                    total: viewModel.scopedCount(in: viewModel.words),
                    started: viewModel.startedCount(in: viewModel.words),
                    learned: viewModel.learnedCount(in: viewModel.words)
                ) {
                    WordStudyView(viewModel: viewModel)
                }

                DeckRow(
                    title: "漢字カード",
                    symbol: "character.textbox",
                    total: viewModel.scopedCount(in: viewModel.kanji),
                    started: viewModel.startedCount(in: viewModel.kanji),
                    learned: viewModel.learnedCount(in: viewModel.kanji)
                ) {
                    KanjiStudyView(viewModel: viewModel)
                }
            } footer: {
                Text("1回で \(CardDeck.sessionSize) 枚まで出します。5回続けてわかると「おぼえた」になり、出なくなります。")
            }

            Section {
                NavigationLink {
                    CardLicenseView(licenses: viewModel.licenses, asOf: viewModel.asOf)
                } label: {
                    Label("データの出典とライセンス", systemImage: "doc.text")
                }
            } footer: {
                // Saying this plainly is the whole mitigation: there is no
                // server to keep card progress on, so it cannot be carried.
                Text("カードの学習状態はこの端末にだけ保存されます。学習記録の引き継ぎには含まれないため、機種変更すると最初からになります。")
            }
        }
        .readableWidth()
    }
}

private struct DeckRow<Destination: View>: View {
    let title: String
    let symbol: String
    let total: Int
    let started: Int
    let learned: Int
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            AdaptiveRow(alignment: .top) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                counts
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        }
    }

    private var counts: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.body.weight(.medium))
            // Both numbers, because 「わかった」 moves one and 「おぼえた」 the
            // other. Showing only the second makes a working deck look stuck.
            Text("\(total) 枚")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("学習中 \(started) 枚・おぼえた \(learned) 枚")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 出典とライセンス。CC BY-SA なので、データを見せる画面から辿れる必要が
/// あります。文面は API が返すものをそのまま出しています。
struct CardLicenseView: View {
    let licenses: [CardLicense]
    let asOf: String

    var body: some View {
        List {
            if !asOf.isEmpty {
                Section { Text("データ基準日 \(asOf)").foregroundStyle(.secondary) }
            }

            ForEach(Array(licenses.enumerated()), id: \.offset) { _, license in
                Section(license.name ?? "データ") {
                    if let attribution = license.attribution {
                        Text(attribution).font(.callout)
                    }
                    if let spdx = license.spdxId {
                        LabeledContent("ライセンス", value: spdx)
                    }
                    if let url = license.url, let link = URL(string: url) {
                        Link(url, destination: link).font(.footnote)
                    }
                }
            }
        }
        .navigationTitle("出典とライセンス")
        .navigationBarTitleDisplayMode(.inline)
    }
}

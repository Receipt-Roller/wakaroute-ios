import SwiftUI
import WakaRouteKit

@MainActor
@Observable
final class SchoolSearchViewModel {
    enum State {
        case idle
        case searching
        case results(SchoolSearchPage)
        case empty
        case failed(message: String, canRetry: Bool)
    }

    private(set) var state: State = .idle
    var keyword = ""
    var ownership: SchoolOwnership?

    private let client: SchoolsClient
    private var searchTask: Task<Void, Never>?

    init(client: SchoolsClient) {
        self.client = client
    }

    func search() {
        // A new search supersedes the one in flight; without this, a slow
        // earlier response can land after a newer one and overwrite it.
        searchTask?.cancel()

        searchTask = Task {
            state = .searching
            let query = SchoolSearchQuery(keyword: keyword, ownership: ownership)

            do {
                let page = try await client.search(query)
                guard !Task.isCancelled else { return }
                state = page.items.isEmpty ? .empty : .results(page)
            } catch let error as APIError {
                guard !Task.isCancelled else { return }
                state = .failed(message: Self.message(for: error), canRetry: error.isTransient)
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(message: "検索できませんでした。", canRetry: true)
            }
        }
    }

    private static func message(for error: APIError) -> String {
        switch error {
        case .offline: "インターネットに接続されていません。"
        case .timedOut: "通信に時間がかかっています。"
        case .http(let status, _) where status >= 500: "サーバーが応答していません。"
        case .http: "検索できませんでした。"
        case .decoding, .unknown: "結果を読み取れませんでした。"
        }
    }
}

struct SchoolSearchView: View {
    @State var viewModel: SchoolSearchViewModel
    let catalogue: SchoolsClient
    let goals: any TargetSchoolsRepository

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.state {
                case .idle:
                    ContentUnavailableView(
                        "高校を探す",
                        systemImage: "magnifyingglass",
                        description: Text("学校名や地域で検索できます。")
                    )

                case .searching:
                    ProgressView("検索中").frame(maxWidth: .infinity, maxHeight: .infinity)

                case .empty:
                    ContentUnavailableView.search

                case let .failed(message, canRetry):
                    ContentUnavailableView {
                        Label("検索できませんでした", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        if canRetry {
                            Button("再試行") { viewModel.search() }
                                .buttonStyle(.borderedProminent)
                        }
                    }

                case let .results(page):
                    List(page.items) { school in
                        NavigationLink(value: school.id) {
                            SchoolRow(school: school)
                        }
                    }
                    .listStyle(.plain)
                    .safeAreaInset(edge: .top) {
                        // The catalogue's own reference date, distinct from when
                        // we fetched it. Application decisions must not be made
                        // on stale data without the student knowing its age.
                        if let asOf = page.asOf {
                            Text("\(page.totalCount) 件・\(asOf) 時点の掲載情報")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(.bar)
                        }
                    }
                }
            }
            .navigationTitle("高校を探す")
            .navigationDestination(for: String.self) { schoolId in
                SchoolDetailView(
                    viewModel: SchoolDetailViewModel(
                        schoolId: schoolId,
                        catalogue: catalogue,
                        goals: goals
                    )
                )
            }
            .searchable(text: $viewModel.keyword, prompt: "学校名・地域")
            .onSubmit(of: .search) { viewModel.search() }
        }
    }
}

private struct SchoolRow: View {
    let school: School

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(school.name).font(.headline)

            HStack(spacing: 8) {
                if let label = school.ownershipLabel {
                    Text(label)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
                if let prefecture = school.prefecture {
                    Text(prefecture).font(.caption).foregroundStyle(.secondary)
                }
            }

            if let address = school.address {
                Text(address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

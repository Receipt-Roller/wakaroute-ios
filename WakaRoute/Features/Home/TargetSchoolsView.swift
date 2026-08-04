import SwiftUI
import WakaRouteKit

/// Manage 志望校 — reorder, set exam dates, add from the school catalogue.
struct TargetSchoolsView: View {
    @State var viewModel: TargetSchoolsViewModel
    let schoolsClient: SchoolsClient

    @State private var isPicking = false

    var body: some View {
        List {
            switch viewModel.state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity)

            case let .failed(message):
                Text(message).foregroundStyle(.secondary)

            case .ready:
                schoolSection
                deadlineSection
            }
        }
        .navigationTitle("志望校")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isPicking = true } label: {
                    Label("追加", systemImage: "plus")
                }
                .disabled(viewModel.isSaving)
            }
            ToolbarItem(placement: .topBarLeading) { EditButton() }
        }
        .sheet(isPresented: $isPicking) {
            SchoolPickerView(client: schoolsClient) { school in
                Task { await viewModel.add(school: school, examDate: nil) }
            }
        }
        .task { await viewModel.load() }
        .alert("保存できませんでした", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var schoolSection: some View {
        Section {
            ForEach(Array(viewModel.schools.enumerated()), id: \.element.id) { index, school in
                TargetSchoolRow(
                    school: school,
                    detail: viewModel.details[school.externalId],
                    isMissing: viewModel.missingIds.contains(school.externalId),
                    preference: TargetSchoolList.preferenceLabel(at: index),
                    onDateChange: { date in
                        Task { await viewModel.setExamDate(date, for: school) }
                    }
                )
            }
            .onDelete { offsets in Task { await viewModel.remove(at: offsets) } }
            .onMove { source, destination in
                Task { await viewModel.move(from: source, to: destination) }
            }

            if viewModel.schools.isEmpty {
                Text("まだ志望校が登録されていません。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("志望校")
        } footer: {
            Text("並べかえると第一志望が変わります。上が第一志望です。")
        }
    }

    /// The soonest exam is the date preparation must actually meet, and it is
    /// often not the 第一志望's. The server computes it; we only explain it.
    @ViewBuilder
    private var deadlineSection: some View {
        if let list = viewModel.list, let days = list.daysRemaining {
            Section {
                LabeledContent("いちばん早い入試まで") {
                    Text("あと \(days) 日").monospacedDigit()
                }
                if list.deadlineIsNotPrimary, let earliest = list.schoolWithEarliestExam {
                    Label(
                        "\(earliest.name) が最初の入試です。準備はこの日に間に合わせます。",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct TargetSchoolRow: View {
    let school: TargetSchool
    /// Catalogue detail, once fetched. Nil simply means not loaded yet.
    let detail: School?
    /// The catalogue no longer has this id.
    let isMissing: Bool
    let preference: String
    let onDateChange: (Date) -> Void

    @State private var isEditingDate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(preference).font(.caption2).foregroundStyle(.secondary)
            Text(school.name).font(.subheadline)

            if let detail {
                Text([detail.ownershipLabel, detail.prefecture, detail.address]
                        .compactMap { $0 }
                        .joined(separator: "・"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if isMissing {
                Label("この学校は掲載一覧にありません", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button {
                isEditingDate = true
            } label: {
                Label(
                    school.targetDate.map { "入試日 \($0)" } ?? "入試日を設定",
                    systemImage: "calendar"
                )
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .sheet(isPresented: $isEditingDate) {
            ExamDatePicker(
                initial: school.examDate() ?? Date(),
                schoolName: school.name
            ) { date in
                onDateChange(date)
                isEditingDate = false
            }
        }
    }
}

private struct ExamDatePicker: View {
    let initial: Date
    let schoolName: String
    let onSelect: (Date) -> Void

    @State private var date: Date
    @Environment(\.dismiss) private var dismiss

    init(initial: Date, schoolName: String, onSelect: @escaping (Date) -> Void) {
        self.initial = initial
        self.schoolName = schoolName
        self.onSelect = onSelect
        _date = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            VStack {
                DatePicker("入試日", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding()
                Spacer()
            }
            .navigationTitle(schoolName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("決定") { onSelect(date) }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Choose a school from the live catalogue.
///
/// Selection carries the catalogue's permanent id, never the name — the id is
/// what the server stores and what survives a school being renamed.
private struct SchoolPickerView: View {
    let client: SchoolsClient
    let onSelect: (School) -> Void

    @State private var viewModel: SchoolSearchViewModel
    @Environment(\.dismiss) private var dismiss

    init(client: SchoolsClient, onSelect: @escaping (School) -> Void) {
        self.client = client
        self.onSelect = onSelect
        _viewModel = State(initialValue: SchoolSearchViewModel(client: client))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.state {
                case .idle:
                    ContentUnavailableView(
                        "志望校を探す",
                        systemImage: "magnifyingglass",
                        description: Text("学校名や地域で検索してください。")
                    )
                case .searching:
                    ProgressView("検索中").frame(maxWidth: .infinity, maxHeight: .infinity)
                case .empty:
                    ContentUnavailableView.search
                case let .failed(message, _):
                    ContentUnavailableView("検索できませんでした", systemImage: "wifi.exclamationmark", description: Text(message))
                case let .results(page):
                    List(page.items) { school in
                        Button {
                            onSelect(school)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(school.name).font(.subheadline).foregroundStyle(.primary)
                                if let prefecture = school.prefecture {
                                    Text([school.ownershipLabel, prefecture].compactMap { $0 }.joined(separator: "・"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("志望校を追加")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $viewModel.keyword, prompt: "学校名・地域")
            .onSubmit(of: .search) { viewModel.search() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
        }
    }
}

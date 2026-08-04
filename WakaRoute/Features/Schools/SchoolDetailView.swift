import SwiftUI
import WakaRouteKit

@MainActor
@Observable
final class SchoolDetailViewModel {
    enum LoadState {
        case loading
        case ready(SchoolDetail)
        case notFound
        case failed(message: String)
    }

    enum AddState: Equatable {
        case unknown
        case notAdded
        case alreadyAdded(preference: String)
        case adding
        case added
        case failed(message: String)
    }

    private(set) var state: LoadState = .loading
    private(set) var addState: AddState = .unknown
    /// True when the exam date came from the catalogue rather than the student.
    private(set) var didSuggestExamDate = false

    let schoolId: String
    private let catalogue: SchoolsClient
    private let goals: any TargetSchoolsRepository

    init(schoolId: String, catalogue: SchoolsClient, goals: any TargetSchoolsRepository) {
        self.schoolId = schoolId
        self.catalogue = catalogue
        self.goals = goals
    }

    private static func formatDate(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func load() async {
        state = .loading
        do {
            state = .ready(try await catalogue.schoolDetail(id: schoolId))
        } catch let error as APIError {
            if case let .http(status, _) = error, status == 404 {
                state = .notFound
            } else {
                state = .failed(message: "学校情報を取得できませんでした。")
            }
        } catch {
            state = .failed(message: "学校情報を取得できませんでした。")
        }

        await refreshAddState()
    }

    private func refreshAddState() async {
        guard let list = try? await goals.targetSchools() else {
            // Not knowing is its own state — better than offering to add a
            // school that is already on the list.
            addState = .unknown
            return
        }

        let sorted = list.goals.sorted { $0.rank < $1.rank }
        if let index = sorted.firstIndex(where: { $0.externalId == schoolId }) {
            addState = .alreadyAdded(preference: TargetSchoolList.preferenceLabel(at: index))
        } else {
            addState = .notAdded
        }
    }

    func addToTargetSchools() async {
        guard case let .ready(detail) = state else { return }
        let school = detail.school
        addState = .adding

        do {
            // Append, never replace: the endpoint takes the whole list, so the
            // existing 志望校 must be read and sent back or they are wiped.
            let current = try await goals.targetSchools()
            var updated = current.goals.sorted { $0.rank < $1.rank }

            guard !updated.contains(where: { $0.externalId == school.id }) else {
                await refreshAddState()
                return
            }

            // Fill the exam date from the published 入試日程 when there is one.
            // A 中学生 should not have to look up and type a date the catalogue
            // already knows; it stays editable either way.
            let suggested = detail.suggestedExamDate(after: Date()).map(Self.formatDate)

            updated.append(
                TargetSchool(
                    externalId: school.id,
                    name: school.name,
                    rank: updated.count,
                    targetDate: suggested
                )
            )
            didSuggestExamDate = suggested != nil

            _ = try await goals.replaceTargetSchools(updated)
            addState = .added
        } catch {
            addState = .failed(message: "志望校に追加できませんでした。")
        }
    }
}

struct SchoolDetailView: View {
    @State var viewModel: SchoolDetailViewModel

    var body: some View {
        List {
            switch viewModel.state {
            case .loading:
                HStack { Spacer(); ProgressView(); Spacer() }

            case .notFound:
                ContentUnavailableView(
                    "この学校は見つかりませんでした",
                    systemImage: "questionmark.circle",
                    description: Text("掲載一覧から削除された可能性があります。")
                )

            case let .failed(message):
                Label(message, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)

            case let .ready(detail):
                headerSection(school: detail.school)
                addSection
                examSection(detail: detail)
                statsSection(detail: detail)
                detailSection(school: detail.school)
                sourceNote
            }
        }
        .navigationTitle("学校情報")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
    }

    private func headerSection(school: School) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(school.name)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                if let kana = school.nameKana {
                    Text(kana).font(.caption).foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    if let ownership = school.ownershipLabel {
                        Text(ownership)
                            .font(.caption2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                    if let campus = school.campusTypeLabel {
                        Text(campus).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let prefecture = school.prefecture {
                        Text(prefecture).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var addSection: some View {
        Section {
            switch viewModel.addState {
            case .unknown, .adding:
                HStack { ProgressView(); Text("確認中").foregroundStyle(.secondary) }

            case .notAdded:
                Button {
                    Task { await viewModel.addToTargetSchools() }
                } label: {
                    Label("志望校に追加", systemImage: "plus.circle.fill")
                }

            case let .alreadyAdded(preference):
                Label("\(preference) に登録済みです", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

            case .added:
                Label("志望校に追加しました", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

            case let .failed(message):
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("再試行") { Task { await viewModel.addToTargetSchools() } }
                }
            }
        } footer: {
            if case .added = viewModel.addState {
                Text(viewModel.didSuggestExamDate
                     ? "公開されている入試日程から入試日を設定しました。「めざす高校」で変更できます。"
                     : "入試日は「めざす高校」から設定できます。")
            }
        }
    }

    /// 入試日程. Shown only when published — an empty section would read as
    /// "no exams", which is not what an unpublished schedule means.
    @ViewBuilder
    private func examSection(detail: SchoolDetail) -> some View {
        if !detail.examSchedules.isEmpty {
            Section("入試日程") {
                ForEach(Array(detail.examSchedules.enumerated()), id: \.offset) { _, schedule in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(schedule.selectionLabel ?? "入試").font(.subheadline.weight(.medium))
                            if let status = schedule.statusLabel {
                                Text(status).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(String(schedule.academicYear))年度")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        if !schedule.testDates.isEmpty {
                            Text("試験日 " + schedule.testDates.joined(separator: "・"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let period = schedule.applicationPeriod {
                            Text("出願 " + period).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// 偏差値 and 倍率, when published.
    @ViewBuilder
    private func statsSection(detail: SchoolDetail) -> some View {
        if detail.latestDeviationScore != nil || !detail.admissions.isEmpty {
            Section("入試のめやす") {
                if let score = detail.latestDeviationScore, let text = score.displayText {
                    LabeledContent("偏差値") {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(text).monospacedDigit()
                            if let population = score.population {
                                Text(population).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                ForEach(Array(detail.admissions.enumerated()), id: \.offset) { _, result in
                    if let ratio = result.competitionRatio {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text([result.selectionLabel, result.department]
                                        .compactMap { $0 }.joined(separator: "・"))
                                    .font(.subheadline)
                                Spacer()
                                // The kind is part of the number, not a detail.
                                Text("\(ratio.kind.label) \(String(format: "%.2f", ratio.value)) 倍")
                                    .font(.subheadline.weight(.medium))
                                    .monospacedDigit()
                            }
                            Text("\(String(result.academicYear))年度・\(ratio.kind.explanation)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "\(result.selectionLabel ?? "入試")、\(ratio.kind.label)"
                            + String(format: "%.2f", ratio.value) + "倍"
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func detailSection(school: School) -> some View {
        Section("所在地") {
            if let address = school.address {
                LabeledContent("住所") {
                    Text(address).multilineTextAlignment(.trailing)
                }
            }
            if let url = school.officialUrl, let link = URL(string: url) {
                Link(destination: link) {
                    Label("公式サイト", systemImage: "safari")
                }
            }
        }
    }

    /// 出願判断には必ず学校・教育委員会の最新情報を — サービス仕様 §6.
    private var sourceNote: some View {
        Section {
            Label(
                "出願の判断は、必ず学校や教育委員会の最新情報を確認してください。",
                systemImage: "info.circle"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

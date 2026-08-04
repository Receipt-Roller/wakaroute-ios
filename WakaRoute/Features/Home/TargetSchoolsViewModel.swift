import Foundation
import Observation
import WakaRouteKit

@MainActor
@Observable
final class TargetSchoolsViewModel {
    enum State {
        case loading
        case ready(TargetSchoolList)
        case failed(message: String)
    }

    private(set) var state: State = .loading
    private(set) var isSaving = false
    var errorMessage: String?

    /// Catalogue detail for saved schools, keyed by id. The goal record holds
    /// only an id and a cached name, so prefecture and ownership come from here.
    private(set) var details: [String: School] = [:]
    /// Saved ids the catalogue no longer knows about.
    private(set) var missingIds: Set<String> = []

    private let repository: any TargetSchoolsRepository
    private let catalogue: SchoolsClient?

    init(repository: any TargetSchoolsRepository, schools: SchoolsClient? = nil) {
        self.repository = repository
        self.catalogue = schools
    }

    var schools: [TargetSchool] {
        guard case let .ready(list) = state else { return [] }
        return list.goals.sorted { $0.rank < $1.rank }
    }

    var list: TargetSchoolList? {
        guard case let .ready(list) = state else { return nil }
        return list
    }

    func load() async {
        state = .loading
        do {
            let list = try await repository.targetSchools()
            state = .ready(list)
            await loadDetails(for: list.goals)
        } catch {
            state = .failed(message: "志望校を読み込めませんでした。")
        }
    }

    /// Fills in catalogue detail for each saved school.
    ///
    /// Runs after the list is already on screen — the names are cached in the
    /// goal record, so a slow or failed catalogue call costs extra detail, not
    /// the screen.
    private func loadDetails(for goals: [TargetSchool]) async {
        guard let catalogue else { return }

        for goal in goals where details[goal.externalId] == nil {
            do {
                details[goal.externalId] = try await catalogue.school(id: goal.externalId)
                missingIds.remove(goal.externalId)
            } catch let error as APIError {
                // A 404 means the id is gone from the catalogue, which is worth
                // showing. Anything else is a network problem and is ignored.
                if case let .http(status, _) = error, status == 404 {
                    missingIds.insert(goal.externalId)
                }
            } catch {
                continue
            }
        }
    }

    func add(school: School, examDate: Date?) async {
        var updated = schools
        guard !updated.contains(where: { $0.externalId == school.id }) else { return }

        updated.append(
            TargetSchool(
                externalId: school.id,
                name: school.name,
                rank: updated.count,
                targetDate: examDate.map(Self.formatDate)
            )
        )
        await save(updated)
    }

    func remove(at offsets: IndexSet) async {
        var updated = schools
        updated.remove(atOffsets: offsets)
        await save(updated)
    }

    func move(from source: IndexSet, to destination: Int) async {
        var updated = schools
        updated.move(fromOffsets: source, toOffset: destination)
        await save(updated)
    }

    func setExamDate(_ date: Date, for school: TargetSchool) async {
        let updated = schools.map { current -> TargetSchool in
            guard current.externalId == school.externalId else { return current }
            return TargetSchool(
                source: current.source,
                externalId: current.externalId,
                name: current.name,
                rank: current.rank,
                targetDate: Self.formatDate(date)
            )
        }
        await save(updated)
    }

    /// The server replaces the whole list and assigns rank from array order,
    /// so every edit sends the complete list rather than a delta.
    private func save(_ schools: [TargetSchool]) async {
        isSaving = true
        defer { isSaving = false }

        do {
            state = .ready(try await repository.replaceTargetSchools(schools))
        } catch {
            errorMessage = "保存できませんでした。通信状況を確認してください。"
            // Reload so the screen shows what the server actually holds rather
            // than an edit the student thinks was saved.
            await load()
        }
    }

    private static func formatDate(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

#if DEBUG
/// Design-review fixtures, matching the server's response shape.
struct SampleTargetSchoolsRepository: TargetSchoolsRepository {
    func targetSchools() async throws -> TargetSchoolList {
        SampleUnderstandingMap.targetSchools(relativeTo: Date())
    }

    func replaceTargetSchools(_ schools: [TargetSchool]) async throws -> TargetSchoolList {
        TargetSchoolList(goals: schools.enumerated().map { index, school in
            TargetSchool(
                source: school.source,
                externalId: school.externalId,
                name: school.name,
                rank: index,
                targetDate: school.targetDate
            )
        })
    }
}

#endif

/// The shipping implementation. Deliberately outside the `#if DEBUG` above —
/// this conformance is what 志望校 run on in production.
extension ProfileClient: TargetSchoolsRepository {}

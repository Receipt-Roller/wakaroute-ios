import Foundation
import Observation
import WakaRouteKit

/// Everything the home screen can be showing.
///
/// There is no longer a 計画中 case. The dashboard is built from progress the
/// server actually records, so it has something true to show from the first
/// launch — the 理解マップ's absence now costs one section rather than the screen.
enum HomeState {
    case loading
    case ready(HomeContent)
    case failed(message: String)
}

struct HomeContent {
    var targetSchools: TargetSchoolList?
    var digest: HomeDigest
    /// The learning content could not be reached. The goal and the study record
    /// are local or already loaded, so they still show.
    var contentUnavailable: Bool
    /// Everything pushed screens need, so a detail view cannot disagree with
    /// the dashboard that opened it.
    var context: MapContext
    /// True when the 理解マップ numbers came from design fixtures.
    var isSample: Bool

    var goal: TargetSchool? { targetSchools?.primary }
}

@MainActor
@Observable
final class HomeViewModel {
    private(set) var state: HomeState = .loading

    private let repository: any UnderstandingMapRepository
    /// 志望校 come from the learner's profile on MANABU2, not from the map.
    private let goals: any TargetSchoolsRepository
    private let schools: SchoolsClient
    private let content: ContentClient?
    private let structureCache: ContentStructureCache?
    private let timer: StudyTimer?
    private let queue: LearningActionQueue?

    /// How far back to look for quizzes worth retrying. Long enough to catch a
    /// gap over a school holiday, short enough that a January failure is not
    /// still being raised in August.
    private static let attemptWindowDays = 90

    init(
        repository: any UnderstandingMapRepository,
        goals: any TargetSchoolsRepository,
        schools: SchoolsClient,
        content: ContentClient? = nil,
        structureCache: ContentStructureCache? = nil,
        timer: StudyTimer? = nil,
        queue: LearningActionQueue? = nil
    ) {
        self.repository = repository
        self.goals = goals
        self.schools = schools
        self.content = content
        self.structureCache = structureCache
        self.timer = timer
        self.queue = queue
    }

    func load() async {
        state = .loading

        // Loaded first, because the goal must show even when nothing else can.
        let targetSchools = try? await goals.targetSchools()
        let study = await studyProgress()

        // Fixtures do not need priming, and design review expects the map to be
        // there whether or not the content endpoints answered.
        if !(repository is LiveUnderstandingMapRepository) { await loadMap() }

        guard let content else {
            state = .ready(makeContent(
                targetSchools: targetSchools,
                catalog: ContentCatalog(paths: [], progress: []),
                study: study,
                contentUnavailable: true
            ))
            return
        }

        let paths: [LearningPathSummary]
        do {
            paths = try await content.paths()
        } catch {
            // Only a screen with nothing at all on it is worth refusing to
            // draw. A student with a 志望校 still has something to see.
            if targetSchools == nil {
                state = .failed(message: "読み込みに失敗しました。通信状況を確認してください。")
            } else {
                state = .ready(makeContent(
                    targetSchools: targetSchools,
                    catalog: ContentCatalog(paths: [], progress: []),
                    study: study,
                    contentUnavailable: true
                ))
            }
            return
        }

        async let progressTask = content.myProgress()
        async let attemptsTask = content.quizAttempts(
            from: ActivityTimeline.dateParameter(
                Calendar.current.date(byAdding: .day, value: -Self.attemptWindowDays, to: Date()) ?? Date()
            ),
            to: ActivityTimeline.dateParameter(Date())
        )

        // Both are optional detail: a learner with no history yet is normal,
        // and losing the whole dashboard over it would not be.
        let progress = (try? await progressTask) ?? []
        let attempts = (try? await attemptsTask) ?? []

        // The map needs exactly these two responses, so it is handed them
        // rather than fetching its own copies.
        await (repository as? LiveUnderstandingMapRepository)?
            .use(progress: progress, quizAttempts: attempts)
        await loadMap()

        // Painted with whatever mapping is already on disk, so the screen is
        // usable immediately. On a first launch that means the per-subject
        // rings are briefly empty — filled in below rather than held back.
        let cached = await structureCache?.cached() ?? ContentStructure()
        state = .ready(makeContent(
            targetSchools: targetSchools,
            catalog: ContentCatalog(paths: paths, progress: progress, structure: cached),
            study: study,
            attempts: attempts,
            contentUnavailable: false
        ))

        await refreshStructure(
            paths: paths,
            progress: progress,
            attempts: attempts,
            study: study,
            targetSchools: targetSchools,
            alreadyShown: cached
        )

        // Anything recorded offline goes out now that the app is clearly online.
        _ = await queue?.run()
    }

    /// Fetches the path→course mapping for paths that changed, then redraws.
    ///
    /// One request per path, so it runs after the screen is already up rather
    /// than in front of it.
    private func refreshStructure(
        paths: [LearningPathSummary],
        progress: [CourseProgress],
        attempts: [QuizAttempt],
        study: StudyProgress,
        targetSchools: TargetSchoolList?,
        alreadyShown: ContentStructure
    ) async {
        guard let structureCache, !alreadyShown.stalePathIds(against: paths).isEmpty else { return }

        let refreshed = await structureCache.structure(refreshedAgainst: paths)
        guard refreshed != alreadyShown else { return }

        state = .ready(makeContent(
            targetSchools: targetSchools,
            catalog: ContentCatalog(paths: paths, progress: progress, structure: refreshed),
            study: study,
            attempts: attempts,
            contentUnavailable: false
        ))
    }

    private func makeContent(
        targetSchools: TargetSchoolList?,
        catalog: ContentCatalog,
        study: StudyProgress,
        attempts: [QuizAttempt] = [],
        contentUnavailable: Bool
    ) -> HomeContent {
        let digest = HomeDigest.make(
            catalog: catalog,
            quizAttempts: attempts,
            recommendations: map.recommendations,
            streak: study.streak,
            todaySeconds: study.todaySeconds
        )

        return HomeContent(
            targetSchools: targetSchools,
            digest: digest,
            contentUnavailable: contentUnavailable,
            context: MapContext(
                targetSchools: targetSchools,
                goalsRepository: goals,
                schoolsClient: schools,
                readiness: ExamReadiness(subjects: map.progress),
                subjects: map.subjects,
                mastery: map.mastery,
                catalog: catalog,
                content: content,
                queue: queue
            ),
            isSample: Self.isShowingFixtures(repository)
        )
    }

    /// The 理解マップ, when there is one.
    ///
    /// Empty in production — no API supplies mastery levels yet — which is what
    /// sends the 教科 tiles to the real 領域 list instead of the map. Loading it
    /// here rather than deleting the path keeps design review working on
    /// fixtures without letting fixtures near the dashboard's own numbers.
    private struct MapData {
        var subjects: [Subject] = []
        var mastery: [SubjectId: MasteryRecord] = [:]
        var progress: [SubjectProgress] = []
        var recommendations: [StudyRecommendation] = []
    }

    private var map = MapData()

    /// True only in a build that still contains the fixtures.
    private static func isShowingFixtures(_ repository: any UnderstandingMapRepository) -> Bool {
        #if DEBUG
        return repository is SampleUnderstandingMapRepository
        #else
        return false
        #endif
    }

    private func loadMap() async {
        guard case let .available(subjects) = try? await repository.subjects() else {
            map = MapData()
            return
        }

        var loaded = MapData(subjects: subjects)
        for subject in subjects {
            guard case let .available(mastery) = try? await repository.mastery(for: subject.id) else { continue }
            loaded.mastery[subject.id] = mastery
            loaded.progress.append(SubjectProgress(subject: subject, mastery: mastery))
            loaded.recommendations += StudyFocus(subject: subject, mastery: mastery).recommendations(limit: 2)
        }
        // One ordering rule across subjects, the same one used within a subject.
        // Sorting twice by different measures is how the ranking silently
        // inverted once before.
        loaded.recommendations.sort(by: StudyRecommendation.isMoreUrgent)
        map = loaded
    }

    /// Streak and today's minutes come from the local record, the same source
    /// the 記録 tab reads. Two screens disagreeing about how many days a student
    /// has kept going would be worse than either number being slightly stale.
    private func studyProgress() async -> StudyProgress {
        guard let timer, let sessions = try? await timer.allSessions() else {
            return StudyProgress(streak: StudyStreak(days: 0, studiedToday: false), todaySeconds: 0)
        }
        return StudyProgress(
            streak: StudyCalendar.streak(sessions: sessions),
            todaySeconds: StudyCalendar.totalSeconds(on: Date(), sessions: sessions)
        )
    }

    private struct StudyProgress {
        let streak: StudyStreak
        let todaySeconds: Int
    }
}

#if DEBUG
/// Design-review only. Feeds the 理解マップ screens from `SampleUnderstandingMap`
/// so the intended layout can be seen before the API exists. The home dashboard
/// itself is always real: fixtures there once hid a bug in the live path for
/// two rounds of review.
struct SampleUnderstandingMapRepository: UnderstandingMapRepository {
    func subjects() async throws -> MapAvailability<[Subject]> {
        .available(SampleUnderstandingMap.subjects)
    }

    func mastery(for subjectId: SubjectId) async throws -> MapAvailability<MasteryRecord> {
        .available(subjectId == SampleUnderstandingMap.math.id ? SampleUnderstandingMap.partwayMastery : MasteryRecord())
    }
}
#endif

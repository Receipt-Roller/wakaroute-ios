import SwiftUI
import WakaRouteKit

/// Phase 1 tab structure from §5 of the 開発ガイド.
///
/// The learning tabs shown after sign-in are deliberately not decided here —
/// that layout is settled by user testing at the start of Phase 2.
struct RootView: View {
    let services: AppServices

    @State private var selection = RootView.initialTab

    /// Design review only: `-startTab 記録` opens straight to a tab so a screen
    /// can be inspected without navigating. Compiled out of release builds.
    private static var opensCards: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-openCards")
        #else
        return false
        #endif
    }

    private static var initialTab: Int {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-startTab"), index + 1 < arguments.count {
            return Int(arguments[index + 1]) ?? 0
        }
        #endif
        return 0
    }

    var body: some View {
        #if DEBUG
        // Design review: open one lesson directly, so a screen deep in the
        // hierarchy can be inspected without navigating to it.
        if let lessonId = RootView.debugLessonId {
            NavigationStack {
                LessonView(
                    viewModel: LessonViewModel(
                        lesson: LessonSummary.placeholder(id: lessonId),
                        content: services.content
                    )
                )
            }
        } else if RootView.opensCards {
            // Cards sit two pushes inside 学ぶ, so design review gets a way
            // straight to them like the other deep screens.
            NavigationStack { CardsView(viewModel: CardsViewModel(library: services.cards)) }
        } else if let document = RootView.debugDocument {
            NavigationStack { LegalDocumentView(document: document) }
        } else if RootView.opensFeedback {
            // The rating only appears after a lesson is finished, which cannot
            // be reached by a launch argument — so it gets its own.
            NavigationStack {
                ScrollView {
                    LessonFeedbackView(
                        viewModel: LessonFeedbackViewModel(
                            lessonId: "preview",
                            content: services.content,
                            queue: services.actionQueue
                        )
                    )
                    .padding()
                }
                .navigationTitle("評価")
            }
        } else if RootView.opensMap {
            // Same purpose as -openLesson: the 理解マップ sits three pushes deep,
            // and it is the screen most worth looking at with live data.
            MapPreviewView(repository: services.understandingMap)
        } else {
            tabs
        }
        #else
        tabs
        #endif
    }

    #if DEBUG
    private static var debugLessonId: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-openLesson"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static var opensMap: Bool {
        ProcessInfo.processInfo.arguments.contains("-openMap")
    }

    private static var opensFeedback: Bool {
        ProcessInfo.processInfo.arguments.contains("-openFeedback")
    }

    /// `-openDoc legal-privacy`. The legal documents are authored as HTML and
    /// rendered through the lesson parser, so they are worth looking at rather
    /// than assuming.
    private static var debugDocument: LegalDocument? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-openDoc"), index + 1 < arguments.count else { return nil }
        return LegalDocument(rawValue: arguments[index + 1])
    }
    #endif

    private var tabs: some View {
        TabView(selection: $selection) {
            HomeView(viewModel: HomeViewModel(
                repository: services.understandingMap,
                goals: services.goals,
                schools: services.schools,
                content: services.content,
                structureCache: services.contentStructure,
                timer: services.studyTimer,
                queue: services.actionQueue
            ))
                .tabItem { Label("ホーム", systemImage: "house") }
                .tag(0)

            LearnView(
                viewModel: LearnViewModel(
                    content: services.content,
                    queue: services.actionQueue,
                    structureCache: services.contentStructure
                ),
                cards: services.cards
            )
                .tabItem { Label("学ぶ", systemImage: "book") }
                .tag(1)

            StudyRecordView(viewModel: StudyRecordViewModel(timer: services.studyTimer, sync: services.studySync, content: services.content))
                .tabItem { Label("記録", systemImage: "clock") }
                .tag(2)

            SchoolSearchView(
                viewModel: SchoolSearchViewModel(client: services.schools),
                catalogue: services.schools,
                goals: services.goals
            )
                .tabItem { Label("高校を探す", systemImage: "magnifyingglass") }
                .tag(3)

            MoreView(auth: services.auth, profile: services.profile, studyTimer: services.studyTimer, handover: services.handover)
                .tabItem { Label("その他", systemImage: "ellipsis.circle") }
                .tag(4)
        }
        // No `.tabViewStyle(.sidebarAdaptable)`.
        //
        // It was tried and changed nothing: that style needs the iOS 18 `Tab`
        // builder, and this TabView uses `.tabItem`, which still works on the
        // iOS 17 the app supports. Adopting it would mean the whole tab list
        // twice behind an availability check — real duplication for a sidebar
        // instead of a tab bar, when the layouts that actually matter on iPad
        // (the lesson beside its quiz, 学ぶ in two columns, the whole 理解マップ
        // at once) are done. Left as a tab bar deliberately, not by oversight.
    }
}

/// Wiring, assembled once at launch. Screens receive what they need rather than
/// reaching for singletons, which is what keeps them previewable and testable.
struct AppServices {
    let schools: SchoolsClient
    let understandingMap: any UnderstandingMapRepository
    let auth: AuthSession
    let studyTimer: StudyTimer
    let profile: ProfileClient
    let goals: any TargetSchoolsRepository
    let content: ContentClient
    let studySync: StudySync
    let handover: AccountHandover
    let actionQueue: LearningActionQueue
    let contentStructure: ContentStructureCache
    let versionGate: AppVersionGate
    let cards: CardLibrary

    @MainActor
    static func live(environment: AppEnvironment = .production) -> AppServices {
        let http = URLSessionHTTPClient()
        let store = KeychainSecretStore(service: environment.keychainService)

        let auth = AuthSession(
            client: DeviceAuthClient(http: http, environment: environment),
            store: store,
            deviceIdProvider: StoredDeviceIdProvider(store: store)
        )

        let studyTimer = StudyTimer(store: Self.sessionStore())
        let studySync = StudySync(
            timer: studyTimer,
            client: StudySyncClient(
                http: AuthenticatedHTTPClient(underlying: http, session: auth),
                environment: environment
            )
        )

        let profileClient = ProfileClient(
            http: AuthenticatedHTTPClient(underlying: http, session: auth),
            environment: environment
        )

        let contentClient = ContentClient(
            http: AuthenticatedHTTPClient(underlying: http, session: auth),
            environment: environment
        )

        let structureCache = ContentStructureCache(
            store: Self.contentStructureStore(),
            content: contentClient
        )

        return AppServices(
            schools: SchoolsClient(http: http, environment: environment),
            understandingMap: Self.understandingMapRepository(
                content: contentClient,
                structureCache: structureCache
            ),
            auth: auth,
            studyTimer: studyTimer,
            profile: profileClient,
            goals: Self.goalsRepository(live: profileClient),
            content: contentClient,
            studySync: studySync,
            handover: AccountHandover(auth: auth, timer: studyTimer, sync: studySync),
            actionQueue: LearningActionQueue(store: Self.pendingActionStore(), content: contentClient),
            contentStructure: structureCache,
            // Unauthenticated on purpose: whether a build is too old is not a
            // question about the student, and asking it must not depend on
            // registration having succeeded.
            versionGate: AppVersionGate(http: http, environment: environment),
            // Unauthenticated too: the card sets are public data on
            // wakaroute.com, the same as 高校検索.
            cards: Self.cardLibrary(http: http, environment: environment)
        )
    }

    /// Card sets are large but public: losing the cache costs one download.
    /// Progress is not — it exists only here, so it falls back to memory rather
    /// than failing the whole feature.
    private static func cardLibrary(http: HTTPClient, environment: AppEnvironment) -> CardLibrary {
        CardLibrary(
            client: CardCatalogClient(http: http, environment: environment),
            wordStore: (try? CardFileStore<WordCard>(filename: "cards-english-words.json"))
                ?? InMemoryCardStore<WordCard>(),
            kanjiStore: (try? CardFileStore<KanjiCard>(filename: "cards-kanji.json"))
                ?? InMemoryCardStore<KanjiCard>(),
            subjectStore: (try? CardFileStore<SubjectCard>(filename: "cards-subjects.json"))
                ?? InMemoryCardStore<SubjectCard>(),
            progressStore: (try? CardProgressFileStore()) ?? InMemoryCardProgressStore()
        )
    }

    /// Losing this cache costs one round of refetching, not any student data.
    private static func contentStructureStore() -> any ContentStructureStore {
        do {
            return try FileContentStructureStore.inApplicationSupport()
        } catch {
            logger.error("Could not open the content structure store; it will be rebuilt each launch.")
            return InMemoryContentStructureStore()
        }
    }

    /// 志望校 have a real API, so the live client is used even in design mode
    /// unless fixtures are explicitly requested.
    private static func goalsRepository(live: ProfileClient) -> any TargetSchoolsRepository {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-useSampleData") {
            return SampleTargetSchoolsRepository()
        }
        #endif
        return live
    }

    /// Same fallback as the session store: losing the queue costs the offline
    /// records, not the feature.
    private static func pendingActionStore() -> any PendingActionStore {
        do {
            return try FilePendingActionStore.inApplicationSupport()
        } catch {
            logger.error("Could not open the pending action store; offline replay is memory-only.")
            return InMemoryPendingActionStore()
        }
    }

    /// Falls back to memory if the on-disk store cannot be opened, so a storage
    /// failure costs the history rather than the whole feature.
    private static func sessionStore() -> any StudySessionStore {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-useSampleData") {
            // In memory, so design fixtures are never written to a real
            // student's on-disk history.
            return InMemoryStudySessionStore(sessions: SampleUnderstandingMap.studySessions(relativeTo: Date()))
        }
        #endif

        do {
            return try FileStudySessionStore.inApplicationSupport()
        } catch {
            logger.error("Could not open the study session store; recording to memory only.")
            return InMemoryStudySessionStore()
        }
    }

    /// The real 理解マップ: published courses, the authored prerequisite graph,
    /// and the learner's own quiz and lesson record.
    ///
    /// 数学 only for now — the other four subjects have content but no
    /// prerequisite edges yet, and the repository reports them as 準備中 rather
    /// than pretending an empty graph means nothing is in the way.
    ///
    /// `-useSampleData` still swaps in fixtures for design review. It is
    /// compiled out of release builds entirely, so there is no switch a shipped
    /// app could flip, and screens fed that way show a サンプル表示 banner.
    private static func understandingMapRepository(
        content: ContentClient,
        structureCache: ContentStructureCache
    ) -> any UnderstandingMapRepository {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-useSampleData") {
            return SampleUnderstandingMapRepository()
        }
        #endif
        return LiveUnderstandingMapRepository(content: content, structureCache: structureCache)
    }
}

import Foundation

// Compiled out of release builds entirely, so there is no path — not even an
// unreachable one — by which invented curriculum data can reach a student. The
// `#if DEBUG` at the call site already prevented it; this makes a mistake there
// a compile error rather than a silent fixture.
#if DEBUG

/// Design-time data only.
///
/// **This is not real curriculum data and must never reach a student.** The
/// structure mirrors the web 理解マップ so screens can be laid out and reviewed,
/// but the element set is partial and the IDs are placeholders — the real ones
/// do not exist yet. `UnavailableUnderstandingMapRepository` is what ships;
/// this type exists for Xcode previews and design review.
public enum SampleUnderstandingMap {

    public static func element(
        _ id: String,
        _ name: String,
        _ domain: String,
        grade: Int,
        after prerequisites: [String] = []
    ) -> LearningElement {
        LearningElement(
            id: ElementId("sample-\(id)"),
            name: name,
            domainId: domain,
            grade: grade,
            prerequisiteIds: prerequisites.map { ElementId("sample-\($0)") }
        )
    }

    public static let math = Subject(
        id: SubjectId("sample-math"),
        name: "数学",
        domains: [
            LearningDomain(id: "A", code: "A", name: "数と式"),
            LearningDomain(id: "B", code: "B", name: "図形"),
            LearningDomain(id: "C", code: "C", name: "関数"),
            LearningDomain(id: "D", code: "D", name: "データの活用")
        ],
        elements: [
            // A 数と式 — the chain the web map shows explicitly.
            element("a1", "正の数・負の数", "A", grade: 1),
            element("a2", "文字を用いた式", "A", grade: 1, after: ["a1"]),
            element("a3", "一次方程式", "A", grade: 1, after: ["a2"]),
            element("a4", "連立方程式", "A", grade: 2, after: ["a3"]),
            element("a5", "式の展開と因数分解", "A", grade: 3, after: ["a2"]),
            element("a6", "平方根", "A", grade: 3, after: ["a1"]),
            element("a7", "二次方程式", "A", grade: 3, after: ["a5", "a6"]),

            // B 図形
            element("b1", "平面図形", "B", grade: 1),
            element("b2", "空間図形", "B", grade: 1, after: ["b1"]),
            element("b3", "図形の合同と証明", "B", grade: 2, after: ["b1"]),
            element("b4", "図形の相似", "B", grade: 3, after: ["b3"]),
            element("b5", "三平方の定理", "B", grade: 3, after: ["b4", "a6"]),

            // C 関数
            element("c1", "比例と反比例", "C", grade: 1, after: ["a2"]),
            element("c2", "一次関数", "C", grade: 2, after: ["c1", "a3"]),
            element("c3", "関数 y=ax²", "C", grade: 3, after: ["c2"]),

            // D データの活用
            element("d1", "データの分布", "D", grade: 1),
            element("d2", "確率", "D", grade: 2, after: ["d1"]),
            element("d3", "標本調査", "D", grade: 3, after: ["d1"])
        ]
    )

    public static let subjects: [Subject] = [
        math,
        Subject(id: SubjectId("sample-japanese"), name: "国語", domains: [], elements: []),
        Subject(id: SubjectId("sample-english"), name: "英語", domains: [], elements: []),
        Subject(id: SubjectId("sample-science"), name: "理科", domains: [], elements: []),
        Subject(id: SubjectId("sample-social"), name: "社会", domains: [], elements: [])
    ]

    /// A 中3 student with a 第一志望 and two safeties, mid-way through the year.
    /// Shaped exactly like the server's response so the screens cannot tell the
    /// difference — including the binding deadline falling on a safety school.
    public static func targetSchools(relativeTo now: Date, calendar: Calendar = .current) -> TargetSchoolList {
        func date(inDays days: Int) -> String {
            let day = calendar.date(byAdding: .day, value: days, to: now) ?? now
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }

        let schools = [
            TargetSchool(externalId: "wk_sample_0001", name: "県立 開成高等学校", rank: 0, targetDate: date(inDays: 138)),
            TargetSchool(externalId: "wk_sample_0002", name: "市立 みなみ高等学校", rank: 1, targetDate: date(inDays: 131)),
            TargetSchool(externalId: "wk_sample_0003", name: "私立 わかば学園高等学校", rank: 2, targetDate: date(inDays: 96))
        ]

        return TargetSchoolList(
            goals: schools,
            bindingDeadline: date(inDays: 96),
            daysRemaining: 96
        )
    }

    public static let dailyRoute = DailyRoute(steps: [
        RouteStep(
            id: "step-1",
            title: "文字を用いた式のしくみ",
            subjectName: "数学",
            kind: .learn,
            estimatedMinutes: 8,
            isComplete: true
        ),
        RouteStep(
            id: "step-2",
            title: "文字式の練習",
            subjectName: "数学",
            kind: .practice,
            estimatedMinutes: 12
        ),
        RouteStep(
            id: "step-3",
            title: "平面図形の復習",
            subjectName: "数学",
            kind: .review,
            estimatedMinutes: 10
        ),
        RouteStep(
            id: "step-4",
            title: "今日の確認",
            subjectName: "数学",
            kind: .check,
            estimatedMinutes: 5
        )
    ])

    public static let streak = StudyStreak(days: 6, studiedToday: true)

    /// About three weeks of plausible history: a six-day run up to today, a
    /// gap, and some earlier days. Uneven on purpose — a perfectly regular
    /// calendar would hide whether the intensity shading actually reads.
    public static func studySessions(relativeTo now: Date, calendar: Calendar = .current) -> [StudySession] {
        // (days ago, minutes, subject, title, kind)
        let plan: [(Int, Int, String, String, RouteStep.Kind)] = [
            (0, 12, "数学", "文字を用いた式のしくみ", .learn),
            (0, 18, "数学", "文字式の練習", .practice),
            (1, 25, "数学", "正の数・負の数の復習", .review),
            (2, 40, "数学", "平面図形", .learn),
            (3, 15, "英語", "不定詞の練習", .practice),
            (4, 55, "数学", "一次方程式", .practice),
            (5, 20, "理科", "光と音", .learn),
            (8, 30, "数学", "比例と反比例", .learn),
            (9, 45, "社会", "地理の確認", .check),
            (10, 22, "国語", "説明文の読解", .practice),
            (14, 35, "数学", "図形の合同", .learn),
            (15, 10, "英語", "単語の確認", .check)
        ]

        return plan.compactMap { daysAgo, minutes, subject, title, kind in
            guard
                let day = calendar.date(byAdding: .day, value: -daysAgo, to: now),
                let start = calendar.date(bySettingHour: 19, minute: 30, second: 0, of: day)
            else { return nil }

            return StudySession(
                startedAt: start,
                endedAt: start.addingTimeInterval(TimeInterval(minutes * 60)),
                title: title,
                subjectName: subject,
                kind: kind,
                isSynced: false
            )
        }
    }

    /// A student who is fine on arithmetic but never solidified 文字を用いた式 —
    /// so 一次関数 looks like the problem while the real gap is two steps back.
    ///
    /// `sample-a2` is in `struggling`: they sat its quiz and missed. That is
    /// what makes this a stumble rather than a student who has simply not got
    /// there yet — see `StudyFocus.isStumbling`.
    public static let partwayMastery = MasteryRecord(
        levels: [
            ElementId("sample-a1"): .stableUnderTime,
            ElementId("sample-a2"): .understandsMeaning,
            ElementId("sample-a3"): .notStarted,
            ElementId("sample-b1"): .appliesToNovel,
            ElementId("sample-b2"): .solvesBasics,
            ElementId("sample-c1"): .notStarted,
            ElementId("sample-d1"): .connectsReasoning
        ],
        struggling: [ElementId("sample-a2")]
    )
}

#endif

import Foundation

/// One concrete thing to do next, and the reason it is next.
///
/// The reason is not decoration. A 中学生 who does not believe a suggestion will
/// skip it, and "前回 60% でした" is a reason they can check against their own
/// memory — unlike a number the app worked out for them.
public struct NextStep: Sendable, Equatable, Identifiable {
    public enum Reason: Sendable, Equatable {
        /// Something later is blocked until this is solid. The 理解マップ traced
        /// back to it — this is 「つまずきの前提まで戻る」.
        ///
        /// `isStruggling` says whether the quiz here was actually sat and
        /// missed. Without it, a student calmly working through the first 要素
        /// of a subject is drawn exactly like one who has failed something.
        case unblock(currentLevel: MasteryLevel, isStruggling: Bool, unblocks: [String])
        /// The most recent attempt at this lesson's quiz fell short.
        case retryQuiz(scorePercent: Int, passingScorePercent: Int)
        /// Started and not finished.
        case resumeCourse(completedLessons: Int, totalLessons: Int)
    }

    public let id: String
    public let title: String
    /// Where it sits, for the second line. Nil when the server did not say.
    public let courseTitle: String?
    public let lessonId: String?
    public let courseId: String?
    public let reason: Reason

    public init(
        id: String,
        title: String,
        courseTitle: String? = nil,
        lessonId: String? = nil,
        courseId: String? = nil,
        reason: Reason
    ) {
        self.id = id
        self.title = title
        self.courseTitle = courseTitle
        self.lessonId = lessonId
        self.courseId = courseId
        self.reason = reason
    }
}

/// What the home screen shows, built only from what the server actually records.
///
/// Deliberately **not** the 理解マップ. That needs a mastery level per 要素 and
/// the prerequisite edges between them, and neither exists yet — so rather than
/// invent a 理解度, this reports progress through the material, which is real.
/// The two must not be confused: finishing a lesson is evidence a student read
/// it, not evidence they can use it in February.
public struct HomeDigest: Sendable, Equatable {
    public let subjects: [SubjectOverview]
    public let nextSteps: [NextStep]
    public let streak: StudyStreak
    public let todaySeconds: Int

    public init(
        subjects: [SubjectOverview],
        nextSteps: [NextStep],
        streak: StudyStreak,
        todaySeconds: Int
    ) {
        self.subjects = subjects
        self.nextSteps = nextSteps
        self.streak = streak
        self.todaySeconds = todaySeconds
    }

    public var totalCourses: Int { subjects.reduce(0) { $0 + $1.totalCourses } }
    public var completedCourses: Int { subjects.reduce(0) { $0 + $1.completedCourses } }
    public var startedCourses: Int { subjects.reduce(0) { $0 + $1.startedCourses } }

    public var progressFraction: Double {
        totalCourses == 0 ? 0 : Double(completedCourses) / Double(totalCourses)
    }

    /// Nothing has been published yet at all.
    public var hasContent: Bool { totalCourses > 0 }

    /// The student has actually done something. Drives whether home greets them
    /// or invites them in — a first-launch screen full of zeroes reads as broken.
    ///
    /// Note what does **not** count: a trace-back suggestion. Those are derived
    /// from the *absence* of work, so counting them would tell a student on
    /// their first launch that they had already begun.
    public var hasStarted: Bool {
        if startedCourses > 0 || completedCourses > 0 || streak.days > 0 { return true }
        // A quiz sat is activity, even when no lesson was marked finished.
        return nextSteps.contains {
            if case .retryQuiz = $0.reason { return true }
            return false
        }
    }

    public var todayMinutes: Int { todaySeconds / 60 }
}

extension HomeDigest {

    /// Builds the digest from what each endpoint returned.
    ///
    /// Pure, so the ordering rules below can be tested without a network.
    public static func make(
        catalog: ContentCatalog,
        quizAttempts: [QuizAttempt] = [],
        recommendations: [StudyRecommendation] = [],
        streak: StudyStreak = StudyStreak(days: 0, studiedToday: false),
        todaySeconds: Int = 0,
        limit: Int = 3
    ) -> HomeDigest {
        let unblocks = unblockSteps(recommendations)
        var covered = Set(unblocks.compactMap(\.courseId))

        let retries = retrySteps(quizAttempts).filter { !covered.contains($0.courseId ?? "") }
        covered.formUnion(retries.compactMap(\.courseId))

        let resumes = resumeSteps(
            Array(catalog.progressByCourse.values),
            excludingCourses: covered
        )

        return HomeDigest(
            subjects: catalog.subjects,
            // The order is the product's whole argument.
            //
            // Going back to the prerequisite comes first: it explains the most
            // and is where the student will actually get unstuck. A failed quiz
            // is next — it is certain evidence something did not stick, but on
            // its own it only says *where* it hurts, not why. Carrying on with
            // an unfinished course is last: it assumes nothing is wrong.
            nextSteps: Array((unblocks + retries + resumes).prefix(limit)),
            streak: streak,
            todaySeconds: todaySeconds
        )
    }

    /// 要素 that other 要素 are waiting on.
    ///
    /// Recommendations with nothing behind them are dropped: those are just
    /// "the next thing", which the retry and resume rows already say with better
    /// evidence. Only a genuine trace-back earns the top of the list.
    private static func unblockSteps(_ recommendations: [StudyRecommendation]) -> [NextStep] {
        recommendations
            .filter { !$0.unblocks.isEmpty }
            .sorted(by: StudyRecommendation.isMoreUrgent)
            .map { recommendation in
                NextStep(
                    id: "unblock-\(recommendation.element.id.rawValue)",
                    title: recommendation.element.name,
                    lessonId: nil,
                    // The 要素 id *is* the MANABU2 course id, which is what
                    // makes the map's advice openable rather than just a label.
                    courseId: recommendation.element.id.rawValue,
                    reason: .unblock(
                        currentLevel: recommendation.currentLevel,
                        isStruggling: recommendation.isStruggling,
                        unblocks: recommendation.unblocks.map(\.name)
                    )
                )
            }
    }

    /// Lessons whose **latest** attempt fell short, newest first.
    ///
    /// Latest matters: a student who failed at 60% and later passed at 90% has
    /// fixed it, and being told to go back would be wrong. Grouping by lesson
    /// and keeping only the newest attempt is what makes the pass win.
    private static func retrySteps(_ attempts: [QuizAttempt]) -> [NextStep] {
        var latest: [String: QuizAttempt] = [:]

        for attempt in attempts {
            // No lesson means nowhere to send the student, and no timestamp
            // means no way to tell whether it is the newest. Both are dropped
            // rather than guessed at.
            guard let lessonId = attempt.lessonId, let moment = when(attempt) else { continue }
            guard let held = latest[lessonId], let heldMoment = when(held) else {
                latest[lessonId] = attempt
                continue
            }
            if moment > heldMoment { latest[lessonId] = attempt }
        }

        return latest.values
            .filter { !$0.isPassed }
            .sorted { lhs, rhs in
                let l = when(lhs) ?? .distantPast
                let r = when(rhs) ?? .distantPast
                // The id break keeps the order stable when two attempts share a
                // timestamp — dictionary order alone would reshuffle the list
                // between launches for no reason the student could see.
                return l == r ? lhs.attemptId < rhs.attemptId : l > r
            }
            .map { attempt in
                NextStep(
                    id: "quiz-\(attempt.attemptId)",
                    title: attempt.lessonTitle ?? "確認クイズ",
                    courseTitle: attempt.courseTitle,
                    lessonId: attempt.lessonId,
                    courseId: attempt.courseId,
                    reason: .retryQuiz(
                        scorePercent: attempt.scorePercent,
                        passingScorePercent: attempt.passingScorePercent
                    )
                )
            }
    }

    private static func when(_ attempt: QuizAttempt) -> Date? {
        attempt.completedAt ?? attempt.startedAt
    }

    /// Courses begun and not finished, most recently worked on first.
    ///
    /// Most recent rather than closest to finishing: someone coming back wants
    /// the thing they put down, not the thing an algorithm decided was tidiest
    /// to close out.
    private static func resumeSteps(
        _ progress: [CourseProgress],
        excludingCourses excluded: Set<String>
    ) -> [NextStep] {
        progress
            .filter { !$0.isCompleted && $0.completedLessons > 0 && !excluded.contains($0.courseId) }
            .sorted { lhs, rhs in
                let l = lhs.lastActivityAt ?? .distantPast
                let r = rhs.lastActivityAt ?? .distantPast
                if l != r { return l > r }
                if lhs.percentComplete != rhs.percentComplete { return lhs.percentComplete > rhs.percentComplete }
                return lhs.courseId < rhs.courseId
            }
            .map { course in
                NextStep(
                    id: "course-\(course.courseId)",
                    title: course.courseTitle ?? "つづきから",
                    courseTitle: nil,
                    lessonId: nil,
                    courseId: course.courseId,
                    reason: .resumeCourse(
                        completedLessons: course.completedLessons,
                        totalLessons: course.totalLessons
                    )
                )
            }
    }
}

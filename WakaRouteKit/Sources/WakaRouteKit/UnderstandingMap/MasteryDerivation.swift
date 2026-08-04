import Foundation

/// Works out how well each 要素 is understood, from what MANABU2 records.
///
/// Only the first three levels are measurable today, and pretending otherwise
/// would be the one mistake this map cannot afford:
///
/// | Level | 意味 | Evidence available |
/// |---|---|---|
/// | 0 まだ | — | nothing touched |
/// | 1 意味がわかる | read it | lessons completed |
/// | 2 基本を解ける | got it right | every quiz sat in the course was passed |
/// | 3 根拠をつなげる | — | **needs 確認テスト**, none authored yet |
/// | 4 初見で使える | — | needs 確認テスト |
/// | 5 時間内に安定する | — | needs test time limits (LMS-DEV t-d1bea71) |
///
/// So nothing is ever reported above 2. That is deliberate: level 2 is
/// `prerequisiteThreshold`, which is all the blocked/root-cause reasoning needs,
/// while level 4 is `masteredThreshold` — so no 要素 is ever called mastered on
/// evidence that would not support it. **Do not infer readiness for 受験 from an
/// untimed quiz pass.**
public enum MasteryDerivation {

    /// The highest level the available evidence can support. Screens showing a
    /// scale should mark everything above this as 準備中 rather than as not
    /// achieved — a student has not failed a level nobody can measure.
    public static let highestMeasurable = MasteryLevel.solvesBasics

    /// Derives one record for a subject.
    ///
    /// Takes the same two responses the rest of the app already loads —
    /// `/me/progress` and `/me/quiz-attempts` — so the map costs no extra
    /// requests.
    public static func record(
        progress: [CourseProgress],
        quizAttempts: [QuizAttempt]
    ) -> MasteryRecord {
        let progressByCourse = Dictionary(
            progress.map { ($0.courseId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var attemptsByCourse: [String: [QuizAttempt]] = [:]
        for attempt in latestAttemptPerLesson(quizAttempts).values {
            guard let courseId = attempt.courseId else { continue }
            attemptsByCourse[courseId, default: []].append(attempt)
        }

        var record = MasteryRecord()
        for courseId in Set(progressByCourse.keys).union(attemptsByCourse.keys) {
            let attempts = attemptsByCourse[courseId] ?? []
            record[ElementId(courseId)] = level(
                progress: progressByCourse[courseId],
                attempts: attempts
            )
            // The only hard evidence that something did not stick. Everything
            // else about a 要素 at 意味がわかる is consistent with a student
            // simply being partway through it.
            if attempts.contains(where: { !$0.isPassed }) {
                record.markStruggling(ElementId(courseId))
            }
        }
        return record
    }

    /// One course's level.
    ///
    /// 基本を解ける is a claim about the whole 要素, so it needs the whole 要素:
    /// every lesson finished, and nothing sat and missed. Passing one quiz
    /// twenty-two lessons from the end of 正の数・負の数 says a lot about that
    /// lesson and very little about 正の数・負の数.
    ///
    /// A course with no quiz still reaches 2 once its lessons are done —
    /// otherwise a 要素 nobody wrote a quiz for would block everything
    /// downstream forever, and the student would be sent back to work they have
    /// already completed.
    static func level(progress: CourseProgress?, attempts: [QuizAttempt]) -> MasteryLevel {
        let started = (progress?.completedLessons ?? 0) > 0 || !attempts.isEmpty
        guard started else { return .notStarted }

        // A missed quiz caps it however much of the course is done.
        if attempts.contains(where: { !$0.isPassed }) { return .understandsMeaning }

        return progress?.isCompleted == true ? .solvesBasics : .understandsMeaning
    }

    /// The most recent attempt for each lesson.
    ///
    /// Only the latest counts: a student who failed at 60% and later passed at
    /// 90% has fixed it, and holding the failure against them would send them
    /// backwards over work they have already redone.
    static func latestAttemptPerLesson(_ attempts: [QuizAttempt]) -> [String: QuizAttempt] {
        var latest: [String: QuizAttempt] = [:]

        for attempt in attempts {
            guard let lessonId = attempt.lessonId, let moment = when(attempt) else { continue }
            guard let held = latest[lessonId], let heldMoment = when(held) else {
                latest[lessonId] = attempt
                continue
            }
            if moment > heldMoment { latest[lessonId] = attempt }
        }
        return latest
    }

    private static func when(_ attempt: QuizAttempt) -> Date? {
        attempt.completedAt ?? attempt.startedAt
    }
}

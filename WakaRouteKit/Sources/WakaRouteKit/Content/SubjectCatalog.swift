import Foundation

/// The five 教科, which are fixed.
///
/// They are never created or deleted, so the app knows them rather than
/// discovering them. That also means a subject with no content yet still
/// appears — as 準備中 rather than silently missing, which is what the
/// サービス仕様 requires of unbuilt features.
public struct SchoolSubject: Sendable, Equatable, Identifiable, Hashable {
    public let id: SubjectId
    /// Must match the 教科 label on the Path exactly.
    public let label: String

    public var name: String { label }

    public init(label: String) {
        self.id = SubjectId(label)
        self.label = label
    }

    public static let japanese = SchoolSubject(label: "国語")
    public static let math = SchoolSubject(label: "数学")
    public static let english = SchoolSubject(label: "英語")
    public static let science = SchoolSubject(label: "理科")
    public static let social = SchoolSubject(label: "社会")

    /// Display order, following the サービス仕様.
    public static let all: [SchoolSubject] = [japanese, math, english, science, social]
}

/// One 教科 with the paths that belong to it.
public struct SubjectPaths: Sendable, Equatable, Identifiable {
    public var id: SubjectId { subject.id }
    public let subject: SchoolSubject
    public let paths: [LearningPathSummary]

    public var hasContent: Bool { !paths.isEmpty }
    public var courseCount: Int { paths.reduce(0) { $0 + $1.courseCount } }
}

public enum SubjectCatalog {

    /// Groups paths under the five 教科 by their labels.
    ///
    /// Matching is on the label, never the path name. A path named
    /// 「数学・数と式」 is only 数学 because it carries the 数学 label — splitting
    /// the name on a separator would drop an entire subject the first time
    /// someone renamed a path or used a different character.
    ///
    /// Whitespace and full-width spaces are normalised, because a label typed
    /// with a stray space would otherwise fail silently.
    public static func group(paths: [LearningPathSummary]) -> [SubjectPaths] {
        SchoolSubject.all.map { subject in
            SubjectPaths(
                subject: subject,
                paths: paths.filter { path in
                    path.labels.contains { normalise($0) == normalise(subject.label) }
                }
            )
        }
    }

    /// Paths carrying no recognised 教科 label.
    ///
    /// Surfaced rather than discarded: silently dropping content someone
    /// authored is worse than showing that it is mislabelled, and this is the
    /// only symptom a typo in a label would ever produce.
    public static func unclassified(paths: [LearningPathSummary]) -> [LearningPathSummary] {
        let known = Set(SchoolSubject.all.map { normalise($0.label) })
        return paths.filter { path in
            !path.labels.contains { known.contains(normalise($0)) }
        }
    }

    /// The 領域 label, when the path carries one beyond its 教科.
    public static func domainLabel(of path: LearningPathSummary) -> String? {
        let known = Set(SchoolSubject.all.map { normalise($0.label) })
        return path.labels.first { !known.contains(normalise($0)) }
    }

    private static func normalise(_ label: String) -> String {
        label
            .replacingOccurrences(of: "\u{3000}", with: " ")   // full-width space
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

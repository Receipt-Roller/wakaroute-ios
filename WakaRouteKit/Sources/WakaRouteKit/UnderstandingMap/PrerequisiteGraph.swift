import Foundation

/// The prerequisite graph for one subject, as authored.
///
/// MANABU2 has no prerequisite concept — grepping its OpenAPI document finds no
/// `prerequisite`, `dependsOn`, `unlock` or `gating` anywhere, and its only
/// ordering is a linear `orderIndex` within a path. A sequence can say
/// 「次は一次関数です」; it cannot say 「一次関数で止まっているのは文字を用いた式が
/// 原因です」, which is the whole of principle #1 of the サービス仕様. So the edges
/// live on the ワカルート side (t-1fa7220).
///
/// Shipped in the bundle today. The shape matches what
/// `GET /api/prerequisites?subject=math` will serve, so moving to the network
/// later changes where the bytes come from and nothing else.
public struct PrerequisiteGraph: Decodable, Sendable, Equatable {
    public struct Domain: Decodable, Sendable, Equatable {
        /// The letter shown on the map (A–D).
        public let code: String
        public let name: String
        /// The MANABU2 path this 領域 corresponds to. Used to check the graph
        /// still lines up with published content.
        public let pathId: String
    }

    public struct Element: Decodable, Sendable, Equatable {
        public let courseId: String
        /// For review and for diagnostics only. **Never** matched against
        /// anything — 開発ガイド and サービス仕様 §6 both forbid names as keys, and
        /// a course is free to be renamed.
        public let title: String
        public let domain: String
        public let grade: Int?
        public let requires: [String]
    }

    public let asOf: String
    public let subject: String
    public let domains: [Domain]
    public let elements: [Element]
}

extension PrerequisiteGraph {

    /// The authored 数学 graph.
    public static func math() throws -> PrerequisiteGraph {
        guard let url = Bundle.module.url(forResource: "prerequisites-math", withExtension: "json") else {
            throw GraphError.missingResource
        }
        return try JSONDecoder().decode(PrerequisiteGraph.self, from: Data(contentsOf: url))
    }

    public enum GraphError: Error, Sendable, Equatable {
        case missingResource
        /// Cycles, dangling edges, duplicate courses — see `problems`.
        case invalid(problems: [String])
    }

    /// Builds the map's `Subject` from the graph.
    ///
    /// Titles come from **live content** wherever the course still exists, so a
    /// renamed course shows its new name; the graph's own `title` is only a
    /// fallback for diagnostics.
    public func subject(id: SubjectId, titlesByCourseId: [String: String] = [:]) -> Subject {
        let known = Set(elements.map(\.courseId))

        return Subject(
            id: id,
            name: subject,
            domains: domains.map { LearningDomain(id: $0.code, code: $0.code, name: $0.name) },
            elements: elements.map { element in
                LearningElement(
                    id: ElementId(element.courseId),
                    name: titlesByCourseId[element.courseId] ?? element.title,
                    domainId: element.domain,
                    grade: element.grade,
                    // An edge pointing at a course that is not in the graph
                    // would silently block its dependant forever, so it is
                    // dropped here and reported by `problems`.
                    prerequisiteIds: element.requires
                        .filter { known.contains($0) }
                        .map { ElementId($0) }
                )
            }
        )
    }

    /// Everything wrong with the graph, in words a human can act on.
    ///
    /// Called on load rather than only in tests: the graph references course ids
    /// that live in another system, and a course deleted there must fail loudly
    /// instead of quietly removing a 要素 from a student's map.
    public func problems(againstLiveCourseIds live: Set<String>? = nil) -> [String] {
        var found: [String] = []

        let ids = elements.map(\.courseId)
        let duplicates = Set(ids.filter { id in ids.filter { $0 == id }.count > 1 })
        for id in duplicates.sorted() {
            found.append("course \(id) appears more than once")
        }

        let known = Set(ids)
        for element in elements {
            for required in element.requires where !known.contains(required) {
                found.append("\(element.title) requires \(required), which is not in the graph")
            }
            if !domains.contains(where: { $0.code == element.domain }) {
                found.append("\(element.title) is in domain \(element.domain), which is not declared")
            }
        }

        if let cycle = firstCycle() {
            found.append("cycle: \(cycle.joined(separator: " → "))")
        }

        if let live {
            for element in elements where !live.contains(element.courseId) {
                found.append("\(element.title) (\(element.courseId)) no longer exists in MANABU2")
            }
        }

        return found
    }

    /// Depth-first search for a back edge. Named rather than boolean so the
    /// error can say which courses are involved.
    private func firstCycle() -> [String]? {
        var requires: [String: [String]] = [:]
        for element in elements { requires[element.courseId] = element.requires }

        let titles = Dictionary(elements.map { ($0.courseId, $0.title) }, uniquingKeysWith: { first, _ in first })
        var settled: Set<String> = []
        var onPath: [String] = []

        func walk(_ id: String) -> [String]? {
            if let index = onPath.firstIndex(of: id) {
                return (onPath[index...] + [id]).map { titles[$0] ?? $0 }
            }
            if settled.contains(id) { return nil }

            onPath.append(id)
            for next in requires[id] ?? [] {
                if let cycle = walk(next) { return cycle }
            }
            onPath.removeLast()
            settled.insert(id)
            return nil
        }

        for element in elements {
            if let cycle = walk(element.courseId) { return cycle }
        }
        return nil
    }
}

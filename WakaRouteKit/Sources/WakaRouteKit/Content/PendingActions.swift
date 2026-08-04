import Foundation

/// Something the student did that has not reached the server yet.
///
/// Recording a view, finishing a lesson and submitting a quiz all happen at
/// moments when a student may well be on a train. Losing any of them because
/// the network was down would be losing work they actually did.
public struct PendingAction: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case view
        case complete
        case quizSubmit
        case feedback
    }

    public let id: UUID
    public let kind: Kind
    public let lessonId: String
    public let createdAt: Date
    /// Only for `quizSubmit`.
    public let answers: [QuizAnswer]?
    /// Only for `feedback`.
    public let feedback: LessonFeedback?
    /// Reused on every replay so the server treats retries as one attempt.
    public let idempotencyKey: String
    /// The server refused this permanently; never retried again.
    public private(set) var isRejected: Bool

    public init(
        id: UUID = UUID(),
        kind: Kind,
        lessonId: String,
        createdAt: Date = Date(),
        answers: [QuizAnswer]? = nil,
        feedback: LessonFeedback? = nil,
        idempotencyKey: String = UUID().uuidString,
        isRejected: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.lessonId = lessonId
        self.createdAt = createdAt
        self.answers = answers
        self.feedback = feedback
        self.idempotencyKey = idempotencyKey
        self.isRejected = isRejected
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, lessonId, createdAt, answers, feedback, idempotencyKey, isRejected
    }

    /// Field by field, so a queue written by an earlier version still loads
    /// rather than throwing away everything the student did offline.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .view
        lessonId = try c.decode(String.self, forKey: .lessonId)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        answers = try c.decodeIfPresent([QuizAnswer].self, forKey: .answers)
        feedback = try c.decodeIfPresent(LessonFeedback.self, forKey: .feedback)
        idempotencyKey = try c.decodeIfPresent(String.self, forKey: .idempotencyKey) ?? UUID().uuidString
        isRejected = try c.decodeIfPresent(Bool.self, forKey: .isRejected) ?? false
    }

    mutating func markRejected() { isRejected = true }
}

public protocol PendingActionStore: Sendable {
    func load() throws -> [PendingAction]
    func save(_ actions: [PendingAction]) throws
}

public struct FilePendingActionStore: PendingActionStore {
    private let url: URL

    public init(url: URL) { self.url = url }

    public static func inApplicationSupport(fileName: String = "pending-actions.json") throws -> FilePendingActionStore {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return FilePendingActionStore(url: directory.appending(path: fileName))
    }

    public func load() throws -> [PendingAction] {
        guard FileManager.default.fileExists(atPath: url.filePath) else { return [] }
        return try JSONDecoder.wakaRoute.decode([PendingAction].self, from: Data(contentsOf: url))
    }

    public func save(_ actions: [PendingAction]) throws {
        try JSONEncoder.wakaRoute.encode(actions).write(to: url, options: .atomic)
    }
}

public final class InMemoryPendingActionStore: PendingActionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [PendingAction] = []

    public init(actions: [PendingAction] = []) { self.actions = actions }

    public func load() throws -> [PendingAction] { lock.withLock { actions } }
    public func save(_ newActions: [PendingAction]) throws { lock.withLock { actions = newActions } }
}

/// Holds what could not be sent, and replays it.
public actor LearningActionQueue {
    public enum Outcome: Sendable, Equatable {
        case nothingToDo
        case sent(count: Int)
        case partial(sent: Int, remaining: Int)
        case failed
    }

    private let store: any PendingActionStore
    private let content: ContentClient
    private var actions: [PendingAction] = []
    private var loaded = false
    private var isRunning = false

    public init(store: any PendingActionStore, content: ContentClient) {
        self.store = store
        self.content = content
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        actions = (try? store.load()) ?? []
        loaded = true
    }

    public var pendingCount: Int {
        loadIfNeeded()
        return actions.filter { !$0.isRejected }.count
    }

    /// Queues an action for later. Called when the immediate attempt failed.
    public func enqueue(_ action: PendingAction) {
        loadIfNeeded()

        // A second 'complete' for the same lesson adds nothing, and a second
        // 'view' even less. Quiz submissions are never collapsed: each is a
        // distinct attempt with its own answers.
        //
        // Feedback is not collapsed either — it is *replaced*. A student who
        // changes their mind after re-reading meant the second answer, and
        // sending the first one afterwards would overwrite it with the opinion
        // they abandoned.
        if action.kind == .feedback {
            actions.removeAll { $0.kind == .feedback && $0.lessonId == action.lessonId && !$0.isRejected }
        } else if actions.contains(where: {
            $0.kind == action.kind && $0.lessonId == action.lessonId && !$0.isRejected
        }), action.kind != .quizSubmit {
            return
        }

        actions.append(action)
        try? store.save(actions)
    }

    /// Replays everything queued, oldest first.
    @discardableResult
    public func run() async -> Outcome {
        guard !isRunning else { return .nothingToDo }
        isRunning = true
        defer { isRunning = false }

        loadIfNeeded()
        // Timestamps survive the round trip only to the second, so two actions
        // queued in the same second would otherwise replay in whatever order
        // the sort happened to produce. The id breaks the tie.
        let pending = actions
            .filter { !$0.isRejected }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
        guard !pending.isEmpty else { return .nothingToDo }

        var sent: Set<UUID> = []
        var rejected: Set<UUID> = []

        for action in pending {
            do {
                try await perform(action)
                sent.insert(action.id)
            } catch let error as APIError where StudySync.isPermanent(error) {
                // Never going to succeed — a deleted lesson, for instance.
                // Setting it aside keeps it from blocking everything behind it.
                rejected.insert(action.id)
            } catch {
                break
            }
        }

        actions.removeAll { sent.contains($0.id) }
        for index in actions.indices where rejected.contains(actions[index].id) {
            actions[index].markRejected()
        }
        try? store.save(actions)

        let remaining = pending.count - sent.count - rejected.count
        if sent.isEmpty && rejected.isEmpty { return .failed }
        return remaining == 0 ? .sent(count: sent.count) : .partial(sent: sent.count, remaining: remaining)
    }

    private func perform(_ action: PendingAction) async throws {
        switch action.kind {
        case .view:
            try await content.recordView(lessonId: action.lessonId)
        case .complete:
            try await content.markComplete(lessonId: action.lessonId)
        case .quizSubmit:
            _ = try await content.submitQuiz(
                lessonId: action.lessonId,
                answers: action.answers ?? [],
                idempotencyKey: action.idempotencyKey
            )
        case .feedback:
            guard let feedback = action.feedback else { return }
            try await content.submitFeedback(
                lessonId: action.lessonId,
                feedback: feedback,
                idempotencyKey: action.idempotencyKey
            )
        }
    }
}

extension QuizAnswer: Decodable {
    public init(from decoder: any Decoder) throws {
        enum Keys: String, CodingKey { case questionId, optionId, textAnswer }
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(
            questionId: try c.decode(String.self, forKey: .questionId),
            optionId: try c.decodeIfPresent(String.self, forKey: .optionId),
            textAnswer: try c.decodeIfPresent(String.self, forKey: .textAnswer)
        )
    }
}

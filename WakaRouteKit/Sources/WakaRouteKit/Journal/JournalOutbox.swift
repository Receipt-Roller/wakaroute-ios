import Foundation

/// A journal write that has not reached the server yet.
///
/// Students write the day's diary at night, often in bed, often with the
/// connection they have rather than the one they want. A paragraph about what
/// finally made sense today is not something to lose to a spinner.
public struct PendingJournalWrite: Codable, Sendable, Equatable, Identifiable {
    public enum Payload: Codable, Sendable, Equatable {
        /// A full-replace diary save. Only the newest one for a day survives —
        /// see `queue(diary:)`.
        case diary(DiaryDraft)
        /// Deleting the diary is a write too, and it must not be overtaken by
        /// an older save still sitting in the queue.
        case deleteDiary
        case entry(NewDayLogEntry)
    }

    public let id: UUID
    public let date: JournalDate
    public let payload: Payload
    public let createdAt: Date
    /// The server refused this permanently. Kept, not retried, so it can be
    /// shown rather than vanishing.
    public private(set) var isRejected: Bool

    public init(
        id: UUID = UUID(),
        date: JournalDate,
        payload: Payload,
        createdAt: Date = Date(),
        isRejected: Bool = false
    ) {
        self.id = id
        self.date = date
        self.payload = payload
        self.createdAt = createdAt
        self.isRejected = isRejected
    }

    mutating func markRejected() { isRejected = true }
}

public protocol JournalOutboxStore: Sendable {
    func load() throws -> [PendingJournalWrite]
    func save(_ writes: [PendingJournalWrite]) throws
}

public struct FileJournalOutboxStore: JournalOutboxStore {
    private let url: URL

    public init(url: URL) { self.url = url }

    public static func inApplicationSupport(fileName: String = "journal-outbox.json") throws -> FileJournalOutboxStore {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return FileJournalOutboxStore(url: directory.appending(path: fileName))
    }

    public func load() throws -> [PendingJournalWrite] {
        guard FileManager.default.fileExists(atPath: url.filePath) else { return [] }
        return try JSONDecoder.wakaRoute.decode([PendingJournalWrite].self, from: Data(contentsOf: url))
    }

    public func save(_ writes: [PendingJournalWrite]) throws {
        try JSONEncoder.wakaRoute.encode(writes).write(to: url, options: .atomic)
    }
}

public final class InMemoryJournalOutboxStore: JournalOutboxStore, @unchecked Sendable {
    private let lock = NSLock()
    private var writes: [PendingJournalWrite] = []

    public init(writes: [PendingJournalWrite] = []) { self.writes = writes }

    public func load() throws -> [PendingJournalWrite] { lock.withLock { writes } }
    public func save(_ newWrites: [PendingJournalWrite]) throws { lock.withLock { writes = newWrites } }
}

/// Holds journal writes that could not be sent, and sends them later.
///
/// Separate from `LearningActionQueue`, which is shaped around a lesson id and
/// would have to be bent out of shape to carry a diary. Same idea, same
/// rules: replay in order, stop at the first transient failure so the rest keep
/// their place, and set aside anything the server will refuse forever.
public actor JournalOutbox {
    public enum Outcome: Sendable, Equatable {
        case nothingToDo
        case sent(count: Int)
        case partial(sent: Int, remaining: Int)
        case failed
    }

    private let store: any JournalOutboxStore
    private let client: JournalClient
    private var writes: [PendingJournalWrite] = []
    private var loaded = false
    private var isRunning = false

    public init(store: any JournalOutboxStore, client: JournalClient) {
        self.store = store
        self.client = client
    }

    /// Everything still waiting, oldest first.
    public func pending() -> [PendingJournalWrite] {
        loadIfNeeded()
        return writes.filter { !$0.isRejected }
    }

    public func pendingCount(for date: JournalDate) -> Int {
        pending().filter { $0.date == date }.count
    }

    // MARK: Queueing

    /// Queues a diary save, replacing any earlier unsent one for the same day.
    ///
    /// The endpoint is a full replace, so two queued saves for one day are not
    /// two edits — the second already contains everything the first said. Left
    /// in the queue, the older one would be sent first and simply be overwritten
    /// a moment later, and if the connection died in between the student would
    /// see their older text come back.
    public func queue(diary draft: DiaryDraft, on date: JournalDate) {
        loadIfNeeded()
        writes.removeAll { $0.date == date && $0.isDiaryWrite && !$0.isRejected }
        writes.append(PendingJournalWrite(date: date, payload: .diary(draft)))
        persist()
    }

    public func queueDiaryDeletion(on date: JournalDate) {
        loadIfNeeded()
        writes.removeAll { $0.date == date && $0.isDiaryWrite && !$0.isRejected }
        writes.append(PendingJournalWrite(date: date, payload: .deleteDiary))
        persist()
    }

    /// Queues a time block. Blocks accumulate: two 30-minute entries are two
    /// blocks, and their `clientEntryId`s keep them apart on the server.
    public func queue(entry: NewDayLogEntry, on date: JournalDate) {
        loadIfNeeded()
        writes.append(PendingJournalWrite(date: date, payload: .entry(entry)))
        persist()
    }

    // MARK: Sending

    @discardableResult
    public func run() async -> Outcome {
        guard !isRunning else { return .nothingToDo }
        isRunning = true
        defer { isRunning = false }

        loadIfNeeded()
        let queued = writes.filter { !$0.isRejected }
        guard !queued.isEmpty else { return .nothingToDo }

        var sent: Set<UUID> = []
        var rejected: Set<UUID> = []

        for write in queued {
            do {
                try await send(write)
                sent.insert(write.id)
            } catch let error as APIError where StudySync.isPermanent(error) {
                // A day that has since scrolled past the 31-day window, or an
                // entry that would push the day over 24 hours. Retrying forever
                // would block everything queued behind it.
                rejected.insert(write.id)
            } catch {
                break
            }
        }

        writes.removeAll { sent.contains($0.id) }
        for index in writes.indices where rejected.contains(writes[index].id) {
            writes[index].markRejected()
        }
        persist()

        let remaining = queued.count - sent.count - rejected.count
        if sent.isEmpty && rejected.isEmpty { return .failed }
        return remaining == 0 ? .sent(count: sent.count) : .partial(sent: sent.count, remaining: remaining)
    }

    private func send(_ write: PendingJournalWrite) async throws {
        switch write.payload {
        case let .diary(draft):
            try await client.saveDiary(draft, on: write.date)
        case .deleteDiary:
            try await client.deleteDiary(on: write.date)
        case let .entry(entry):
            try await client.addEntry(entry, on: write.date)
        }
    }

    // MARK: Storage

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        writes = (try? store.load()) ?? []
    }

    private func persist() {
        try? store.save(writes)
    }
}

private extension PendingJournalWrite {
    var isDiaryWrite: Bool {
        switch payload {
        case .diary, .deleteDiary: true
        case .entry: false
        }
    }
}

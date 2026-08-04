import Foundation
import Testing
@testable import WakaRouteKit

/// Every on-disk store lives under **Application Support**, whose name contains
/// a space. `URL.path()` percent-encodes it, so `FileManager` answers "no such
/// file" for a file that is plainly there — and nothing throws.
///
/// The failure is invisible from the outside: writes succeed, reads come back
/// empty, and the next write overwrites what was never read. Study history
/// reset on every launch, the offline queue lost anything recorded before a
/// restart, and the path cache refetched twenty requests each time. Found on a
/// simulator, not by any of these tests, which is why they exist now.
///
/// The directory names below deliberately contain a space.
@Suite("File stores survive a path with a space in it")
struct FileStoreTests {

    private func directoryWithASpace(_ name: String) throws -> URL {
        let url = URL.temporaryDirectory
            .appending(path: "WakaRoute Tests \(name) \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A study session written to disk is still there on the next read")
    func studySessionsRoundTrip() throws {
        let directory = try directoryWithASpace("sessions")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileStudySessionStore(url: directory.appending(path: "study-sessions.json"))
        let session = StudySession(
            startedAt: Date(timeIntervalSince1970: 1_785_000_000),
            endedAt: Date(timeIntervalSince1970: 1_785_000_600),
            title: "学習",
            subjectName: "数学",
            kind: .practice
        )

        try store.save([session])
        #expect(try store.load().map(\.id) == [session.id], "A relaunch must not lose the student's record.")
    }

    @Test("A queued offline action is still there on the next read")
    func pendingActionsRoundTrip() throws {
        let directory = try directoryWithASpace("actions")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FilePendingActionStore(url: directory.appending(path: "pending-actions.json"))
        let action = PendingAction(kind: .complete, lessonId: "l-1")

        try store.save([action])
        let loaded = try store.load()

        #expect(loaded.count == 1, "Work done offline must survive the app being killed.")
        #expect(loaded.first?.id == action.id)
        // The key is what stops a replay becoming a second attempt, so it is
        // checked by name rather than left to a whole-value comparison.
        #expect(loaded.first?.idempotencyKey == action.idempotencyKey)
    }

    @Test("The path structure cache is still there on the next read")
    func contentStructureRoundTrip() throws {
        let directory = try directoryWithASpace("structure")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileContentStructureStore(url: directory.appending(path: "content-structure.json"))
        var structure = ContentStructure()
        structure.record(pathId: "p-1", courses: [.init(id: "c-1", title: "コース"), .init(id: "c-2", title: "コース")], courseCount: 2)

        try store.save(structure)
        #expect(try store.load() == structure, "Otherwise every launch refetches every path.")
    }

    @Test("A store whose file was never written reads as empty rather than throwing")
    func missingFileIsEmpty() throws {
        let directory = try directoryWithASpace("missing")
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try FileStudySessionStore(url: directory.appending(path: "nothing.json")).load().isEmpty)
        #expect(try FilePendingActionStore(url: directory.appending(path: "nothing.json")).load().isEmpty)
        #expect(try FileContentStructureStore(url: directory.appending(path: "nothing.json")).load() == ContentStructure())
    }

    /// The helper the stores use, checked directly so the reason survives even
    /// if someone rewrites the stores.
    @Test("filePath does not percent-encode")
    func filePathIsNotEncoded() {
        let url = URL(filePath: "/tmp/Application Support/x.json")
        #expect(url.filePath == "/tmp/Application Support/x.json")
        #expect(url.path().contains("%20"), "Which is exactly why filePath exists.")
    }
}

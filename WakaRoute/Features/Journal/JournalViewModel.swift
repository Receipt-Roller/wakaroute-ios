import Foundation
import Observation
import WakaRouteKit

/// 受験日記 and the day's time log, for one day at a time.
///
/// The server holds all of it. This keeps the day it is currently showing, the
/// count of writes still waiting to be sent, and nothing else — there is no
/// local copy of a diary that could disagree with the one on the server.
@MainActor
@Observable
final class JournalViewModel {
    private(set) var date: JournalDate
    private(set) var day: JournalDay?
    private(set) var week: [JournalDaySummary] = []
    private(set) var isLoading = false
    /// Set when the day could not be read at all. Distinct from an empty day,
    /// which is a perfectly normal thing for a Tuesday to be.
    private(set) var loadFailed = false
    /// Writes made on this device that the server has not acknowledged yet.
    ///
    /// Held, not just counted: what is in here has to appear on the screen. An
    /// outbox that keeps a student's diary safe while the screen shows it
    /// vanishing has not kept anything, as far as the student can tell.
    private(set) var unsent: [PendingJournalWrite] = []
    /// The server's considered "no", for the screen to explain.
    var lastRefusal: JournalRefusal?

    private let client: JournalClient
    private let outbox: JournalOutbox

    init(client: JournalClient, outbox: JournalOutbox, date: JournalDate = .today()) {
        self.client = client
        self.outbox = outbox
        self.date = date
    }

    var isWritable: Bool { date.isWritable() }

    /// 9月21日（月）
    var title: String {
        date.startOfDay.formatted(
            .dateTime.month().day().weekday(.short).locale(Locale(identifier: "ja_JP"))
        )
    }

    var isToday: Bool { date == JournalDate.today() }

    // MARK: Loading

    func load() async {
        isLoading = true
        defer { isLoading = false }

        // Anything queued goes first, so what the screen then reads back from
        // the server already includes it.
        await flush()
        await reload()
        await loadWeek()
    }

    private func reload() async {
        do {
            day = try await client.day(date)
            loadFailed = false
        } catch {
            // Keeping the previous day on screen would be showing one date's
            // records under another's heading.
            day = nil
            loadFailed = true
            logger.error("Could not load the journal for the selected day.")
        }
        unsent = await outbox.pending().filter { $0.date == date }
    }

    /// The seven days ending on the one being shown.
    ///
    /// Read from `summary`, which carries no diary text — the week strip is
    /// totals and nothing more, and stays safe to have on screen with somebody
    /// looking over the student's shoulder.
    private func loadWeek() async {
        let start = date.adding(days: -6)
        week = (try? await client.summary(from: start, to: date)) ?? []
    }

    func show(_ newDate: JournalDate) async {
        guard newDate != date else { return }
        date = newDate
        await reload()
        await loadWeek()
    }

    func goBackOneDay() async { await show(date.adding(days: -1)) }

    func goForwardOneDay() async {
        let next = date.adding(days: 1)
        guard next <= JournalDate.today() else { return }
        await show(next)
    }

    var canGoForward: Bool { date < JournalDate.today() }

    // MARK: Writing

    /// Saves the diary, keeping it if it cannot be sent.
    ///
    /// The student's words reach the outbox before the network is touched, so
    /// a failed request costs a retry rather than a paragraph.
    func saveDiary(_ draft: DiaryDraft) async {
        // Nothing written, nothing to write. Without this, closing an untouched
        // form would send a delete for a diary that never existed and take a
        // 404 for it.
        guard !(draft.isEmpty && record.diary == nil) else { return }

        do {
            if draft.isEmpty {
                try await client.deleteDiary(on: date)
            } else {
                _ = try await client.saveDiary(draft, on: date)
            }
        } catch {
            if let refusal = JournalRefusal(error) {
                // The server has answered. Sending it again gets the same
                // answer, so it is explained rather than queued.
                lastRefusal = refusal
            } else if draft.isEmpty {
                await outbox.queueDiaryDeletion(on: date)
            } else {
                await outbox.queue(diary: draft, on: date)
            }
        }
        await refreshAfterWrite()
    }

    func addEntry(_ entry: NewDayLogEntry) async {
        do {
            _ = try await client.addEntry(entry, on: date)
        } catch {
            if let refusal = JournalRefusal(error) {
                lastRefusal = refusal
            } else {
                await outbox.queue(entry: entry, on: date)
            }
        }
        await refreshAfterWrite()
    }

    func deleteEntry(_ entry: DayLogEntry) async {
        do {
            try await client.deleteEntry(entry.entryId)
        } catch {
            // Deletions are not queued. A block still on the server is visibly
            // still there, which is better than a screen claiming it is gone
            // while the server disagrees.
            lastRefusal = JournalRefusal(error)
        }
        await refreshAfterWrite()
    }

    private func refreshAfterWrite() async {
        await reload()
        await loadWeek()
    }

    private func flush() async {
        _ = await outbox.run()
        unsent = await outbox.pending().filter { $0.date == date }
    }

    // MARK: Derived

    /// The day as the student should see it: the server's record with anything
    /// this device has not managed to send yet folded in. Composed in the Kit —
    /// see `JournalDayRecord`, which is where that logic is tested.
    var record: JournalDayRecord {
        JournalDayRecord(date: date, day: day, unsent: unsent)
    }
}

import Foundation

/// What the app can currently show for a subject.
///
/// `unavailable` is a first-class outcome, not an error. The 理解マップ has no
/// API yet, and both wikis are explicit that unbuilt features must be shown as
/// 計画中 rather than filled in with invented data.
public enum MapAvailability<Value: Sendable>: Sendable {
    case available(Value)
    case unavailable(reason: String)
}

public protocol UnderstandingMapRepository: Sendable {
    func subjects() async throws -> MapAvailability<[Subject]>
    func mastery(for subjectId: SubjectId) async throws -> MapAvailability<MasteryRecord>
}

/// The shipping implementation until the API exists.
///
/// It deliberately returns nothing rather than falling back to sample data, so
/// there is no path by which placeholder progress reaches a real student.
public struct UnavailableUnderstandingMapRepository: UnderstandingMapRepository {
    public init() {}

    private static let reason = "理解マップのデータ連携は準備中です。"

    public func subjects() async throws -> MapAvailability<[Subject]> {
        .unavailable(reason: Self.reason)
    }

    public func mastery(for subjectId: SubjectId) async throws -> MapAvailability<MasteryRecord> {
        .unavailable(reason: Self.reason)
    }
}

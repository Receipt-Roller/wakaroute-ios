import Foundation

/// The learner's own profile and 志望校.
///
/// Every call needs a token, so this takes an `AuthenticatedHTTPClient` rather
/// than a bare one — there is no way to construct it that forgets the header.
public struct ProfileClient: Sendable {
    private let http: any HTTPClient
    private let environment: AppEnvironment

    public init(http: AuthenticatedHTTPClient, environment: AppEnvironment) {
        self.http = http
        self.environment = environment
    }

    private func url(_ path: String) -> URL {
        environment.manabu2BaseURL.appending(path: path)
    }

    public func profile() async throws -> LearnerProfile {
        try await http.sendDecoding(
            HTTPRequest(method: .get, url: url("/api/v1/me"), headers: ["Accept": "application/json"]),
            as: LearnerProfile.self
        )
    }

    public func targetSchools() async throws -> TargetSchoolList {
        try await http.sendDecoding(
            HTTPRequest(method: .get, url: url("/api/v1/me/target-schools"), headers: ["Accept": "application/json"]),
            as: TargetSchoolList.self
        )
    }

    /// Replaces the whole list. Order in the array becomes the rank, so the
    /// first entry is 第一志望.
    @discardableResult
    public func replaceTargetSchools(_ schools: [TargetSchool]) async throws -> TargetSchoolList {
        struct Write: Encodable {
            let source: String
            let externalId: String
            let name: String
            let targetDate: String?
        }
        struct Body: Encodable { let goals: [Write] }

        let body = Body(
            goals: schools.map {
                Write(source: $0.source, externalId: $0.externalId, name: $0.name, targetDate: $0.targetDate)
            }
        )

        return try await http.sendDecoding(
            HTTPRequest(
                method: .put,
                url: url("/api/v1/me/target-schools"),
                headers: [
                    "Content-Type": "application/json",
                    "Accept": "application/json",
                    // A replace is destructive; a blind retry after a timeout
                    // must not apply twice.
                    "Idempotency-Key": UUID().uuidString
                ],
                body: try JSONEncoder().encode(body)
            ),
            as: TargetSchoolList.self
        )
    }
}

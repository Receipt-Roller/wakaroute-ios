import Foundation

/// RFC 7807 error body returned by the MANABU2 API.
///
/// Branching is done on `code`; `detail` is human-facing prose and the guide
/// warns it can change wording at any time.
public struct ProblemDetails: Decodable, Sendable, Equatable {
    public let title: String?
    public let status: Int?
    public let detail: String?
    public let code: String?
}

/// Every failure the networking layer can produce, kept as distinct cases so
/// the UI can tell "no connection" apart from "server is broken" apart from
/// "we asked for something invalid" — §7 of the 開発ガイド requires these be
/// separate states rather than one generic error.
public enum APIError: Error, Sendable, Equatable {
    /// No usable connection, or the request timed out.
    case offline
    case timedOut
    /// Server answered with a non-2xx status.
    case http(status: Int, problem: ProblemDetails?)
    /// Response arrived but did not match the expected shape. Never fatal:
    /// a decode failure must not crash the app.
    case decoding(String)
    case unknown(String)

    /// The `code` field, when the server supplied one.
    public var code: String? {
        if case let .http(_, problem) = self { return problem?.code }
        return nil
    }

    /// True when retrying the identical request might succeed. Only GETs should
    /// act on this, and only with a bounded number of attempts.
    public var isTransient: Bool {
        switch self {
        case .offline, .timedOut:
            return true
        case let .http(status, _):
            return status >= 500 || status == 429
        case .decoding, .unknown:
            return false
        }
    }
}

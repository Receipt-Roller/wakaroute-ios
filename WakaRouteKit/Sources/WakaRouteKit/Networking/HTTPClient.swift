import Foundation

public struct HTTPRequest: Sendable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
    }

    public var method: Method
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: Method, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    /// Response header fields, keyed case-insensitively.
    ///
    /// Only a caller that revalidates a cache needs these, so they are
    /// defaulted away rather than forced on every construction site.
    public let headers: HTTPHeaders

    public init(status: Int, body: Data, headers: HTTPHeaders = HTTPHeaders()) {
        self.status = status
        self.body = body
        self.headers = headers
    }
}

/// Header fields that answer to any capitalisation.
///
/// HTTP field names are case-insensitive and servers disagree in practice —
/// `ETag`, `Etag` and `etag` are the same field, and a plain dictionary lookup
/// silently misses two of the three.
public struct HTTPHeaders: Sendable, Equatable {
    private let fields: [String: String]

    public init(_ fields: [String: String] = [:]) {
        self.fields = Dictionary(
            fields.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    public subscript(field: String) -> String? { fields[field.lowercased()] }
}

/// Seam between our code and URLSession, so tests can drive the auth and
/// repository layers without touching the network.
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.unknown("Response was not HTTP.")
            }
            let headers = HTTPHeaders(
                Dictionary(
                    http.allHeaderFields.compactMap { key, value in
                        guard let field = key as? String, let text = value as? String else { return nil }
                        return (field, text)
                    },
                    uniquingKeysWith: { first, _ in first }
                )
            )
            return HTTPResponse(status: http.statusCode, body: data, headers: headers)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw APIError.offline
            case .timedOut:
                throw APIError.timedOut
            default:
                throw APIError.unknown(error.localizedDescription)
            }
        }
    }
}

extension HTTPClient {
    /// Sends a request and decodes a successful body, turning any non-2xx into
    /// an `APIError` carrying the server's Problem Details.
    public func sendDecoding<T: Decodable>(_ request: HTTPRequest, as type: T.Type) async throws -> T {
        let response = try await send(request)

        guard (200..<300).contains(response.status) else {
            let problem = try? JSONDecoder().decode(ProblemDetails.self, from: response.body)
            throw APIError.http(status: response.status, problem: problem)
        }

        do {
            return try JSONDecoder.wakaRoute.decode(T.self, from: response.body)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }
}

extension JSONDecoder {
    public static let wakaRoute: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = ISO8601Date.parse(text) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(text)")
                )
            }
            return date
        }
        return decoder
    }()
}

/// Parses the timestamps MANABU2 actually sends.
///
/// `.iso8601` cannot be used. The server is .NET and emits seven-digit
/// fractional seconds (`2026-08-02T14:48:17.0204684+00:00`); Foundation's
/// built-in strategy only accepts fractional seconds on the newest OS
/// versions, so the same payload decodes on one device and fails with
/// `dataCorrupted` on another. That is exactly the kind of bug that passes
/// every test on a modern simulator and breaks on a student's phone.
enum ISO8601Date {
    // Configured once and never mutated afterwards. Foundation's date
    // formatters are documented as safe for concurrent parsing; the compiler
    // cannot express that, hence the annotation rather than a lock or a new
    // formatter per response.
    nonisolated(unsafe) private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let withoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ text: String) -> Date? {
        if let date = withFractionalSeconds.date(from: text) { return date }
        if let date = withoutFractionalSeconds.date(from: text) { return date }

        // .NET can emit more fractional digits than ISO8601DateFormatter
        // accepts. Trim to three and retry rather than losing the timestamp.
        guard let dot = text.firstIndex(of: ".") else { return nil }
        let afterDot = text.index(after: dot)
        guard let offsetStart = text[afterDot...].firstIndex(where: { !$0.isNumber }) else { return nil }

        let digits = text[afterDot..<offsetStart]
        guard digits.count > 3 else { return nil }

        let trimmed = text[..<afterDot] + digits.prefix(3) + text[offsetStart...]
        return withFractionalSeconds.date(from: String(trimmed))
    }
}

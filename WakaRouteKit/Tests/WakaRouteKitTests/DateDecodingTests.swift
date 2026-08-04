import Foundation
import Testing
@testable import WakaRouteKit

/// The date formats MANABU2 actually emits.
///
/// These matter more than they look. `.iso8601` accepts seven-digit fractional
/// seconds only on the newest Foundation, so a payload that decodes on a
/// current simulator throws `dataCorrupted` on an older iPhone — and the
/// failure lands on device registration, silently costing the student their
/// account. Found on a real handset, not in a test.
@Suite("Date decoding")
struct DateDecodingTests {

    private struct Box: Decodable { let d: Date }

    private func decode(_ text: String) throws -> Date {
        let json = Data(#"{"d":"\#(text)"}"#.utf8)
        return try JSONDecoder.wakaRoute.decode(Box.self, from: json).d
    }

    @Test("Seven-digit fractional seconds, as /devices/register returns")
    func dotNetFractionalSeconds() throws {
        let date = try decode("2026-08-02T14:48:17.0204684+00:00")
        #expect(abs(date.timeIntervalSince1970 - 1785682097.02) < 0.05)
    }

    @Test("Three-digit fractional seconds")
    func milliseconds() throws {
        let date = try decode("2026-08-02T14:48:17.020+00:00")
        #expect(abs(date.timeIntervalSince1970 - 1785682097.02) < 0.05)
    }

    @Test("No fractional seconds")
    func wholeSeconds() throws {
        let date = try decode("2026-08-02T14:48:17+00:00")
        #expect(abs(date.timeIntervalSince1970 - 1785682097) < 0.5)
    }

    @Test("Zulu suffix")
    func zulu() throws {
        let date = try decode("2026-08-02T14:48:17Z")
        #expect(abs(date.timeIntervalSince1970 - 1785682097) < 0.5)
    }

    @Test("Non-UTC offsets keep their instant")
    func offsetIsRespected() throws {
        let tokyo = try decode("2026-08-02T23:48:17+09:00")
        let utc = try decode("2026-08-02T14:48:17Z")
        #expect(abs(tokyo.timeIntervalSince(utc)) < 0.5)
    }

    @Test("Genuinely bad input still fails, rather than decoding to nonsense")
    func rejectsBadInput() {
        #expect(throws: (any Error).self) { try decode("not a date") }
        #expect(throws: (any Error).self) { try decode("") }
    }

    /// The whole registration payload, exactly as production returns it.
    @Test("The live registration response decodes")
    func decodesLiveRegistration() throws {
        let json = """
        {
          "deviceSecret": "mnbd_abc123",
          "secretWarning": "Store deviceSecret now, in the Keychain or Keystore.",
          "isNewAccount": true,
          "auth": {
            "accessToken": "eyJhbGciOi",
            "expiresAt": "2026-08-02T14:48:17.0204684+00:00",
            "refreshToken": "dEtKxRb9h8",
            "user": { "id": "00000000-0000-4000-8000-000000000002", "email": "", "displayName": "" },
            "scopes": ["read:catalog", "read:content", "read:progress", "write:progress"]
          }
        }
        """

        let registration = try JSONDecoder.wakaRoute.decode(DeviceRegistration.self, from: Data(json.utf8))

        #expect(registration.deviceSecret == "mnbd_abc123")
        #expect(registration.isNewAccount)
        #expect(registration.auth.scopes.count == 4)
        #expect(registration.auth.user.isLinked == false)
    }
}

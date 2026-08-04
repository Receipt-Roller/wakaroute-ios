import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Supplies the stable per-install identifier sent as `deviceId`.
///
/// This is a label, not a credential — the server authenticates the device
/// secret, never this value. It still has to be stable across launches and at
/// least 16 characters, because a collision would hand one student another
/// student's history.
public protocol DeviceIdProvider: Sendable {
    func deviceId() throws -> String
}

public struct StoredDeviceIdProvider: DeviceIdProvider {
    static let storageKey = "deviceId"

    private let store: SecretStore

    public init(store: SecretStore) {
        self.store = store
    }

    public func deviceId() throws -> String {
        if let existing = try store.read(Self.storageKey), existing.count >= 16 {
            return existing
        }

        let generated = Self.makeDeviceId()
        try store.write(generated, for: Self.storageKey)
        return generated
    }

    /// Prefers `identifierForVendor`, falling back to a generated UUID when the
    /// system withholds one. Either way the result is persisted, so the value
    /// survives the vendor ID being reset.
    private static func makeDeviceId() -> String {
        #if canImport(UIKit)
        if let vendorId = UIDevice.current.identifierForVendor?.uuidString {
            return vendorId
        }
        #endif
        return UUID().uuidString
    }
}

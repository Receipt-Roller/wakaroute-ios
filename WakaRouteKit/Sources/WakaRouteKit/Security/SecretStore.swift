import Foundation
#if canImport(Security)
import Security
#endif

/// Storage for values that must never reach UserDefaults, backups, or logs:
/// the device secret and the token pair.
public protocol SecretStore: Sendable {
    func read(_ key: String) throws -> String?
    func write(_ value: String, for key: String) throws
    func delete(_ key: String) throws
}

public enum SecretStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case malformedData

    /// The raw Keychain status, for diagnostics. `-34018` is the usual culprit
    /// on device: the app has no keychain entitlement, which happens when
    /// signing is misconfigured and produces a silent, total storage failure.
    public var osStatus: OSStatus? {
        if case let .unexpectedStatus(status) = self { return status }
        return nil
    }

    public var diagnosticDescription: String {
        switch self {
        case let .unexpectedStatus(status):
            let known: String
            switch status {
            case -34018: known = "キーチェーンの権限がありません（entitlement）"
            case -25300: known = "項目が見つかりません"
            case -25299: known = "項目が重複しています"
            case -25308: known = "キーチェーンにアクセスできません（ロック中）"
            default: known = "不明なエラー"
            }
            return "\(known)（OSStatus \(status)）"
        case .malformedData:
            return "保存された値を読み取れませんでした"
        }
    }
}

#if canImport(Security)
/// Keychain-backed store.
///
/// Items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable by
/// background refresh after the first unlock, but never migrated to a new
/// device via backup. A restored backup must re-register rather than inherit
/// another handset's credential.
public struct KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    public func read(_ key: String) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError.unexpectedStatus(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.malformedData
        }
        return value
    }

    public func write(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(key)

        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }

        guard updateStatus == errSecItemNotFound else {
            throw SecretStoreError.unexpectedStatus(updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SecretStoreError.unexpectedStatus(addStatus)
        }
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.unexpectedStatus(status)
        }
    }
}
#endif

/// Test double. Never used in a shipping build.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func read(_ key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    public func write(_ value: String, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    public func delete(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = nil
    }
}

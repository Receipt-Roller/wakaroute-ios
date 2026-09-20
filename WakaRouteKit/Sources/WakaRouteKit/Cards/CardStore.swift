import Foundation

/// Keeps a card set on the device between launches.
///
/// **Test that it reads back, not just that it writes.** A store that writes
/// correctly and reads nothing looks like a working store: it starts empty
/// every launch and silently overwrites what was there. This app has already
/// shipped that bug once — see `FilePath.swift`.
public protocol CardStoring<Card>: Sendable {
    associatedtype Card: Codable & Sendable & Equatable
    func load() throws -> CardCatalog<Card>?
    func save(_ catalog: CardCatalog<Card>) throws
}

public struct CardFileStore<Card: Codable & Sendable & Equatable>: CardStoring {
    private let url: URL

    public init(filename: String) throws {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        url = directory.appending(path: filename)
    }

    public func load() throws -> CardCatalog<Card>? {
        guard FileManager.default.fileExists(atPath: url.filePath) else { return nil }
        return try JSONDecoder.wakaRoute.decode(CardCatalog<Card>.self, from: Data(contentsOf: url))
    }

    public func save(_ catalog: CardCatalog<Card>) throws {
        try JSONEncoder.wakaRoute.encode(catalog).write(to: url, options: .atomic)
    }
}

/// In-memory, for tests.
public final class InMemoryCardStore<Card: Codable & Sendable & Equatable>: CardStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var catalog: CardCatalog<Card>?

    public init(_ catalog: CardCatalog<Card>? = nil) { self.catalog = catalog }

    public func load() throws -> CardCatalog<Card>? { lock.withLock { catalog } }
    public func save(_ new: CardCatalog<Card>) throws { lock.withLock { catalog = new } }
}
